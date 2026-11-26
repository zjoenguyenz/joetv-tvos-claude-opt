import Foundation
import Network

// MARK: - Local HLS assembly server
//
// The assembly leg of the native YouTube route: the
// resolver hands back two deciphered fMP4 URLs (video +
// audio as SEPARATE files — YouTube's adaptive shape).
// AVPlayer cannot play two bare files as one programme,
// so this server assembles them into a local HLS
// presentation:
//
//   master.m3u8 ──► video.m3u8 ──► video.bin (byte ranges
//        │                          relayed to the origin)
//        └────────► audio.m3u8 ──► audio.bin
//
// Each media playlist is a VOD: the format's init
// range becomes the EXT-X-MAP and the rest of the file
// is declared as EXTINF segments with EXT-X-BYTERANGEs
// — one per fMP4 fragment when the file's sidx index
// was read at session creation (FL-358: a single
// whole-file segment gives AVPlayer no byte-range
// entry point for a seek, so every scrub collapsed
// back to the segment's first byte), or the pre-FL-358
// single whole-file segment when it was not.
// The segment endpoints are transparent range relays:
// whatever Range AVPlayer asks for is forwarded to the
// deciphered origin URL and the bytes stream back
// through a bounded, back-pressured channel (8 events
// in flight at most; the producer emits its first
// chunk at 32 KB and ~256 KB chunks after that —
// 2.0.44) — the whole file is never buffered in
// memory, by construction.
//
// Port discipline (FL-252 + design §4.4): a fixed port
// is a DEVICE-wide resource, so this server owns NO
// fixed port at all — it asks for the LOOPBACK
// interface with an OS-assigned ephemeral port
// (port 0), reads the real port back from the ready
// listener and builds session URLs from it. 18080
// stays DiagLog's alone (untouched) and no sibling
// app's port is used.
//
// Loopback is enforced at TWO layers, because the
// bind layer alone is not documentation-provable
// (review round 7, MAJOR): the listener is created
// with requiredLocalEndpoint = 127.0.0.1:0 — a
// different construction from DiagLogServer's proven
// NWListener(using:on:) shape, and whether NWListener
// honours requiredLocalEndpoint as a listen-address
// restriction is not something Apple's docs state
// outright — AND, independently, accept() hard-gates
// every accepted connection on its peer endpoint:
// anything that did not arrive from this device's own
// loopback is cancelled before a byte is read. The
// second layer is the guarantee; it proves itself in
// the log. The only legitimate client is this app's
// own AVPlayer on the same device, so nothing here is
// reachable from the LAN and no PIN is needed. What
// IS copied from DiagLogServer is the discipline
// around the listener (plain NWParameters.tcp,
// per-instance start guard, state surfaced verbatim)
// — the mechanism's discipline, not its bind call,
// and never its port.
//
// Swift 6: @MainActor like DiagLogServer — Network
// handlers are @Sendable closures that capture only the
// connection plus a weak self and hop straight back with
// Task { @MainActor in } before touching any state.
// Continuation resume values are Bool / Data counts —
// Sendable by construction ([CONTINUATION-SENDING]).

@MainActor
final class JoeYtHlsServer {
    static let shared = JoeYtHlsServer()

    /// The OS-assigned ephemeral port of the live
    /// listener (design §4.4: port 0 at bind time, the
    /// real value read back from the ready listener).
    /// Set BEFORE state flips to .ready, cleared when
    /// the listener dies; session URLs are built from
    /// this value, never from a constant.
    private var boundPort: UInt16?

    private enum State {
        case idle
        case starting
        case ready
    }

    /// FL-358: one fMP4 fragment of a stream, as indexed
    /// by the file's own sidx box — the byte range the
    /// media playlist declares as one HLS segment, and
    /// the duration AVPlayer maps seek times onto.
    private struct MediaSegment: Sendable {
        var offset: Int64
        var length: Int64
        var durationSeconds: Double
    }

    /// One registered playback session: the two origin
    /// streams of one resolved episode.
    private struct StreamEntry {
        var origin: URL
        var contentLength: Int64
        var initRange: JoeYtByteRange?
        var durationSeconds: Double
        var mimeType: String
        /// The UA the origin request must carry (stored
        /// per entry — review round 1, MINOR: relay used
        /// to ignore makeSession's parameter and hardcode
        /// the spec's UA).
        var userAgent: String
        /// FL-358: the stream's sidx fragment index,
        /// read from the origin at session creation.
        /// Empty = the index could not be read or did
        /// not validate, and the media playlist keeps
        /// its single-segment shape for this stream.
        var segments: [MediaSegment] = []
    }

    /// FL-350 (2.0.45, leg 2): one subtitle rendition
    /// carried by a session — the fetched WebVTT bytes,
    /// kept byte-exact (no origin relay: the route below
    /// serves this Data as-is). The display name is built
    /// from the language code, never taken from the
    /// track's own name (which can carry anything).
    private struct SubtitleRendition {
        var language: String
        var name: String
        var vtt: Data
        var isDefault: Bool
    }

    private struct Session {
        var video: StreamEntry
        var audio: StreamEntry
        var videoCodec: String
        var audioCodec: String
        var width: Int
        var height: Int
        var bandwidth: Int
        var createdAt: Date
        /// FL-350 (leg 2): the session's subtitle
        /// renditions (empty = the master playlist stays
        /// byte-identical to the pre-subtitle shape).
        var subtitles: [SubtitleRendition] = []
        /// Languages whose rendition has already been
        /// served once (the first-serve log fires once
        /// per rendition, not per request).
        var servedSubtitleLangs: Set<String> = []
        /// Design §4.4 logging point ("segment đầu tiên
        /// được phục vụ"): flipped the first time media
        /// BYTES of this session are actually delivered
        /// to the client (2.0.44 correction — the pre-fix
        /// flag flipped at head-send, before a single
        /// body byte had moved; see noteFirstMediaServed),
        /// so that moment is logged exactly once per
        /// session; later chunks stay silent.
        var firstSegmentServed = false
    }

    private let queue = DispatchQueue(label: "joetv.yt.hlsserver")
    private var listener: NWListener?
    private var state: State = .idle
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var sessions: [String: Session] = [:]
    private var sessionOrder: [String] = []

    private init() {}

    private func log(_ message: String) {
        DiagLog.write("YT-HLS", message)
    }

    // MARK: Session registration

    /// Register one resolved episode and return the
    /// master-playlist URL AVPlayer should load, with
    /// the session's id (FL-349, leg 1: the handle the
    /// player keeps beside the queued item so the
    /// advance gate can ask firstMediaServed(sessionID:)).
    /// Starts the listener on first use. Nil = the server
    /// could not start (logged); the caller falls back.
    func makeSession(playable: JoeYtPlayable, userAgent: String)
        async -> (url: URL, sessionID: String)? {
        guard let videoURL = playable.videoURL, let audioURL = playable.audioURL else {
            return nil
        }
        guard await ensureStarted() else { return nil }
        let id = UUID().uuidString
        // FL-350 (leg 2): the carried caption tracks are
        // fetched NOW, once per episode, both concurrently
        // — a session is born with its renditions or
        // without them; a subtitle failure never blocks
        // the session (the fetch logs and returns nil).
        let renditions = await fetchRenditions(playable: playable,
                                               sessionID: id,
                                               userAgent: userAgent)
        var video = StreamEntry(
            origin: videoURL,
            contentLength: playable.videoContentLength,
            initRange: playable.videoInitRange,
            durationSeconds: playable.durationSeconds,
            mimeType: "video/mp4",
            userAgent: userAgent)
        var audio = StreamEntry(
            origin: audioURL,
            contentLength: playable.audioContentLength,
            initRange: playable.audioInitRange,
            durationSeconds: playable.durationSeconds,
            mimeType: "audio/mp4",
            userAgent: userAgent)
        // FL-358: read each stream's sidx fragment index
        // from the origin NOW, once per episode (two
        // small range fetches), so the media playlists
        // can declare per-fragment segments and a seek
        // can enter the file at the target fragment's
        // byte offset. A stream whose index does not
        // read or validate simply keeps the
        // single-segment playlist — playback is never
        // blocked for seek support.
        video.segments = await fetchSegmentIndex(entry: video,
                                                  sessionID: id,
                                                  fileLabel: "video")
        audio.segments = await fetchSegmentIndex(entry: audio,
                                                  sessionID: id,
                                                  fileLabel: "audio")
        let session = Session(
            video: video, audio: audio,
            videoCodec: playable.videoCodec, audioCodec: playable.audioCodec,
            width: playable.width, height: playable.height,
            bandwidth: max(0, playable.videoBitrate) + max(0, playable.audioBitrate),
            createdAt: Date(),
            subtitles: renditions)
        sessions[id] = session
        sessionOrder.append(id)
        // Keep at most 4 sessions (current + prefetched
        // next + slack); older origins are expired signed
        // URLs anyway.
        while sessionOrder.count > 4 {
            let dropped = sessionOrder.removeFirst()
            sessions.removeValue(forKey: dropped)
        }
        log("session \(id.prefix(8)) — assembly itag \(playable.videoItag)+\(playable.audioItag), "
            + "\(playable.width)x\(playable.height), dur \(Int(playable.durationSeconds))s")
        for rendition in renditions {
            log("session \(id.prefix(8)): phụ đề vào master — \(rendition.language) (\(rendition.vtt.count) byte vtt)")
        }
        // FL-484/485 instrumentation (2.1.6, LOG-ONLY): a
        // loopback self-probe at session-presentation
        // time — one TCP connect attempt to the relay's
        // own port, its result logged beside the serve
        // logs above. ensureStarted's only health check is
        // listener.state == .ready: in the 2026-11-24
        // incident the listener reported ready while its
        // accepts wedged, and nothing in the log could see
        // it — the probe exists to capture that signature
        // next time. It changes NO behaviour: the listener
        // is never restarted or re-bound here.
        if let boundPort {
            probeLoopback(port: boundPort, sessionID: id)
        }
        guard let boundPort else { return nil }
        guard let url = URL(string: "http://127.0.0.1:\(boundPort)/yt/\(id)/master.m3u8")
        else { return nil }
        return (url, id)
    }

