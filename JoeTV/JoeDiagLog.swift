import Foundation
import Network

/// v2.0.33 — rolling diagnostic log + LAN export (audit item 6).
///
/// WHY this exists: the owner tests on a real Apple TV and
/// cannot pull logs off it — tvOS gives an app no share sheet,
/// no activity view and no file exporter (Apple's HIG states
/// activity views are not supported on tvOS, and
/// UIActivityViewController / ShareLink / fileExporter are all
/// unavailable on the platform), so the usual "share the log"
/// routes do not even compile here. The route that works is
/// the one this file builds: the app keeps a small rolling log
/// in its own sandbox (below), and when the owner opens
/// Settings → "Gửi log chẩn đoán" a tiny HTTP server
/// (DiagLogServer, bottom of this file) serves that one file
/// over the home LAN; Settings shows the address in large type
/// plus a QR code of it, and the owner downloads the .txt in
/// Safari on his iPhone and sends it into the chat.
///
/// WHAT may be written: short, factual breadcrumbs from the
/// load / playback / settings paths. NEVER a credential value
/// and never a full URL: debrid tokens ride inside Torrentio /
/// MediaFusion URLs, so write() scrubs a message in three
/// passes before the line touches disk — URLs of any scheme
/// or case reduce to scheme://host, scheme-less Torrentio
/// config bases are erased whole, and every credential VALUE
/// in force is erased wherever it appears in any shape
/// (defence in depth — callers are expected to log ids and
/// outcomes, not links, but the scrubber means a careless
/// caller still cannot leak a token through this file). The
/// one deliberate credential-adjacent line is
/// logLaunchPresence(): presence + length ONLY, by design, so
/// a fault report can distinguish "token never arrived" from
/// "token present but the service rejected it" without the
/// log itself becoming a secret.
enum DiagLog {

    // MARK: - Storage

    /// The log's directory: Application Support (created if
    /// needed), falling back to Caches if Application Support
    /// is unavailable. Resolved ONCE — `static let`
    /// initialisation is thread-safe by the runtime's own
    /// guarantee, so no caller ever races the creation.
    private static let storageDirectory: URL = {
        let fm = FileManager.default
        if let base = try? fm.url(for: .applicationSupportDirectory,
                                  in: .userDomainMask,
                                  appropriateFor: nil, create: true) {
            try? fm.createDirectory(at: base,
                                    withIntermediateDirectories: true)
            return base
        }
        if let base = try? fm.url(for: .cachesDirectory,
                                  in: .userDomainMask,
                                  appropriateFor: nil, create: true) {
            try? fm.createDirectory(at: base,
                                    withIntermediateDirectories: true)
            return base
        }
        return fm.temporaryDirectory
    }()

    /// The log file itself: Application Support/joetv-diag.log.
    static var fileURL: URL {
        storageDirectory.appendingPathComponent("joetv-diag.log")
    }

    // MARK: - Serialisation state
    //
    // Every mutable value below is touched ONLY while `lock`
    // is held. NSLock is Sendable, and the `let` statics are
    // immutable references, so the enum is safe to call
    // from ANY thread or actor — URLSession delegate queues
    // and @MainActor view code alike.
    // Swift 6: nonisolated(unsafe) on the two `var` statics —
    // writeCounter is read and written only inside write()'s
    // locked body, and didLogLaunchPresence is flipped only
    // inside logLaunchPresence()'s locked prologue (released
    // BEFORE it calls write(), which takes the same
    // non-recursive lock itself). The access pattern is
    // deliberately synchronous (DiagLog.write is called from
    // hot sync paths and delegate callbacks), so actor
    // isolation would change every call site's signature;
    // the lock discipline is the safety argument, exactly as
    // with SourceHealth's statics.

    private static let lock = NSLock()
    private nonisolated(unsafe) static var writeCounter = 0
    private nonisolated(unsafe) static var didLogLaunchPresence = false

    /// Bounded size: the file is capped at 1 MB; on rotation
    /// the newest ~700 KB are kept (see rotateIfNeededLocked).
    private static let sizeCap = 1_000_000
    private static let rotationKeepBytes = 700_000

