import SwiftUI
import AVKit

// MARK: - Native YouTube player (AVQueuePlayer spine)
//
// The playback leg of the native YouTube route. Ported
// from the probe's proven player shape (Probe 3+7:
// AVQueuePlayer + prefetch insert + clean auto-advance
// on the owner's TV) and fed by the resolver + the local
// HLS assembly:
//
// - The current episode resolves and plays IMMEDIATELY;
//   exactly ONE next episode is pre-resolved behind it
//   (hiding the ~2.4 s solver cost) and inserted into the
//   same queue — prefetch depth is 1, never a second
//   player pulling media in parallel (FL-065).
// - Auto-advance is the queue's own. Manual next lives
//   in the player's OWN transport bar
//   (AVPlayerViewController.transportBarCustomMenuItems —
//   the Q1 ruling): NO press is consumed on this surface.
//   The window-level press consumer that used to eat
//   Right-arrow here is DELETED (FL-349): it starved the
//   native seek and broke the subtitle panel, because it
//   fired panel-unaware while the panel was open. Right/
//   Left are the native seek, the Down-panel with the
//   subtitle/audio pickers is fully native, and a manual
//   advance fires through a readiness gate (below) so it
//   never jumps into an item that cannot frame yet.
// - NO focusable SwiftUI buttons overlay the player
//   (the 2026-11-20 11:15 device lesson: AVPlayerView-
//   Controller traps focus — overlay buttons are
//   unreachable). Slates (veil / failure / end) appear
//   only when the player is NOT the live surface.
// - Every resolve/advance chain runs through ONE
//   in-flight gate and carries an attempt token
//   (FL-330 rules 4–5, FL-041): a late completion of a
//   superseded attempt never touches the live player,
//   and state verdicts read the same quantities on both
//   sides (currentItem identity + timeControlStatus).
// - A stalled or failed item gets ONE re-resolve of the
//   same episode (fresh signed URLs), seeking back to
//   the last vouched checkpoint; behind the re-resolve
//   stands the FL-347 muxed tier — ONE swap to the
//   current playable's muxed fallback — and only a
//   failure past both tiers is terminal and hands back
//   through the same Auto fall-through wiring the page
//   player uses.

@MainActor
final class JoeYtNativePlayerModel: ObservableObject {
    @Published private(set) var phase: Phase = .starting
    @Published private(set) var currentIndex: Int
    @Published var statusLine: String?

    enum Phase: Equatable {
        case starting
        case playing
        case failed(String)
        case ended
    }

    let player = AVQueuePlayer()
    private let request: JoeYtPlayRequest
    private let firstPlayable: JoeYtPlayable

    private var started = false
    private var terminal = false
    /// Monotonic attempt token: bumped by every new
    /// resolve/advance/recovery chain; completions check
    /// it before touching the player (FL-041).
    private var attempt = 0
    /// The FL-330 in-flight gate: one operation chain at
    /// a time on this player.
    private var opInFlight = false
    private var prefetchTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var supervisorTask: Task<Void, Never>?
    /// The queue item currently carrying the NEXT episode
    /// (inserted by prefetch), and the index it belongs
    /// to. Nil while a prefetch is still resolving.
    private var queuedItem: AVPlayerItem?
    private var queuedIndex: Int?
    /// Set when the owner pressed Next before the
    /// prefetched item landed: the advance fires the
    /// moment the insert completes.
    private var advancePending = false
    /// Stall bookkeeping: how long the current item has
    /// been continuously waiting, and whether the ONE
    /// re-resolve recovery has been spent on it.
    private var waitingSince: Date?
    private var recoverySpent = false
    /// FL-347: the playable the CURRENT item was built
    /// from, retained so the terminal doors can still
    /// reach its muxed fallback after the assembly item
    /// exists. buildItem consumes the playable it is
    /// handed, and the pre-fix model kept only
    /// firstPlayable — by the time an item stalled
    /// terminally, the muxed URL was held nowhere and
    /// the muxed tier was unreachable by construction.
    /// Assigned wherever an item becomes current:
    /// start(), the recovery completion, and the
    /// supervisor's transition block (promoted from
    /// queuedPlayable). Prefetch alone never writes it.
    private var currentPlayable: JoeYtPlayable?
    /// The playable behind the prefetched queue entry,
    /// promoted to currentPlayable only when the
    /// supervisor's transition bookkeeping confirms the
    /// queued item actually became current.
    private var queuedPlayable: JoeYtPlayable?
    /// FL-349 (2.0.45, leg 1): the HLS session behind
    /// the prefetched queue entry (the makeSession
    /// handle), kept beside queuedItem so the advance
    /// gate can ask the server whether the item's first
    /// media byte has actually been served. Nil for
    /// non-assembly items.
    private var queuedSessionID: String?
    /// FL-351 Branch D (2.0.45, leg 4): the height of
    /// the variant ACTUALLY in the player / in the
    /// queue — the figure the status pill and the start
    /// veil speak. Probe 18 closed every client door
    /// above the per-title ceiling, so the app states
    /// the true level instead of leaving it to
    /// guesswork (§6.3 Branch D). Tracked per BUILT
    /// item, not per playable: an assembly build that
    /// fell back to the muxed file plays the muxed
    /// height, and the label follows the item. Assigned
    /// wherever an item is built for currency (start,
    /// recovery, the muxed swap) and promoted with the
    /// queue bookkeeping in the transition block.
    private var currentItemHeight = 0
    private var queuedItemHeight = 0

    /// The spoken quality label for a variant height
    /// ("480p"); empty when the height is unknown (an
    /// HLS-manifest playable carries no fixed variant) —
    /// the display then says nothing rather than
    /// guessing.
    static func qualityText(height: Int) -> String {
        height > 0 ? "\(height)p" : ""
    }

    /// The starting episode's quality label (the veil).
    /// Once the first item is BUILT, its own height is
    /// the truth (an assembly build that fell back to
    /// the muxed file plays the muxed height — gate
    /// round 1, B-1); before the build lands, the
    /// playable's height is the only figure there is.
    var startingQualityLabel: String {
        Self.qualityText(height: currentItemHeight > 0
                         ? currentItemHeight : firstPlayable.height)
    }
    /// FL-349 (2.0.45, leg 1): the manual-advance
    /// readiness gate's stamp. A MANUAL advance (the
    /// transport-bar menu action — the only manual
    /// entry) stamps the moment it arms; the advance
    /// then fires only when the queued item can
    /// actually frame (readyToPlay + ≥3 s buffered, or
    /// the session's first media byte served), checked
    /// at the arm-consumption points and on every
    /// supervisor tick, with a hard 10 s cap after
    /// which it fires anyway. Queue auto-advance and
    /// the episode-end paths never stamp — the gate
    /// binds manual advance only. The FL-330
    /// advancePending lifecycle is untouched: the stamp
    /// is a condition ON TOP of its consumption points,
    /// never a replacement for them.
    private var gatedAdvanceArmedAt: Date?
    /// FL-347: the muxed swap tier's spent flag — ONE
    /// muxed attempt per episode, reset exactly where
    /// recoverySpent resets (the transition block and
    /// retry()).
    private var muxedSpent = false
    /// 2.0.44 watchdog: whether the CURRENT item has
    /// ever been observed playing — its startup window
    /// is over. Reset wherever a new item becomes
    /// current; the waiting leg's threshold keys on it
    /// (45 s while starting up, 20 s mid-episode).
    private var currentItemFramed = false
    /// FL-485 (2.1.6): the CURRENT item has ENDED
    /// (AVPlayerItemDidPlayToEndTime fired for it). The
    /// stall watchdog reads this: an ended item parked at
    /// pos == duration is ENDED, never a mid-episode
    /// freeze, and must never draw recoverOrFail /
    /// terminalFailure. Set at the top of
    /// handleItemEnded; cleared wherever a new item
    /// becomes current (start, the supervisor's
    /// transition block, the recovery completion, the
    /// muxed swap, the FL-484 loopback re-presentation)
    /// and in retry().
    private var currentItemEnded = false
    /// FL-484 (2.1.6): the loopback-connect retry budget
    /// for the CURRENT item — a bounded count of
    /// same-playable re-presentations spent on a local
    /// connect refusal WITHOUT consuming recoverySpent.
    /// Reset at the same points as currentItemEnded.
    private var loopbackRetries = 0
    /// FL-485 (2.1.6): the status observation on the
    /// QUEUED successor item. Until now a queued item
    /// carried no status observer at all — a successor
    /// that failed (or never loaded) while queued was
    /// invisible until the current item ended and the
    /// queue silently failed to advance (the convicted
    /// specimen: a queued ep=4 item with zero requests to
    /// its session in 23 minutes). Installed at both
    /// insert sites; invalidated wherever the queue
    /// bookkeeping is cleared.
    private var queuedStatusObservation: NSKeyValueObservation?
    /// 2.0.44 watchdog: the waiting leg's progress
    /// baselines. While the playhead or the loaded
    /// buffer end keeps moving, the waiting deadline
    /// re-baselines — an item that is still loading is
    /// never condemned (the 2.0.43 incident: the flat
    /// 20 s leg fired at 20 s; the item framed at
    /// 22.9 s).
    private var waitingProgressPosition: Double = 0
    private var waitingProgressBuffer: Double = 0
    private var firstFrameLogged = false
    private var playStartedAt = Date()
    /// The last position the supervisor itself vouched
    /// for (the recovery seek checkpoint — FL-041: the
    /// target is remembered, never re-derived from a
    /// collapsed playhead).
    private var checkpointSeconds: Double = 0
    /// The owner's manual subtitle/audio picks, captured
    /// from the outgoing item and re-applied to the next
    /// (FL-049) — the player's own UI writes them; the
    /// model only carries them across items.
    private var manualSelections: [AVMediaCharacteristic: AVMediaSelectionOption?] = [:]
    private var itemStatusObservation: NSKeyValueObservation?
    /// FL-499 witness (log-only): timeControlStatus
    /// transitions, so pause provenance is provable from
    /// DiagLog.
    private var timeControlObservation: NSKeyValueObservation?
    private var lastLoggedTimeControl: AVPlayer.TimeControlStatus?
    /// FL-499 witness (log-only): the current item's
    /// selected legible/audible options, re-read by the
    /// supervisor; a change WITHIN an item is logged (the
    /// item-start selection keeps its own line), so a
    /// subtitle pick made in the player's panel is
    /// provable from DiagLog.
    /// FL-499 gate R1 F-C1: the OWNER's pause intent —
    /// set only on positive evidence (a transition to
    /// .paused on a healthy, not-ended item while the
    /// phase is starting/playing — Brief 2: the KVO is the
    /// only source, the Play/Pause bridge is deleted),
    /// cleared by any
    /// transition to playing/waiting and by retry().
    /// Recovery completions consult it before play(), and
    /// the failure funnel defers to it (deferredFailure).
    /// A bare timeControlStatus == .paused is NOT used:
    /// an item failure itself drops the player's rate, so
    /// that test would also defer every failure that hits
    /// a PLAYING episode (inference) and freeze the screen.
    private var ownerPaused = false
    /// FL-499 gate R1 F-C1: a failure that arrived while
    /// the owner had paused — held, not recovered, until
    /// the owner's next Play (native resume seen by the
    /// KVO, or a nonzero rate seen by the supervisor).
    private var deferredFailure: DeferredFailure?

    /// FL-499 gate R1 F-C2: a held failure is stamped with
    /// the episode (index + item identity) that produced
    /// it. An episode transition cancels it; a release
    /// whose stamp does not match the episode on screen
    /// drops it — it never runs against another episode.
    private struct DeferredFailure {
        var reason: String
        var loopback: Bool
        let episodeIndex: Int
        let itemID: ObjectIdentifier?
        /// The owner's Play already asked for it, but the
        /// funnel was busy (opInFlight): run when free.
        var released = false
    }
    private var selectionWitnessItem: ObjectIdentifier?
    private var selectionWitnessValue: String?
    private var selectionWitnessTick = 0
    private var endObserver: NSObjectProtocol?
    private var stallObserver: NSObjectProtocol?
    /// FL-343 (A) paused-limbo bookkeeping. The leg's
    /// precondition is POSITIVE evidence the pause is
    /// not the owner's: fireAdvance() stamps the
    /// moment (and playhead) of a model-issued
    /// advanceToNextItem, and the stamp lives until the
    /// supervisor's transition bookkeeping confirms the
    /// queue actually moved. A pause the OWNER commands
    /// can never create that stamp — the native player's
    /// transport is not routed through this model — so
    /// the leg cannot fire on a user pause BY
    /// CONSTRUCTION (review round 1, Lens C F-C2/F-C3:
    /// the earlier buffer/waiting classifier both
    /// swallowed a user pause issued mid-rebuffer and
    /// latched a real stall as a user pause when its
    /// buffer had not drained yet; a one-shot classifier
    /// cannot separate the two, so the leg keys on the
    /// model's own unconfirmed advance instead — the
    /// exact FL-343 incident shape. A mid-item stall
    /// with no advance in flight is the
    /// AVPlayerItemPlaybackStalled observer's leg, and
    /// a .waiting park is the waiting leg's.)
    private var advanceUnconfirmedSince: Date?
    private var advanceUnconfirmedPosition: Double = 0
    private var pausedStallSince: Date?
    private var pausedStallPosition: Double = 0

    var onFallThrough: ((MovieRoute) -> Void)?
    var onDetailFallThrough: ((JoeYtChainPlay) -> Void)?
    /// Design §4.6's trigger from inside the player:
    /// the native construction itself is dead (the
    /// assembly server would not start AND no muxed
    /// fallback URL exists) — the router swaps this
    /// surface for the degraded door+page player. Wired
    /// by the view from the router (review round 7,
    /// MAJOR: this hand-over did not exist — the two
    /// construction-failure exits went straight to the
    /// terminal slate/chain, skipping §4.6).
    var onPageFallback: (() -> Void)?