    /// FL-349 (2.0.45, leg 1): whether the session's
    /// first media byte has actually been served — the
    /// advance gate's server-side readiness signal (the
    /// flag noteFirstMediaServed flips when the first
    /// body bytes move). Unknown session = false.
    func firstMediaServed(sessionID: String) -> Bool {
        sessions[sessionID]?.firstSegmentServed ?? false
    }

    /// FL-484/485 instrumentation (2.1.6, LOG-ONLY): one
    /// TCP connect to the relay's own 127.0.0.1 port. The
    /// result is logged and the probe connection is
    /// cancelled in every terminal state — the probe
    /// never serves, never retries, and never touches
    /// the listener. On loopback a .waiting refusal is
    /// the wedge's signature: the port IS bound (this
    /// process bound it) yet the connect does not
    /// complete.
    private func probeLoopback(port: UInt16, sessionID: String) {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return }
        let connection = NWConnection(host: "127.0.0.1",
                                      port: endpointPort,
                                      using: .tcp)
        let label = String(sessionID.prefix(8))
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                DiagLog.write("YT-HLS", "loopback self-probe session \(label): OK — 127.0.0.1:\(port) nhận kết nối")
                connection.cancel()
            case .waiting(let error):
                DiagLog.write("YT-HLS", "loopback self-probe session \(label): WAITING — \(error.localizedDescription)")
                connection.cancel()
            case .failed(let error):
                DiagLog.write("YT-HLS", "loopback self-probe session \(label): FAIL — \(error.localizedDescription)")
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: .global(qos: .utility))
    }

    // MARK: Subtitle renditions (FL-350, leg 2)

    /// The display name for a subtitle language code,
    /// built from the code alone ("vi" → Tiếng Việt,
    /// "en" → English, a regional variant follows its
    /// base code, anything else shows the code itself).
    private static func subtitleDisplayName(_ code: String) -> String {
        if code == "vi" || code.hasPrefix("vi-") { return "Tiếng Việt" }
        if code == "en" || code.hasPrefix("en-") { return "English" }
        return code
    }

    /// Fetch the playable's carried caption tracks (at
    /// most two) into renditions, concurrently. A track
    /// that fails or yields nothing is simply absent —
    /// the session plays without it (never blocked).
    private func fetchRenditions(playable: JoeYtPlayable,
                                 sessionID: String,
                                 userAgent: String) async -> [SubtitleRendition] {
        let tracks = playable.captions
        guard !tracks.isEmpty else { return [] }
        var datas: [Data?] = []
        if tracks.count == 1 {
            datas = [await fetchCaptionVTT(track: tracks[0],
                                           sessionID: sessionID,
                                           userAgent: userAgent)]
        } else {
            async let first = fetchCaptionVTT(track: tracks[0],
                                              sessionID: sessionID,
                                              userAgent: userAgent)
            async let second = fetchCaptionVTT(track: tracks[1],
                                               sessionID: sessionID,
                                               userAgent: userAgent)
            let pair = await (first, second)
            datas = [pair.0, pair.1]
        }
        var out: [SubtitleRendition] = []
        for (index, track) in tracks.enumerated() {
            guard index < datas.count, let data = datas[index] else { continue }
            out.append(SubtitleRendition(
                language: track.languageCode,
                name: Self.subtitleDisplayName(track.languageCode),
                vtt: data,
                isDefault: index == playable.chosenCaption))
        }
        return out
    }

    /// One track's timedtext, as WebVTT bytes. The
    /// track's own baseUrl gains fmt=vtt (its existing
    /// query items ride along untouched; the URL itself
    /// is never logged — FL-073). V-2 discipline: the
    /// answer must actually BE VTT (start with WEBVTT);
    /// when it is not, the default timedtext XML is
    /// converted syntactically (see
    /// convertTimedTextToVTT). A track yielding 0 cues
    /// counts as absent. Every failure is logged with
    /// its status and returns nil — playback is never
    /// blocked for subtitles (FL-076).
    private func fetchCaptionVTT(track: JoeYtCaptionTrack,
                                 sessionID: String,
                                 userAgent: String) async -> Data? {
        let id8 = sessionID.prefix(8)
        guard var components = URLComponents(url: track.baseURL,
                                             resolvingAgainstBaseURL: false)
        else {
            log("session \(id8): phụ đề \(track.languageCode) fetch hỏng — baseUrl không parse được (phát không phụ đề)")
            return nil
        }
        var query = components.queryItems ?? []
        query.removeAll { $0.name == "fmt" }
        query.append(URLQueryItem(name: "fmt", value: "vtt"))
        components.queryItems = query
        guard let url = components.url else {
            log("session \(id8): phụ đề \(track.languageCode) fetch hỏng — không dựng được URL timedtext (phát không phụ đề)")
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            log("session \(id8): phụ đề \(track.languageCode) fetch hỏng — \(error.localizedDescription) (phát không phụ đề)")
            return nil
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            log("session \(id8): phụ đề \(track.languageCode) fetch hỏng — HTTP \(status) (phát không phụ đề)")
            return nil
        }
        if data.starts(with: Data("WEBVTT".utf8)) {
            guard Self.countCues(in: data) > 0 else {
                log("session \(id8): phụ đề \(track.languageCode) 0 cue — coi như không có")
                return nil
            }
            return data
        }
        guard let converted = Self.convertTimedTextToVTT(data),
              Self.countCues(in: converted) > 0 else {
            log("session \(id8): phụ đề \(track.languageCode) fetch hỏng — đáp án không phải VTT, XML cũng không chuyển được (phát không phụ đề)")
            return nil
        }
        return converted
    }

    /// Cue count of a WebVTT payload (the "-->" lines).
    private static func countCues(in data: Data) -> Int {
        let text = String(decoding: data, as: UTF8.self)
        return text.components(separatedBy: "-->").count - 1
    }

    /// Syntax-only conversion of a timedtext XML answer
    /// to WebVTT: cue timings + text, tags stripped,
    /// entities decoded — no timing or wording is
    /// invented. Two element shapes are recognised: the
    /// `<text start="s" dur="s">` form (seconds — the
    /// shape the design names) and the srv3
    /// `<p t="ms" d="ms">` form (milliseconds), so the
    /// converter stands whichever of the two the default
    /// format actually answers with.
    private static func convertTimedTextToVTT(_ data: Data) -> Data? {
        guard let xml = String(data: data, encoding: .utf8) else { return nil }
        var cues: [(start: Double, end: Double, text: String)] = []
        appendTimedTextCues(xml, scale: 1,
                            pattern: "<text[^>]*?start=\"([0-9.]+)\"[^>]*?dur=\"([0-9.]+)\"[^>]*?>(.*?)</text>",
                            into: &cues)
        if cues.isEmpty {
            appendTimedTextCues(xml, scale: 1,
                                pattern: "<text[^>]*?dur=\"([0-9.]+)\"[^>]*?start=\"([0-9.]+)\"[^>]*?>(.*?)</text>",
                                swapped: true, into: &cues)
        }
        if cues.isEmpty {
            appendTimedTextCues(xml, scale: 0.001,
                                pattern: "<p[^>]*?t=\"([0-9]+)\"[^>]*?d=\"([0-9]+)\"[^>]*?>(.*?)</p>",
                                into: &cues)
        }
        if cues.isEmpty {
            appendTimedTextCues(xml, scale: 0.001,
                                pattern: "<p[^>]*?d=\"([0-9]+)\"[^>]*?t=\"([0-9]+)\"[^>]*?>(.*?)</p>",
                                swapped: true, into: &cues)
        }
        guard !cues.isEmpty else { return nil }
        var out = "WEBVTT\n\n"
        for cue in cues {
            let text = decodeTimedText(cue.text)
            guard !text.isEmpty else { continue }
            out += "\(vttTimestamp(cue.start)) --> \(vttTimestamp(cue.end))\n\(text)\n\n"
        }
        return Data(out.utf8)
    }

    private static func appendTimedTextCues(
        _ xml: String, scale: Double, pattern: String, swapped: Bool = false,
        into cues: inout [(start: Double, end: Double, text: String)]) {
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.dotMatchesLineSeparators])
        else { return }
        let ns = xml as NSString
        for match in regex.matches(in: xml, range: NSRange(location: 0, length: ns.length)) {
            guard match.numberOfRanges == 4,
                  let first = Double(ns.substring(with: match.range(at: 1))),
                  let second = Double(ns.substring(with: match.range(at: 2)))
            else { continue }
            let startRaw = swapped ? second : first
            let durRaw = swapped ? first : second
            let start = startRaw * scale
            cues.append((start: start, end: start + durRaw * scale,
                         text: ns.substring(with: match.range(at: 3))))
        }
    }

    /// Strip inner tags and decode the XML entities a
    /// timedtext body carries (named + numeric).
    private static func decodeTimedText(_ raw: String) -> String {
        var text = raw.replacingOccurrences(
            of: "<[^>]+>", with: "", options: .regularExpression)
        if let regex = try? NSRegularExpression(pattern: "&#([0-9]+);") {
            let ns = text as NSString
            var out = ""
            var cursor = 0
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: cursor,
                                                  length: match.range.location - cursor))
                if let value = UInt32(ns.substring(with: match.range(at: 1))),
                   let scalar = UnicodeScalar(value) {
                    out += String(scalar)
                }
                cursor = match.range.location + match.range.length
            }
            out += ns.substring(from: cursor)
            text = out
        }
        text = text.replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// HH:MM:SS.mmm — the WebVTT timestamp form.
    private static func vttTimestamp(_ seconds: Double) -> String {
        let total = max(0, seconds)
        let hours = Int(total) / 3600
        let minutes = (Int(total) % 3600) / 60
        let secs = total - Double(hours * 3600 + minutes * 60)
        return String(format: "%02d:%02d:%06.3f", hours, minutes, secs)
    }

    /// Start the listener if needed and wait (bounded)
    /// until it reports ready. Returns false on failure.
    ///
    /// FL-343 (B): the wait is no longer a single passive
    /// watch from .idle. A listener that DIES mid-start
    /// (its state handler drops the machine back to .idle
    /// inside the wait) is started over within the same
    /// call, and a listener still wedged in .starting
    /// after a full bounded wait is torn down and started
    /// once more — the pre-fix shape returned false and
    /// left the wedge for the NEXT makeSession to inherit,
    /// which is how one silent listener death stranded
    /// every later session of the process on a dead port.
    func ensureStarted() async -> Bool {
        if state == .ready { return true }
        for _ in 0..<2 {
            if state == .idle { startListener() }
            // The instance THIS round is waiting on
            // (review round 1, Lens A F-A1): the sleeps
            // below suspend, and a concurrent makeSession
            // may tear down and replace the listener
            // meanwhile — the stuck-.starting teardown
            // after the wait must only ever lower the
            // instance this round actually waited on,
            // never a healthy successor.
            let waited = listener
            for _ in 0..<30 {
                if state == .ready { return true }
                // Died mid-start: the state handler has
                // already reset the machine to .idle —
                // break to the outer loop and start over.
                if state == .idle { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if state == .ready { return true }
            if state == .starting, listener === waited {
                log("listener kẹt ở .starting quá hạn chờ — hạ và mở lại")
                teardownListener()
            }
        }
        log("listener chưa ready sau các lần thử — assembly không khả dụng lượt này")
        return false
    }

    /// Bring the listener down and reset the machine to
    /// .idle (FL-343 B): reference and port are cleared
    /// BEFORE the cancel, so the dead listener's own late
    /// .cancelled event fails the identity guard in the
    /// state handler and can never write over a successor
    /// listener's state.
    private func teardownListener() {
        let dead = listener
        listener = nil
        boundPort = nil
        state = .idle
        dead?.cancel()
    }

    private func startListener() {
        guard listener == nil else { return }
        state = .starting
        // Port 0 = the OS assigns an ephemeral port
        // (design §4.4); the real value is read back
        // from the listener when it reports .ready.
        guard let anyPort = NWEndpoint.Port(rawValue: 0) else {
            log("listener: không tạo được endpoint cổng ephemeral — assembly không khả dụng")
            state = .idle
            return
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("127.0.0.1"), port: anyPort)
        let created: NWListener
        do {
            created = try NWListener(using: parameters)
        } catch {
            // Back to .idle, not a latched .failed (review
            // round 1, MINOR): a transient failure must
            // not demote assembly for the process lifetime
            // — the next makeSession retries the start.
            state = .idle
            log("listener tạo thất bại: \(error.localizedDescription) — sẽ thử lại ở session sau")
            return
        }
        listener = created
        created.stateUpdateHandler = { [weak self] newState in
            Task { @MainActor in
                self?.listenerStateChanged(newState, listener: created)
            }
        }
        created.newConnectionHandler = { [weak self] conn in
            Task { @MainActor in
                self?.accept(conn)
            }
        }
        created.start(queue: queue)
        log("listener start trên 127.0.0.1 (cổng ephemeral, OS cấp)")
    }

    private func listenerStateChanged(_ newState: NWListener.State,
                                      listener: NWListener) {
        switch newState {
        case .setup:
            // FL-343 (B) + fault-library rule: EVERY state
            // of the listener is handled and logged — a
            // state that falls through silently is a state
            // the server can die in without a trace (the
            // pre-fix default branch swallowed .waiting,
            // and the .cancelled branch never logged).
            guard self.listener === listener else { return }
            log("listener setup — đang khởi động")
        case .waiting(let error):
            // .waiting = the listener exists but has no
            // usable path right now (interface down /
            // not ready). It is NOT a serving state: left
            // latched, makeSession keeps handing out URLs
            // on a port nothing accepts on — the FL-343
            // device shape. Tear down to .idle so the next
            // makeSession starts a fresh listener.
            guard self.listener === listener else { return }
            log("listener WAITING: \(error.localizedDescription) — hạ listener, session sau sẽ mở lại")
            teardownListener()
        case .ready:
            // Identity check FIRST (review count round
            // 1, Lens A F-1): a STALE event from a
            // replaced listener must never write the
            // live listener's state — a late .failed
            // dragging state to .idle while the current
            // listener is ready would strand every
            // makeSession (ensureStarted only starts
            // from .idle, and startListener early-returns
            // while a listener exists): assembly dead
            // for the process lifetime.
            guard self.listener === listener else { return }
            // Read the OS-assigned port back from the
            // listener itself (NWListener.port) and set
            // it BEFORE .ready so ensureStarted can only
            // observe a ready state that already has a
            // usable port. The log records only that the
            // port is ephemeral (design §4.4's logging
            // point) — never the number.
            //
            // A .ready with NO readable port is not a
            // serving state (review round 1, Lens C
            // F-C7): latched, ensureStarted would answer
            // true while makeSession's boundPort guard
            // fails every session — the FL-343 silent-
            // death shape behind a green-looking state.
            // Treat it as a failed start.
            guard let port = listener.port?.rawValue else {
                log("listener ready nhưng không đọc được cổng — hạ listener, session sau sẽ mở lại")
                teardownListener()
                return
            }
            boundPort = port
            state = .ready
            log("listener ready trên 127.0.0.1 (ephemeral)")
        case .failed(let error):
            guard self.listener === listener else { return }
            // Reset to .idle so the next makeSession
            // retries (review round 1, MINOR — the .failed
            // latch made one transient bind failure
            // permanent for the process).
            log("listener FAILED: \(error.localizedDescription) — lần mở session sau sẽ thử mở lại")
            teardownListener()
        case .cancelled:
            if self.listener === listener {
                // Logged (FL-343 B: this branch was silent
                // — a cancelled listener left no trace at
                // all). Back to .idle UNCONDITIONALLY
                // (review round 7, MINOR): a listener
                // cancelled while still .starting previously
                // left the state latched at .starting
                // forever — ensureStarted only starts from
                // .idle, so assembly would have been dead
                // for the process lifetime, the exact latch
                // the round-1 fix removed from the .failed
                // branch.
                log("listener CANCELLED — hạ listener, session sau sẽ mở lại")
                teardownListener()
            }
        @unknown default:
            // A state a future OS adds (review round 1,
            // Lens B F-1): NWListener.State is an imported
            // enum and this switch must keep a door for
            // cases the current SDK does not declare —
            // and per the FL-343 rule the door is LOGGED,
            // never silent. The state itself is left
            // untouched: an unknown state is not evidence
            // the listener stopped serving.
            if self.listener === listener {
                log("listener state lạ (\(newState)) — giữ nguyên, không suy đoán")
            }
        }
    }

    // MARK: Connection handling

    private func accept(_ conn: NWConnection) {
        // The loopback hard gate (review round 7,
        // MAJOR): whatever the bind semantics turn out
        // to be on any given OS build, a connection
        // whose peer is not this device's own loopback
        // is cancelled before a single byte is read —
        // and the refusal is logged, so the guarantee is
        // provable from the diagnostic log alone. Fail
        // closed on any endpoint shape that is not a
        // loopback hostPort.
        switch conn.endpoint {
        case .hostPort(let host, _):
            let hostText = "\(host)"
            guard hostText == "127.0.0.1" || hostText == "::1"
                    || hostText == "localhost"
                    || hostText.hasPrefix("::ffff:127.0.0.1") else {
                log("accept: TỪ CHỐI kết nối không phải loopback (peer \(hostText)) — hủy ngay")
                conn.cancel()
                return
            }
        default:
            log("accept: TỪ CHỐI kết nối có endpoint không phải hostPort — hủy ngay")
            conn.cancel()
            return
        }
        connections[ObjectIdentifier(conn)] = conn
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) {
            [weak self] data, _, _, _ in
            Task { @MainActor in
                self?.handle(conn, requestData: data ?? Data())
            }
        }
    }

    private func close(_ conn: NWConnection) {
        conn.cancel()
        connections.removeValue(forKey: ObjectIdentifier(conn))
    }

    /// Parse one request (request line + the Range header
    /// are all this server routes on) and dispatch.
    private func handle(_ conn: NWConnection, requestData: Data) {
        guard !requestData.isEmpty else { close(conn); return }
        let text = String(decoding: requestData, as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { close(conn); return }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            log("serve (request line không hợp lệ) → 400")
            respondText(conn, status: 400, body: "bad request",
                        headOnly: requestLine.hasPrefix("HEAD "))
            return
        }
        let method = String(parts[0])
        let path = String(parts[1])
        // A HEAD response must carry the headers a GET
        // would, with NO body (RFC 9110) — every response
        // path below honours this flag, including the
        // error paths (review round 7, MINOR).
        let headOnly = (method == "HEAD")
        var rangeHeader: String?
        for line in lines.dropFirst() {
            let lower = line.lowercased()
            if lower.hasPrefix("range:") {
                rangeHeader = line.dropFirst("range:".count)
                    .trimmingCharacters(in: .whitespaces)
            }
        }
        // Freeze the parsed value into an immutable let
        // before any closure captures it (FL-341): the
        // relay Task below captures this let, never the
        // mutated var above.
        let parsedRangeHeader = rangeHeader
        // /yt/<session>/<file>
        // Serve logging (FL-343 PHÒNG NGỪA 3): every
        // request this server answers is recorded with
        // its method, its INTERNAL path (session prefix +
        // file — never an origin URL) and the status
        // returned, 404s included. The pre-fix server
        // logged nothing per request, so a dead listener
        // and a live one were indistinguishable in the
        // diagnostic log.
        let segments = path.split(separator: "/").map(String.init)
        // FL-350 (leg 2): the subtitle route —
        // /yt/<session>/subs/<lang>.vtt (FOUR segments;
        // the media routes below are three). The stored
        // VTT bytes are served as-is; the first serve of
        // each rendition is logged once.
        if segments.count == 4, segments[0] == "yt", segments[2] == "subs" {
            let file = segments[3]
            let lang = file.hasSuffix(".vtt") ? String(file.dropLast(4)) : file
            if var session = sessions[segments[1]],
               let rendition = session.subtitles.first(where: { $0.language == lang }) {
                if !session.servedSubtitleLangs.contains(lang) {
                    session.servedSubtitleLangs.insert(lang)
                    sessions[segments[1]] = session
                    log("serve \(method) /yt/\(segments[1].prefix(8))/subs/\(file) → 200 (lần đầu)")
                } else {
                    log("serve \(method) /yt/\(segments[1].prefix(8))/subs/\(file) → 200")
                }
                respondData(conn, status: 200, data: rendition.vtt,
                            contentType: "text/vtt", headOnly: headOnly)
            } else {
                log("serve \(method) /yt/\(segments[1].prefix(8))/subs/\(file) → 404")
                respondText(conn, status: 404, body: "not found", headOnly: headOnly)
            }
            return
        }
        guard segments.count == 3, segments[0] == "yt",
              let session = sessions[segments[1]] else {
            if segments.count == 3, segments[0] == "yt" {
                log("serve \(method) /yt/\(segments[1].prefix(8))/\(segments[2]) → 404")
            } else {
                log("serve \(method) (path không thuộc /yt/) → 404")
            }
            respondText(conn, status: 404, body: "not found", headOnly: headOnly)
            return
        }
        let file = segments[2]
        switch file {
        case "master.m3u8":
            log("serve \(method) /yt/\(segments[1].prefix(8))/master.m3u8 → 200")
            respondText(conn, status: 200, body: masterPlaylist(session),
                        contentType: "application/vnd.apple.mpegurl", headOnly: headOnly)
        case "video.m3u8":
            log("serve \(method) /yt/\(segments[1].prefix(8))/video.m3u8 → 200")
            respondText(conn, status: 200,
                        body: mediaPlaylist(entry: session.video, file: "video.bin"),
                        contentType: "application/vnd.apple.mpegurl", headOnly: headOnly)
        case "audio.m3u8":
            log("serve \(method) /yt/\(segments[1].prefix(8))/audio.m3u8 → 200")
            respondText(conn, status: 200,
                        body: mediaPlaylist(entry: session.audio, file: "audio.bin"),
                        contentType: "application/vnd.apple.mpegurl", headOnly: headOnly)
        case "video.bin", "audio.bin":
            let entry = (file == "video.bin") ? session.video : session.audio
            Task { [weak self] in
                await self?.relay(conn, sessionID: segments[1], entry: entry,
                                  rangeHeader: parsedRangeHeader, headOnly: headOnly,
                                  method: method, file: file)
            }
        default:
            log("serve \(method) /yt/\(segments[1].prefix(8))/\(file) → 404")
            respondText(conn, status: 404, body: "not found", headOnly: headOnly)
        }
    }

    // MARK: Playlists

    private func masterPlaylist(_ session: Session) -> String {
        let bandwidth = session.bandwidth > 0 ? session.bandwidth : 4_400_000
        let resolution = (session.width > 0 && session.height > 0)
            ? ",RESOLUTION=\(session.width)x\(session.height)" : ""
        let codecs = (session.videoCodec.isEmpty || session.audioCodec.isEmpty)
            ? "" : ",CODECS=\"\(session.videoCodec),\(session.audioCodec)\""
        // FL-350 (leg 2): one EXT-X-MEDIA line per
        // subtitle rendition BEFORE the variant, and the
        // variant names the group. No renditions → the
        // master stays byte-identical to the pre-subtitle
        // shape (no SUBTITLES declaration, no fake panel
        // entry).
        // 2.0.46 (owner ruling 2026-11-21 02:05): TVB
        // YouTube titles are already Vietnamese-dubbed,
        // so subtitle renditions are PANEL-ONLY — emitted
        // with DEFAULT=NO and AUTOSELECT=NO so nothing
        // pre-selects them; the rendition's isDefault
        // record no longer drives emission. The owner's
        // manual panel pick remains available.
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:6",
            "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"AAC\",DEFAULT=YES,AUTOSELECT=YES,URI=\"audio.m3u8\"",
        ]
        for rendition in session.subtitles {
            lines.append("#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID=\"subs\",NAME=\"\(rendition.name)\",LANGUAGE=\"\(rendition.language)\",DEFAULT=NO,AUTOSELECT=NO,URI=\"subs/\(rendition.language).vtt\"")
        }
        let subtitlesAttr = session.subtitles.isEmpty ? "" : ",SUBTITLES=\"subs\""
        lines.append("#EXT-X-STREAM-INF:BANDWIDTH=\(bandwidth)\(resolution)\(codecs),AUDIO=\"aud\"\(subtitlesAttr)")
        lines.append("video.m3u8")
        // No trailing newline: with no renditions this is
        // byte-identical to the pre-subtitle master (the
        // old multiline literal carried none either).
        return lines.joined(separator: "\n")
    }

    private func mediaPlaylist(entry: StreamEntry, file: String) -> String {
        let duration = entry.durationSeconds > 0 ? entry.durationSeconds : 3600
        // FL-358: with an sidx fragment index the
        // TARGETDURATION is the longest FRAGMENT (the
        // HLS meaning of the field); without one it
        // stays the whole duration, as before.
        let target: Int
        if entry.segments.isEmpty {
            target = Int(duration.rounded(.up)) + 1
        } else {
            let longest = entry.segments.map(\.durationSeconds).max() ?? duration
            target = Int(longest.rounded(.up)) + 1
        }
        var lines: [String] = [
            "#EXTM3U",
            "#EXT-X-VERSION:6",
            "#EXT-X-TARGETDURATION:\(target)",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:VOD",
        ]
        var segmentStart: Int64 = 0
        if let initRange = entry.initRange {
            lines.append("#EXT-X-MAP:URI=\"\(file)\",BYTERANGE=\"\(initRange.length)@\(initRange.start)\"")
            segmentStart = initRange.end + 1
        }
        if entry.segments.isEmpty {
            lines.append(String(format: "#EXTINF:%.3f,", duration))
            if entry.contentLength > segmentStart {
                let mediaLength = entry.contentLength - segmentStart
                lines.append("#EXT-X-BYTERANGE:\(mediaLength)@\(segmentStart)")
            }
            lines.append(file)
        } else {
            // FL-358: one segment per fMP4 fragment.
            // AVPlayer maps a seek time onto these
            // segments by their cumulative EXTINF
            // durations and requests ONLY the segment
            // holding the target — the relay forwards
            // that Range to the origin verbatim, so the
            // origin fetch starts at exactly the target
            // fragment's offset instead of the file's
            // first media byte.
            for segment in entry.segments {
                lines.append(String(format: "#EXTINF:%.3f,", segment.durationSeconds))
                lines.append("#EXT-X-BYTERANGE:\(segment.length)@\(segment.offset)")
                lines.append(file)
            }
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Segment index (sidx, FL-358)

    /// Read and parse the sidx box of one stream from
    /// its origin, returning the fragment index the
    /// media playlist declares as segments. The box is
    /// expected to start where the init range ends (the
    /// layout the resolver's formats carry — initRange
    /// and indexRange are adjacent in the /player
    /// payload); the box's own type field is the proof,
    /// and anything that is not a well-formed sidx, or
    /// whose entries do not tile the file inside its
    /// content length, yields an empty result and the
    /// stream keeps the single-segment playlist. Every
    /// failure is logged with its reason (never a URL)
    /// and never blocks the session.
    private func fetchSegmentIndex(entry: StreamEntry, sessionID: String,
                                   fileLabel: String) async -> [MediaSegment] {
        let id8 = sessionID.prefix(8)
        guard let initRange = entry.initRange else {
            log("session \(id8): sidx \(fileLabel) bỏ qua — không có initRange (playlist giữ 1 segment)")
            return []
        }
        // Same overflow class as the parser's cursor
        // (gate round 1, FL-358): the additions below
        // (end + 1, indexStart + 16 / + 39) must never
        // trap on an out-of-range initRange — reject it
        // here and keep the legacy playlist.
        guard initRange.end >= 0, initRange.end <= Int64.max - 64 else {
            log("session \(id8): sidx \(fileLabel) bỏ qua — initRange.end ngoài tầm (playlist giữ 1 segment)")
            return []
        }
        let indexStart = initRange.end + 1
        guard entry.contentLength > indexStart + 16 else {
            log("session \(id8): sidx \(fileLabel) bỏ qua — file không còn đủ byte sau init (playlist giữ 1 segment)")
            return []
        }
        // Probe: the box header (size + type) plus the
        // fixed fields through reference_count — the
        // version-0 header is 32 bytes, the version-1
        // header is 40 bytes (its earliest_presentation_
        // time and first_offset are 64-bit), so 40 bytes
        // are probed to cover both versions.
        let probeEnd = min(indexStart + 39, entry.contentLength - 1)
        guard let probe = await fetchOriginRange(
                origin: entry.origin, userAgent: entry.userAgent,
                start: indexStart, end: probeEnd),
              probe.count >= 16 else {
            log("session \(id8): sidx \(fileLabel) đọc hỏng ở probe (playlist giữ 1 segment)")
            return []
        }
        let probeBytes = [UInt8](probe)
        guard Self.boxType(probeBytes) == "sidx" else {
            log("session \(id8): sidx \(fileLabel) bỏ qua — box sau init không phải sidx (playlist giữ 1 segment)")
            return []
        }
        let boxSize = Int64(Self.u32(probeBytes, at: 0))
        // Minimum box size is version-correct: the
        // fixed header through reference_count is 32
        // bytes for version 0 and 40 bytes for
        // version 1 (probe.count >= 16 above, so the
        // version byte at offset 8 is always present).
        let minBoxSize: Int64 = probeBytes[8] == 1 ? 40 : 32
        // Written as a subtraction (safe: the guard
        // above already proved contentLength >
        // indexStart + 16) so the comparison itself can
        // never overflow, however large indexStart is.
        guard boxSize >= minBoxSize, boxSize <= entry.contentLength - indexStart else {
            log("session \(id8): sidx \(fileLabel) bỏ qua — cỡ box \(boxSize) không hợp lệ (playlist giữ 1 segment)")
            return []
        }
        let box: Data
        if boxSize <= Int64(probe.count) {
            box = probe.prefix(Int(boxSize))
        } else {
            guard let full = await fetchOriginRange(
                    origin: entry.origin, userAgent: entry.userAgent,
                    start: indexStart, end: indexStart + boxSize - 1),
                  Int64(full.count) == boxSize else {
                log("session \(id8): sidx \(fileLabel) đọc hỏng ở box đầy đủ (playlist giữ 1 segment)")
                return []
            }
            box = full
        }
        guard let segments = Self.parseSidx([UInt8](box),
                                            boxStart: indexStart,
                                            contentLength: entry.contentLength,
                                            durationSeconds: entry.durationSeconds)
        else {
            log("session \(id8): sidx \(fileLabel) parse/đối chiếu hỏng (playlist giữ 1 segment)")
            return []
        }
        log("session \(id8): sidx \(fileLabel) OK — \(segments.count) đoạn fragment (seek theo đoạn khả dụng)")
        return segments
    }

    /// One bounded range fetch against an origin URL:
    /// the bytes of exactly [start, end] (inclusive),
    /// or nil on any failure. The origin must answer
    /// 206 with exactly the requested count — anything
    /// else is not index data this parser may trust.
    private func fetchOriginRange(origin: URL, userAgent: String,
                                  start: Int64, end: Int64) async -> Data? {
        guard end >= start else { return nil }
        var request = URLRequest(url: origin)
        request.timeoutInterval = 15
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 206,
                  Int64(data.count) == end - start + 1 else { return nil }
            return data
        } catch {
            return nil
        }
    }

    /// The 4-character box type at bytes 4..<8.
    private static func boxType(_ bytes: [UInt8]) -> String {
        guard bytes.count >= 8 else { return "" }
        return String(decoding: bytes[4..<8], as: UTF8.self)
    }

    /// Big-endian UInt16 at a byte offset (0 when the
    /// offset is out of bounds — callers validate the
    /// layout before trusting a parsed value).
    private static func u16(_ bytes: [UInt8], at offset: Int) -> Int {
        guard offset >= 0, offset + 2 <= bytes.count else { return 0 }
        return Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
    }

    /// Big-endian UInt32 at a byte offset (same
    /// out-of-bounds contract as u16).
    private static func u32(_ bytes: [UInt8], at offset: Int) -> Int64 {
        guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
        return Int64(bytes[offset]) << 24
            | Int64(bytes[offset + 1]) << 16
            | Int64(bytes[offset + 2]) << 8
            | Int64(bytes[offset + 3])
    }

    /// Big-endian UInt64 at a byte offset (same
    /// out-of-bounds contract as u16). Unsigned on
    /// purpose (gate round 1, FL-358): the sidx v1
    /// first_offset is a 64-bit UNSIGNED field — reading
    /// it into a signed Int64 reinterprets values
    /// >= 2^63 as negative offsets. Callers must
    /// range-check before converting to Int64.
    private static func u64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        guard offset >= 0, offset + 8 <= bytes.count else { return 0 }
        let high = u32(bytes, at: offset)
        let low = u32(bytes, at: offset + 4)
        return UInt64(high) << 32 | UInt64(low)
    }

    /// Parse a complete sidx box (ISO/IEC 14496-12:
    /// version 0 carries 32-bit first_offset, version 1
    /// 64-bit; each reference is 12 bytes —
    /// reference_type(1) + referenced_size(31),
    /// subsegment_duration(32), SAP fields(32)) into
    /// the file's fragment list. Nil on any
    /// inconsistency: a non-media reference, a zero
    /// size or duration, a fragment tiling that runs
    /// past the file's content length, or a total
    /// duration wildly off the resolver's duration —
    /// a wrong index is worse than no index, because
    /// AVPlayer would seek by it. The fallback contract
    /// is total (gate round 1, FL-358): EVERY value
    /// read from the box is range-checked BEFORE it can
    /// influence a returned segment — the unsigned v1
    /// first_offset must fit a non-negative Int64, the
    /// initial tiling cursor must lie inside
    /// [boxEnd, contentLength], and each segment's end
    /// is validated BEFORE that segment is appended, so
    /// no path returns a segment whose own guard has
    /// not already passed.
    private static func parseSidx(_ bytes: [UInt8], boxStart: Int64,
                                  contentLength: Int64,
                                  durationSeconds: Double) -> [MediaSegment]? {
        guard bytes.count >= 32, boxType(bytes) == "sidx" else { return nil }
        guard boxStart >= 0 else { return nil }
        let version = bytes[8]
        let timescale = u32(bytes, at: 16)
        guard timescale > 0 else { return nil }
        let firstOffset: Int64
        let referenceCount: Int
        let entriesStart: Int
        if version == 0 {
            // Layout (ISO/IEC 14496-12): size(4) type(4)
            // version(1) flags(3) reference_ID(4)
            // timescale(4) earliest_presentation_time(4)
            // first_offset(4) reserved(2)
            // reference_count(2) — header total 32 bytes.
            guard bytes.count >= 32 else { return nil }
            // u32 tops out at 0xFFFFFFFF, so this value
            // is always a non-negative Int64.
            firstOffset = u32(bytes, at: 24)
            referenceCount = u16(bytes, at: 30)
            entriesStart = 32
        } else if version == 1 {
            // Layout (ISO/IEC 14496-12): size(4) type(4)
            // version(1) flags(3) reference_ID(4)
            // timescale(4) earliest_presentation_time(8)
            // first_offset(8) reserved(2)
            // reference_count(2) — header total 40 bytes.
            guard bytes.count >= 40 else { return nil }
            // first_offset is UNSIGNED 64-bit here:
            // reject anything that cannot be represented
            // as a non-negative Int64 byte offset at all,
            // before any arithmetic touches it.
            let rawFirstOffset = u64(bytes, at: 28)
            guard rawFirstOffset <= UInt64(Int64.max) else { return nil }
            firstOffset = Int64(rawFirstOffset)
            referenceCount = u16(bytes, at: 38)
            entriesStart = 40
        } else {
            return nil
        }
        guard referenceCount >= 2, referenceCount <= 20_000,
              entriesStart + referenceCount * 12 <= bytes.count else { return nil }
        // Validate the initial tiling cursor BEFORE the
        // loop and before any segment exists: the first
        // referenced byte must lie at or after the end
        // of this box (bytes IS the complete box, so its
        // count is the box size) and inside the file.
        // Both additions are overflow-checked — a sum
        // that traps would break the fallback contract
        // as surely as a wrong offset would.
        let (boxEnd, boxEndOverflow) = boxStart
            .addingReportingOverflow(Int64(bytes.count))
        guard !boxEndOverflow, boxEnd <= contentLength else { return nil }
        let (initialCursor, cursorOverflow) = boxEnd
            .addingReportingOverflow(firstOffset)
        guard !cursorOverflow, initialCursor >= boxEnd,
              initialCursor <= contentLength else { return nil }
        var segments: [MediaSegment] = []
        segments.reserveCapacity(referenceCount)
        var cursor = initialCursor
        var totalDuration: Double = 0
        for index in 0..<referenceCount {
            let at = entriesStart + index * 12
            let rawSize = u32(bytes, at: at)
            // reference_type is the top bit: anything
            // but 0 is an index reference, not media —
            // this parser does not follow nested sidx.
            guard rawSize >> 31 == 0 else { return nil }
            let size = rawSize & 0x7FFF_FFFF
            let durationTicks = u32(bytes, at: at + 4)
            guard size > 0, durationTicks > 0 else { return nil }
            // This segment's end is validated BEFORE
            // the segment is appended (overflow-checked
            // for the same reason as the cursor above).
            let (segmentEnd, endOverflow) = cursor
                .addingReportingOverflow(size)
            guard !endOverflow, segmentEnd <= contentLength else { return nil }
            let segmentDuration = Double(durationTicks) / Double(timescale)
            segments.append(MediaSegment(offset: cursor, length: size,
                                         durationSeconds: segmentDuration))
            totalDuration += segmentDuration
            cursor = segmentEnd
        }
        if durationSeconds > 0 {
            guard totalDuration > durationSeconds * 0.5,
                  totalDuration < durationSeconds * 1.5 else { return nil }
        }
        return segments
    }

    // MARK: Origin relay (byte ranges, streamed)

    /// One relay event from the detached origin
    /// producer. All payloads are value types — Sendable
    /// by construction ([CONTINUATION-SENDING] discipline
    /// applied to streams).
    private enum RelayEvent: Sendable {
        case head(status: Int, contentType: String,
                  contentLength: String?, contentRange: String?)
        case chunk(Data)
        case failed(String)
    }

    /// Build ONE origin fetch as a bounded, back-
    /// pressured event stream (buffer of 8 events ≈
    /// 2 MB of chunks). The policy is .bufferingOldest
    /// on purpose: per the stdlib doc, when the buffer
    /// is full this policy "discard[s] the newly
    /// received element", "keeping at most the
    /// specified number of oldest values" — so a yield
    /// returns .dropped carrying the very event that
    /// was NOT buffered, and events already buffered
    /// are never evicted. The producer therefore WAITS
    /// and retries that same event, and bytes are
    /// neither lost nor duplicated. That makes the
    /// header's "never buffered whole" claim
    /// structural, not a hope about relative speeds.
    ///
    /// 2.0.44 — WHERE the bytes come from changed; the
    /// stream above did not. The pre-fix producer
    /// iterated URLSession.AsyncBytes element by
    /// element (one async hop per byte) and emitted
    /// nothing until 256 KB had accumulated: the
    /// 2.0.43 diagnosis convicted that as the
    /// pathological startup (first chunk at 12–23 s,
    /// position pinned at 0, the 20 s stall watchdog
    /// condemning a live item). The producer now
    /// drains JoeYtOriginFetch — a data task whose
    /// URLSessionDataDelegate hands over network-sized
    /// Data BLOCKS as they arrive — and emits its
    /// FIRST chunk at 32 KB (the init segment plus the
    /// first GOPs are all AVPlayer needs to frame),
    /// then ~256 KB chunks. The producer also counts
    /// the bytes it has taken from the origin and logs
    /// a flow line per 1 MB (spec §5.3): paired with
    /// the relay's consumer-side flow lines, the next
    /// log separates "origin stopped feeding" from
    /// "client stopped draining" without a new round.
    ///
    /// Static and parameter-fed on purpose (FL-341): the
    /// detached producer below captures ONLY the immutable
    /// Sendable parameters and the stream continuation,
    /// and the URLRequest is assembled INSIDE the detached
    /// task from them. Building and mutating the request
    /// in the @MainActor caller made it a main-actor-region
    /// value, and Swift 6 rejected capturing it into the
    /// producer's `sending` closure (CI run #21).
    private static func originEvents(originURL: URL, userAgent: String,
                                     fallbackType: String,
                                     rangeHeader: String?,
                                     headOnly: Bool,
                                     flowPath: String) -> AsyncStream<RelayEvent> {
        AsyncStream<RelayEvent>(bufferingPolicy: .bufferingOldest(8)) { continuation in
            let producer = Task.detached(priority: .userInitiated) {
                // Returns false when the consumer is
                // gone (terminated / cancelled).
                func emit(_ event: RelayEvent) async -> Bool {
                    while !Task.isCancelled {
                        let result = continuation.yield(event)
                        if case .terminated = result { return false }
                        if case .dropped = result {
                            try? await Task.sleep(nanoseconds: 10_000_000)
                            continue
                        }
                        return true
                    }
                    return false
                }
                // The request is assembled here, inside
                // the detached task (FL-341 — see the
                // note above).
                var request = URLRequest(url: originURL)
                request.timeoutInterval = 30
                // A HEAD probe is answered with a HEAD to
                // the origin too (review round 7, MINOR):
                // issuing a full GET and discarding the
                // body after the headers wasted an origin
                // download per probe.
                if headOnly { request.httpMethod = "HEAD" }
                request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                if let rangeHeader {
                    request.setValue(rangeHeader, forHTTPHeaderField: "Range")
                }
                let fetch = JoeYtOriginFetch(fallbackType: fallbackType)
                fetch.start(request: request)
                // Any exit below — normal end, consumer
                // gone, cancellation — releases the data
                // task; after a normal completion this is
                // a no-op (the fetch already invalidated
                // its session).
                defer { fetch.cancel() }
                var buffer = Data()
                buffer.reserveCapacity(256 * 1024)
                var firstChunkPending = true
                var producedBytes: Int64 = 0
                var nextFlowMark: Int64 = 1_048_576
                var failureMessage: String?
                var consumerGone = false
                drain: for await block in fetch.blocks {
                    switch block {
                    case .head(let status, let contentType,
                               let contentLength, let contentRange):
                        guard await emit(.head(
                            status: status, contentType: contentType,
                            contentLength: contentLength,
                            contentRange: contentRange)) else {
                            consumerGone = true
                            break drain
                        }
                    case .data(let data):
                        fetch.consumed(bytes: data.count)
                        producedBytes += Int64(data.count)
                        buffer.append(data)
                        // First chunk at 32 KB so the
                        // init segment + first frames
                        // reach AVPlayer immediately;
                        // ~256 KB chunks after that keep
                        // the event rate low (2.0.44).
                        let threshold = firstChunkPending
                            ? 32 * 1024 : 256 * 1024
                        if buffer.count >= threshold {
                            guard await emit(.chunk(buffer)) else {
                                consumerGone = true
                                break drain
                            }
                            buffer.removeAll(keepingCapacity: true)
                            firstChunkPending = false
                        }
                        if producedBytes >= nextFlowMark {
                            DiagLog.write("YT-HLS",
                                "flow producer \(flowPath): đã nhận \(producedBytes) byte từ origin")
                            nextFlowMark += 1_048_576
                        }
                    case .failed(let message):
                        failureMessage = message
                    }
                }
                if !consumerGone {
                    if !buffer.isEmpty {
                        _ = await emit(.chunk(buffer))
                    }
                    if let failureMessage {
                        _ = await emit(.failed(failureMessage))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    /// The Range header for a resume fetch, computed
    /// from AVPlayer's ORIGINAL range and the bytes
    /// already delivered against it (FL-343 A): the
    /// resume asks for exactly the undelivered remainder
    /// of the original window. Nil when the original
    /// range cannot be continued (suffix form, multi-
    /// range, unparseable) — the caller then closes
    /// instead of guessing at byte offsets.
    private static func resumeRange(originalRange: String?,
                                    bytesSent: Int64) -> (header: String, start: Int64)? {
        guard let originalRange else {
            // No range was requested: the response is the
            // whole file from byte 0, so the remainder
            // starts exactly at the delivered count.
            return ("bytes=\(bytesSent)-", bytesSent)
        }
        let trimmed = originalRange.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("bytes=") else { return nil }
        let spec = trimmed.dropFirst("bytes=".count)
        let parts = spec.split(separator: "-", maxSplits: 1,
                               omittingEmptySubsequences: false)
        guard parts.count == 2, let start = Int64(parts[0]) else { return nil }
        let resumeStart = start + bytesSent
        if parts[1].isEmpty {
            return ("bytes=\(resumeStart)-", resumeStart)
        }
        guard let end = Int64(parts[1]), resumeStart <= end else { return nil }
        return ("bytes=\(resumeStart)-\(end)", resumeStart)
    }

    /// Forward the request (with AVPlayer's Range, if
    /// any) to the deciphered origin and stream the reply
    /// back in ~256 KB chunks. The origin's status and
    /// range headers are relayed verbatim — AVPlayer's
    /// byte-range bookkeeping depends on them.
    ///
    /// The fetch itself runs in a DETACHED producer task
    /// that accumulates bytes into chunks off the main
    /// actor (review round 1, MINOR: iterating
    /// URLSession.AsyncBytes byte-by-byte inside this
    /// @MainActor function resumed the actor once per
    /// byte — the known-slowest consumption pattern;
    /// 2.0.44 removed the per-byte iteration itself —
    /// the producer now drains delegate-delivered Data
    /// blocks, see originEvents). Only chunk-sized
    /// events cross back here.
    ///
    /// FL-343 (A): a mid-stream origin cut no longer
    /// closes the connection on first failure. The head
    /// AVPlayer already holds promises a fixed byte
    /// count; when the origin drops part-way, the relay
    /// re-issues the fetch for the UNDELIVERED remainder
    /// of the original range (up to 3 resumes, backoff
    /// 0.5 s / 1.5 s / 1.5 s) and keeps streaming against
    /// the SAME head — AVPlayer sees one slow response,
    /// not a truncated file. The resume head is never
    /// re-sent, and a resume response is trusted only
    /// when it is a 206 whose Content-Range starts at
    /// exactly the requested resume offset.
    private func relay(_ conn: NWConnection, sessionID: String, entry: StreamEntry,
                       rangeHeader: String?, headOnly: Bool,
                       method: String, file: String) async {
        // Only immutable Sendable values cross into the
        // detached producers built below (FL-341): each
        // fetch's URLRequest is assembled inside its own
        // detached task from these lets.
        let originURL = entry.origin
        let userAgent = entry.userAgent
        let fallbackType = entry.mimeType
        let servePath = "/yt/\(sessionID.prefix(8))/\(file)"
        let resumeDelays: [UInt64] = [500_000_000, 1_500_000_000, 1_500_000_000]
        /// 2.0.44 instrumentation anchors (spec §5.3):
        /// the serve-done line measures from here, and
        /// the consumer flow lines fire per 1 MB handed
        /// to AVPlayer.
        let relayStartedAt = Date()
        var nextConsumerMark: Int64 = 1_048_576

        var headSent = false
        var bytesSent: Int64 = 0
        /// The status of the FIRST head (the one AVPlayer
        /// holds): resumes are armed only for a 2xx head
        /// (review round 1, Lens C F-C5).
        var headStatus: Int?
        /// Whether the FIRST head was 2xx — the first-
        /// media-bytes milestone only counts behind a
        /// good head (2.0.44).
        var headWas2xx = false
        /// The body byte count the FIRST head promised
        /// AVPlayer; resumes stream against this same
        /// promise, so completeness is judged against it.
        var expectedBytes: Int64?
        var attempt = 0                    // 0 = original fetch; 1...3 = resumes
        var effectiveRange = rangeHeader
        var expectedResumeStart: Int64 = 0

        // 2.0.44 instrumentation (spec §5.3): the Range
        // AVPlayer asked for opens this request's serve
        // record — byte offsets only, never an origin
        // URL. (The pre-fix log's first word about a
        // media request was the head-status line, which
        // read as a completed serve; see the head case.)
        log("serve \(method) \(servePath) — range AVPlayer xin: \(rangeHeader ?? "(không có — cả file)")")

        while true {
            var failure: String?
            var clientGone = false
            var finished = false
            let events = Self.originEvents(
                originURL: originURL, userAgent: userAgent,
                fallbackType: fallbackType,
                rangeHeader: effectiveRange, headOnly: headOnly,
                flowPath: servePath)
            stream: for await event in events {
                switch event {
                case .head(let status, let contentType, let contentLength, let contentRange):
                    if attempt > 0 {
                        // A resume's head is NEVER relayed
                        // (AVPlayer already holds the first
                        // one). Trust the resume only when
                        // the origin answered 206 starting
                        // at exactly the byte we asked for;
                        // anything else would corrupt the
                        // byte accounting, so it counts as
                        // a failed attempt.
                        let rangeStart = contentRange
                            .flatMap { Self.contentRangeStart($0) }
                        if status != 206 || rangeStart != expectedResumeStart {
                            failure = "origin trả status \(status) cho lần nối tiếp (cần 206 từ byte \(expectedResumeStart))"
                            break stream
                        }
                        continue stream
                    }
                    if status >= 400 {
                        // Design §4.4's logging point: an
                        // upstream failure is recorded with
                        // its STATUS at the layer that sees
                        // it (FL-076) — never the URL. The
                        // status still relays verbatim to
                        // AVPlayer; recovery from a dead
                        // origin is the player model's
                        // item-level re-resolve leg.
                        log("relay: upstream trả status \(status) cho một segment")
                    }
                    var head = "HTTP/1.1 \(status) \(Self.statusText(status))\r\n"
                    head += "Content-Type: \(contentType)\r\n"
                    head += "Accept-Ranges: bytes\r\n"
                    if let contentLength {
                        head += "Content-Length: \(contentLength)\r\n"
                        expectedBytes = Int64(contentLength)
                    }
                    if let contentRange {
                        head += "Content-Range: \(contentRange)\r\n"
                    }
                    head += "Connection: close\r\n\r\n"
                    guard await send(conn, data: Data(head.utf8)) else {
                        clientGone = true
                        break stream
                    }
                    headSent = true
                    headStatus = status
                    headWas2xx = (200..<300).contains(status)
                    // 2.0.44 (spec §2.3): this line is
                    // written when the HEAD is sent, and
                    // it must SAY that — the pre-fix text
                    // ("serve … → 206") read as if media
                    // had been delivered, when it proved
                    // only that headers had flowed. The
                    // origin head itself (status + the
                    // length/range it promised) is part
                    // of the same line; the first media
                    // bytes get their own milestone at
                    // the first chunk below.
                    log("serve-head \(method) \(servePath) → \(status) — origin head: len=\(contentLength ?? "-") range=\(contentRange ?? "-") (mốc head — chưa giao byte media nào)")
                    if headOnly {
                        finished = true
                        break stream
                    }
                case .chunk(let data):
                    guard await send(conn, data: data) else {
                        clientGone = true
                        break stream
                    }
                    let firstMedia = bytesSent == 0
                    bytesSent += Int64(data.count)
                    // The first-segment milestone fires
                    // HERE now (2.0.44, spec §2.3): the
                    // first body bytes have actually been
                    // handed to AVPlayer — at head-send
                    // (the pre-fix call site) it certified
                    // a delivery that had not happened.
                    if firstMedia, headWas2xx {
                        noteFirstMediaServed(sessionID: sessionID)
                    }
                    if bytesSent >= nextConsumerMark {
                        log("flow consumer \(servePath): đã giao \(bytesSent) byte cho AVPlayer")
                        nextConsumerMark += 1_048_576
                    }
                case .failed(let message):
                    failure = message
                    break stream
                }
            }
            if clientGone || finished {
                logServeDone(method: method, path: servePath,
                             bytes: bytesSent, expected: expectedBytes,
                             startedAt: relayStartedAt,
                             outcome: clientGone
                                ? "client đóng kết nối"
                                : "xong (HEAD — không body)")
                close(conn)
                return
            }
            // A stream that ended WITHOUT a failure event
            // is complete only if it delivered every byte
            // the first head promised (review round 1,
            // Lens C F-C4): an origin that closes early
            // but politely — including a resume whose own
            // Content-Range ends short — is short exactly
            // like one that errors, so the shortfall is
            // judged here, against the FIRST head's
            // promise, and flows into the same resume
            // machinery below.
            var failureMessage = failure
            if failureMessage == nil, let expectedBytes,
               bytesSent < expectedBytes {
                failureMessage = "origin đóng sớm — mới chuyển \(bytesSent)/\(expectedBytes) byte"
            }
            guard let failure = failureMessage else {
                // No failure, and every promised byte
                // delivered: the body is complete.
                logServeDone(method: method, path: servePath,
                             bytes: bytesSent, expected: expectedBytes,
                             startedAt: relayStartedAt,
                             outcome: "đủ byte — hoàn tất")
                close(conn)
                return
            }
            if !headSent {
                log("relay: origin lỗi mạng — \(failure)")
                log("serve \(method) \(servePath) → 502")
                logServeDone(method: method, path: servePath,
                             bytes: bytesSent, expected: expectedBytes,
                             startedAt: relayStartedAt,
                             outcome: "origin lỗi trước head — trả 502")
                respondText(conn, status: 502, body: "origin error", headOnly: headOnly)
                return
            }
            // The head is already with AVPlayer. If every
            // promised byte was in fact delivered (the
            // origin cut the connection on its final
            // flush), there is nothing to resume.
            if let expectedBytes, bytesSent >= expectedBytes {
                log("relay: origin đứt ở cuối — đã đủ \(bytesSent) byte theo head, đóng bình thường")
                logServeDone(method: method, path: servePath,
                             bytes: bytesSent, expected: expectedBytes,
                             startedAt: relayStartedAt,
                             outcome: "đủ byte — origin đứt ở lần flush cuối")
                close(conn)
                return
            }
            // No resumes behind an error head (review
            // round 1, Lens C F-C5): AVPlayer has already
            // rejected a ≥400 response, and a resume would
            // demand a 206 the origin will not give —
            // three attempts and their backoffs would
            // only delay the close.
            guard !headOnly, attempt < resumeDelays.count,
                  let headStatus, (200..<300).contains(headStatus),
                  let resume = Self.resumeRange(originalRange: rangeHeader,
                                                bytesSent: bytesSent) else {
                log("relay: origin đứt giữa chừng — \(failure); không nối tiếp được nữa — đóng kết nối")
                logServeDone(method: method, path: servePath,
                             bytes: bytesSent, expected: expectedBytes,
                             startedAt: relayStartedAt,
                             outcome: "origin đứt giữa chừng — đóng kết nối")
                close(conn)
                return
            }
            attempt += 1
            effectiveRange = resume.header
            expectedResumeStart = resume.start
            log("relay: origin đứt giữa chừng — \(failure); nối tiếp lần \(attempt) từ byte \(resume.start) (đã chuyển \(bytesSent) byte)")
            try? await Task.sleep(nanoseconds: resumeDelays[attempt - 1])
        }
    }

    /// The start offset of a Content-Range header value
    /// ("bytes 200-399/1234" → 200); nil for any other
    /// shape (including the "*" total form).
    private static func contentRangeStart(_ value: String) -> Int64? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("bytes ") else { return nil }
        let rangePart = trimmed.dropFirst("bytes ".count)
        guard let dash = rangePart.firstIndex(of: "-") else { return nil }
        return Int64(rangePart[..<dash])
    }

    /// Design §4.4 logging point: the first media
    /// bytes of a session DELIVERED to the client,
    /// logged once (the session's flag latches). The
    /// millisecond figure is measured from
    /// Session.createdAt — the moment makeSession
    /// registered the session, the per-session start
    /// milestone this file already keeps. A HEAD probe
    /// never reaches here (it returns at the head), so
    /// only a real GET relay with a 2xx upstream head
    /// counts. No URL is logged.
    ///
    /// 2.0.44 (spec §2.3): the pre-fix milestone
    /// (noteFirstSegmentServed) was noted at HEAD-send
    /// and its text claimed a served segment — in the
    /// 2.0.43 session log, "484 ms" certified headers,
    /// not media. The call site is now the first chunk
    /// actually sent, and the text says bytes.
    private func noteFirstMediaServed(sessionID: String) {
        guard var session = sessions[sessionID],
              !session.firstSegmentServed else { return }
        session.firstSegmentServed = true
        sessions[sessionID] = session
        let ms = Int(Date().timeIntervalSince(session.createdAt) * 1000)
        log("session \(sessionID.prefix(8)) — byte media đầu tiên đã giao cho AVPlayer sau \(ms) ms (mốc: createdAt của session)")
    }

    /// 2.0.44 (spec §5.3): the uniform close-out line
    /// of every media relay — bytes actually delivered
    /// against the first head's promise, wall time,
    /// and how the serve ended. Written at EVERY relay
    /// exit, so a request's record always ends with
    /// numbers, never with the head line alone.
    private func logServeDone(method: String, path: String, bytes: Int64,
                              expected: Int64?, startedAt: Date,
                              outcome: String) {
        let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
        let expectedText = expected.map { "\($0)" } ?? "-"
        log("serve-done \(method) \(path) — bytes=\(bytes) expected=\(expectedText) ms=\(ms) outcome=\(outcome)")
    }

    private static func statusText(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 416: return "Range Not Satisfiable"
        case 502: return "Bad Gateway"
        default: return "Status"
        }
    }

    // MARK: Small responses

    private func respondText(_ conn: NWConnection, status: Int, body: String,
                             contentType: String = "text/plain; charset=utf-8",
                             headOnly: Bool = false) {
        let bodyData = Data(body.utf8)
        // The whole head is ONE immutable let, built in a
        // single expression before the Task below reads
        // it (FL-341): no += mutation of a value a
        // closure captures.
        let head = "HTTP/1.1 \(status) \(Self.statusText(status))\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(bodyData.count)\r\n"
            + "Connection: close\r\n\r\n"
        Task { [weak self] in
            guard let self else { return }
            guard await self.send(conn, data: Data(head.utf8)) else {
                self.close(conn)
                return
            }
            if !headOnly {
                _ = await self.send(conn, data: bodyData)
            }
            self.close(conn)
        }
    }

    /// FL-350 (leg 2): respondText's Data-bodied twin
    /// (the subtitle route serves stored VTT bytes
    /// byte-exact — a String round-trip could rewrite
    /// them). Same head discipline: one immutable head
    /// value, built before the Task reads it (FL-341).
    private func respondData(_ conn: NWConnection, status: Int, data: Data,
                             contentType: String,
                             headOnly: Bool = false) {
        let head = "HTTP/1.1 \(status) \(Self.statusText(status))\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(data.count)\r\n"
            + "Connection: close\r\n\r\n"
        Task { [weak self] in
            guard let self else { return }
            guard await self.send(conn, data: Data(head.utf8)) else {
                self.close(conn)
                return
            }
            if !headOnly {
                _ = await self.send(conn, data: data)
            }
            self.close(conn)
        }
    }

    /// One send, awaited. The completion resumes with a
    /// Bool — Sendable by construction.
    private func send(_ conn: NWConnection, data: Data) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            conn.send(content: data, completion: .contentProcessed { error in
                cont.resume(returning: error == nil)
            })
        }
    }
}