    /// The URL scrubber's pattern: a whole URL run — no
    /// whitespace, no quotes (a quoted URL in a message ends
    /// at its closing quote, which must survive). v2.0.40
    /// (audit P0.3 / H-2): case-insensitive and stremio:// is
    /// a scrubbed scheme too — the app itself accepts
    /// stremio:// MediaFusion links, and an engine error
    /// string may spell a scheme in capitals; the old
    /// lowercase-http(s)-only pattern let both shapes through
    /// with their token-carrying paths intact.
    private static let urlRegex = try! NSRegularExpression(
        pattern: #"(?i)(?:https?|stremio)://[^\s"']+"#)

    /// A scheme-less Torrentio config base: a run carrying
    /// realdebrid= / torbox= / premiumize= segments with no
    /// scheme in front of it (the shape a bare base or an
    /// engine error takes). Erased whole — host included —
    /// because the run's path IS the credential.
    private static let configBaseRegex = try! NSRegularExpression(
        pattern: #"(?i)[^\s"']*(?:realdebrid|torbox|premiumize)=[^\s"']*"#)

    // MARK: - Writing

    /// Append ONE line: `[yyyy-MM-dd HH:mm:ss.SSS] [category]
    /// message`. The message is URL-scrubbed first (see the
    /// file header) and flattened to a single line, so one
    /// write is always exactly one log line.
    static func write(_ category: String, _ message: String) {
        // FIX-213 (Fault 6): the first write of the
        // process arms the stall heartbeat below — no
        // call-site wiring, and the guard inside makes
        // every later write a no-op for this.
        startStallWatchdogIfNeeded()
        let clean = scrubbed(message)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let line = "[\(timestamp())] [\(category)] \(clean)\n"
        guard let data = line.data(using: .utf8) else { return }
        lock.lock()
        defer { lock.unlock() }
        appendLocked(data)
        writeCounter += 1
        if writeCounter % 64 == 0 {
            rotateIfNeededLocked()
        }
    }

    // MARK: - Stall + focus breadcrumbs (FIX-213, Fault 6)
    //
    // INSTRUMENTATION ONLY — nothing in this section
    // changes any behaviour; it exists so the owner's
    // next test session produces conviction-grade
    // evidence for the TVB-home lag fault (DIAG-20261122
    // Fault 6: mechanism unconvicted; the log previously
    // carried no frame-time, hitch or focus-latency
    // instrumentation at all). Two pieces:
    //  • a main-queue stall heartbeat: every probe
    //    interval a block is posted to the main queue,
    //    and the delay between its deadline and its
    //    execution IS the main queue's stall. A stall
    //    beyond the threshold writes ONE [stall] line
    //    carrying the last focus context (below), so a
    //    hitch is attributable to a surface + focus step.
    //  • noteFocus: the focus-step breadcrumb — one
    //    [focus] line per focus step on a named surface,
    //    and the context the next [stall] line carries.
    // Both state values follow this file's standing
    // discipline: touched only under `lock`, hence the
    // nonisolated(unsafe) statics (see the serialisation
    // note above).

    private nonisolated(unsafe) static var stallWatchdogStarted = false
    private nonisolated(unsafe) static var lastFocusContext = "none"
    private static let stallProbeQueue =
        DispatchQueue(label: "joetv.diaglog.stallwatch")
    private static let stallThresholdSeconds = 0.25
    private static let stallProbeIntervalSeconds = 0.5

    /// FIX-214 (DESIGN-PASS-214 §3.3): [focus] writes
    /// hop to this serial queue — the breadcrumb must
    /// never put a synchronous file write on the focus
    /// path itself (2.1.3's instrumentation did, on the
    /// TVB home: a minor but real contributor sitting on
    /// the exact path it was measuring). The context
    /// SET stays synchronous under the lock (cheap, and
    /// the next [stall] line must see the latest step);
    /// only the file append is deferred.
    private static let focusWriteQueue =
        DispatchQueue(label: "joetv.diaglog.focuswrite")

    /// The focus-step breadcrumb: records the context
    /// for the next [stall] line and writes one [focus]
    /// line. Callers (FIX-214): the TVB home's card-focus
    /// hook (JoeTVB.swift), the Phim/Home core's focus
    /// hooks and the Torrent home's focus hooks
    /// (JoePhimHome.swift / JoeTorrent.swift) — through
    /// 2.1.3 the TVB hook was the ONLY caller, so whole
    /// surfaces produced stalls labelled focus=none.
    static func noteFocus(surface: String, key: String?) {
        let context = "\(surface)|\(key ?? "nil")"
        lock.lock()
        lastFocusContext = context
        lock.unlock()
        focusWriteQueue.async {
            write("focus", "step \(context)")
        }
    }

    /// FIX-214 (DESIGN-PASS-214 §3.3): the section
    /// breadcrumb — the stall context RESETS at every
    /// section boundary and a [section] line marks the
    /// crossing. Through 2.1.3 the context was sticky
    /// for the whole session (set by the TVB hook, never
    /// cleared), so log 17's stalls carried a "tvb-home"
    /// label long after the owner had left that home,
    /// and 16 of its 42 stalls read focus=none. Called
    /// from the shell's section-change consumer
    /// (JoeTVApp.swift).
    static func noteSection(_ section: String) {
        lock.lock()
        lastFocusContext = "section:\(section)"
        lock.unlock()
        focusWriteQueue.async {
            write("section", section)
        }
    }

    /// Arm the stall heartbeat (once per process).
    private static func startStallWatchdogIfNeeded() {
        lock.lock()
        if stallWatchdogStarted {
            lock.unlock()
            return
        }
        stallWatchdogStarted = true
        lock.unlock()
        scheduleStallProbe()
    }

    /// One heartbeat round: after the probe interval a
    /// block is posted to the main queue; its execution
    /// delay past the deadline is the stall. Beyond the
    /// threshold it is written as one [stall] line with
    /// the last focus context; either way the next round
    /// is scheduled. The probe lives on its own serial
    /// queue and touches shared state only under `lock`.
    private static func scheduleStallProbe() {
        let deadline = Date().addingTimeInterval(stallProbeIntervalSeconds)
        stallProbeQueue.asyncAfter(
            deadline: .now() + stallProbeIntervalSeconds) {
            DispatchQueue.main.async {
                let stall = Date().timeIntervalSince(deadline)
                if stall > stallThresholdSeconds {
                    lock.lock()
                    let context = lastFocusContext
                    lock.unlock()
                    write("stall", "main-queue stall "
                          + "\(Int(stall * 1000))ms focus=\(context)")
                }
                scheduleStallProbe()
            }
        }
    }

    /// The file's full current contents ("" when absent or
    /// unreadable) — the export server's body source.
    static func currentText() -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Append under the lock: create the file on first use,
    /// then write at its end through a file handle. Failures
    /// are silent by design — a diagnostic log must never be
    /// able to break the feature it is observing.
    private static func appendLocked(_ data: Data) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL)
        }
    }

    /// Rotation, called under the lock every 64 writes: when
    /// the file is over the cap, drop from the front up to the
    /// first newline AFTER (size − keepBytes) — so the kept
    /// tail starts on a whole line — and prepend a marker
    /// saying the older lines are gone. The newest content is
    /// always kept; the file can only exceed the cap between
    /// two checks by at most 63 lines.
    private static func rotateIfNeededLocked() {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? Int, size > sizeCap,
              let data = try? Data(contentsOf: fileURL),
              data.count > rotationKeepBytes
        else { return }
        let threshold = data.count - rotationKeepBytes
        var start = data.count
        if let newline = data[threshold...].firstIndex(of: 0x0A) {
            start = newline + 1
        }
        let marker = "[\(timestamp())] [diag] log rotated — older lines dropped\n"
        var rotated = Data(marker.utf8)
        if start < data.count {
            rotated.append(data[start...])
        }
        try? rotated.write(to: fileURL)
    }

    // MARK: - Formatting + redaction

    /// One line's timestamp prefix. Until claude/opt-1 this
    /// built a fresh DateFormatter per call ("formatters are
    /// not thread-safe, writes are rare").
    ///
    /// claude/opt-1 (OPTIMIZATION-AUDIT item 5): writes are no
    /// longer rare ([focus] lines fire per focus step), so the
    /// formatter is built ONCE and reused under its own lock —
    /// still entirely outside the file-state lock above. Same
    /// locale and format; the time zone is the auto-updating
    /// current zone, which is what a fresh formatter picked up
    /// on every call, so the text of every line is unchanged.
    /// Swift 6: nonisolated(unsafe) — the formatter is only
    /// ever used inside timestampLock (the house lock
    /// discipline, as with the statics above).
    private static let timestampLock = NSLock()
    private nonisolated(unsafe) static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.timeZone = TimeZone.autoupdatingCurrent
        return f
    }()

    private static func timestamp() -> String {
        let now = Date()
        return timestampLock.withLock {
            timestampFormatter.string(from: now)
        }
    }

    /// Scrub a message in three passes (v2.0.40, audit
    /// P0.3 / H-2):
    /// 1. Every URL (any case; http / https / stremio)
    ///    reduces to scheme://host — paths and queries are
    ///    exactly where debrid tokens live (Torrentio config
    ///    segments, MediaFusion's minted link), so they never
    ///    reach disk. A match URLComponents cannot parse at
    ///    all becomes "[url]".
    /// 2. A scheme-less Torrentio config base (a run carrying
    ///    realdebrid= / torbox= / premiumize= with no scheme)
    ///    is erased whole.
    /// 3. Value pass: every credential value currently in
    ///    force is erased wherever it appears, in any shape —
    ///    this is the pass that catches a bare token inside an
    ///    engine/FFmpeg error string, the one source whose
    ///    wording the app does not control.
    /// Matches are replaced back-to-front so the earlier
    /// ranges stay valid while the string mutates.
    private static func scrubbed(_ message: String) -> String {
        var result = message
        let full = NSRange(location: 0,
                           length: (result as NSString).length)
        for match in urlRegex.matches(in: result, range: full).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let raw = String(result[range])
            if let comps = URLComponents(string: raw),
               let scheme = comps.scheme, let host = comps.host {
                result.replaceSubrange(range, with: "\(scheme)://\(host)")
            } else {
                result.replaceSubrange(range, with: "[url]")
            }
        }
        let rest = NSRange(location: 0,
                           length: (result as NSString).length)
        for match in configBaseRegex.matches(in: result,
                                             range: rest).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: "[redacted]")
        }
        for secret in secretValues() {
            result = result.replacingOccurrences(of: secret,
                                                 with: "[redacted]")
        }
        return result
    }

    /// Every credential value in force (stored or bundled),
    /// longest first so a longer value is erased before any
    /// shorter value it contains. Gathered fresh on every
    /// scrub: log writes are breadcrumbs, not a hot loop, and
    /// a cached list would go stale the moment the owner
    /// rotates a token mid-session. Values under 8 characters
    /// are skipped — too short to be a credential, too likely
    /// to be an innocent substring of ordinary text. Every
    /// URL-shaped value is ALSO listed scheme-stripped: an
    /// engine error may carry a link as a bare host/path
    /// fragment with no scheme in front of it, and the
    /// literal value pass can only erase a string it is
    /// given verbatim (review, F-R1-1).
    private static func secretValues() -> [String] {
        let raw: [String?] = [
            TorrentSettings.addonURL,
            TorrentSettings.effectiveBase,
            TorrentSettings.rdToken,
            TorrentSettings.torboxToken,
            TorrentSettings.premiumizeToken,
            TorrentSettings.mfURL,
            TorrentSettings.mfBase,
            TorrentSettings.subAddonURL,
            // The sports slots are owner-pasted addon links
            // of the same kind as the two above (a stored
            // value may be a self-hosted instance on the
            // owner's own machine), so their stored and
            // effective forms belong in the list too — the
            // public defaults they fall back to are harmless
            // to erase (review, fresh-count round 1).
            TorrentSettings.sportsURL,
            TorrentSettings.sports2URL,
            TorrentSettings.sportsBase,
            TorrentSettings.sports2Base,
            BundledTokens.rdToken,
            BundledTokens.torboxToken,
            BundledTokens.premiumizeToken,
            BundledTokens.mfURL,
            TMDBBundledKey.value,
            UserDefaults.standard.string(forKey: "tmdb_api_key"),
        ]
        var seen = Set<String>()
        var out: [String] = []
        for value in raw {
            let v = (value ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard v.count >= 8, seen.insert(v).inserted else { continue }
            out.append(v)
        }
        // Scheme-stripped twins of the URL-shaped values (see
        // the header note): same floor, same dedupe; the
        // final sort puts every longer form ahead of any
        // shorter value it contains.
        let originals = out
        for v in originals {
            for scheme in ["https://", "http://", "stremio://"] {
                guard v.lowercased().hasPrefix(scheme) else { continue }
                let stripped = String(v.dropFirst(scheme.count))
                if stripped.count >= 8, seen.insert(stripped).inserted {
                    out.append(stripped)
                }
                break
            }
        }
        return out.sorted { $0.count > $1.count }
    }

    // MARK: - Launch presence (audit item 6)

    /// ONE settings line per process, recording for every
    /// stored credential its PRESENCE + LENGTH ONLY — never a
    /// value (see the file header for why). A session header
    /// line (app build + system version) is written first.
    /// The once-per-process guard is the lock-protected
    /// `didLogLaunchPresence` flag; the flag is flipped under
    /// the lock and released BEFORE the writes, because write()
    /// takes the same (non-recursive) lock itself.
    static func logLaunchPresence() {
        lock.lock()
        if didLogLaunchPresence {
            lock.unlock()
            return
        }
        didLogLaunchPresence = true
        lock.unlock()

        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        // Foundation's ProcessInfo, not UIDevice: this
        // function is nonisolated (any caller may log the
        // launch line), and the version triple is all the
        // session header needs — no UIKit dependency rides
        // along for it.
        let os = ProcessInfo.processInfo.operatingSystemVersion
        write("diag", "session start app=\(short)/\(build) "
              + "system=\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")

        func presence(_ label: String, _ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "\(label)=absent"
                : "\(label)=present len=\(value.count)"
        }

        let tmdbUserKey = UserDefaults.standard
            .string(forKey: "tmdb_api_key") ?? ""
        let parts: [String] = [
            presence("torrentio", TorrentSettings.addonURL),
            presence("rd", TorrentSettings.rdToken),
            presence("torbox", TorrentSettings.torboxToken),
            presence("premiumize", TorrentSettings.premiumizeToken),
            presence("mf", TorrentSettings.mfURL),
            "mfEnabled=\(TorrentSettings.mfEnabled ? "on" : "off")",
            presence("sports", TorrentSettings.sportsURL),
            presence("subtitles", TorrentSettings.subAddonURL),
            presence("tmdbUserKey", tmdbUserKey),
            presence("bundledRD", BundledTokens.rdToken),
            presence("bundledTorbox", BundledTokens.torboxToken),
            presence("bundledPremiumize", BundledTokens.premiumizeToken),
            presence("bundledMF", BundledTokens.mfURL),
            "configured=\(TorrentSettings.isConfigured)",
            "mfEffective=\(TorrentSettings.mfBase != nil)",
        ]
        write("settings", "launch presence: " + parts.joined(separator: " "))
    }
}