    /// The app's WatchStore, handed in by the view from
    /// the environment (design §3.4). Optional on
    /// purpose: progress recording must never be able
    /// to block playback — a missing store only skips
    /// the writes.
    private var watchStore: WatchStore?
    /// Supervisor ticks since the last periodic
    /// progress save, and the position that save
    /// carried (the periodic save fires on a 15 s
    /// cadence and only when the position has actually
    /// moved — the JoePlayerView points, §3.4).
    private var ticksSinceSave = 0
    private var lastSavedPosition: Double = -1
    /// FL-352 (2.0.45, leg 5): the nil-store save skip is
    /// logged ONCE per player session. The view attaches
    /// the store before start(), so a nil here means the
    /// wiring broke — the log must say so instead of the
    /// save dying silently (the banned silent-guard
    /// pattern on a user-data write path).
    private var nilStoreSaveLogged = false
    /// FL-352 (2.0.45, leg 5): the resume candidate for
    /// the STARTING episode, read from the store in
    /// start() BEFORE any save of this session can
    /// overwrite the row (the first-frame force save
    /// writes the live ~0 position). Nil = no row for
    /// this episode (or no store). Evaluated once, in
    /// the supervisor's first playing tick after the
    /// first frame.
    private var resumeCandidateSeconds: Double?
    private var resumeCandidateDuration: Double = 0
    private var resumeEvaluated = false
    /// The CURRENT item's duration, refreshed by the
    /// supervisor on every tick while that item is
    /// current (review count round 1, Lens A F-2): at
    /// the episode-transition tick, player.currentItem
    /// is ALREADY the incoming episode, so a save for
    /// the OUTGOING episode that read the live item
    /// would stamp the new episode's duration onto the
    /// old episode's row — a pos/dur pair that can
    /// exceed 1.0. The transition save passes this
    /// tracked value explicitly instead.
    private var currentDurationSeconds: Double = 0

    func attachStore(_ store: WatchStore) {
        watchStore = store
    }

    init(request: JoeYtPlayRequest, firstPlayable: JoeYtPlayable) {
        self.request = request
        self.firstPlayable = firstPlayable
        self.currentIndex = request.startIndex
    }

    var episodeLabel: String {
        "Tập \(currentIndex + 1) / \(request.videoIds.count)"
    }

    var hasNextEpisode: Bool {
        currentIndex + 1 < request.videoIds.count
    }