// MARK: - Origin fetch (block delivery, 2.0.44)

/// One origin fetch's block source: a URLSession data
/// task whose delegate (URLSessionDataDelegate,
/// Foundation) hands over network-sized Data BLOCKS
/// as they arrive, bridged into an AsyncStream the
/// relay producer drains. This replaces the pre-2.0.44
/// consumption pattern — iterating URLSession.AsyncBytes
/// one element per async hop — which the 2.0.43
/// diagnosis convicted as the pathological startup
/// cost: the first 256 KB chunk took 12–23 s to
/// assemble while AVPlayer sat at position 0.
///
/// Flow control is real, not hopeful. The delegate
/// counts bytes handed to the stream but not yet taken
/// by the producer; past the high-water mark it
/// SUSPENDS the task (URLSessionTask.suspend), and the
/// producer resumes it (consumed(bytes:)) once the
/// backlog drains below the low-water mark. The
/// stream's policy is .unbounded because dropping an
/// origin block is never an option (a dropped block is
/// a hole in the media) — the suspend/resume pair is
/// what bounds the depth in practice.
///
/// Threading: delegate callbacks arrive on the
/// session's serial delegate queue; the producer side
/// runs in the relay's detached task. Every mutable
/// slot sits behind `lock`, the continuation is only
/// ever yielded to (AsyncStream continuations are
/// thread-safe), and NOTHING here is captured by a
/// closure — the object owns its state, so there is
/// no FL-341 capture surface. @unchecked Sendable on
/// exactly that basis.
private final class JoeYtOriginFetch: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    enum Block: Sendable {
        case head(status: Int, contentType: String,
                  contentLength: String?, contentRange: String?)
        case data(Data)
        case failed(String)
    }

    let blocks: AsyncStream<Block>
    private let continuation: AsyncStream<Block>.Continuation
    private let fallbackType: String

    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var handedOutBytes: Int64 = 0
    private var takenBytes: Int64 = 0
    private var taskSuspended = false
    private var terminated = false

    private static let highWater: Int64 = 4 * 1024 * 1024
    private static let lowWater: Int64 = 1 * 1024 * 1024

    init(fallbackType: String) {
        self.fallbackType = fallbackType
        var captured: AsyncStream<Block>.Continuation?
        blocks = AsyncStream<Block>(bufferingPolicy: .unbounded) { captured = $0 }
        continuation = captured!
        super.init()
        continuation.onTermination = { [weak self] _ in
            self?.cancel()
        }
    }

    func start(request: URLRequest) {
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.name = "joetv.yt.originfetch"
        let created = URLSession(configuration: .default,
                                 delegate: self,
                                 delegateQueue: delegateQueue)
        let dataTask = created.dataTask(with: request)
        lock.lock()
        session = created
        task = dataTask
        lock.unlock()
        dataTask.resume()
    }

    /// Producer side: one block has been taken from
    /// the stream. If the task is suspended and the
    /// backlog has drained below the low-water mark,
    /// resume it.
    func consumed(bytes: Int) {
        lock.lock()
        takenBytes += Int64(bytes)
        let shouldResume = taskSuspended
            && (handedOutBytes - takenBytes) < Self.lowWater
        if shouldResume {
            taskSuspended = false
            // resume() is issued WHILE HOLDING the lock, so
            // the flag can never diverge from the task's real
            // state. suspend()/resume() are synchronous
            // URLSessionTask calls that never synchronously
            // invoke delegate methods, so holding the NSLock
            // across the call cannot deadlock against the
            // delegate queue.
            task?.resume()
        }
        lock.unlock()
    }

    /// Release the fetch (consumer gone, producer
    /// finished, or stream terminated). Idempotent;
    /// a no-op after normal completion.
    func cancel() {
        lock.lock()
        if terminated {
            lock.unlock()
            return
        }
        terminated = true
        let liveTask = task
        let liveSession = session
        task = nil
        session = nil
        lock.unlock()
        liveTask?.cancel()
        liveSession?.invalidateAndCancel()
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        continuation.yield(.head(
            status: http?.statusCode ?? 200,
            contentType: http?.value(forHTTPHeaderField: "Content-Type") ?? fallbackType,
            contentLength: http?.value(forHTTPHeaderField: "Content-Length"),
            contentRange: http?.value(forHTTPHeaderField: "Content-Range")))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        continuation.yield(.data(data))
        lock.lock()
        handedOutBytes += Int64(data.count)
        let shouldSuspend = !taskSuspended
            && (handedOutBytes - takenBytes) > Self.highWater
        if shouldSuspend {
            taskSuspended = true
            // suspend() is issued WHILE HOLDING the lock, so
            // the flag can never diverge from the task's real
            // state. suspend()/resume() are synchronous
            // URLSessionTask calls that never synchronously
            // invoke delegate methods, so holding the NSLock
            // across the call cannot deadlock against the
            // delegate queue.
            dataTask.suspend()
        }
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error {
            // A cancel WE issued (the consumer went
            // away; the producer is finishing) is not
            // an origin failure — the pre-fix shape
            // surfaced it as .failed into a stream
            // whose consumer had already left, so
            // silence here is equivalent, and a client
            // abort is never misread downstream as an
            // origin fault.
            let nsError = error as NSError
            let selfCancelled = nsError.domain == NSURLErrorDomain
                && nsError.code == NSURLErrorCancelled
            if !selfCancelled {
                continuation.yield(.failed(error.localizedDescription))
            }
        }
        continuation.finish()
        lock.lock()
        let liveSession = self.session
        self.session = nil
        self.task = nil
        lock.unlock()
        liveSession?.finishTasksAndInvalidate()
    }
}