// MARK: - LAN export server (v2.0.33)

/// The tiny HTTP server behind Settings → "Gửi log chẩn
/// đoán": it serves DiagLog's file at
/// http://<Apple-TV-LAN-IP>:18080/log, as a download named
/// joetv-diag.txt, and serves nothing else.
///
/// v2.0.48 (FL-378): the server is ONE app-lifetime
/// instance (DiagLogServer.shared), started ONCE at app
/// launch and never stopped by any screen; the export
/// screen only DISPLAYS its state. The pre-2.0.48 shape —
/// a fresh instance per screen opening, owned by the
/// view's @State, stopped fire-and-forget on disappear —
/// is what killed the channel: NWListener.cancel() is
/// asynchronous, so a reopened screen's new listener
/// bound port 18080 while the previous listener still
/// held it, and the bind died with NWError 48 ("Address
/// already in use") — force-quitting could not be
/// relied on to clear it. With exactly one instance
/// whose start() is idempotent, a second bind is
/// impossible in normal flow.
///
/// v2.0.40 (audit P0.2 / H-1): the request must carry a
/// ONE-TIME PIN — a random 4-digit code minted at every
/// start(), shown on the export screen and carried in the
/// address the screen displays (…/log?pin=NNNN, or an
/// X-Diag-Pin header). The log file is token-free by
/// DiagLog's scrubber, but it still holds viewing history,
/// hosts and seek positions, and the old server handed it
/// to ANY device on the LAN that knocked. Three wrong codes
/// stop the server for 60 seconds.
///
/// Swift 6: the server is @MainActor — the listener, the
/// live-connection table and the state callback are touched
/// ONLY on the main actor. Network.framework handlers are
/// @Sendable closures running on the server's private serial
/// queue; each one captures only Sendable values (the
/// listener / connection) plus a weak self, and hops straight
/// back with Task { @MainActor in } before touching any
/// state, so the class needs no unchecked Sendable
/// conformance and no unsafe isolation opt-outs. The
/// listener and every connection
/// are STARTED on that serial queue, which is where their
/// bytes are received; the (≤1 MB, already in memory) reply
/// is assembled and sent from the main actor hop.
@MainActor
final class DiagLogServer {