    private func log(_ message: String) {
        DiagLog.write("YT-PLAY", message)
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        // FL-352 (2.0.45, leg 5): capture the resume
        // candidate for the starting episode NOW, before
        // this session's saves can overwrite the row. The
        // store keeps ONE row per series (its latest
        // episode), so the candidate applies only when
        // the row's episode IS the starting one — a row
        // for another episode counts as no row at all.
        if let store = watchStore,
           let row = store.progressFor(key: WatchStore.ytProgressKey(pid: request.pid)),
           WatchStore.episodeNumber(of: row) == request.startIndex + 1 {
            resumeCandidateSeconds = Double(row.pos) / 1000
            resumeCandidateDuration = Double(row.dur) / 1000
        }
        player.automaticallyWaitsToMinimizeStalling = true
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) {
            [weak self] observed, _ in
            // Sendable values only cross to the main actor
            // (the itemStatusObservation pattern).
            let status = observed.timeControlStatus
            let seconds = observed.currentTime().seconds
            let item = observed.currentItem
            let itemHealthy = item?.status == .readyToPlay && item?.error == nil
            let duration = item?.duration.seconds ?? .nan
            let atEnd = duration.isFinite && seconds.isFinite && seconds >= duration - 1
            Task { @MainActor in
                self?.witnessTimeControl(status, at: seconds)
                self?.trackOwnerPause(status, itemHealthy: itemHealthy, atEnd: atEnd)
            }
        }
        startSupervisor()
        // The initial build chain carries the attempt
        // token like every other chain (review round 1,
        // BLOCKER 3): if any gated operation has run
        // meanwhile, this completion must not touch the
        // player.
        let startAttempt = attempt
        Task { [weak self] in
            guard let self else { return }
            let built = await self.buildItem(for: self.firstPlayable)
            // If stop() landed during buildItem, this
            // completion is stale twice over (terminal +
            // the attempt bump in stop()). A session the
            // build may have registered on the shared
            // HLS server for this now-dead player is
            // inert: it is never handed to any player,
            // its signed origins expire on their own,
            // and the server's 4-session cap evicts it
            // (review round 7, MINOR — accepted residue,
            // recorded here rather than hidden).
            guard !self.terminal, self.attempt == startAttempt else { return }
            guard let built else {
                self.handOverToPageFallback(reason: "không dựng được item đầu tiên — assembly chết và không có muxed dự phòng")
                return
            }
            let item = built.item
            self.currentPlayable = self.firstPlayable
            self.currentItemHeight = built.height
            // 2.0.48 (Approach C): a real measurement —
            // the variant this item actually plays feeds
            // the per-series ceiling map (JoeYtQualityMap).
            JoeYtQualityMap.record(pid: self.request.pid,
                                   height: built.height)
            self.currentItemFramed = false
            self.currentItemEnded = false
            self.loopbackRetries = 0
            self.player.replaceCurrentItem(with: item)
            self.observeCurrentItem(item)
            self.playStartedAt = Date()
            self.playUnlessOwnerPaused(site: "mở player")
            self.log("mở player — ep=\(self.currentIndex + 1) kind=\(self.kindName(self.firstPlayable.kind)) itag=\(self.firstPlayable.videoItag)")
            self.startPrefetch()
        }
    }

    func stop() {
        terminal = true
        // Invalidate every in-flight chain by TOKEN as
        // well as by the terminal flag (review round 7,
        // MINOR): a completion that wakes after stop()
        // is stale on both checks, not just one.
        attempt += 1
        // The end-point progress save (design §3.4):
        // the last vouched position of the episode on
        // screen leaves with the player.
        saveProgressSnapshot()
        // FL-349 (2.0.45, leg 1): no consumer clear here
        // any more — this model owns no press consumer
        // at all (registerPressConsumer is deleted), so
        // there is nothing to clear, and clearing would
        // have risked un-registering the PAGE surface's
        // own consumer on a surface swap.
        // Reset the prefetch bookkeeping synchronously —
        // the cancelled task's defer only runs if the
        // model is still alive to execute it (review
        // round 2, BLOCKER 1).
        prefetchInFlight = false
        advancePending = false
        prefetchTask?.cancel()
        statusTask?.cancel()
        supervisorTask?.cancel()
        itemStatusObservation?.invalidate()
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        // FL-485 (2.1.6): the queued successor's
        // observation dies with the player's own.
        queuedStatusObservation?.invalidate()
        queuedStatusObservation = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        if let stallObserver {
            NotificationCenter.default.removeObserver(stallObserver)
        }
        player.pause()
        player.removeAllItems()
    }

    // MARK: Item construction

    private func kindName(_ kind: JoeYtPlayable.Kind) -> String {
        switch kind {
        case .assembly: return "assembly"
        case .muxed: return "muxed"
        case .hlsManifest: return "hls"
        }
    }

    /// Item construction (assembly sessions are
    /// created here; the result is applied by the caller
    /// under its attempt token). FL-349 (2.0.45, leg 1):
    /// the result also carries the assembly session's id
    /// (the makeSession handle) so a QUEUED item's
    /// readiness can be checked against the server's
    /// first-media-served record; nil for direct items.
    /// FL-351 Branch D (2.0.45, leg 4): the result also
    /// carries the height of the variant the item
    /// ACTUALLY plays — the assembly height on the
    /// session path, the MUXED height when the build
    /// fell back to the muxed file — the figure the
    /// player's quality label speaks.
    private func buildItem(for playable: JoeYtPlayable)
        async -> (item: AVPlayerItem, sessionID: String?, height: Int)? {
        switch playable.kind {
        case .hlsManifest, .muxed:
            guard let url = playable.directURL else { return nil }
            return (AVPlayerItem(url: url), nil, playable.height)
        case .assembly:
            if let session = await JoeYtHlsServer.shared.makeSession(
                playable: playable, userAgent: playable.clientUserAgent) {
                return (AVPlayerItem(url: session.url), session.sessionID,
                        playable.height)
            }
            if let fallback = playable.fallbackDirectURL {
                log("assembly server không khởi động được — rơi xuống bản muxed dự phòng")
                return (AVPlayerItem(url: fallback), nil, playable.fallbackHeight)
            }
            return nil
        }
    }

    private func observeCurrentItem(_ item: AVPlayerItem?) {
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        if let stallObserver {
            NotificationCenter.default.removeObserver(stallObserver)
            self.stallObserver = nil
        }
        guard let item else { return }
        // [.new, .initial] (review round 2, MINOR): the
        // supervisor installs this observation up to
        // 500 ms after a queue-advanced item becomes
        // current — an item ALREADY .failed by then never
        // fires a .new-only callback and recovery would
        // wait for the 20 s stall leg instead of failing
        // over at once.
        //
        // The error text is read from the OBSERVED item
        // inside the callback (FL-343): the pre-fix
        // handler read player.currentItem?.error on the
        // main actor, which during an advance/replace is
        // a DIFFERENT item than the one that failed — its
        // error is nil, so real failures reached the log
        // (and the recovery reason) as the textless
        // "item failed (không có error text)". The read
        // itself mirrors the .status read directly above
        // it — same delivery context, property reads
        // only; the AVPlayerItem reference never crosses
        // the hop, only the two Sendable values do
        // (review round 1, Lens A F-A2).
        itemStatusObservation = item.observe(\.status, options: [.new, .initial]) {
            [weak self] observed, _ in
            let status = observed.status
            let errorText = observed.error?.localizedDescription
            // FL-484 (2.1.6): the error's domain + code ride
            // along (Sendable values, the same FL-343
            // pattern) so the failure classifier can tell a
            // loopback connect refusal from an origin
            // failure — the text alone cannot convict the
            // class.
            let nsError = observed.error as NSError?
            let errorDomain = nsError?.domain
            let errorCode = nsError?.code
            Task { @MainActor in
                self?.handleItemStatus(status, errorText: errorText,
                                       errorDomain: errorDomain,
                                       errorCode: errorCode)
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.handleItemEnded()
            }
        }
        // FL-343 (A): AVPlayer's own stall signal. The
        // incident item never failed and never ended —
        // it sat cut mid-stream while no status changed;
        // this notification is the one signal AVFoundation
        // raises for exactly that shape, and the pre-fix
        // model never subscribed to it.
        stallObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.handlePlaybackStalled()
            }
        }
    }

    private func handleItemStatus(_ status: AVPlayerItem.Status,
                                  errorText: String?,
                                  errorDomain: String? = nil,
                                  errorCode: Int? = nil) {
        guard !terminal else { return }
        switch status {
        case .readyToPlay:
            applyMediaSelections(to: player.currentItem)
            // FL-350 (2.0.45, leg 2): the apply point's
            // own evidence line — what each group actually
            // selected for THIS item, read back from the
            // item after the apply. (The comment inside
            // applyMediaSelections long claimed a per-item
            // log; this line is that log, at the call
            // point, once per item.)
            log("media selection ep=\(currentIndex + 1): legible=\(selectionLanguage(of: player.currentItem, characteristic: .legible)) audible=\(selectionLanguage(of: player.currentItem, characteristic: .audible))")
            log("item start ep=\(currentIndex + 1): \(seekWitness(of: player.currentItem))")
        case .failed:
            let message = errorText
                ?? "item failed (không có error text)"
            log("item FAILED ep=\(currentIndex + 1) — \(message)")
            let loopback = isLoopbackConnectFailure(errorDomain: errorDomain,
                                                    errorCode: errorCode,
                                                    errorText: errorText)
            if deferIfOwnerPaused(reason: message, loopback: loopback) { return }
            // FL-484 (2.1.6): classify BEFORE the cascade.
            // A loopback connect refusal against the app's
            // OWN 127.0.0.1 assembly relay is a LOCAL
            // failure class of its own: the 2026-11-24
            // trace showed it firing ~40–100 ms after
            // placement, while the wedged listener
            // momentarily refused connects, and the
            // unclassified cascade burned the ONE-SHOT
            // recovery on it exactly like a dead origin —
            // the cascade's next step then diverted to
            // the muxed swap and the episode silently
            // dropped to the muxed tier. On this class the
            // SAME assembly playable is re-presented
            // (bounded) and the recovery budget is NOT
            // consumed. Every other failure flows into
            // recoverOrFail exactly as before. This
            // handler is the single funnel for fresh open,
            // resume and autoplay-next alike — every
            // item-open surface shares this classification.
            if loopback {
                retryLoopbackItem(reason: message)
            } else {
                recoverOrFail(reason: message)
            }
        default:
            break
        }
    }

    /// FL-484 (2.1.6): the loopback connect-refusal
    /// class — the CURRENT item is an assembly item (its
    /// URL is the app's own 127.0.0.1 relay) AND the
    /// failure is a connect refusal: NSURLErrorDomain
    /// -1004 (NSURLErrorCannotConnectToHost), or the
    /// exact refusal text the incident log carried
    /// ("Could not connect to the server." — the
    /// localized text of that same code on this OS).
    private func isLoopbackConnectFailure(errorDomain: String?,
                                          errorCode: Int?,
                                          errorText: String?) -> Bool {
        guard currentPlayable?.kind == .assembly else { return false }
        if errorDomain == NSURLErrorDomain,
           errorCode == NSURLErrorCannotConnectToHost {
            return true
        }
        return errorText == "Could not connect to the server."
    }

    /// FL-484 (2.1.6): re-present the SAME assembly
    /// playable after a loopback connect refusal — a
    /// fresh item (and a fresh assembly session) on the
    /// same relay, replaced in, re-observed, sought back
    /// to the vouched checkpoint, played. Bounded at 2
    /// re-presentations per item; recoverySpent is NOT
    /// touched — a local refusal is not an origin
    /// failure, and spending the one-shot re-resolve on
    /// it is the convicted defect. On exhaustion (or a
    /// failed rebuild) the normal cascade resumes with
    /// the refusal as its reason. The completion mirrors
    /// recoverOrFail's discipline: attempt token, the
    /// in-flight gate, the episode-index revalidation,
    /// the prefetched-queue reconciliation, and the
    /// armed-advance consumption.
    private func retryLoopbackItem(reason: String) {
        guard !terminal, !opInFlight else { return }
        if deferIfOwnerPaused(reason: reason, loopback: true) { return }
        guard loopbackRetries < 2, let playable = currentPlayable else {
            log("FL-484: loopback retry đã hết (hoặc không còn playable) — về cascade thường")
            recoverOrFail(reason: reason)
            return
        }
        loopbackRetries += 1
        let myTry = loopbackRetries
        attempt += 1
        let myAttempt = attempt
        opInFlight = true
        let episodeIndex = currentIndex
        let seekTo = checkpointSeconds
        log("FL-484: loopback connect bị từ chối — dựng lại item assembly ep=\(currentIndex + 1) (thử \(myTry)/2, KHÔNG tốn recovery) — \(reason)")
        Task { [weak self] in
            guard let self else { return }
            // A short beat for the wedged listener to
            // clear before the new session's first fetch.
            try? await Task.sleep(nanoseconds: 750_000_000)
            let built = await self.buildItem(for: playable)
            guard !self.terminal, self.attempt == myAttempt else {
                self.opInFlight = false
                return
            }
            guard let built else {
                self.opInFlight = false
                self.log("FL-484: dựng lại item thất bại — về cascade thường")
                self.recoverOrFail(reason: reason)
                return
            }
            guard self.currentIndex == episodeIndex else {
                self.opInFlight = false
                self.log("FL-484: tập hiện tại đã đổi trong lúc dựng lại — bỏ replace")
                return
            }
            self.currentItemHeight = built.height
            self.currentItemFramed = false
            self.currentItemEnded = false
            self.player.replaceCurrentItem(with: built.item)
            self.observeCurrentItem(built.item)
            // The same queue reconciliation as the
            // recovery replace: a dropped prefetched item
            // must not leave stale bookkeeping behind.
            if let queued = self.queuedItem,
               !self.player.items().contains(where: { $0 === queued }) {
                self.clearQueuedBookkeeping()
                self.log("FL-484: item prefetch không còn trong hàng đợi sau replace — dọn sổ, prefetch lại")
                self.startPrefetch()
            }
            if seekTo > 2 {
                await self.player.seek(
                    to: CMTime(seconds: seekTo, preferredTimescale: 600))
            }
            self.waitingSince = nil
            self.advanceUnconfirmedSince = nil
            self.pausedStallSince = nil
            self.playStartedAt = Date()
            self.playUnlessOwnerPaused(site: "FL-484 loopback")
            self.opInFlight = false
            self.log("FL-484: item assembly đã dựng lại — phát ep=\(self.currentIndex + 1) từ \(Int(seekTo))s")
            if self.advancePending, !self.prefetchInFlight {
                self.advancePending = false
                self.runAdvanceChain()
            }
        }
    }

    /// FL-485 (2.1.6): clear every piece of queued-
    /// successor bookkeeping in one place — the item, its
    /// index / playable / session / height, and its
    /// status observation — so no field (or observer) is
    /// left stale behind when a path drops the queue.
    /// The pre-existing clear points keep their inline
    /// field writes and additionally invalidate the
    /// observation (see the transition block, the two
    /// replace reconciliations, and stop()).
    private func clearQueuedBookkeeping() {
        queuedStatusObservation?.invalidate()
        queuedStatusObservation = nil
        queuedItem = nil
        queuedIndex = nil
        queuedPlayable = nil
        queuedSessionID = nil
        queuedItemHeight = 0
    }

    /// FL-485 (2.1.6): observe the QUEUED successor's
    /// status from the moment it is inserted. A queued
    /// item that fails while waiting is logged the moment
    /// it happens — previously invisible, because no
    /// observer existed. The DECISION is still taken at
    /// item end (handleItemEnded) and by the watchdog's
    /// ended leg, which read the same status. The
    /// callback hops to the main actor with Sendable
    /// values only (the FL-343 discipline): the item
    /// itself is matched by ObjectIdentifier, never
    /// carried across the hop.
    private func observeQueuedItem(_ item: AVPlayerItem) {
        queuedStatusObservation?.invalidate()
        let watchedID = ObjectIdentifier(item)
        queuedStatusObservation = item.observe(\.status, options: [.new, .initial]) {
            [weak self] observed, _ in
            let status = observed.status
            let errorText = observed.error?.localizedDescription
            Task { @MainActor in
                guard let self,
                      let queued = self.queuedItem,
                      ObjectIdentifier(queued) == watchedID,
                      status == .failed else { return }
                self.log("FL-485: item xếp hàng ep=\((self.queuedIndex ?? -1) + 1) FAILED trong lúc chờ — \(errorText ?? "không có error text")")
            }
        }
    }

    /// FL-485 (2.1.6): the queued successor cannot carry
    /// the advance (it failed, or it never became ready):
    /// drop it from the player and the bookkeeping, then
    /// take the EXPLICIT advance — armed behind an
    /// in-flight operation exactly like the
    /// nothing-queued case, or the gated
    /// resolve → insert → advance chain now (the same
    /// flow a fresh next-episode open uses).
    private func dropQueuedAndAdvanceExplicitly() {
        if let queued = queuedItem {
            player.remove(queued)
        }
        clearQueuedBookkeeping()
        if prefetchInFlight || opInFlight {
            advancePending = true
            log("FL-485: advance tường minh đã arm (đang bận: prefetch/recovery)")
        } else {
            runAdvanceChain()
        }
    }

    private func handlePlaybackStalled() {
        guard !terminal else { return }
        log("playback stalled ep=\(currentIndex + 1) tại \(Int(checkpointSeconds))s — AVPlayer báo item đứng giữa chừng")
        recoverOrFail(reason: "playback stalled")
    }

    private func handleItemEnded() {
        guard !terminal else { return }
        // FL-485 (2.1.6): record the end FIRST — the
        // stall watchdog reads currentItemEnded, and an
        // item parked at pos == duration from this moment
        // on is ENDED, never a mid-episode freeze.
        currentItemEnded = true
        // The outgoing item is still the current item at
        // this instant — capture the owner's manual
        // subtitle/audio picks from it before the queue
        // moves on (FL-049).
        captureManualSelections(from: player.currentItem)
        log("item hết ep=\(currentIndex + 1)")
        if !hasNextEpisode {
            // FL-499 gate R2: nothing may recover behind
            // the end slate.
            cancelDeferredFailure(why: "hết tập cuối — end slate")
            phase = .ended
            log("hết tập cuối — end slate")
            return
        }
        // FL-485 (2.1.6): with a successor queued, its
        // STATE decides — the pre-fix handler did nothing
        // here and trusted the queue to advance, but the
        // convicted specimen's queued item had never
        // loaded at all (zero requests to its session in
        // 23 minutes, no status observer anywhere), so
        // the advance silently never came and the stall
        // watchdog later condemned the ENDED item.
        //
        // READY: the queue itself advances; the
        // supervisor's currentItem watch performs the
        // index bookkeeping (one code path for both the
        // automatic and the manual advance — FL-330) —
        // exactly the pre-fix behaviour.
        //
        // FAILED, or never became ready: drop the queued
        // item and run the explicit advance (the same
        // resolve+present flow a fresh next-episode open
        // uses) instead of trusting an advance that
        // cannot come.
        //
        // With NOTHING queued (review round 2, BLOCKER
        // 2) the queue cannot advance either: the player
        // sits paused on the ended item, timeControlStatus
        // is .paused — never .waiting — so the stall leg
        // can never fire. Drive the same path a press
        // would take: arm behind the in-flight prefetch,
        // or run the gated chain now.
        if let queued = queuedItem {
            switch queued.status {
            case .readyToPlay:
                log("FL-485: hết tập — successor ep=\(currentIndex + 2) READY, queue tự advance (native)")
            case .failed:
                log("FL-485: hết tập — successor ep=\(currentIndex + 2) đã FAILED trong hàng đợi — bỏ hàng đợi, chạy advance tường minh")
                dropQueuedAndAdvanceExplicitly()
            default:
                log("FL-485: hết tập — successor ep=\(currentIndex + 2) chưa từng ready (status=\(queued.status.rawValue)) — bỏ hàng đợi, chạy advance tường minh")
                dropQueuedAndAdvanceExplicitly()
            }
            return
        }
        if prefetchInFlight || opInFlight {
            // opInFlight = a recovery chain is
            // re-placing this episode (review round
            // 3, MINOR): arm exactly like the prefetch
            // case — the recovery completion consumes
            // the arm when its gate frees. (Arming was
            // previously skipped here, and the advance
            // was silently lost.)
            advancePending = true
            log("hết tập trong lúc đang bận (prefetch/recovery) — advance đã arm")
        } else {
            runAdvanceChain()
        }
    }

    // MARK: Supervisor (500 ms — the probe's cadence)

    private func startSupervisor() {
        supervisorTask?.cancel()
        supervisorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, !self.terminal else { return }
                self.supervisorTick()
            }
        }
    }

    private func supervisorTick() {
        // Episode bookkeeping: the queue advanced (auto
        // or manual) — the current item is now the one
        // prefetch inserted.
        if let queued = queuedItem, player.currentItem === queued,
           let index = queuedIndex {
            // The outgoing episode's final progress
            // leaves BEFORE the bookkeeping switches the
            // index (design §3.4's end point for it) —
            // with the OUTGOING episode's tracked
            // duration, not the incoming item's (Lens A
            // F-2).
            saveProgressSnapshot(durationOverride: currentDurationSeconds)
            currentIndex = index
            // FL-485 (2.1.6): the promoted item's queued
            // observation is spent with its bookkeeping.
            queuedStatusObservation?.invalidate()
            queuedStatusObservation = nil
            queuedItem = nil
            queuedIndex = nil
            queuedSessionID = nil
            // FL-351 (leg 4): the queued variant's height
            // becomes the playing variant's height.
            currentItemHeight = queuedItemHeight
            queuedItemHeight = 0
            // 2.0.48 (Approach C): the advanced-to variant
            // is really playing now — record its height.
            JoeYtQualityMap.record(pid: request.pid,
                                   height: currentItemHeight)
            // An arm the natural advance just satisfied is
            // spent (review round 2, BLOCKER 1).
            advancePending = false
            // FL-349 (2.0.45, leg 1): a MANUAL advance the
            // natural queue advance just satisfied is
            // spent too — the gate stamp and its pill clear
            // with the transition that consumed them.
            if gatedAdvanceArmedAt != nil {
                gatedAdvanceArmedAt = nil
                if statusLine == "Đang tải tập tiếp theo…" {
                    statusLine = nil
                }
            }
            recoverySpent = false
            cancelDeferredFailure(why: "queue đã sang ep=\(index + 1) (supervisor xác nhận chuyển tập)")
            // FL-347: the new episode gets its own muxed
            // budget, and the prefetched playable is
            // promoted to current — only NOW, at the
            // supervisor's identity confirmation, never
            // at prefetch time (spec §4.3.1).
            muxedSpent = false
            currentPlayable = queuedPlayable
            queuedPlayable = nil
            currentItemFramed = false
            currentItemEnded = false
            loopbackRetries = 0
            firstFrameLogged = false
            waitingSince = nil
            // The advance the stamp waited on HAS landed
            // (this block IS the supervisor's identity
            // confirmation) — the limbo leg's precondition
            // is spent.
            advanceUnconfirmedSince = nil
            pausedStallSince = nil
            checkpointSeconds = 0
            playStartedAt = Date()
            observeCurrentItem(player.currentItem)
            phase = .playing
            // FL-351 Branch D (leg 4): the pill states the
            // level actually playing — the promoted
            // item's own height — beside the episode.
            let pillQuality = Self.qualityText(height: currentItemHeight)
            flashStatus(pillQuality.isEmpty
                        ? "Tập \(currentIndex + 1)"
                        : "Tập \(currentIndex + 1) · \(pillQuality)")
            log("đã qua tập — currentItem là ep=\(currentIndex + 1) (đọc cùng đại lượng: item identity)")
            startPrefetch()
        }

        // FL-349 (2.0.45, leg 1): the manual-advance
        // readiness gate's tick. A stamped advance whose
        // item is not yet ready waits here (the pill the
        // arm raised says so) until the item can actually
        // frame; past the hard 10 s cap it fires anyway —
        // the pre-gate behaviour — rather than stranding
        // the owner's press. A stamp whose item never
        // landed is simply spent at the cap: the
        // advancePending / prefetch machinery still owns
        // that advance itself.
        if let armedAt = gatedAdvanceArmedAt {
            let age = Date().timeIntervalSince(armedAt)
            // Gate round 2 (C2-1): the spend-without-firing
            // belongs ONLY to the terminal slates (.failed /
            // .ended). In .starting the gate evaluates
            // exactly as in .playing — a stamp can
            // legitimately be live there (the transport
            // menu is installed during .starting and the
            // queued item can already exist), and spending
            // it there would silently drop the owner's
            // press, or un-gate it via advancePending.
            let onTerminalSlate: Bool
            switch phase {
            case .failed, .ended: onTerminalSlate = true
            case .starting, .playing: onTerminalSlate = false
            }
            if onTerminalSlate {
                // If the episode failed or ended while the
                // gate waited, the arm is spent WITHOUT
                // firing — advancing out of the failure
                // slate would hide the failure the owner
                // must see and answer.
                gatedAdvanceArmedAt = nil
                if statusLine == "Đang tải tập tiếp theo…" {
                    statusLine = nil
                }
            } else if queuedItem != nil, !opInFlight {
                if gateReadiness().itemReady {
                    gatedAdvanceArmedAt = nil
                    if statusLine == "Đang tải tập tiếp theo…" {
                        statusLine = nil
                    }
                    fireAdvance()
                    log("advance fired — sẵn sàng sau \(Int(age * 1000))ms")
                } else if age > 10 {
                    gatedAdvanceArmedAt = nil
                    if statusLine == "Đang tải tập tiếp theo…" {
                        statusLine = nil
                    }
                    fireAdvance()
                    log("advance fired — quá trần 10s, bắn cưỡng bức")
                }
            } else if age > 10 {
                gatedAdvanceArmedAt = nil
                if statusLine == "Đang tải tập tiếp theo…" {
                    statusLine = nil
                }
            }
        }

        // Refresh the tracked duration from the item
        // that is current NOW — after the transition
        // block above has consumed the outgoing value
        // (Lens A F-2).
        if let item = player.currentItem {
            let d = item.duration.seconds
            if d.isFinite, d > 0 { currentDurationSeconds = d }
        }

        witnessMediaSelection()
        // FL-499 gate R1 F-C1: a native resume on a failed
        // item may never reach .playing/.waiting — a
        // nonzero rate is the owner's Play all the same.
        // A release the busy funnel parked (released) runs
        // as soon as no operation is in flight.
        if let held = deferredFailure, !opInFlight,
           phase == .starting || phase == .playing,
           held.released || player.rate != 0 {
            ownerPaused = false
            runDeferredFailure(trigger: held.released ? "đã nhả, funnel rảnh" : "rate≠0")
        }

        let status = player.timeControlStatus
        if status == .playing {
            waitingSince = nil
            // The current item has framed and is
            // playing: its startup window is over, and
            // any later wait is a mid-episode wait
            // (2.0.44 watchdog).
            currentItemFramed = true
            // Playback is moving: any paused-limbo
            // bookkeeping is spent.
            advanceUnconfirmedSince = nil
            pausedStallSince = nil
            if !firstFrameLogged,
               let item = player.currentItem, item.status == .readyToPlay {
                firstFrameLogged = true
                phase = .playing
                let ms = Int(Date().timeIntervalSince(playStartedAt) * 1000)
                log("first frame ep=\(currentIndex + 1) sau \(ms)ms")
                // The start-point progress save (§3.4):
                // the Continue Watching row exists from
                // the episode's first frame, not only
                // after the first periodic tick.
                saveProgressSnapshot(force: true)
            }
            let position = player.currentTime().seconds
            if position.isFinite, position > 1 {
                checkpointSeconds = position
            }
            // The periodic save (§3.4): every ~15 s of
            // ticks, and only when the position has
            // genuinely moved since the last save.
            ticksSinceSave += 1
            if ticksSinceSave >= 30, position.isFinite,
               abs(position - lastSavedPosition) >= 5 {
                saveProgressSnapshot()
            }
            // FL-352 (2.0.45, leg 5): the resume seek,
            // evaluated ONCE, on the first playing tick
            // after the first frame (the candidate was
            // captured in start(), before this session's
            // saves could overwrite the row).
            if !resumeEvaluated, firstFrameLogged {
                resumeEvaluated = true
                evaluateResume()
            }
        } else if status == .waitingToPlayAtSpecifiedRate {
            // 2.0.44 watchdog (spec §5.2): TWO thresholds
            // plus a PROGRESS condition. An item that has
            // never framed is in its startup window —
            // 45 s; an item that has played and is
            // re-buffering mid-episode gets 20 s. And
            // while the playhead or the loaded buffer
            // end keeps moving, the deadline re-baselines
            // instead of counting down: an item that is
            // still loading is never condemned. The
            // pre-fix leg was a flat 20 s with no progress
            // condition — in the 2.0.43 session it fired
            // at 20 s on an item that framed at 22.9 s,
            // and the identical re-resolve repeated the
            // slow startup into a second condemnation.
            let position = player.currentTime().seconds
            let bufferEnd = player.currentItem
                .map { loadedBufferEndSeconds($0) } ?? 0
            if waitingSince == nil {
                waitingSince = Date()
                waitingProgressPosition = position.isFinite ? position : 0
                waitingProgressBuffer = bufferEnd
            } else {
                let moved = (position.isFinite
                                && abs(position - waitingProgressPosition) >= 0.5)
                    || bufferEnd >= waitingProgressBuffer + 1.0
                if moved {
                    waitingSince = Date()
                    if position.isFinite {
                        waitingProgressPosition = position
                    }
                    waitingProgressBuffer = bufferEnd
                }
            }
            let limit: TimeInterval = currentItemFramed ? 20 : 45
            if let since = waitingSince,
               Date().timeIntervalSince(since) > limit, !opInFlight {
                // FL-485 (2.1.6): an ENDED item waiting on
                // its queued successor is not stalled — it
                // is finished. The pre-fix leg read
                // pos == duration as a freeze and fired the
                // recovery cascade at an item that had
                // already ended; with the recovery budget
                // already spent (the FL-484 shape) that
                // fell straight through to the terminal
                // slate the owner read as "no source
                // available" at an episode transition.
                // Ended items belong to the item-end paths:
                // a healthy successor advances natively,
                // and a successor that STILL has not become
                // ready past the limit (it may have been
                // mid-load at the end event itself) gets
                // the explicit advance here. recoverOrFail
                // never fires for an ended item.
                if currentItemEnded {
                    if let queued = queuedItem,
                       queued.status != .readyToPlay {
                        log("FL-485: watchdog — item ep=\(currentIndex + 1) đã HẾT, successor ep=\(currentIndex + 2) vẫn chưa ready sau \(Int(limit))s chờ — advance tường minh, KHÔNG recover")
                        dropQueuedAndAdvanceExplicitly()
                    }
                    waitingSince = nil
                } else {
                    log("stall — waiting \(Int(limit))s ở ep=\(currentIndex + 1) tại \(Int(checkpointSeconds))s (khung: \(currentItemFramed ? "giữa tập" : "khởi động"), không tiến triển)")
                    recoverOrFail(reason: "stall waiting \(Int(limit))s")
                }
            }
        } else {
            waitingSince = nil
            tickPausedLimbo()
        }
    }

    /// The end of the item's loaded buffer, in
    /// seconds: the waiting leg's progress signal.
    /// While origin bytes keep arriving, this end
    /// keeps moving even when the playhead cannot yet
    /// move — the difference between a slow item and a
    /// dead one.
    private func loadedBufferEndSeconds(_ item: AVPlayerItem) -> Double {
        guard let last = item.loadedTimeRanges.last else { return 0 }
        let end = last.timeRangeValue.end.seconds
        return end.isFinite ? end : 0
    }

    /// FL-343 (A), second leg: recovery watches PROGRESS,
    /// not only the player's nominal state. In the
    /// incident the queue was told to advance over an
    /// item whose origin had been cut mid-stream; the
    /// item neither failed nor ended, and the player
    /// parked at .paused awaiting a supervisor
    /// confirmation that could never come — the pre-fix
    /// supervisor only watched .waiting, so nothing ever
    /// fired.
    ///
    /// The leg's precondition is the model's OWN
    /// unconfirmed advance (see the stamp's declaration):
    /// fireAdvance() issued advanceToNextItem and the
    /// transition bookkeeping never confirmed it. That
    /// stamp is something a user pause can never
    /// produce, so the leg is safe for the owner's pause
    /// BY CONSTRUCTION — it never has to guess intent
    /// from buffer or waiting signals (review round 1,
    /// Lens C F-C2/F-C3: those signals misclassify in
    /// both directions). The fire condition: phase
    /// .playing, the stamp live, the player parked at
    /// .paused (this leg only runs on .paused ticks),
    /// the playhead frozen within 0.5 s of where the
    /// stretch found it, for over 20 s. A playhead that
    /// moves again spends the stamp — the advance (or
    /// playback) is alive after all. A player parked at
    /// the item's END is excluded: the end-of-item paths
    /// own that state.
    private func tickPausedLimbo() {
        guard phase == .playing, !opInFlight,
              advanceUnconfirmedSince != nil,
              let item = player.currentItem else {
            pausedStallSince = nil
            return
        }
        let position = player.currentTime().seconds
        let duration = item.duration.seconds
        if duration.isFinite, duration > 0, position.isFinite,
           position >= duration - 0.5 {
            pausedStallSince = nil
            return
        }
        if position.isFinite,
           abs(position - advanceUnconfirmedPosition) >= 0.5 {
            // The playhead moved well past the point the
            // advance was issued from — playback is
            // alive; the stamp is spent.
            advanceUnconfirmedSince = nil
            pausedStallSince = nil
            return
        }
        if pausedStallSince == nil {
            pausedStallSince = Date()
            pausedStallPosition = position
            return
        }
        if position.isFinite,
           abs(position - pausedStallPosition) >= 0.5 {
            // Still creeping — re-baseline instead of
            // firing on a slow-but-alive item.
            pausedStallSince = Date()
            pausedStallPosition = position
            return
        }
        if let since = pausedStallSince,
           Date().timeIntervalSince(since) > 20 {
            log("stall — paused-limbo 20s ở ep=\(currentIndex + 1) tại \(Int(checkpointSeconds))s (advance không được supervisor xác nhận, vị trí đứng yên)")
            advanceUnconfirmedSince = nil
            pausedStallSince = nil
            recoverOrFail(reason: "stall paused-limbo")
        }
    }

    // MARK: Recovery — ONE re-resolve per item

    private func recoverOrFail(reason: String) {
        guard !terminal, !opInFlight else { return }
        if deferIfOwnerPaused(reason: reason, loopback: false) { return }
        if recoverySpent {
            // FL-347: the muxed tier stands in front of
            // the terminal door — a spent recovery is
            // not yet a dead episode while the current
            // playable still holds an untried muxed
            // fallback.
            if tryMuxedSwap(reason: reason) { return }
            terminalFailure(reason: reason)
            return
        }
        recoverySpent = true
        attempt += 1
        let myAttempt = attempt
        opInFlight = true
        let videoId = request.videoIds[currentIndex]
        let seekTo = checkpointSeconds
        // The episode this recovery belongs to (review
        // round 5, MINOR): re-validated in the completion
        // before the replace — if the stalled item
        // un-stalled and the queue auto-advanced during
        // the awaits, the current item is a DIFFERENT
        // episode and replacing it would desync the
        // screen from the index bookkeeping.
        let episodeIndex = currentIndex
        log("re-resolve ep=\(currentIndex + 1) (lần duy nhất) — lý do: \(reason); checkpoint \(Int(seekTo))s")
        Task { [weak self] in
            guard let self else { return }
            let result = await JoeYtResolver.shared.resolve(videoId: videoId)
            guard !self.terminal, self.attempt == myAttempt else {
                self.opInFlight = false
                return
            }
            switch result {
            case .playable(let playable, _):
                if let built = await self.buildItem(for: playable) {
                    let item = built.item
                    guard !self.terminal, self.attempt == myAttempt else {
                        self.opInFlight = false
                        return
                    }
                    guard self.currentIndex == episodeIndex else {
                        self.opInFlight = false
                        self.log("recovery: tập hiện tại đã đổi trong lúc resolve (item tự hết stall và queue đã qua tập) — bỏ replace")
                        return
                    }
                    // FL-347: the recovered item becomes
                    // current from THIS playable — retain
                    // it (and restart its startup window).
                    self.currentPlayable = playable
                    self.currentItemHeight = built.height
                    // 2.0.48 (Approach C): the recovered
                    // variant is a real measurement too.
                    JoeYtQualityMap.record(pid: self.request.pid,
                                           height: built.height)
                    self.currentItemFramed = false
                    self.currentItemEnded = false
                    self.loopbackRetries = 0
                    self.player.replaceCurrentItem(with: item)
                    self.observeCurrentItem(item)
                    // Reconcile the prefetched queue entry
                    // with the replace (review round 3,
                    // MINOR): Apple's text documents
                    // removal of the replaced item only and
                    // is silent about followers — if tvOS
                    // dropped the queued item, its
                    // bookkeeping must not go stale (a
                    // stale queuedItem would re-create the
                    // episode-end dead-end after any
                    // recovery). Correct under either
                    // semantics.
                    if let queued = self.queuedItem,
                       !self.player.items().contains(where: { $0 === queued }) {
                        self.queuedStatusObservation?.invalidate()
                        self.queuedStatusObservation = nil
                        self.queuedItem = nil
                        self.queuedIndex = nil
                        self.queuedPlayable = nil
                        self.queuedSessionID = nil
                        self.queuedItemHeight = 0
                        self.log("recovery: item prefetch không còn trong hàng đợi sau replace — dọn sổ, prefetch lại")
                        self.startPrefetch()
                    }
                    if seekTo > 2 {
                        await self.player.seek(
                            to: CMTime(seconds: seekTo, preferredTimescale: 600))
                    }
                    self.waitingSince = nil
                    self.advanceUnconfirmedSince = nil
                    self.pausedStallSince = nil
                    self.playStartedAt = Date()
                    self.playUnlessOwnerPaused(site: "re-resolve")
                    self.opInFlight = false
                    self.log("re-resolve xong — phát lại ep=\(self.currentIndex + 1) từ \(Int(seekTo))s")
                    // An advance armed while this recovery
                    // ran (the episode ended, or the owner
                    // pressed Next, mid-recovery — review
                    // round 3, MINOR) is consumed now that
                    // the gate is free — UNLESS a prefetch
                    // is still in flight (review round 4,
                    // BLOCKER): starting the chain here
                    // would resolve the same next episode a
                    // second time and race the prefetch's
                    // insert. Leave the arm set; with
                    // opInFlight now cleared, the
                    // prefetch's success consumption (or
                    // its failure hand-off) owns it.
                    if self.advancePending, !self.prefetchInFlight {
                        self.advancePending = false
                        self.runAdvanceChain()
                    }
                } else {
                    self.opInFlight = false
                    self.handOverToPageFallback(reason: "recovery: không dựng được item sau re-resolve — assembly chết và không có muxed dự phòng")
                }
            case .solverFailed:
                // §4.6 trigger one, on the RECOVERY leg
                // (review count round 1, Lens C F2): the
                // same result at first resolve goes to
                // the page fallback through the router —
                // the recovery leg must not cut the page
                // tier out of the native → page →
                // chain/slate order.
                self.opInFlight = false
                self.handOverToPageFallback(reason: "recovery: solver chết ở lần re-resolve — \(reason)")
            case .unplayable(let status, _) where status == "NO_FORMATS":
                // §4.6 trigger two, same reasoning: the
                // router maps NO_FORMATS to the page
                // fallback at first resolve; recovery
                // agrees.
                self.opInFlight = false
                self.handOverToPageFallback(reason: "recovery: re-resolve không còn format nào dùng được — \(reason)")
            default:
                self.opInFlight = false
                // FL-347: the second terminal door gets
                // the same muxed check as the first — a
                // re-resolve that comes back unplayable
                // must not slate the episode while the
                // CURRENT playable's muxed fallback is
                // still untried.
                if !self.tryMuxedSwap(reason: reason) {
                    self.terminalFailure(reason: reason)
                }
            }
        }
    }

    /// FL-347: the muxed swap — the second recovery
    /// tier, checked at BOTH doors into terminalFailure
    /// (recovery already spent; re-resolve came back
    /// unplayable). The design contract (§4.4: "hỏng →
    /// muxed 18 có tên", and its failure-class table's
    /// "no class is silent") gives the assembly leg a
    /// named fallback: the SAME episode as one muxed
    /// file, played directly — the construction Probe
    /// 16 proved on the owner's TV. The pre-fix model
    /// never reached it: the muxed URL existed only
    /// inside buildItem's server-failure branch, and
    /// the playable was discarded once the assembly
    /// item existed (see currentPlayable).
    ///
    /// The swap mirrors the recovery replace's
    /// discipline: observe the new item, reconcile the
    /// prefetched queue entry, seek back to the
    /// vouched checkpoint (FL-041), clear the stall
    /// bookkeeping, play. The swapped item then lives
    /// under the same supervisor — if IT fails or
    /// stalls, recoverOrFail finds both tiers spent
    /// and the failure is truly terminal. Returns
    /// false (nothing done) when the tier does not
    /// apply: already spent, no retained playable, the
    /// playable is not an assembly, or it carries no
    /// muxed fallback.
    private func tryMuxedSwap(reason: String) -> Bool {
        guard !muxedSpent,
              let playable = currentPlayable,
              playable.kind == .assembly,
              let muxedURL = playable.fallbackDirectURL else { return false }
        muxedSpent = true
        log("lùi muxed 18 — lý do: \(reason)")
        // FL-484 (2.1.6): the swap is a QUALITY DOWNGRADE
        // and must never be silent in the log — this
        // marker names it in one greppable line: the
        // episode, the tier it fell FROM, the tier it
        // lands ON. (Log only — no UI change.)
        log("MUXED-SWAP-DOWNGRADE ep=\(currentIndex + 1): assembly → muxed itag 18 (\(playable.fallbackHeight)p) — lý do: \(reason)")
        // FL-351 (leg 4): the item now playing is the
        // muxed variant — the spoken height follows it.
        currentItemHeight = playable.fallbackHeight
        // 2.0.48 (Approach C): the muxed variant really
        // obtained is a measurement like any other.
        JoeYtQualityMap.record(pid: request.pid,
                               height: playable.fallbackHeight)
        let item = AVPlayerItem(url: muxedURL)
        player.replaceCurrentItem(with: item)
        observeCurrentItem(item)
        // The same queue reconciliation as the recovery
        // replace: if the swap dropped the prefetched
        // item, its bookkeeping must not go stale.
        if let queued = queuedItem,
           !player.items().contains(where: { $0 === queued }) {
            queuedStatusObservation?.invalidate()
            queuedStatusObservation = nil
            queuedItem = nil
            queuedIndex = nil
            queuedPlayable = nil
            queuedSessionID = nil
            queuedItemHeight = 0
            log("muxed swap: item prefetch không còn trong hàng đợi sau replace — dọn sổ, prefetch lại")
            startPrefetch()
        }
        let seekTo = checkpointSeconds
        waitingSince = nil
        advanceUnconfirmedSince = nil
        pausedStallSince = nil
        currentItemFramed = false
        currentItemEnded = false
        loopbackRetries = 0
        playStartedAt = Date()
        if seekTo > 2 {
            player.seek(to: CMTime(seconds: seekTo, preferredTimescale: 600))
        }
        playUnlessOwnerPaused(site: "muxed swap")
        log("muxed swap xong — phát bản muxed ep=\(currentIndex + 1) từ \(Int(seekTo))s")
        return true
    }

    /// The §4.6 hand-over for a dead native
    /// construction: the assembly leg and the muxed leg
    /// are BOTH unusable, so the episode goes to the
    /// degraded door+page surface through the router —
    /// never straight to a terminal slate while a
    /// proven fallback surface exists. This model
    /// latches terminal and strips its queue first, so
    /// nothing of the native machinery can touch the
    /// screen after the swap.
    private func handOverToPageFallback(reason: String) {
        guard !terminal else { return }
        terminal = true
        player.pause()
        player.removeAllItems()
        log("pageFallback — \(reason)")
        onPageFallback?()
    }

    /// One WatchStore progress write for the episode
    /// on screen (design §3.4 — the native player
    /// records at the same points as JoePlayerView:
    /// start / periodic / end). Identity is the stable
    /// title identity (FL-058): the catalogue pid keys
    /// the row, and the matched title's TMDB id is
    /// stamped when the request carries it, so the row
    /// canonical-matches the same film's chain rows.
    /// One row per series (the store's own same-series
    /// rule keeps the latest episode), never per
    /// episode — a long series must not flood the
    /// shared 40-row progress store.
    private func saveProgressSnapshot(force: Bool = false,
                                      durationOverride: Double? = nil) {
        guard let store = watchStore else {
            // FL-352 (2.0.45, leg 5): a save path with no
            // store attached is a wiring fault, not a
            // state to pass over in silence — logged once
            // per session (this function is called from
            // stop() and the periodic ticks; once is
            // evidence, more is spam).
            if !nilStoreSaveLogged {
                nilStoreSaveLogged = true
                log("progress save BỎ QUA — watchStore chưa gắn (nil)")
            }
            return
        }
        var position = checkpointSeconds
        let live = player.currentTime().seconds
        if live.isFinite, live > position { position = live }
        guard force || position > 1 else { return }
        var entry = WatchStore.Entry()
        entry.kind = WatchStore.kindYT
        entry.key = WatchStore.ytProgressKey(pid: request.pid)
        entry.ep = "Tập \(currentIndex + 1)"
        entry.epLabel = "Đang xem: Tập \(currentIndex + 1)"
        entry.title = request.seriesTitle
        entry.slug = request.pid
        entry.source = "yt"
        if request.tmdbId > 0 {
            entry.tmdbId = "\(request.tmdbId)"
        }
        entry.pos = Int64(position * 1000)
        if let override = durationOverride, override > 0 {
            entry.dur = Int64(override * 1000)
        } else if let item = player.currentItem {
            let duration = item.duration.seconds
            if duration.isFinite, duration > 0 {
                entry.dur = Int64(duration * 1000)
            }
        }
        entry.ts = Int64(Date().timeIntervalSince1970 * 1000)
        store.saveProgress(entry)
        // FL-352 (2.0.45, leg 5): the write side's own
        // evidence line — FL-352's conviction rested on
        // the save being healthy, and the acceptance
        // check pairs this line with the rail row on the
        // read side (two-ended evidence).
        log("progress save — yt|\(request.pid) ep=\(currentIndex + 1) pos=\(Int(position))s")
        lastSavedPosition = position
        ticksSinceSave = 0
    }

    /// FL-352 (2.0.45, leg 5): apply the resume
    /// candidate captured in start(), or log why it does
    /// not apply. The thresholds are the house resume
    /// rule: at least 5 s in (a smaller position is a
    /// fresh start, not a resume) and at least 30 s left
    /// before the episode's end (a position inside that
    /// tail is a finished episode, not a resume).
    private func evaluateResume() {
        guard let pos = resumeCandidateSeconds else {
            log("resume — bỏ qua (không có hàng)")
            return
        }
        if pos < 5 {
            log("resume — bỏ qua (pos<5s)")
            return
        }
        let duration = currentDurationSeconds > 0
            ? currentDurationSeconds : resumeCandidateDuration
        if duration > 0, duration - pos < 30 {
            log("resume — bỏ qua (sát cuối tập)")
            return
        }
        player.seek(to: CMTime(seconds: pos, preferredTimescale: 600))
        checkpointSeconds = pos
        log("resume — yt|\(request.pid) ep=\(currentIndex + 1) tại \(Int(pos))s")
    }

    private func terminalFailure(reason: String) {
        guard !terminal else { return }
        log("terminal failure ep=\(currentIndex + 1) — \(reason)")
        if let chainPlay = request.chainPlay {
            terminal = true
            log("Auto: native route hỏng hẳn — trả tập về detail chuỗi")
            onDetailFallThrough?(chainPlay)
        } else if request.mode == .auto, let route = request.chainRoute {
            terminal = true
            log("Auto: native route hỏng hẳn — rơi về chuỗi")
            onFallThrough?(route)
        } else {
            // Pause BEFORE the slate (review round 3,
            // MINOR): this branch does not latch terminal,
            // so an un-stalling item would otherwise keep
            // playing (audio) behind the failure slate
            // with the supervisor machinery still live.
            player.pause()
            // Drop any armed advance (review round 6,
            // MINOR): this branch is the sole producer of
            // the failure slate retry() serves, and an arm
            // left set here would be consumed by the
            // retry's recovery completion — skipping the
            // very episode the owner asked to replay. All
            // three recovery failure exits land here.
            advancePending = false
            // FL-499 gate R2: a held (or parked) failure
            // dies with the episode's native life — the
            // slate's own retry() is the only way back.
            cancelDeferredFailure(why: "terminal failure — tấm bảng lỗi")
            phase = .failed("Không phát được qua YouTube. Anh bấm Thử lại, hoặc quay lại rồi chọn nguồn khác.")
        }
    }

    /// The failure slate's retry: a fresh resolve of the
    /// current episode with the recovery budget restored.
    func retry() {
        guard !terminal else { return }
        phase = .starting
        // FL-499 gate R1 F-C1: Thử lại is a play request.
        ownerPaused = false
        cancelDeferredFailure(why: "Thử lại (dựng lại từ đầu)")
        recoverySpent = false
        // FL-485 (2.1.6): the retried item is a fresh
        // presentation — the ended flag and the loopback
        // budget reset with the recovery budgets.
        currentItemEnded = false
        loopbackRetries = 0
        // FL-347: the owner's retry restores BOTH
        // recovery budgets (same reset points as
        // recoverySpent, spec §4.3.2).
        muxedSpent = false
        checkpointSeconds = 0
        recoverOrFail(reason: "owner retry")
    }

    // MARK: Prefetch (exactly one episode deep)

    /// Whether a prefetch is ACTUALLY running. A stored
    /// Task handle cannot answer this (a finished task
    /// stays non-nil — review round 1, BLOCKER 1: after
    /// a failed prefetch the handle lived on forever and
    /// Manual Next armed an advance no live task would
    /// ever consume). The flag is set at start and
    /// cleared by the task's own defer, generation-
    /// guarded so a superseded task cannot clear its
    /// successor's flag.
    private var prefetchInFlight = false
    private var prefetchGeneration = 0

    private func startPrefetch() {
        prefetchTask?.cancel()
        guard hasNextEpisode, queuedItem == nil else { return }
        let nextIndex = currentIndex + 1
        let videoId = request.videoIds[nextIndex]
        prefetchGeneration += 1
        let generation = prefetchGeneration
        prefetchInFlight = true
        prefetchTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.prefetchGeneration == generation {
                    self.prefetchInFlight = false
                    // advancePending's lifecycle ends with
                    // the prefetch that could have consumed
                    // it (review round 2, BLOCKER 1): a
                    // stale arm left true here made a LATER
                    // episode's successful prefetch skip an
                    // episode nobody asked to skip. The two
                    // failure exits below hand a LIVE arm
                    // off to the advance chain BEFORE this
                    // backstop clears it. Exception (review
                    // round 3, MINOR): while a recovery
                    // chain holds the gate, the arm belongs
                    // to the recovery completion — the
                    // backstop must not clear it first.
                    if !self.opInFlight {
                        self.advancePending = false
                    }
                }
            }
            let result = await JoeYtResolver.shared.resolve(videoId: videoId)
            guard !self.terminal, !Task.isCancelled,
                  self.currentIndex + 1 == nextIndex, self.queuedItem == nil
            else { return }
            guard case .playable(let playable, let metrics) = result else {
                self.log("prefetch ep=\(nextIndex + 1): resolve không ra playable — tập kế sẽ resolve khi tới lượt")
                self.handOffArmedAdvance()
                return
            }
            guard let built = await self.buildItem(for: playable) else {
                self.log("prefetch ep=\(nextIndex + 1): dựng item thất bại")
                self.handOffArmedAdvance()
                return
            }
            let item = built.item
            guard !self.terminal, !Task.isCancelled,
                  self.currentIndex + 1 == nextIndex, self.queuedItem == nil
            else { return }
            self.player.insert(item, after: nil)
            self.queuedItem = item
            self.queuedIndex = nextIndex
            // FL-349 (leg 1): the session handle rides
            // beside the queued item for the gate's
            // first-media-served check.
            self.queuedSessionID = built.sessionID
            // FL-351 (leg 4): the queued variant's height
            // rides beside it, promoted at the transition.
            self.queuedItemHeight = built.height
            // FL-347: retained for the promotion at the
            // supervisor's transition confirmation —
            // prefetch alone never touches currentPlayable.
            self.queuedPlayable = playable
            // FL-485 (2.1.6): the queued successor carries
            // a status observation from this moment (see
            // observeQueuedItem).
            self.observeQueuedItem(item)
            self.log("prefetch ep=\(nextIndex + 1) đã vào hàng đợi (solver \(metrics.solverMs)ms)")
            // Consume an armed advance — UNLESS a
            // recovery chain holds the gate (review round
            // 3, MINOR): advancing now and letting the
            // recovery then replaceCurrentItem back would
            // desync the index bookkeeping from the
            // screen. The recovery completion consumes
            // the arm instead. FL-349 (leg 1): the
            // consumption passes through the readiness
            // gate — a stamped MANUAL advance fires here
            // only when the item is ready, else the
            // supervisor tick owns it (with the 10 s cap).
            if self.advancePending, !self.opInFlight {
                self.advancePending = false
                self.consumeAdvance()
            }
        }
    }

    // MARK: Manual next (transport-bar menu — FL-349)

    /// FL-349 (2.0.45, leg 1): the press consumer that
    /// used to live here is DELETED, not replaced. It ate
    /// every Right-arrow while playing — panel-unaware —
    /// so the owner's seek presses became next-episode
    /// jumps and the subtitle panel lost its keys (the
    /// Diag_9 conviction). On this surface NO press is
    /// consumed: Right/Left are the native seek, the
    /// panel is fully native, and manual next is the
    /// transport-bar menu action (Q1) calling
    /// requestAdvance(trigger:) below.

    /// Whether the queued item can actually frame: its
    /// status is readyToPlay AND (its loaded ranges
    /// already cover ≥ 3 s OR its assembly session has
    /// served its first media byte — the server's own
    /// record, for an item whose ranges AVPlayer has not
    /// filled yet).
    private func gateReadiness() -> (itemReady: Bool, mediaServed: Bool) {
        guard let item = queuedItem else { return (false, false) }
        let mediaServed = queuedSessionID.map {
            JoeYtHlsServer.shared.firstMediaServed(sessionID: $0)
        } ?? false
        let ready = item.status == .readyToPlay
            && (loadedBufferEndSeconds(item) >= 3 || mediaServed)
        return (ready, mediaServed)
    }

    /// Arm the readiness gate for a manual advance: the
    /// stamp, the waiting pill (the existing statusPill —
    /// no new chrome), and the arm log line. Re-arming
    /// while a stamp is live only refreshes the log; the
    /// original stamp (and its 10 s cap) stands.
    private func armGate() {
        if gatedAdvanceArmedAt == nil {
            gatedAdvanceArmedAt = Date()
            statusTask?.cancel()
            statusLine = "Đang tải tập tiếp theo…"
        }
        let r = gateReadiness()
        log("advance đã arm — chờ item sẵn sàng (ready=\(r.itemReady ? 1 : 0) media=\(r.mediaServed ? 1 : 0))")
    }

    /// The one consumption funnel for every advance the
    /// FL-330 machinery fires (prefetch success, advance
    /// chain completions): with a gate stamp live, the
    /// fire passes through the readiness gate — ready
    /// fires now (with the fired log), not-ready leaves
    /// the stamp for the supervisor tick and its 10 s
    /// cap. Without a stamp this is fireAdvance()
    /// exactly — queue auto-advance and the episode-end
    /// paths are never gated.
    private func consumeAdvance() {
        guard gatedAdvanceArmedAt != nil else {
            fireAdvance()
            return
        }
        guard queuedItem != nil, !opInFlight else { return }
        let r = gateReadiness()
        guard r.itemReady, let armedAt = gatedAdvanceArmedAt else { return }
        gatedAdvanceArmedAt = nil
        if statusLine == "Đang tải tập tiếp theo…" {
            statusLine = nil
        }
        fireAdvance()
        log("advance fired — sẵn sàng sau \(Int(Date().timeIntervalSince(armedAt) * 1000))ms")
    }

    /// Manual next, serialised through the in-flight
    /// gate: with the prefetched item in the queue the
    /// advance fires through the readiness gate at once;
    /// without it, the advance is armed and fires when
    /// the prefetch lands (or a resolve-then-advance
    /// chain runs if no prefetch is in flight). The ONLY
    /// manual entry — the transport-bar menu action.
    func requestAdvance(trigger: String) {
        // player.currentItem != nil: no advance chain may
        // run before the first item is live (BLOCKER 3).
        guard !terminal, hasNextEpisode, !opInFlight,
              player.currentItem != nil
        else { return }
        log("advance bằng tay (trigger=\(trigger)) — ep=\(currentIndex + 2)")
        armGate()
        if queuedItem != nil {
            consumeAdvance()
        } else if prefetchInFlight {
            advancePending = true
        } else {
            // No prefetch running (its resolve failed
            // earlier): the gated chain.
            runAdvanceChain()
        }
    }

    /// The gated resolve → insert → advance chain: ONE
    /// operation under the in-flight gate + attempt
    /// token. Three callers share it: a manual press with
    /// nothing queued and no prefetch running; the
    /// episode-end handler in the same state (review
    /// round 2, BLOCKER 2); and a failed prefetch that
    /// had an advance armed (handOffArmedAdvance).
    private func runAdvanceChain() {
        guard !terminal, hasNextEpisode, !opInFlight,
              player.currentItem != nil
        else { return }
        // A caller that armed during a recovery can land
        // here with the next item ALREADY queued (the
        // prefetch finished meanwhile): advance to it
        // instead of resolving a second copy (review
        // round 3, MINOR). FL-349 (leg 1): the fire
        // passes through the readiness gate like every
        // consumption (consumeAdvance).
        if queuedItem != nil {
            consumeAdvance()
            return
        }
        opInFlight = true
        attempt += 1
        let myAttempt = attempt
        let nextIndex = currentIndex + 1
        let videoId = request.videoIds[nextIndex]
        Task { [weak self] in
            guard let self else { return }
            let result = await JoeYtResolver.shared.resolve(videoId: videoId)
            guard !self.terminal, self.attempt == myAttempt else {
                self.opInFlight = false
                return
            }
            switch result {
            case .playable(let playable, _):
                if let built = await self.buildItem(for: playable),
                   !self.terminal, self.attempt == myAttempt {
                    let item = built.item
                    // Re-check the queue AFTER the awaits
                    // (review round 4, BLOCKER): a prefetch
                    // that landed meanwhile already inserted
                    // its copy — inserting a second one
                    // overwrites queuedItem with an item the
                    // supervisor can never match to the
                    // playing copy, stalling the index
                    // bookkeeping for a whole episode.
                    // Advance to the queued copy instead.
                    if self.queuedItem != nil {
                        self.opInFlight = false
                        self.log("advance chain: prefetch đã kịp vào hàng đợi — advance tới bản đó, không insert trùng")
                        self.consumeAdvance()
                    } else {
                        self.player.insert(item, after: nil)
                        self.queuedItem = item
                        self.queuedIndex = nextIndex
                        // FL-349 (leg 1): the session
                        // handle, as at the prefetch insert.
                        self.queuedSessionID = built.sessionID
                        self.queuedItemHeight = built.height
                        // FL-347: same retention as the
                        // prefetch insert — promoted at
                        // the transition confirmation.
                        self.queuedPlayable = playable
                        // FL-485 (2.1.6): same queued-item
                        // status observation as the
                        // prefetch insert.
                        self.observeQueuedItem(item)
                        self.opInFlight = false
                        self.consumeAdvance()
                    }
                } else if !self.terminal, self.attempt == myAttempt {
                    // buildItem nil: the construction is
                    // dead — a §4.6 trigger, handed over
                    // exactly like start() and recovery
                    // (review count round 1, Lens C F1).
                    // The old log-only else left the
                    // player parked on the ENDED item with
                    // phase still .playing when this chain
                    // ran from the episode-end handler —
                    // the FL-029 silent-death shape.
                    self.opInFlight = false
                    self.advancePending = false
                    self.handOverToPageFallback(reason: "advance chain: không dựng được item cho tập kế — assembly chết và không có muxed dự phòng")
                } else {
                    self.opInFlight = false
                }
            case .solverFailed:
                // §4.6 trigger one on the advance leg:
                // same hand-over as everywhere else.
                self.opInFlight = false
                self.advancePending = false
                self.handOverToPageFallback(reason: "advance chain: solver chết khi resolve tập kế")
            case .unplayable(let status, _) where status == "NO_FORMATS":
                // §4.6 trigger two on the advance leg.
                self.opInFlight = false
                self.advancePending = false
                self.handOverToPageFallback(reason: "advance chain: tập kế không còn format nào dùng được")
            default:
                self.opInFlight = false
                // The chain WAS the arm's consumer
                // (review round 5, MINOR): an advance
                // armed while this chain ran (the episode
                // ended mid-chain) must not survive its
                // failure — a stale arm would be consumed
                // by a later owner retry()'s recovery and
                // skip the episode he asked to replay.
                // Every OTHER failure class here is
                // terminal for the chain (Lens C F1):
                // Auto falls through to the next series,
                // manual shows the slate — never a silent
                // park on the ended item.
                self.advancePending = false
                self.terminalFailure(reason: "advance chain: resolve tập \(nextIndex + 1) thất bại")
            }
        }
    }

    /// A prefetch that failed while an advance was armed
    /// (a press, or the episode ending mid-prefetch)
    /// hands the arm to the gated chain instead of
    /// dropping it (review round 2, BLOCKERs 1+2).
    /// Gated EXACTLY like the success path (review round
    /// 5, BLOCKER): while a recovery holds the gate, the
    /// arm must SURVIVE — clearing it here and calling a
    /// chain whose guard then refuses is how an advance
    /// gets silently destroyed. The recovery completion
    /// is the arm's consumer in that ordering.
    private func handOffArmedAdvance() {
        if advancePending, !opInFlight {
            advancePending = false
            runAdvanceChain()
        }
    }

    private func fireAdvance() {
        guard let queued = queuedItem, player.currentItem !== queued else { return }
        cancelDeferredFailure(why: "advance sang tập kế")
        player.advanceToNextItem()
        // An advance consumed after the current item had
        // already ENDED (the late-prefetch path) leaves
        // the player paused on the new item — press play
        // explicitly; while already playing this is a
        // no-op.
        player.play()
        // FL-343 (A): stamp the expectation. The
        // supervisor's transition bookkeeping clears it
        // when the queue's current item actually becomes
        // the queued one; if 20 s pass with the player
        // parked .paused and the playhead frozen, the
        // advance never landed — the paused-limbo leg.
        advanceUnconfirmedSince = Date()
        advanceUnconfirmedPosition = player.currentTime().seconds
        pausedStallSince = nil
        log("advanceToNextItem — chờ supervisor xác nhận bằng item identity")
    }

    // MARK: Media selections (defaults + owner's manual picks)

    /// On an item's ready: apply the standing defaults
    /// (subtitles OFF, audio en) ONLY where the owner
    /// has not picked manually; a manual pick is captured
    /// from the outgoing item and re-applied instead
    /// (FL-049). 2.0.46 (owner ruling 2026-11-21 02:05):
    /// TVB YouTube titles are already Vietnamese-dubbed,
    /// so the legible default is NO selection — the
    /// assembled HLS still carries the subtitle
    /// renditions for the player's own panel, where the
    /// owner's manual pick (including a track) applies.
    private func applyMediaSelections(to item: AVPlayerItem?) {
        guard let item else { return }
        let asset = item.asset
        for characteristic in [AVMediaCharacteristic.legible,
                               AVMediaCharacteristic.audible] {
            guard let group = asset.mediaSelectionGroup(forMediaCharacteristic: characteristic),
                  !group.options.isEmpty else { continue }
            if let manual = manualSelections[characteristic] {
                item.select(manual, in: group)
                continue
            }
            if characteristic == .legible {
                // 2.0.46 (owner ruling 2026-11-21 02:05):
                // subtitles start OFF — explicitly select
                // no legible option so neither the playlist
                // nor a system preference can surface one.
                // AVPlayerItem.select(_:in:) takes an
                // Optional option; passing nil deselects
                // every option in the group (AVFoundation,
                // AVPlayerItem.h — selectMediaOption:inGroup:).
                item.select(nil, in: group)
            } else {
                let pick = group.options.first { $0.locale?.language.languageCode?.identifier == "en" }
                    ?? group.defaultOption
                if let pick { item.select(pick, in: group) }
            }
        }
    }

    private func captureManualSelections(from item: AVPlayerItem?) {
        guard let item else { return }
        for characteristic in [AVMediaCharacteristic.legible,
                               AVMediaCharacteristic.audible] {
            if let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: characteristic) {
                manualSelections[characteristic] = item.currentMediaSelection
                    .selectedMediaOption(in: group)
            }
        }
    }

    /// FL-350 (2.0.45, leg 2): one group's selected
    /// language for the apply-point log line — the
    /// language code when an option is selected, "off"
    /// when the group exists but nothing is selected,
    /// "none" when the item carries no such group at
    /// all.
    private func selectionLanguage(of item: AVPlayerItem?,
                                   characteristic: AVMediaCharacteristic) -> String {
        guard let item,
              let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: characteristic)
        else { return "none" }
        guard let option = item.currentMediaSelection
            .selectedMediaOption(in: group)
        else { return "off" }
        return option.locale?.language.languageCode?.identifier ?? "?"
    }

    // MARK: FL-499 — witnesses + owner-pause bookkeeping

    /// FL-499 Brief 2 witness (log-only): the item's
    /// seekable ranges and duration at item start, so a
    /// scrub that does not move is attributable from
    /// DiagLog (empty/indefinite ranges vs. a live
    /// transport refusing).
    private func seekWitness(of item: AVPlayerItem?) -> String {
        guard let item else { return "seekable=none duration=none" }
        let ranges = item.seekableTimeRanges.map { value -> String in
            let range = value.timeRangeValue
            return "\(Self.witnessTime(range.start))–\(Self.witnessTime(range.end))"
        }
        return "seekable=[\(ranges.joined(separator: ","))] duration=\(Self.witnessTime(item.duration))"
    }

    private static func witnessTime(_ time: CMTime) -> String {
        if time.isIndefinite { return "indefinite" }
        guard time.isNumeric else { return "invalid" }
        return String(format: "%.1fs", time.seconds)
    }

    /// FL-499 gate R1 F-C1: owner-pause bookkeeping from
    /// the timeControlStatus KVO — the ONLY source since
    /// Brief 2 deleted the Play/Pause bridge (Siri and CEC
    /// play/pause both reach AVKit natively).
    private func trackOwnerPause(_ status: AVPlayer.TimeControlStatus,
                                 itemHealthy: Bool, atEnd: Bool) {
        guard !terminal else { return }
        switch status {
        case .paused:
            // No opInFlight exclusion: a native pause during
            // a stall-triggered rebuild (old item healthy)
            // is the owner's too, and the rebuild's
            // completion must honour it. Model-issued
            // pauses all latch terminal or leave the
            // starting/playing phases first.
            if (phase == .starting || phase == .playing),
               itemHealthy, !atEnd, !currentItemEnded, !ownerPaused {
                ownerPaused = true
                log("pause của chủ (ghi nhận) — cứu hộ sẽ không tự phát lại")
            }
        case .playing, .waitingToPlayAtSpecifiedRate:
            if ownerPaused {
                ownerPaused = false
            }
            if deferredFailure != nil {
                runDeferredFailure(trigger: "resume")
            }
        @unknown default:
            break
        }
    }

    /// FL-499 gate R1 F-C1: the funnel's pause gate.
    /// Returns true when the failure was held.
    private func deferIfOwnerPaused(reason: String, loopback: Bool) -> Bool {
        guard ownerPaused else { return false }
        let itemID = player.currentItem.map(ObjectIdentifier.init)
        if var held = deferredFailure {
            if held.episodeIndex != currentIndex || held.itemID != itemID {
                log("lỗi hoãn cũ (ep=\(held.episodeIndex + 1)) không thuộc item hiện tại — thay bằng lỗi mới của ep=\(currentIndex + 1)")
                deferredFailure = DeferredFailure(reason: reason, loopback: loopback,
                                                  episodeIndex: currentIndex, itemID: itemID)
                return true
            }
            // Second failure on the same held item: the
            // regular cascade outranks the loopback retry
            // (an origin-class failure is the more severe
            // reading; a loopback re-present would only
            // meet it again).
            let wasLoopback = held.loopback
            held.loopback = held.loopback && loopback
            if !loopback { held.reason = reason }
            deferredFailure = held
            log("lỗi thứ hai trong lúc đang hoãn (ep=\(currentIndex + 1), \(loopback ? "loopback" : "cascade")) — phân loại thắng: \(held.loopback ? "loopback" : "cascade")\(wasLoopback != held.loopback ? " (đổi từ loopback)" : "")")
            return true
        }
        deferredFailure = DeferredFailure(reason: reason, loopback: loopback,
                                          episodeIndex: currentIndex, itemID: itemID)
        log("item lỗi trong lúc chủ pause — hoãn cứu hộ tới lần Play kế (KHÔNG tốn recovery, ep=\(currentIndex + 1), \(loopback ? "loopback" : "cascade")) — \(reason)")
        return true
    }

    /// Returns true when the held failure was run or
    /// parked for the supervisor; false when there was
    /// none or it was dropped (stamp mismatch).
    @discardableResult
    private func runDeferredFailure(trigger: String) -> Bool {
        guard var pending = deferredFailure, !terminal else { return false }
        // FL-499 gate R2: only a live surface may recover;
        // on a slate (.failed / .ended) the held failure is
        // dropped, never run.
        guard phase == .starting || phase == .playing else {
            deferredFailure = nil
            log("bỏ cứu hộ đã hoãn (trigger=\(trigger)) — pha \(phaseName), không còn mặt phát")
            return false
        }
        // Stamp check: never run against another episode.
        let itemID = player.currentItem.map(ObjectIdentifier.init)
        if pending.episodeIndex != currentIndex
            || (itemID != nil && itemID != pending.itemID) {
            deferredFailure = nil
            log("bỏ cứu hộ đã hoãn (trigger=\(trigger)) — dấu ep=\(pending.episodeIndex + 1) không khớp tập/item hiện tại ep=\(currentIndex + 1)")
            return false
        }
        ownerPaused = false
        guard !opInFlight else {
            // The funnel would refuse silently: keep the
            // failure, marked released, for the supervisor
            // to run once the operation finishes.
            if !pending.released {
                pending.released = true
                deferredFailure = pending
                log("cứu hộ đã hoãn chưa chạy được (trigger=\(trigger), đang có thao tác) — giữ lại, chạy khi rảnh")
            }
            return true
        }
        deferredFailure = nil
        log("chạy cứu hộ đã hoãn (trigger=\(trigger), ep=\(currentIndex + 1), \(pending.loopback ? "loopback" : "cascade")) — \(pending.reason)")
        if pending.loopback {
            retryLoopbackItem(reason: pending.reason)
        } else {
            recoverOrFail(reason: pending.reason)
        }
        return true
    }

    /// Cancels a held failure at an episode transition
    /// (or a retry), with a log line.
    private func cancelDeferredFailure(why: String) {
        guard let held = deferredFailure else { return }
        deferredFailure = nil
        log("huỷ cứu hộ đã hoãn của ep=\(held.episodeIndex + 1) — \(why)")
    }

    /// FL-499 gate R1 F-C1: every rebuild completion's
    /// play. A rebuild that lands while the owner has
    /// paused leaves the player paused; the owner's next
    /// Play continues from the rebuilt item.
    private func playUnlessOwnerPaused(site: String) {
        if ownerPaused {
            log("\(site): dựng xong trong lúc chủ pause — giữ pause, chờ lần Play kế")
        } else {
            player.play()
        }
    }

    /// Short phase name for witness lines.
    var phaseName: String {
        switch phase {
        case .starting: return "starting"
        case .playing: return "playing"
        case .failed: return "failed"
        case .ended: return "ended"
        }
    }

    private func witnessTimeControl(_ status: AVPlayer.TimeControlStatus, at seconds: Double) {
        guard status != lastLoggedTimeControl else { return }
        lastLoggedTimeControl = status
        let name: String
        switch status {
        case .playing: name = "playing"
        case .paused: name = "paused"
        case .waitingToPlayAtSpecifiedRate: name = "waiting"
        @unknown default: name = "unknown(\(status.rawValue))"
        }
        let at = seconds.isFinite ? String(format: "%.1f", seconds) : "?"
        log("timeControlStatus → \(name) @ \(at)s")
    }

    /// Re-reads the current item's selection about once a
    /// second (every 2nd supervisor tick), only once the
    /// item is readyToPlay (its selection groups are then
    /// loaded, so the synchronous accessor never waits).
    /// A new item only sets the baseline — its start
    /// selection is logged at the apply point already.
    private func witnessMediaSelection() {
        selectionWitnessTick += 1
        guard selectionWitnessTick % 2 == 0,
              let item = player.currentItem,
              item.status == .readyToPlay else { return }
        let value = "legible=\(selectionLanguage(of: item, characteristic: .legible)) audible=\(selectionLanguage(of: item, characteristic: .audible))"
        let id = ObjectIdentifier(item)
        if selectionWitnessItem != id {
            selectionWitnessItem = id
            selectionWitnessValue = value
            return
        }
        guard value != selectionWitnessValue else { return }
        selectionWitnessValue = value
        log("media selection \(value) (đổi trong tập, ep=\(currentIndex + 1))")
    }

    private func flashStatus(_ text: String) {
        statusLine = text
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            self?.statusLine = nil
        }
    }
}

// MARK: - Player controller host

/// FL-499 witness: a plain AVPlayerViewController that
/// LOGS every press it receives and then calls super — it
/// consumes nothing and intercepts nothing (no gesture is
/// added: WWDC21 10191, "avoid adding extra gestures to the
/// player"). Presses AVKit's own subviews handle (e.g. a
/// bar dismiss) never climb to this level; the design's
/// §1.7 table reads that case as "no press began line".
final class JoeYtPlayerController: AVPlayerViewController {
    var onPress: ((UIPress.PressType) -> Void)?

    override func pressesBegan(_ presses: Set<UIPress>,
                               with event: UIPressesEvent?) {
        for press in presses { onPress?(press.type) }
        super.pressesBegan(presses, with: event)
    }

    /// FL-499 Brief 2: the host's second witness of the
    /// end of a modal dismissal (the first is the delegate's
    /// playerViewControllerDidEndDismissalTransition). The
    /// host de-duplicates; this observes only — super runs
    /// first and nothing is changed.
    var onDismissedDisappear: (() -> Void)?

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed { onDismissedDisappear?() }
    }

    /// Owner-readable press names for witness lines.
    static func name(of type: UIPress.PressType) -> String {
        switch type {
        case .upArrow: return "upArrow"
        case .downArrow: return "downArrow"
        case .leftArrow: return "leftArrow"
        case .rightArrow: return "rightArrow"
        case .select: return "select"
        case .menu: return "menu"
        case .playPause: return "playPause"
        case .pageUp: return "pageUp"
        case .pageDown: return "pageDown"
        default: return "raw\(type.rawValue)"
        }
    }
}