    /// The ONE app-lifetime instance (v2.0.48, FL-378):
    /// started once from the root view at launch; the
    /// export screen reads its state through
    /// onStateChange and never creates or stops a server.
    static let shared = DiagLogServer()

    enum State {
        case starting
        case serving(url: String)
        case failed(String)
    }

    /// State observer — set by the export view before start().
    /// Always invoked on the main actor (see emit).
    var onStateChange: ((State) -> Void)?

    /// The queue the listener and its connections run on.
    private let queue = DispatchQueue(label: "joetv.diaglog.server")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    /// The URL the live listener serves, remembered so a
    /// start() that finds the server already running can
    /// re-report the CURRENT state to a screen that just
    /// opened (v2.0.48, FL-378) instead of leaving it on
    /// its .starting face forever.
    private var servingURL: String?

    /// The one-time PIN for this serving session (v2.0.40,
    /// P0.2): minted fresh by every start() that creates a
    /// listener, shown on the export screen, and required on
    /// every request. Read by the view to display it.
    private(set) var pin = ""
    /// Consecutive wrong-PIN requests since the last success.
    private var failedAttempts = 0
    /// After 3 consecutive wrong PINs the server refuses to
    /// start until this instant (the 60-second lockout).
    /// STATIC on purpose (review round 3, R3-1): the
    /// failure message tells the owner to close and reopen
    /// the screen, so the deadline must live at class level
    /// and survive any screen restart; reopening inside the
    /// window reports .failed, reopening after it serves
    /// with a fresh PIN. (v2.0.48: the server itself is now
    /// the app-lifetime shared instance — the static
    /// deadline stays, belt and braces, and its semantics
    /// are unchanged.) Main-actor isolation comes from the
    /// class.
    private static var lockoutUntil: Date?