// MARK: - FL-499 Brief 2: modal presentation

/// FL-499 Brief 2 §3: the ONE funnel for every
/// programmatic route out of the live player. A route
/// that leaves the player (chain fall-through, detail
/// hand-back, page fallback) dismisses the modal FIRST
/// and mutates navigation only in the dismissal's
/// completion, so no navigation change ever lands while
/// the modal still covers the screen. Held by the
/// player view in @State; the host registers itself.
@MainActor
final class JoeYtPlayerSurface {
    weak var host: JoeYtPlayerHost?

    func dismissThen(trigger: String, _ mutate: @escaping @MainActor () -> Void) {
        if let host {
            host.dismissPlayer(trigger: trigger, then: mutate)
        } else {
            DiagLog.write("YT-PLAY", "đóng player (trigger=\(trigger)) — không có host, đi thẳng")
            mutate()
        }
    }
}

/// FL-499 Brief 2 §4: the veil's strings, built by the
/// view from the model exactly as the SwiftUI veil built
/// them.
struct JoeYtVeilText: Equatable {
    var title: String
    var detail: String
}

/// FL-499 Brief 2 §4: the veil and the status pill as ONE
/// non-focusable UIKit overlay, installed in the player
/// controller's contentOverlayView (between the video and
/// AVKit's own controls). Plain UIView/UILabel/
/// UIActivityIndicatorView only — none of them can become
/// focused — and user interaction is off, so the overlay
/// takes neither focus nor presses. Metrics mirror the
/// retired SwiftUI veil/pill (sizes, weights, opacities,
/// spacing, insets).
final class JoeYtPlayerOverlayView: UIView {
    private let veil = UIView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let veilTitle = UILabel()
    private let veilDetail = UILabel()
    private let pill = UIView()
    private let pillLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear

        veil.backgroundColor = .black
        veil.translatesAutoresizingMaskIntoConstraints = false
        addSubview(veil)
        spinner.color = .white
        veilTitle.font = .systemFont(ofSize: 29, weight: .semibold)
        veilTitle.textColor = .white
        veilTitle.textAlignment = .center
        veilDetail.font = .systemFont(ofSize: 24)
        veilDetail.textColor = UIColor.white.withAlphaComponent(0.7)
        veilDetail.textAlignment = .center
        let stack = UIStackView(arrangedSubviews: [spinner, veilTitle, veilDetail])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        veil.addSubview(stack)

        pill.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        pill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pill)
        pillLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        pillLabel.textColor = .white
        pillLabel.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(pillLabel)

        NSLayoutConstraint.activate([
            veil.leadingAnchor.constraint(equalTo: leadingAnchor),
            veil.trailingAnchor.constraint(equalTo: trailingAnchor),
            veil.topAnchor.constraint(equalTo: topAnchor),
            veil.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.centerXAnchor.constraint(equalTo: veil.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: veil.centerYAnchor),
            pillLabel.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 22),
            pillLabel.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -22),
            pillLabel.topAnchor.constraint(equalTo: pill.topAnchor, constant: 11),
            pillLabel.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -11),
            // The SwiftUI pill sat inside the safe area
            // with .padding(.horizontal, 80) and
            // .padding(.bottom, 60).
            pill.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 80),
            pill.trailingAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.trailingAnchor, constant: -80),
            pill.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -60),
        ])
        apply(veil: nil, statusLine: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        pill.layer.cornerRadius = pill.bounds.height / 2
    }

    func apply(veil text: JoeYtVeilText?, statusLine: String?) {
        if let text {
            veilTitle.text = text.title
            veilDetail.text = text.detail
            veil.isHidden = false
            if !spinner.isAnimating { spinner.startAnimating() }
        } else {
            veil.isHidden = true
            spinner.stopAnimating()
        }
        // Same z-order as the SwiftUI ZStack: the pill
        // above the veil.
        if let statusLine {
            pillLabel.text = statusLine
            pill.isHidden = false
        } else {
            pill.isHidden = true
        }
    }
}