    /// Start serving on port 18080. Idempotent while a
    /// listener is alive: a start() that finds the
    /// app-lifetime server already running NEVER binds
    /// again (v2.0.48, FL-378) — it re-reports the
    /// current state, so a screen opening onto a live
    /// server lands straight on its address. A start()
    /// after a failure (listener nil) is the one retry
    /// path, exactly as the lockout flow below assumes.
    func start() {
        if let until = Self.lockoutUntil, until > Date() {
            emit(.failed("Kênh gửi log đang tạm dừng sau 3 lần nhập sai mã PIN — chờ khoảng 1 phút rồi mở lại màn hình này."))
            return
        }
        guard listener == nil else {
            if let listener, listener.state == .ready,
               let port = listener.port {
                // Recompute the address on EVERY re-report
                // while the listener is live. The cached
                // URL was built from the LAN address at
                // listener-ready time, and the address can
                // drift under a live listener — DHCP
                // reassignment, an Ethernet/Wi-Fi switch —
                // while the wildcard-bound server stays
                // reachable at the NEW address; advertising
                // the cached one would strand the export
                // screen and its QR on a dead address for
                // the app's whole lifetime (review round 2,
                // defect 1). The PIN never changes here;
                // only the host part can move. The same
                // recompute covers the ready-but-no-address
                // launch case (network not up yet when the
                // listener reported ready): no URL was ever
                // built then, and this path builds it now
                // instead of wedging on .starting.
                if let ip = Self.lanIPAddress() {
                    let url = "http://\(ip):\(port.rawValue)/log?pin=\(pin)"
                    servingURL = url
                    emit(.serving(url: url))
                } else if let servingURL {
                    emit(.serving(url: servingURL))
                } else {
                    emit(.failed("Không tìm thấy địa chỉ mạng nội bộ"))
                }
            } else if let servingURL {
                emit(.serving(url: servingURL))
            } else {
                emit(.starting)
            }
            return
        }
        // No URL can be current before this listener reports
        // ready — drop any stale one before minting the new
        // PIN (defence in depth beside the lockout teardown's
        // own clear; review round 3, D-1).
        servingURL = nil
        pin = String(format: "%04d", Int.random(in: 0...9999))
        failedAttempts = 0
        emit(.starting)
        guard let port = NWEndpoint.Port(rawValue: 18080) else {
            emit(.failed("Không mở được kênh gửi log (cổng không hợp lệ)."))
            return
        }
        let created: NWListener
        do {
            created = try NWListener(using: NWParameters.tcp, on: port)
        } catch {
            emit(.failed("Không mở được kênh gửi log: \(error.localizedDescription)"))
            return
        }
        listener = created
        created.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.listenerStateChanged(state, listener: created)
            }
        }
        created.newConnectionHandler = { [weak self] conn in
            Task { @MainActor in
                self?.accept(conn)
            }
        }
        created.start(queue: queue)
    }

    /// Cancel the listener and every live connection.
    /// v2.0.48 (FL-378): no screen calls this any more —
    /// the app-lifetime server is never stopped by the
    /// UI. It remains as the class's own teardown
    /// primitive (the PIN lockout path cancels the
    /// listener directly, for its own reasons).
    func stop() {
        servingURL = nil
        listener?.cancel()
        listener = nil
        for conn in connections.values { conn.cancel() }
        connections.removeAll()
    }

    // MARK: - Listener / connection handling (main actor)

    private func listenerStateChanged(_ state: NWListener.State,
                                      listener: NWListener) {
        switch state {
        case .ready:
            guard let ip = Self.lanIPAddress(), let port = listener.port else {
                emit(.failed("Không tìm thấy địa chỉ mạng nội bộ"))
                return
            }
            let url = "http://\(ip):\(port.rawValue)/log?pin=\(pin)"
            servingURL = url
            emit(.serving(url: url))
        case .failed(let error):
            // Clear the URL only when THIS listener is the
            // live one — a stale listener's terminal state
            // must not erase a successor's URL (review
            // round 3, observation 1).
            if self.listener === listener { self.listener = nil; servingURL = nil }
            emit(.failed("Kênh gửi log lỗi: \(error.localizedDescription)"))
        case .cancelled:
            if self.listener === listener { self.listener = nil; servingURL = nil }
        default:
            break
        }
    }

    /// Accept one connection: register it (so stop() can
    /// cancel it), start it on the server queue, and read ONE
    /// bounded request (8192 bytes is far more than a Safari
    /// request line + headers). Only the PIN is read from the
    /// request (v2.0.40, P0.2 — see handle); the path itself
    /// is not routed on. A client that connects and never
    /// sends is reaped by stop() when the screen closes.
    private func accept(_ conn: NWConnection) {
        connections[ObjectIdentifier(conn)] = conn
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
            [weak self] data, _, _, _ in
            Task { @MainActor in
                self?.handle(conn, requestData: data ?? Data())
            }
        }
    }

    /// The PIN gate (v2.0.40, P0.2 / H-1): a request carrying
    /// this session's PIN gets the log and resets the failure
    /// count; any other request gets a 403 and counts. The
    /// third consecutive failure stops the server for 60
    /// seconds (lockoutUntil) — the offending connection
    /// still receives its 403 before the listener goes down.
    /// A connection that closed without sending a single byte
    /// never made a request at all, so it is NOT a wrong-PIN
    /// attempt and never counts: a LAN port scan or a browser
    /// preconnect must not be able to lock the owner out of
    /// his own export (review round 2, F-1).
    private func handle(_ conn: NWConnection, requestData: Data) {
        guard !requestData.isEmpty else {
            conn.cancel()
            connections.removeValue(forKey: ObjectIdentifier(conn))
            return
        }
        if !pin.isEmpty, Self.requestPIN(in: requestData) == pin {
            failedAttempts = 0
            respond(to: conn)
            return
        }
        failedAttempts += 1
        let locking = failedAttempts >= 3
        if locking {
            Self.lockoutUntil = Date().addingTimeInterval(60)
        }
        respondForbidden(to: conn) { [weak self] in
            guard let self, locking else { return }
            self.listener?.cancel()
            self.listener = nil
            // The URL this server was reachable at is dead
            // with the listener — clear it here too, or a
            // later start() re-report could hand out the
            // pre-lockout URL carrying the OLD PIN (review
            // round 3, D-1).
            self.servingURL = nil
            for other in self.connections.values { other.cancel() }
            self.connections.removeAll()
            self.emit(.failed("Quá 3 lần nhập sai mã PIN — kênh gửi log đã tạm dừng 60 giây. Đóng màn hình này, chờ một chút rồi mở lại."))
        }
    }

    /// Extract the PIN a request carries: the `pin=` item of
    /// the request line's query, or an `X-Diag-Pin` header.
    /// Nothing else in the request is inspected or stored,
    /// and the PIN itself is only ever compared, never logged.
    nonisolated private static func requestPIN(in data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        for line in text.components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("x-diag-pin:") {
                return lower.dropFirst("x-diag-pin:".count)
                    .trimmingCharacters(in: .whitespaces)
            }
            if lower.hasPrefix("get ") || lower.hasPrefix("head "),
               let r = lower.range(of: "pin=") {
                let tail = lower[r.upperBound...]
                let digits = tail.prefix { $0.isNumber }
                // The digit run must BE the whole query value:
                // it ends at end-of-line, a space (the HTTP
                // version follows), & or # — "pin=0123xyz" is
                // the value "0123xyz", not this session's PIN
                // (review round 2, F-2).
                let next = tail.dropFirst(digits.count).first
                if !digits.isEmpty,
                   next == nil || next == " " || next == "&" || next == "#" {
                    return String(digits)
                }
            }
        }
        return nil
    }

    /// Send the log as a plain-text download and close. The
    /// body is DiagLog.currentText() (already token-free —
    /// see DiagLog's scrubber); an empty log still downloads
    /// as a one-line placeholder so the owner gets a file,
    /// not a hung browser tab.
    private func respond(to conn: NWConnection) {
        let text = DiagLog.currentText()
        let bodyText = text.isEmpty
            ? "Joe TV diagnostic log is empty.\n" : text
        let body = Data(bodyText.utf8)
        let header = "HTTP/1.1 200 OK\r\n"
            + "Content-Type: text/plain; charset=utf-8\r\n"
            + "Content-Disposition: attachment; filename=\"joetv-diag.txt\"\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n\r\n"
        var payload = Data(header.utf8)
        payload.append(body)
        sendAndClose(conn, payload: payload)
    }

    /// The wrong/missing-PIN answer: a short 403, no log
    /// content, no hint about the right code. `after` runs
    /// once the answer is on its way (the lockout path uses
    /// it to take the listener down).
    private func respondForbidden(to conn: NWConnection,
                                  after: @escaping @MainActor () -> Void) {
        let body = Data("403 — wrong or missing PIN.\n".utf8)
        let header = "HTTP/1.1 403 Forbidden\r\n"
            + "Content-Type: text/plain; charset=utf-8\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n\r\n"
        var payload = Data(header.utf8)
        payload.append(body)
        sendAndClose(conn, payload: payload, after: after)
    }

    /// Send one payload, then close the connection and drop
    /// it from the live table.
    private func sendAndClose(_ conn: NWConnection, payload: Data,
                              after: (@MainActor () -> Void)? = nil) {
        conn.send(content: payload, completion: .contentProcessed {
            [weak self] _ in
            conn.cancel()
            Task { @MainActor in
                self?.connections.removeValue(
                    forKey: ObjectIdentifier(conn))
                after?()
            }
        })
    }

    /// Deliver a state change on the main actor, as the
    /// contract promises the view — the hop is explicit even
    /// though this class is already main-actor isolated, so
    /// the guarantee survives any future re-isolation.
    private func emit(_ state: State) {
        let callback = onStateChange
        Task { @MainActor in
            callback?(state)
        }
    }

    // MARK: - LAN address

    /// The box's first LAN IPv4 address: the first AF_INET
    /// address on en0/en1/en2 (the Apple TV's Ethernet / Wi-Fi
    /// interfaces) that is up, not loopback and not 127.*.
    /// nil when the box has no LAN address at all — the
    /// caller then reports .failed instead of showing an
    /// address that could never answer. getifaddrs lives in
    /// the Darwin module Foundation re-exports on tvOS.
    nonisolated static func lanIPAddress() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return nil }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let ptr = cursor {
            cursor = ptr.pointee.ifa_next
            guard let addr = ptr.pointee.ifa_addr,
                  addr.pointee.sa_family == sa_family_t(AF_INET)
            else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            guard name == "en0" || name == "en1" || name == "en2"
            else { continue }
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr,
                              socklen_t(addr.pointee.sa_len),
                              &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let ip = String(cString: host)
            if !ip.hasPrefix("127.") { return ip }
        }
        return nil
    }
}