/// FL-499 Brief 2 §1: the plain host the representable
/// returns. A black, non-focusable view; it OWNS the
/// player controller and presents it modally while the
/// model's phase is starting/playing, dismisses it on the
/// failure/end slates. Present and dismiss are each
/// guarded by state so neither can run twice; a dismissal
/// the user made (Menu) latches, so the still-playing
/// phase can never re-present it.
final class JoeYtPlayerHost: UIViewController {
    /// Brief 2 §1 names .fullScreen; this build uses
    /// .overFullScreen (PR deviation D1). UIKit documents
    /// that .fullScreen REMOVES the presenting controller's
    /// views once the presentation completes — here that is
    /// the app's root UIHostingController, i.e. the whole
    /// SwiftUI tree, router and this player view included,
    /// whose appearance callbacks then run. Whether SwiftUI
    /// turns that into onDisappear (→ model.stop(), the
    /// router's stop(), the root's .task cancellation) is
    /// undocumented; .overFullScreen keeps the presenter's
    /// views in place by documented contract, so the model
    /// lifecycle stays bound to the SwiftUI view, not to the
    /// modal (Brief 2 invariant). One constant: flipping it
    /// to .fullScreen is a one-token change.
    static let presentationStyle: UIModalPresentationStyle = .overFullScreen
    static let presentationStyleName = "overFullScreen"

    let playerController = JoeYtPlayerController()
    let overlay = JoeYtPlayerOverlayView()
    /// Fired once, after a USER dismissal finished.
    var onUserDismiss: (() -> Void)?

    private var wantsLive = false
    private var appeared = false
    /// true from present() until a dismissal is confirmed.
    private var presented = false
    /// a programmatic dismissal is in flight.
    private var dismissing = false
    /// the user dismissed: never present again.
    private var userDismissed = false
    /// F-B1: a route dismissal was asked for — the surface
    /// is leaving: never present again (the phase may
    /// still read .playing, so wantsLive stays true).
    private var routeDismissed = false
    /// UIKit confirmed the presentation (its completion
    /// ran). A dismissal asked for before that is held
    /// and run from the completion — UIKit does not
    /// honour a dismiss issued mid-presentation.
    private var presentConfirmed = false
    private var overlayInstalled = false
    private var pendingAfterDismiss: [@MainActor () -> Void] = []

    override func loadView() {
        let root = UIView()
        root.backgroundColor = .black
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        playerController.modalPresentationStyle = Self.presentationStyle
        playerController.onDismissedDisappear = { [weak self] in
            self?.playerDismissalEnded(source: "viewDidDisappear")
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        appeared = true
        reconcile()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        appeared = false
    }

    func setLive(_ live: Bool) {
        wantsLive = live
        reconcile()
    }

    private func log(_ message: String) {
        DiagLog.write("YT-PLAY", message)
    }

    private func installOverlayIfNeeded() {
        guard !overlayInstalled else { return }
        playerController.loadViewIfNeeded()
        guard let container = playerController.contentOverlayView else {
            log("overlay — contentOverlayView=nil, veil/pill không gắn được")
            return
        }
        overlay.frame = container.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(overlay)
        overlayInstalled = true
    }

    func applyOverlay(veil: JoeYtVeilText?, statusLine: String?) {
        installOverlayIfNeeded()
        overlay.apply(veil: veil, statusLine: statusLine)
    }

    private func reconcile() {
        if wantsLive {
            guard !presented, !dismissing, !userDismissed, !routeDismissed else { return }
            guard appeared, view.window != nil else { return }
            if let other = presentedViewController {
                log("player modal — chưa present được: đang có \(type(of: other)) che")
                return
            }
            installOverlayIfNeeded()
            presented = true
            presentConfirmed = false
            log("player modal — present (style=\(Self.presentationStyleName))")
            // Strong self: the completion must run even if
            // SwiftUI dismantles the host meanwhile (a held
            // route dismissal waits on it).
            present(playerController, animated: false) {
                MainActor.assumeIsolated {
                    self.presentationFinished()
                }
            }
            if playerController.presentingViewController == nil {
                // UIKit refused the presentation (it logs
                // its own reason); nothing is up.
                log("player modal — present bị UIKit từ chối")
                presented = false
            }
        } else if presented, !dismissing {
            dismissPlayer(trigger: "slate", then: nil)
        }
    }

    /// The programmatic dismissal (trigger = slate | route).
    /// Runs `then` once the modal is gone; never mutates
    /// navigation itself.
    func dismissPlayer(trigger: String, then: (@MainActor () -> Void)?) {
        // F-B1: latch BEFORE anything runs, so neither the
        // reconcile() at the end of finishProgrammaticDismiss
        // nor any later SwiftUI update can re-present over
        // the destination; with presented=false after it,
        // dismantle's guard makes no second dismissal.
        if trigger == "route" { routeDismissed = true }
        guard presented else {
            if trigger != "slate" {
                log("đóng player (trigger=\(trigger)) — modal không mở, đi thẳng")
            }
            then?()
            return
        }
        if let then { pendingAfterDismiss.append(then) }
        guard !dismissing else { return }
        dismissing = true
        log("đóng player (trigger=\(trigger))")
        guard presentConfirmed else {
            log("player modal — dismiss chờ present hoàn tất")
            return
        }
        performDismiss()
    }

    /// The modal is up (on screen) or a dismissal of it is
    /// still pending.
    var isPlayerPresented: Bool { presented }

    private func presentationFinished() {
        guard presented else { return }
        presentConfirmed = true
        if dismissing { performDismiss() }
    }

    private func performDismiss() {
        guard playerController.presentingViewController != nil else {
            finishProgrammaticDismiss()
            return
        }
        // Strong self, as for present: queued navigation
        // mutations run from this completion.
        playerController.dismiss(animated: false) {
            MainActor.assumeIsolated {
                self.finishProgrammaticDismiss()
            }
        }
    }

    private func finishProgrammaticDismiss() {
        guard dismissing else { return }
        dismissing = false
        presented = false
        presentConfirmed = false
        let work = pendingAfterDismiss
        pendingAfterDismiss = []
        for item in work { item() }
        reconcile()
    }

    /// End of a dismissal UIKit ran (delegate DidEnd or the
    /// controller's own viewDidDisappear — first wins). A
    /// dismissal this host did not start is the user's.
    func playerDismissalEnded(source: String) {
        guard presented, !dismissing else { return }
        presented = false
        presentConfirmed = false
        userDismissed = true
        log("player modal — dismissal của người dùng xong (\(source))")
        log("menu → đóng player (trigger=menu)")
        onUserDismiss?()
    }
}

/// AVPlayerViewController as the ONLY transport surface:
/// the OS renders its focus, its panel carries the
/// subtitle/audio pickers, and no SwiftUI control is
/// overlaid on it (the 11:15 lesson).
private struct JoeYtPlayerControllerView: UIViewControllerRepresentable {
    let player: AVQueuePlayer
    /// FL-349 (2.0.45, leg 1, path A — Q1): the
    /// next-episode action's presence + handler for the
    /// transport bar's custom menu items. The action
    /// lives in the player's OWN transport bar (Apple's
    /// AVPlayerViewController.transportBarCustomMenuItems,
    /// tvOS 15+ — "you can extend the list of transport
    /// bar controls, using the new property of
    /// AVPlayerViewController, transportBarCustomMenuItems.
    /// It supports instances of UIAction and UIMenu
    /// classes", WWDC21 session 10191), so it is reached
    /// by the native focus engine like every other
    /// transport control — no press is consumed and no
    /// overlay is drawn.
    let hasNextEpisode: Bool
    let onNextEpisode: () -> Void
    /// leader (owner 2026-11-23: Back "lúc được lúc không …
    /// giành giựt nhau"): the transport bar's visibility,
    /// reported up for the press witness lines (Brief 2:
    /// the SwiftUI exit command it once fed is deleted).
    var onBarVisibility: ((Bool) -> Void)? = nil
    /// FL-499 witness: every press the controller receives
    /// (log-only; the controller always calls super).
    var onPress: ((UIPress.PressType) -> Void)? = nil
    /// FL-499 Brief 2 §1: phase starting/playing — the
    /// modal is up exactly while this is true.
    let live: Bool
    /// FL-499 Brief 2 §4: overlay content (nil = hidden).
    let veil: JoeYtVeilText?
    let statusLine: String?
    /// FL-499 Brief 2 §3: the dismissal funnel's link.
    let surface: JoeYtPlayerSurface
    /// FL-499 Brief 2 §2: run once a USER dismissal
    /// (Menu) has finished.
    let onUserDismiss: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> JoeYtPlayerHost {
        let host = JoeYtPlayerHost()
        let controller = host.playerController
        controller.player = player
        controller.showsPlaybackControls = true
        // opt-2 (Back fix): delegate to LOG the transport
        // bar's announced visibility; Brief 2 adds the
        // dismissal callbacks (Coordinator below). Nothing
        // else is answered, so AVKit's behaviour is
        // otherwise unchanged.
        controller.delegate = context.coordinator
        context.coordinator.host = host
        context.coordinator.onNextEpisode = onNextEpisode
        context.coordinator.onBarVisibility = onBarVisibility
        context.coordinator.pressWitness = onPress
        controller.onPress = { [weak coordinator = context.coordinator] type in
            coordinator?.pressWitness?(type)
        }
        host.onUserDismiss = onUserDismiss
        surface.host = host
        applyMenuItems(to: controller, coordinator: context.coordinator)
        host.applyOverlay(veil: veil, statusLine: statusLine)
        host.setLive(live)
        return host
    }

    func updateUIViewController(_ host: JoeYtPlayerHost,
                                context: Context) {
        let controller = host.playerController
        if controller.player !== player {
            controller.player = player
        }
        context.coordinator.onNextEpisode = onNextEpisode
        context.coordinator.onBarVisibility = onBarVisibility
        context.coordinator.pressWitness = onPress
        host.onUserDismiss = onUserDismiss
        surface.host = host
        applyMenuItems(to: controller, coordinator: context.coordinator)
        host.applyOverlay(veil: veil, statusLine: statusLine)
        host.setLive(live)
    }

    /// FL-499 Brief 2 §3: the surface leaving the tree with
    /// the modal still up (any navigation change not routed
    /// through the funnel) is a route dismissal too.
    static func dismantleUIViewController(_ host: JoeYtPlayerHost,
                                          coordinator: Coordinator) {
        guard host.isPlayerPresented else { return }
        host.dismissPlayer(trigger: "route", then: nil)
    }

    /// opt-2 (Back fix, owner 2026-11-22: "mở tvb phim
    /// chạy thì sẽ không bấm được nút back, bấm 3-4 lần nó
    /// mới work"): pre-fix this re-ASSIGNED a brand-new
    /// `[UIAction]` to transportBarCustomMenuItems on EVERY
    /// SwiftUI update of the player view — each phase flip,
    /// each status-pill flash/clear, each WatchStore
    /// progress publish (the view observes WatchStore) —
    /// i.e. several AVKit transport-bar rebuilds in the
    /// first seconds of every episode, exactly the window
    /// in which the owner's Menu presses went unanswered.
    /// The normal-film AVPlayerViewController host (whose
    /// update is empty) never does this, and its Back is
    /// device-proven. Now the items are assigned only when
    /// the item's PRESENCE changes; the action calls
    /// through the coordinator, so it always runs the
    /// latest closure. Same bar, same title, same action.
    private func applyMenuItems(to controller: AVPlayerViewController,
                                coordinator: Coordinator) {
        guard coordinator.appliedHasNext != hasNextEpisode else { return }
        coordinator.appliedHasNext = hasNextEpisode
        if hasNextEpisode {
            controller.transportBarCustomMenuItems = [
                UIAction(title: "Tập tiếp theo") { [weak coordinator] _ in
                    // UIKit runs action handlers on main;
                    // assumeIsolated states that for the
                    // @MainActor coordinator under Swift 6.
                    MainActor.assumeIsolated {
                        coordinator?.onNextEpisode?()
                    }
                }
            ]
        } else if !controller.transportBarCustomMenuItems.isEmpty {
            controller.transportBarCustomMenuItems = []
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        /// nil = nothing assigned yet (first apply always runs).
        var appliedHasNext: Bool?
        var onNextEpisode: (() -> Void)?
        var onBarVisibility: ((Bool) -> Void)?
        /// FL-499 witness sink (refreshed on every update,
        /// so it always logs the view's current state).
        var pressWitness: ((UIPress.PressType) -> Void)?

        /// FL-499 Brief 2: the host whose modal this
        /// delegate reports on.
        weak var host: JoeYtPlayerHost?

        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            willTransitionToVisibilityOfTransportBar visible: Bool,
            with _: AVPlayerViewControllerAnimationCoordinator
        ) {
            DiagLog.write("YT-PLAY", "transport bar \(visible ? "hiện" : "ẩn")")
            onBarVisibility?(visible)
        }

        /// FL-499 Brief 2 §2 (tvOS-only delegate member):
        /// AVKit asks before it dismisses itself on Menu.
        /// Witness only — the answer is AVKit's documented
        /// default (true), so the dismissal is UIKit's own.
        func playerViewControllerShouldDismiss(
            _ playerViewController: AVPlayerViewController
        ) -> Bool {
            DiagLog.write("YT-PLAY", "player modal — AVKit hỏi dismiss → đồng ý")
            return true
        }

        /// FL-499 Brief 2 §2 (tvOS-only delegate member):
        /// the dismissal finished. The host classifies it —
        /// its own programmatic dismissals (slate/route) are
        /// already accounted for and are ignored there.
        func playerViewControllerDidEndDismissalTransition(
            _ playerViewController: AVPlayerViewController
        ) {
            host?.playerDismissalEnded(source: "delegate DidEnd")
        }
    }
}

/// Swift 6: the same SE-0470 main-actor isolated
/// conformance PlayerController.Coordinator uses (see the
/// note there) — AVKit calls the delegate on main only.
extension JoeYtPlayerControllerView.Coordinator: @MainActor AVPlayerViewControllerDelegate {}

// MARK: - Player view

struct JoeYtNativePlayerView: View {
    let request: JoeYtPlayRequest
    /// The router's §4.6 swap: fired by the model when
    /// the native construction dies outright (assembly
    /// + muxed both unusable).
    var onPageFallback: (() -> Void)? = nil
    @EnvironmentObject private var nav: JoeNavigator
    @EnvironmentObject private var watch: WatchStore
    @Environment(\.joeTheme) private var theme
    @StateObject private var model: JoeYtNativePlayerModel
    /// leader: last transport-bar visibility AVKit
    /// announced (the bar announces "hiện" as the player
    /// opens, so the initial value is true).
    @State private var transportBarVisible = true
    @FocusState private var retryFocused: Bool
    /// FL-353 sweep (2.0.45 gate round 5, C5-3): the end
    /// slate's back button focus.
    @FocusState private var endFocused: Bool
    /// FL-499 Brief 2 §3: the dismissal funnel's link to
    /// the modal host (one per player view).
    @State private var surface = JoeYtPlayerSurface()

    init(request: JoeYtPlayRequest, firstPlayable: JoeYtPlayable,
         onPageFallback: (() -> Void)? = nil) {
        self.request = request
        self.onPageFallback = onPageFallback
        _model = StateObject(wrappedValue: JoeYtNativePlayerModel(
            request: request, firstPlayable: firstPlayable))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            // FL-499 Brief 2 §1: the host is mounted for
            // the player view's whole life (a plain black,
            // non-focusable UIViewController); it PRESENTS
            // the AVPlayerViewController modally while the
            // phase is starting/playing and dismisses it on
            // the failure/end slates, so the slate's button
            // is the only focusable thing on screen then —
            // the 2026-11-20 11:15 lesson is kept by the
            // dismissal instead of by unmounting. Unmounting
            // the host itself would orphan a presented modal.
            JoeYtPlayerControllerView(
                player: model.player,
                hasNextEpisode: model.hasNextEpisode,
                onNextEpisode: { model.requestAdvance(trigger: "menu") },
                onBarVisibility: { transportBarVisible = $0 },
                onPress: { type in
                    DiagLog.write("YT-PLAY", "press began type=\(JoeYtPlayerController.name(of: type)) bar=\(transportBarVisible ? "hiện" : "ẩn") phase=\(model.phaseName) hasNext=\(model.hasNextEpisode)")
                },
                live: model.phase == .starting || model.phase == .playing,
                veil: model.phase == .starting ? veilText : nil,
                statusLine: model.statusLine,
                surface: surface,
                // FL-499 Brief 2 §2: the ONLY exit from the
                // live player — UIKit's own modal dismissal
                // (Menu), reported by the host once it has
                // finished; the host logs
                // "menu → đóng player (trigger=menu)".
                onUserDismiss: { nav.ytPlayer = nil })
                .ignoresSafeArea()
            if model.phase == .ended {
                endSlate
            }
            if case .failed(let text) = model.phase {
                failureSlate(text)
            }
        }
        // FL-499 Brief 2 §2: NO .onExitCommand and NO
        // .onPlayPauseCommand here any more. While the
        // player is live it is a modal AVPlayerViewController
        // and AVKit owns Menu (bar dismiss, then its own
        // dismissal) and Play/Pause natively. On the slates
        // (modal dismissed) Menu climbs to the root's
        // handler, which closes this layer.
        .onAppear {
            model.attachStore(watch)
            // FL-499 Brief 2 §3: every route out of the live
            // player dismisses the modal FIRST, then mutates.
            model.onPageFallback = { [surface] in
                surface.dismissThen(trigger: "route") {
                    onPageFallback?()
                }
            }
            model.onFallThrough = { [surface] route in
                surface.dismissThen(trigger: "route") {
                    nav.ytPlayer = nil
                    nav.ytDetail = nil
                    nav.movie = route
                }
            }
            model.onDetailFallThrough = { [surface] token in
                surface.dismissThen(trigger: "route") {
                    nav.ytPlayer = nil
                    nav.ytChainPlay = token
                }
            }
        }
        .task { model.start() }
        .onDisappear { model.stop() }
    }

    /// FL-499 Brief 2 §4: the veil's strings — the retired
    /// SwiftUI veil's exact text, now drawn by the UIKit
    /// overlay inside the player's contentOverlayView.
    private var veilText: JoeYtVeilText {
        JoeYtVeilText(
            title: "Đang mở phim…",
            detail: "\(request.seriesTitle) · \(model.episodeLabel)\(model.startingQualityLabel.isEmpty ? "" : " · \(model.startingQualityLabel)")")
    }

    private var endSlate: some View {
        ZStack {
            Color.black.opacity(0.85)
            VStack(spacing: 14) {
                Text("Đã hết tập cuối của bộ này.")
                    .font(.system(size: 31, weight: .semibold))
                    .foregroundStyle(.white)
                // FL-353 same-family sweep (gate round 5,
                // C5-3): this slate was TEXT-ONLY — no
                // focusable element, so the Menu promise in
                // its own second line could never fire (the
                // §8.1 mechanism: an onExitCommand receives
                // Menu only while something in its tree
                // holds focus) and Menu exited the app
                // instead. One focusable button —
                // failureSlate's exact construction in this
                // file — makes both exits real.
                Button {
                    DiagLog.write("YT-PLAY", "slate end — về detail (trigger=nút)")
                    nav.ytPlayer = nil
                } label: {
                    JoeSecondaryLabel(title: "Quay lại danh sách tập")
                }
                .joeCardButton()
                .focused($endFocused)
                Text("Bấm Menu để quay lại danh sách tập.")
                    .font(.system(size: 25))
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
        .ignoresSafeArea()
        .defaultFocus($endFocused, true)
    }

    private func failureSlate(_ text: String) -> some View {
        ZStack {
            Color.black.opacity(0.9)
            VStack(spacing: 22) {
                Text(text)
                    .font(.system(size: 27))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 1100)
                Button {
                    model.retry()
                } label: {
                    JoeSecondaryLabel(title: "Thử lại")
                }
                .joeCardButton()
                .focused($retryFocused)
            }
        }
        .ignoresSafeArea()
        .defaultFocus($retryFocused, true)
    }
}
