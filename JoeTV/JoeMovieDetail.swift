import SwiftUI
import UIKit

/// Movie detail: header (poster, meta, synopsis), the favourite
/// toggle, "Nguồn khác:" chips for the other provider carrying
/// the same film, and per-server episode chips. Tapping an
/// episode builds a PlayDirector — links are resolved FRESH
/// inside the director (never from this screen, never stored),
/// with the Android failover ladder behind it.
struct JoeMovieDetail: View {
    let route: MovieRoute
    @EnvironmentObject private var watch: WatchStore
    @EnvironmentObject private var nav: JoeNavigator
    /// Idea 7a: the follow store (FollowStore.shared) —
    /// observed so the "Theo dõi" toggle's label re-renders
    /// the moment a follow / unfollow lands.
    @ObservedObject private var followStore = FollowStore.shared
    @Environment(\.joeTheme) private var theme
    @State private var provider: String
    @State private var slug: String
    @State private var detail: Detail?
    @State private var tmdb: TMDBInfo?
    /// Idea 3(c) (checkpoint 2.0.25): the title logo lives in
    /// its OWN state now — TMDBClient.fetchInfo no longer
    /// awaits the logo (its TMDBInfo.logoURL is always ""),
    /// so the detail fetches the logo in parallel via
    /// TMDBClient.fetchLogo and publishes it here the moment
    /// it lands ("" until then). The backdrop/overview in
    /// `tmdb` apply as soon as fetchInfo returns; nothing
    /// serialises behind the logo.
    @State private var tmdbLogoURL: String = ""
    @State private var alternatives: [(code: String, slug: String)] = []
    /// Idea 20: the actor page presented over this detail
    /// when a TMDB cast member is tapped — see
    /// JoeActorPage.swift (.tmdb mode).
    @State private var actorRoute: JoeActorRoute?
    /// Idea 21: the franchise strip's resolved state — the
    /// collection name and its PLAYABLE parts only (matched
    /// via Providers.search on the part's TMDB id; unmatched
    /// parts are dropped silently, and the current title's
    /// own part is excluded). Empty = no strip.
    @State private var franchiseName = ""
    @State private var franchiseMovies: [Movie] = []
    /// The film's resolved cross-service identity (v2.0.5,
    /// D3): the detail-time ladder's result (Providers
    /// .resolveIdentity, run in load() alongside
    /// findAlternatives). nil = the ladder has not landed
    /// for this record yet; a landed value with an empty
    /// imdbId is a resolved NEGATIVE — the Torrent entry's
    /// honest state, not a loading state.
    @State private var filmIdentity: Providers.FilmIdentity?
    @State private var loadFailed = false
    /// v2.0.29 (cluster A, items 1b + 4): the first-open
    /// initial-focus landing has been WRITTEN (see
    /// landInitialFocus(on:)) — the write happens once per
    /// detail, at its first paint, never on a provider
    /// switch (the switch path of load() does not call it,
    /// so a switch never yanks focus off the chip the owner
    /// tapped).
    @State private var didLandInitialFocus = false
    @State private var playerHolder: DirectorHolder?
    @State private var switching = false
    /// C-9: the last provider/slug whose detail actually loaded.
    /// A failed switch reverts to these (see load()).
    @State private var lastGoodProvider: String
    @State private var lastGoodSlug: String
    @State private var switchNotice: String?
    /// v2.0.31 (L7): TVB holders struck during this page's
    /// life — a holder whose loaded payload CONTRADICTED
    /// the snapshot identity (or, for a name-fallback
    /// record, failed to affirm it), or that failed to
    /// load at all, is never retried on this page; the
    /// load walks the remaining holders and lands on the
    /// honest no-exact-source state when none are left.
    /// Empty on every non-TVB page.
    @State private var tvbStruck: Set<String> = []
    /// v2.0.31 (L7): every TVB holder struck — the error
    /// slate is showing the no-exact-source wording
    /// instead of a film (and instead of the generic
    /// network wording).
    @State private var tvbNoExactSource = false
    /// v2.0.31 (I1): the auto-pick runs at most once per
    /// page — after it moves the page to a playable
    /// holder, later loads (the switch that follows
    /// included) never re-evaluate into a second move.
    @State private var tvbAutoPickDone = false
    /// v2.0.33 (item 3): Details the I1 probe already
    /// fetched and identity-gated for OTHER playable
    /// holders, keyed by provider code — kept so the
    /// auto-pick switch (and any later manual switch to a
    /// probed holder) can paint the winning source's
    /// episodes from the probe's own payload instead of
    /// refetching it. Consumed (removed) by load()'s
    /// switch path when it is used; a holder that was not
    /// probed, or whose entry was already consumed, takes
    /// the ordinary fetch path unchanged. Empty on every
    /// non-TVB page.
    @State private var tvbKeptDetails: [String: TVBKeptDetail] = [:]
    /// v2.0.33 (item 2a): the I1 probe found NO playable
    /// TVB source for this title at all — the episode
    /// section then shows the honest no-source notice
    /// (see serverGroups) instead of an empty silence.
    /// Set from the probe outcome in
    /// launchAlternativesAndIdentity and cleared by
    /// load() whenever a painted detail actually has a
    /// playable start episode. False on every non-TVB
    /// page.
    @State private var tvbNoPlayableSource = false
    /// Owner source-priority policy (2026-11-15, IN v2.0.0 per
    /// the owner's 16:08 ruling): the Nguồn phát mode for THIS
    /// film's play sessions — Tự động (true, the default) or a
    /// pinned source (false, set by tapping any specific source
    /// chip/row). Per-session state on the detail view: it is
    /// never persisted and resets with the film.
    @State private var autoSource = true
    /// TVB YouTube feature (design §1.6 final paragraph +
    /// the owner's shared-grid ruling, 2026-11-19): when
    /// this TVB title has a YouTube match, THIS detail gains
    /// the [Tự động] [YouTube] source modes and ONE shared
    /// episode grid — Auto takes YouTube per-episode, the
    /// chain covers the episodes YouTube lacks. Any specific
    /// chain-source tap pins the chain (ytChainPinned, the
    /// existing pin gesture); the Tự động / YouTube chips
    /// clear the pin. Per-session, never persisted — the
    /// same discipline as autoSource.
    @ObservedObject private var ytStore = JoeYtStore.shared
    @ObservedObject private var ytSession = JoeYtSession.shared
    /// v2.1.1 (WS-C, DIAG-2050 §1c): the YouTube identity
    /// surface's model, observed ONLY for the Private
    /// Cinema trailer sign-in prompt (pcTrailerSignInPrompt):
    /// its userCode / flowError / flowFinished drive that
    /// prompt exactly as they drive the router's
    /// JoeYtDeviceCodeView. No other theme reads it here.
    @ObservedObject private var ytIdentity = JoeYtIdentity.shared
    /// v2.1.1 (WS-C): a trailer attempt in THIS detail ended
    /// in needsIdentity and the PC sign-in prompt is up.
    /// Set only under .privateCinema (see startTrailerPreview);
    /// every other theme keeps the preview's silent rule.
    @State private var trailerSignInPrompt = false
    @State private var ytMode: JoeYtSourceMode = .auto
    @State private var ytChainPinned = false

    /// 2.0.48: the backdrop preview's controller (Leg 3 —
    /// see JoePreview.swift). One per detail presentation;
    /// killed by ANY input (the onChange hooks below) and
    /// torn down on disappear.
    @StateObject private var preview = JoePreviewController()
    @Environment(\.scenePhase) private var scenePhase

    @FocusState private var ytEpFocus: Int?
    @FocusState private var focusedEp: String?
    /// v2.0.49 (item 7): bumped by handleExitCommand to
    /// make detailScrollContent's ScrollViewReader jump
    /// to the top of the page (owner order 2026-11-21).
    @State private var topScrollSignal = 0
    /// FIX-213 (Fault 1, DIAG-20261122): the Menu exit's
    /// second-press arm. Menu #1 jumps to the top and arms
    /// this; Menu #2 closes — INDEPENDENT of whether the
    /// jump's programmatic focus write landed on Play (a
    /// write aimed at a view the lazy stack has not
    /// re-realised yet is dropped silently, and pre-fix
    /// each dropped write cost another apparently-dead
    /// Menu press). Cleared by any focus change and any
    /// button press (see focusLandingChanged /
    /// killPreviewOnInput), so an armed exit never
    /// survives the user navigating or interacting.
    @State private var exitArmed = false
    @FocusState private var focusedPlay: Bool
    /// v2.0.5 (N1, pair h): the favourite button joins the
    /// detail's focus system — pre-fix it was the one header
    /// control with NO binding, so the play ↔ favourite pair
    /// had no declared route at all.
    @FocusState private var focusedFav: Bool
    /// Idea 7a: the follow toggle's focus binding, paired
    /// with focusedFav exactly as the favourite button's is.
    @FocusState private var focusedFollow: Bool
    @FocusState private var focusedAlt: String?
    /// v2.1.1 (WS-C): the PC trailer sign-in prompt's two
    /// buttons ("retry" / "dismiss") share one binding —
    /// the branches are mutually exclusive in time with
    /// the retry button, exactly as in JoeYtDeviceCodeView.
    @FocusState private var focusedSignIn: String?
    @FocusState private var focusedRetry: Bool
    /// Idea 20: the cast row's focus binding (member ids).
    @FocusState private var focusedCast: Int?
    /// Idea 21: the franchise strip's focus binding.
    @FocusState private var focusedFranchise: String?
    /// v2.1.1 fix round (Lens C F2): the PC detail's
    /// back row ("← Quay lại") focus binding. Read only
    /// by the PC composition's back row; every other
    /// theme never installs the button, so the binding
    /// simply never lands there.
    @FocusState private var focusedBack: Bool

    struct DirectorHolder: Identifiable {
        let id = UUID()
        let director: PlayDirector
        /// Player-slate heading data (UI-6 defect D-18): the
        /// film title + episode for the slate's kicker line.
        var title = ""
        var episode = ""
        /// The active source mode for the slate's source line
        /// (owner source-priority policy): "Nguồn: Tự động…"
        /// or the pinned source's name.
        var sourceLine = ""
    }

    init(route: MovieRoute) {
        self.route = route
        _provider = State(initialValue: route.provider)
        _slug = State(initialValue: route.slug)
        _lastGoodProvider = State(initialValue: route.provider)
        _lastGoodSlug = State(initialValue: route.slug)
    }

    private var favKey: String { WatchStore.movieFavKey(provider: provider, slug: slug) }
    private var isFav: Bool { watch.isFavorite(key: favKey) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if theme.id == .ultra {
                ultraBackdrop
            } else if theme.id == .privateCinema {
                // v2.1.0 (Private Cinema): the PC detail
                // rides its own fixed full-screen backdrop,
                // modelled on Ultra's (see cinemaBackdrop).
                cinemaBackdrop
            }
            detailScroll
        }
    }

    /// 2.0.48 type-erasure fix (CI run #33): with every
    /// leaf of the chain extracted, the timeout migrated
    /// to the chain's ROOT — the checker resolving the
    /// four layers' nested opaque types where they
    /// compose (the detailScroll body, :350). The layers
    /// now erase to AnyView at every boundary: each
    /// layer's body is checked against a concrete AnyView
    /// base, and no parent ever resolves another layer's
    /// underlying type. The same erasure caps the file's
    /// other multi-layer composition points — the four
    /// themed detail compositions where the content
    /// switch composes them, the placeholder header's
    /// theme switch, the franchise strip, and the Ultra
    /// backdrop stack where body composes it. Modifier
    /// order, views and conditions are unchanged
    /// everywhere.
    private var detailScrollContent: AnyView {
        // v2.0.49 (item 7): the ScrollView now sits inside
        // a ScrollViewReader so Menu can jump straight to
        // the top of the page (see handleExitCommand). The
        // shape stays one AnyView wrapping one expression.
        AnyView(ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
            // v2.0.8 (Phase 7): lazy root — server groups and
            // their episode chips build as they scroll into
            // view instead of all up front. Children, order
            // and the 32 gap are identical to the eager stack.
            LazyVStack(alignment: .leading, spacing: 32) {
                if let detail {
                    if let switchNotice {
                        // C-9: a failed provider switch reverted —
                        // say so, naming both providers (§8).
                        Text(switchNotice)
                            .font(theme.id == .privateCinema
                                  ? JoePCType.outfit(25)
                                  : .system(size: 25))
                            .foregroundStyle(.orange)
                    }
                    // v2.0.0 (UI-5): the detail's anatomy follows
                    // the active design over the SAME state, load
                    // logic and actions — A backdrop-led with the
                    // poster overlapping the band, D centred, F
                    // source-list-first.
                    switch theme.id {
                    case .billboard:
                        billboardDetail(detail)
                    case .posterWall:
                        wallDetail(detail)
                    case .sourceBoard:
                        boardDetail(detail)
                    case .ultra:
                        ultraDetail(detail)
                    case .privateCinema:
                        privateCinemaDetail(detail)
                    }
                    // Idea 21: the franchise strip sits at the
                    // END of the detail, below every theme's
                    // episode/server region — one shared slot,
                    // so no theme composition moves. It renders
                    // only when a collection part matched a
                    // playable title (see loadFranchise).
                    AnyView(franchiseStrip)
                } else if loadFailed {
                    // §8: the G3 error shape + Retry.
                    // v2.0.31 (L7): a TVB page that exhausted
                    // its holders says THAT — the app never
                    // substitutes a different film, and the
                    // wording must not blame the network for
                    // an identity verdict.
                    VStack(alignment: .leading, spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 44))
                            .foregroundStyle(.orange)
                        Text(tvbNoExactSource
                             ? "Không mở được đúng phim này."
                             : "Không tải được thông tin phim.")
                            .font(theme.id == .privateCinema
                                  ? JoePCType.outfit(29, weight: .semibold)
                                  : .system(size: 29, weight: .semibold))
                            .foregroundStyle(theme.text)
                        Text(tvbNoExactSource
                             ? "Các nguồn TVB đều không dùng được hoặc không khớp đúng phim — app không mở thay bằng phim khác."
                             : "Kiểm tra mạng rồi thử lại.")
                            .font(theme.id == .privateCinema
                                  ? JoePCType.outfit(25) : .system(size: 25))
                            .foregroundStyle(theme.meta)
                        Button {
                            retryButtonTapped()
                        } label: {
                            JoePrimaryLabel(title: "Thử lại")
                        }
                        .joeCardButton()
                        .focused($focusedRetry)
                    }
                    .padding(.top, 60)
                    // v2.0.6 (leader hardening, error-8b doctrine):
                    // the landing on this surface is DECLARED, not
                    // left to load()'s one-shot focusedRetry write
                    // racing the branch swap — the same cure the
                    // player slate got in v2.0.5.
                    .defaultFocus($focusedRetry, true)
                } else {
                    placeholderHeader
                    ProgressView("Đang tải danh sách tập…")
                        .font(theme.id == .privateCinema
                              ? JoePCType.outfit(29) : .system(size: 29))
                        .foregroundStyle(theme.text)
                        .tint(theme.text)
                }
            }
            .id("joeDetailTop")
            // No manual padding: the layer sits inside the root
            // safe area, which IS the §4 inset (80/60).
            // FIX-214 (FULL-THEME-AUDIT-214 B10): under
            // Private Cinema the drawn text frame is x94,
            // not the ambient x80 — the PC leg adds the
            // +14 here (the one shared stack, so the
            // increment is a value branch, not a second
            // composition). Legacy themes keep x80.
            .padding(.horizontal, theme.id == .privateCinema ? 14 : 0)
            }
            // v2.0.49 (item 7): the Menu-to-top jump's scroll
            // hook, inside the reader.
            .onChange(of: topScrollSignal) { _, _ in
                proxy.scrollTo("joeDetailTop", anchor: .top)
            }
        })
    }

    /// 2.0.48 structural fix (CI runs #30/#31): the
    /// detail scroll's modifier chain used to be ONE
    /// expression tree — ScrollView + six tasks + two
    /// covers + some twenty hooks — and the type-checker
    /// timed out inside it, the reported line migrating
    /// between runs. The chain is now staged through
    /// computed properties, type-erased to AnyView at
    /// every boundary since run #33 (this one carries the
    /// six .task modifiers, their bodies slimmed to calls
    /// into named async methods below), so no single
    /// expression is heavy. Modifier ORDER is unchanged.
    ///
    /// Stepwise stage (CI run #34): run #33's erasure
    /// moved the timeout onto the AnyView wrap itself
    /// (:367) — erasing the RETURN type never shrank the
    /// argument expression the checker still had to price
    /// inside the call. The three chain layers now compose
    /// IMPERATIVELY: sequential let bindings, each applying
    /// exactly ONE modifier, so every statement is priced
    /// on its own and no single expression composes the
    /// chain. The nesting each binding builds is identical
    /// to the chained form it replaces — same modifiers,
    /// same order, same closures.
    private var detailScrollTasks: AnyView {
        let loadStage = detailScrollContent
            .task(id: loadTaskID) { await load() }
        let enrichStage = loadStage
            .task(id: detail?.movie.id ?? "") { await runTMDBEnrichment() }
        let logoStage = enrichStage
            .task(id: detail?.movie.id ?? "") { await runTMDBLogoFetch() }
        let dwellStage = logoStage
            .task(id: dwellTaskID) {
                // v2.0.8 (Phase 2/3): dwell pre-resolve — see
                // dwellPreResolve(). SwiftUI cancels and restarts
                // this task whenever the key changes (provider,
                // slug, focused episode, detail arrival), so
                // speculative work dies on exit/switch by itself.
                await dwellPreResolve()
            }
        let previewStage = dwellStage
            .task(id: previewTaskID) {
                // 2.0.48 (Leg 3): the backdrop preview's dwell.
                // Keyed WITHOUT the focused episode on purpose:
                // the preview target is fixed at open time (the
                // episode Play would play), and a focus move is
                // an input that KILLS the preview (rule D1) —
                // it must never restart this task into a fresh
                // attempt. Provider/slug changes re-key it, but
                // the kill latch the switch's own input set
                // keeps the new run silent.
                await runPreview()
            }
        let franchiseStage = previewStage
            .task(id: tmdb?.collectionId ?? 0) {
                // Idea 21: the franchise load — keyed on the
                // loaded TMDBInfo's collection id, so it starts
                // the moment fetchInfo lands a collection and
                // re-runs only for a different one. Fail-soft:
                // no collection / no matched part leaves the
                // strip absent and the detail exactly as it was.
                await loadFranchise()
            }
        return AnyView(franchiseStage)
    }

    /// Structural fix, stage 3: the two full-screen
    /// covers, the declared Play focus and the exit hook.
    /// Stepwise since run #34 (see detailScrollTasks):
    /// one modifier per let binding.
    private var detailScrollCovers: AnyView {
        let actorStage = detailScrollTasks
            .fullScreenCover(item: $actorRoute) { route in
                JoeActorPage(route: route)
            }
        let playerStage = actorStage
            .fullScreenCover(item: $playerHolder) { holder in
                JoePlayerView(director: holder.director,
                              attemptRows: chainAttemptRows,
                              filmTitle: holder.title,
                              filmEpisode: holder.episode,
                              sourceLine: holder.sourceLine)
            }
        let focusStage = playerStage
            .defaultFocus($focusedPlay, true)
        let exitStage = focusStage
            // Menu closes THIS detail (1.9.2, Team 9 item 4): the
            // handler lives on the detail's OWN root — the
            // placement the player's own-root handler device-proves.
            // The 1.9.1 handler sat on the root ZStack's wrapper
            // layer, outside this view, and Menu exited the app
            // from here on device. Unconditional: it exists exactly
            // while the detail does.
            .onExitCommand { handleExitCommand() }
        return AnyView(exitStage)
    }

    /// Structural fix, final stage: the preview/input
    /// hooks, the scene-phase hook, the YouTube session
    /// task and the chain hand-back hook. Stepwise since
    /// run #34 (see detailScrollTasks): one modifier per
    /// let binding.
    private var detailScroll: AnyView {
        // 2.0.48 (Leg 3, rule D1): ANY input kills the
        // backdrop preview for this visit. Every focus
        // binding on this screen reports here — a swipe
        // or arrow press moves focus before anything
        // else can happen — and the remaining inputs
        // (Play presentation, provider switch, the app
        // leaving the foreground) ride their own hooks.
        // Focus transitions report their old/new VALUES
        // so the controller can tell the app's own
        // initial focus landing (the visit's first
        // unset→set transition) from a user press; every
        // other transition kills, dwell included (see
        // JoePreview.swift focusInput).
        let epFocusStage = detailScrollCovers
            .onChange(of: focusedEp) { old, new in
                focusLandingChanged(old: old, new: new)
            }
        let ytEpFocusStage = epFocusStage
            .onChange(of: ytEpFocus) { old, new in
                focusLandingChanged(old: old, new: new)
            }
        let playFocusStage = ytEpFocusStage
            .onChange(of: focusedPlay) { old, new in
                focusLandingChanged(old: old, new: new)
            }
        let favFocusStage = playFocusStage
            .onChange(of: focusedFav) { old, new in
                focusLandingChanged(old: old, new: new)
            }
        let followFocusStage = favFocusStage
            .onChange(of: focusedFollow) { old, new in
                focusLandingChanged(old: old, new: new)
            }
        let altFocusStage = followFocusStage
            .onChange(of: focusedAlt) { old, new in
                focusLandingChanged(old: old, new: new)
            }
        let retryFocusStage = altFocusStage
            .onChange(of: focusedRetry) { old, new in
                focusLandingChanged(old: old, new: new)
            }
        let castFocusStage = retryFocusStage
            .onChange(of: focusedCast) { old, new in
                focusLandingChanged(old: old, new: new)
            }
        let franchiseFocusStage = castFocusStage
            .onChange(of: focusedFranchise) { old, new in
                focusLandingChanged(old: old, new: new)
            }
        // v2.1.1 fix round (Lens C F2): the PC back row's
        // binding joins the D1 reporting like every other
        // binding on this screen — one stage, same shape.
        let backFocusStage = franchiseFocusStage
            .onChange(of: focusedBack) { old, new in
                focusLandingChanged(old: old, new: new)
            }
        let playerStage = backFocusStage
            .onChange(of: playerHolder?.id) { handlePlayerPresentation() }
        let ytPlayerStage = playerStage
            .onChange(of: nav.ytPlayer?.id) { handleYtPlayerPresentation() }
        let providerStage = ytPlayerStage
            .onChange(of: provider) { handleProviderChange() }
        let sceneStage = providerStage
            .onChange(of: scenePhase) { handleScenePhaseChange() }
        let disappearStage = sceneStage
            .onDisappear { handleDetailDisappear() }
        let ytSessionStage = disappearStage
            // TVB YouTube feature: the catalogue + session state
            // the source-row integration reads, and the chain
            // hand-back — when the YouTube player (launched from
            // this detail in Auto) gives an episode back, this
            // detail plays it via the chain itself.
            .task { await loadYtSession() }
        let chainStage = ytSessionStage
            .onChange(of: nav.ytChainPlay) { _, token in
                handleYtChainPlay(token)
            }
        return AnyView(chainStage)
    }

    // MARK: - 2.0.48 sweep: hook handlers + hoisted keys

    /// Sweep (CI run #32): the type-check timeout
    /// migrated a third time — from the scenePhase
    /// line (run #30) to the session-refresh line
    /// (run #31) to the ytPlayer hook (run #32,
    /// :420) — so the whole file was swept in one
    /// pass: every remaining inline body in the
    /// scroll chain and every preview call standing
    /// in a view closure moved into a named method,
    /// and every compound expression in a modifier
    /// argument or task key was hoisted into an
    /// explicitly-typed let or computed property.
    /// Behaviour is unchanged everywhere: same
    /// conditions, same order, same arguments and
    /// reason strings.

    /// The load task's key (was inline in the chain).
    private var loadTaskID: String {
        slug + "|" + provider
    }

    /// The dwell task's key (was inline in the chain).
    private var dwellTaskID: String {
        provider + "|" + slug + "|" + (focusedEp ?? "")
            + "|" + (detail == nil ? "0" : "1")
    }

    /// The preview task's key (was inline in the
    /// chain).
    private var previewTaskID: String {
        "preview|" + provider + "|" + slug
            + "|" + (detail == nil ? "0" : "1")
    }

    /// The chain player's attempt rows (was an
    /// inline array literal in the cover closure).
    private var chainAttemptRows: [String] {
        [Providers.displayName(Providers.KK),
         Providers.displayName(Providers.VS),
         Providers.displayName(Providers.F4K),
         Providers.displayName(Providers.TP)]
    }

    /// One focus binding's landing report (was
    /// inline in nine .onChange closures in the
    /// chain): the optional bindings land when the
    /// value goes unset → set.
    private func focusLandingChanged<T>(old: T?, new: T?) {
        // FIX-213 (Fault 1): any focus change disarms the
        // Menu exit — the arm belongs to the exact moment
        // after the jump-to-top, and any navigation since
        // means the next Menu is a fresh first press.
        exitArmed = false
        preview.focusInput(landingShaped: old == nil && new != nil)
    }

    /// The Bool bindings' landing report: a landing
    /// is the false → true transition.
    private func focusLandingChanged(old: Bool, new: Bool) {
        exitArmed = false
        preview.focusInput(landingShaped: !old && new)
    }

    /// The chain player's presentation (was an
    /// inline if in its .onChange closure).
    private func handlePlayerPresentation() {
        if playerHolder != nil { preview.kill(reason: "play") }
    }

    /// The YouTube player's presentation — the
    /// chain player's hook does not cover it, and a
    /// TVB title's Play tap (focus already resting
    /// on Play, no focus change) reaches ONLY this
    /// hook. (Was an inline if in its .onChange
    /// closure — the run #32 timeout site.)
    private func handleYtPlayerPresentation() {
        if nav.ytPlayer != nil { preview.kill(reason: "play") }
    }

    /// The provider switch's preview kill (was an
    /// inline .onChange closure body).
    private func handleProviderChange() {
        preview.kill(reason: "input")
    }

    /// The detail's disappearance stops the preview
    /// outright (was an inline .onDisappear
    /// closure).
    private func handleDetailDisappear() {
        preview.stop()
    }

    /// The chain hand-back (was a multi-statement
    /// .onChange closure in the chain): when the
    /// YouTube player (launched from this detail in
    /// Auto) gives an episode back, this detail
    /// plays it via the chain itself.
    private func handleYtChainPlay(_ token: JoeYtChainPlay?) {
        guard let token, token.route == route else { return }
        nav.ytChainPlay = nil
        if let d = detail { play(d, epName: token.epName) }
    }

    /// Menu closes THIS detail (was an inline
    /// .onExitCommand closure in the covers stage).
    private func handleExitCommand() {
        // v2.0.49 (item 7, owner order 2026-11-21 22:32):
        // Menu jumps straight to the top of the page
        // first. Focus on the Play button (this page's
        // declared first element) keeps today's behaviour
        // — Menu closes the detail; anywhere else, Menu
        // scrolls to the top and lands focus on Play,
        // swallowing the exit. Gate R1 (lens C): the
        // preview kill follows the branch — leaving the
        // page kills unconditionally; the jump-to-top
        // branch keeps the visit alive, so it may only
        // kill an attempt actually in flight
        // (killIfAttempting), never latch the visit.
        if focusedPlay == true {
            preview.kill(reason: "menu")
            nav.movie = nil
        } else if exitArmed {
            // FIX-213 (Fault 1): the previous Menu already
            // jumped to the top and armed the exit; the
            // focus write did not land (or focus has since
            // rested somewhere the write cannot be proven
            // from), so this press closes — the exit no
            // longer depends on the programmatic write.
            preview.kill(reason: "menu")
            nav.movie = nil
        } else {
            preview.killIfAttempting(reason: "menu")
            topScrollSignal += 1
            focusedPlay = true
            exitArmed = true
        }
    }

    /// The error branch's Retry press (was inline
    /// in the button's action closure in the content
    /// stage). D1 (review round 2, defect 2): a
    /// Select press is owner input even on this
    /// surface — a successful retry re-keys the
    /// preview task when the detail lands, and
    /// without this kill a preview could auto-play
    /// inside a visit the owner already interacted
    /// with (the provider switch carries the
    /// equivalent explicit kill via its hook).
    private func retryButtonTapped() {
        preview.kill(reason: "input")
        Task { await retryLoad() }
    }

    /// The one bare preview kill every press on
    /// this screen performs (rule D1), named so a
    /// press closure that must also run its own
    /// action (the source rows) stays a pair of
    /// plain calls.
    private func killPreviewOnInput() {
        // FIX-213 (Fault 1): a button press is owner
        // input — it disarms the Menu exit arm like any
        // focus change does (see focusLandingChanged).
        exitArmed = false
        preview.kill(reason: "input")
    }

    /// The YouTube catalogue/session warm-up that used
    /// to sit inline in a .task closure at the end of
    /// the detail scroll's chain (CI run #31 timed out
    /// type-checking exactly there). Same two calls,
    /// same order.
    private func loadYtSession() async {
        ytStore.ensureLoaded()
        await ytSession.refresh()
    }

    /// The TMDB enrichment task's body, moved out of
    /// its .task closure (structural fix above). The
    /// closure now only calls this; every statement,
    /// guard and merge below is the original body,
    /// verbatim.
    private func runTMDBEnrichment() async {
        // TMDB enrichment (v1.6), fail-soft: runs when a
        // TMDB API key is available — the bundled key
        // injected at build time, or one the owner saved in
        // Settings (the saved key wins). Any failure leaves
        // tmdb nil and the screen is the provider-only one.
        //
        // v2.0.1 (Android FIX2 parity): the task stays
        // decoupled from the detail fetch (it always was —
        // a separate task) and publishes in stages, so the
        // band never waits behind the credits call. A film
        // whose payload carries no TMDB id — or a record
        // with no backdrop — is hunted by the name + year
        // title search for a backdrop, exactly like the
        // Android pipeline.
        //
        // v2.0.8 (Phase 2): the staging is now literal —
        // fetchInfo's result publishes the MOMENT it lands
        // (before the backdrop hunt starts), then the
        // backdrop hunt (only when still needed) and the
        // cast fetch run as concurrent async lets, each
        // merging into tmdb when it lands: the hunt fills
        // backdropURL, the credits fill cast. Fail-soft
        // everywhere, exactly as before: no info and no
        // hunted backdrop leaves tmdb nil, and cast only
        // ever merges onto a published info.
        guard let detail, !TMDBClient.apiKey.isEmpty else {
            tmdb = nil
            return
        }
        let movie = detail.movie
        var info: TMDBInfo?
        if let tvbCtx = route.tvb {
            // Swift 6 round (fault c, owner device test
            // of 2.0.31): a TVB session's enrichment is
            // pinned to the SNAPSHOT identity — its TMDB
            // id, as "tv" — never to the provider
            // payload's own tmdbId/tmdbType stamps. The
            // pre-fix task trusted those stamps: a
            // payload whose tmdbType was "" or "movie"
            // made TMDBClient resolve the id in the
            // MOVIE namespace (its kind rule maps every
            // non-"tv" type to "movie"), and TMDB's
            // numeric ids are per-type namespaces, so a
            // same-numbered film's overview / backdrop /
            // cast / rating painted over the correct
            // TVB detail — the wrong-film INFO the owner
            // still saw after the L7 draw gate, which
            // only ever verified the provider payload,
            // never this layer. tvbPinnedIdentity has
            // always pinned the identity ladder this
            // way; the enrichment now takes the same pin.
            info = await TMDBClient.fetchInfo(
                tmdbId: "\(tvbCtx.tmdbId)", type: "tv")
        } else if !movie.tmdbId.isEmpty {
            info = await TMDBClient.fetchInfo(
                tmdbId: movie.tmdbId, type: movie.tmdbType)
        }
        if let info {
            tmdb = info
        }
        let needsBackdrop = info?.backdropURL.isEmpty ?? true
        async let backdropFetch = backdropHunt(
            needed: needsBackdrop, movie: movie)
        async let castFetch = castIfAvailable(movie: movie)
        let backdropURL = await backdropFetch
        if let backdropURL {
            if var current = tmdb {
                if current.backdropURL.isEmpty {
                    current.backdropURL = backdropURL
                    tmdb = current
                }
            } else {
                var created = TMDBInfo()
                created.backdropURL = backdropURL
                tmdb = created
            }
        }
        let cast = await castFetch
        if !cast.isEmpty, var current = tmdb {
            current.cast = cast
            tmdb = current
        }
        if info == nil, backdropURL == nil {
            tmdb = nil
        }
    }

    /// The title-logo task's body, moved out of its
    /// .task closure the same way — original body,
    /// verbatim.
    private func runTMDBLogoFetch() async {
        // Idea 3(c) (checkpoint 2.0.25): the title logo is
        // fetched in PARALLEL with the enrichment task
        // above — its own .task, keyed on the same detail
        // identity, so it starts when the detail loads its
        // TMDB info, is cancelled/restarted with it, and
        // publishes into tmdbLogoURL the moment it lands.
        // fetchInfo's backdrop/overview never wait for it.
        // Fail-soft exactly like the rest of the TMDB
        // chain: no key / no TMDB id / a failed call
        // leaves the logo empty and the text title stands.
        tmdbLogoURL = ""
        guard let detail, !TMDBClient.apiKey.isEmpty else { return }
        // Swift 6 round (fault c): the logo takes the
        // same snapshot pin as the enrichment task above
        // — a TVB session resolves its logo by the
        // snapshot's TMDB id as "tv", never by the
        // provider payload's stamps (see there).
        let logoId: String
        let logoType: String
        if let tvbCtx = route.tvb {
            logoId = "\(tvbCtx.tmdbId)"
            logoType = "tv"
        } else {
            guard !detail.movie.tmdbId.isEmpty else { return }
            logoId = detail.movie.tmdbId
            logoType = detail.movie.tmdbType
        }
        let logo = await TMDBClient.fetchLogo(
            tmdbId: logoId, type: logoType)
        guard !Task.isCancelled else { return }
        tmdbLogoURL = logo
    }

    /// Instant header built from the tapped card's own data,
    /// shown while the provider detail is still loading — the
    /// page never opens on a bare full-screen spinner again
    /// (in v1.1 a detail could spin for 15–20 s). v2.0.0: the
    /// placeholder follows the active design's head anatomy.
    @ViewBuilder
    private var placeholderHeaderContent: some View {
        let m = placeholderMovie()
        switch theme.id {
        case .posterWall:
            // The loaded D detail's rhythm (title margin-top
            // 24 below the poster), so the page keeps its
            // shape when the detail lands.
            VStack(alignment: .center, spacing: 0) {
                posterArt(m)
                Text(route.name)
                    .font(.system(size: 56, weight: .heavy))
                    .foregroundStyle(theme.text)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.top, 24)
                providerChip
                    .padding(.top, 10)
            }
            .frame(maxWidth: .infinity)
        case .sourceBoard:
            HStack(alignment: .top, spacing: 36) {
                posterArt(m)
                VStack(alignment: .leading, spacing: 14) {
                    Text(route.name)
                        .font(.system(size: 54, weight: .heavy))
                        .foregroundStyle(theme.text)
                        .lineLimit(3)
                    if !route.year.isEmpty {
                        Text(route.year)
                            .font(.system(size: 27))
                            .foregroundStyle(theme.meta)
                    }
                    providerChip
                }
                Spacer(minLength: 0)
            }
        case .ultra:
            // Ultra's placeholder rides the full-screen
            // backdrop layer in body (painted from the launch
            // payload): just the title column, in the loaded
            // composition's rhythm.
            VStack(alignment: .leading, spacing: 0) {
                Text(route.name)
                    .font(.system(size: 60, weight: .heavy))
                    .foregroundStyle(theme.text)
                    .lineLimit(3)
                    .padding(.top, 30)
                if !route.year.isEmpty {
                    Text(route.year)
                        .font(.system(size: 29))
                        .foregroundStyle(theme.heroMeta)
                        .padding(.top, 12)
                }
                providerChip
                    .padding(.top, 14)
            }
        case .privateCinema:
            // v2.1.0 (Private Cinema): the placeholder rides
            // the full-screen cinemaBackdrop layer in body
            // (painted from the launch payload): a skeleton
            // mirroring privateCinemaDetail's header — no
            // poster in the header (the PC composition paints
            // no poster there; it rides cinemaBackdrop), so
            // the page keeps its shape when the detail lands.
            VStack(alignment: .leading, spacing: 0) {
                Text(route.name)
                    .font(JoePCType.display(100))
                    .tracking(6)
                    .foregroundStyle(theme.text)
                    .lineLimit(2)
                    .padding(.top, 30)
                if !route.year.isEmpty {
                    Text(route.year)
                        .font(JoePCType.outfit(29))
                        .foregroundStyle(theme.heroMeta)
                        .padding(.top, 12)
                }
                providerChip
                    .padding(.top, 14)
            }
        case .billboard:
            // v2.0.1: the placeholder carries the SAME band +
            // overlap composition as the loaded detail (the
            // Android pipeline starts at open from the launch
            // payload): the band's poster treatment paints
            // from the tapped card's decoded cache on the
            // first frame, and the page does not change shape
            // when the detail lands.
            let bandTopPadding: CGFloat = bandVisible(
                movie: m, tmdbURL: nil) ? -168 : 0
            VStack(alignment: .leading, spacing: 0) {
                backdropBand(movie: m, tmdbURL: nil)
                HStack(alignment: .top, spacing: 44) {
                    posterArt(m)
                    VStack(alignment: .leading, spacing: 16) {
                        Text(route.name)
                            .font(.system(size: 60, weight: .heavy))
                            .foregroundStyle(theme.text)
                            .lineLimit(3)
                        if !route.year.isEmpty {
                            Text(route.year)
                                .font(.system(size: 29))
                                .foregroundStyle(theme.heroMeta)
                        }
                        providerChip
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, bandTopPadding)
            }
        }
    }

    /// Type-erased face of the placeholder header
    /// (run #33 fix): the builder above switches over
    /// the four themes, composing four different
    /// opaque branch types; only this erased property
    /// is referenced from the scroll content, so the
    /// switch's type never propagates into it.
    private var placeholderHeader: AnyView {
        AnyView(placeholderHeaderContent)
    }

    /// The scenePhase preview-kill, extracted from the body
    /// chain: inline, its closure pushed the (very large)
    /// detail body past the type-checker's reasonable-time
    /// limit (CI run #30, JoeMovieDetail.swift:515). Behaviour
    /// is unchanged — same condition, same kill call, same
    /// reason string.
    private func handleScenePhaseChange() {
        if scenePhase != .active { preview.kill(reason: "inactive") }
    }

    /// The placeholder header's movie, assembled OUTSIDE the
    /// @ViewBuilder block above: assignment statements are ()
    /// expressions, and a () child cannot conform to View —
    /// the builder block may only declare the finished value.
    private func placeholderMovie() -> Movie {
        var m = Movie()
        m.provider = provider
        m.slug = slug
        m.name = route.name
        m.poster = route.poster
        m.year = route.year
        return m
    }

    private var providerChip: some View {
        Text(Providers.displayName(provider))
            .font(theme.id == .privateCinema
                  ? JoePCType.outfit(25, weight: .semibold)
                  : .system(size: 25, weight: .semibold))
            .foregroundStyle(theme.text.opacity(0.85))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Capsule().fill(theme.surface2))
    }

    // MARK: - Themed detail compositions (v2.0.0)

    /// A — Billboard: backdrop band (430) with the scrim floor,
    /// the poster frame overlapping the band's lower edge, info
    /// to its right; then the Nguồn phát chips and the episode
    /// chips. OWNER FIDELITY RULE (2026-11-15, with his photo of
    /// the render): this page keeps the render's composition
    /// exactly — inside the info column: origin-name, title,
    /// meta line, genre chips, synopsis, actors line, then
    /// Xem ngay / Yêu thích; below the header block: Nguồn phát
    /// chips, then Chọn tập chips. No re-layout.
    private func billboardDetail(_ d: Detail) -> AnyView {
        // Design-A detail margins (design-A/detail.html): the
        // "Nguồn phát" block sits margin-top 38 below the header
        // block; the "Chọn tập" block is a rail-title block
        // (margin-top 36). Per-element margins, spacing 0 — the
        // uniform 32 gap matched neither drawing value.
        let headerTopPadding: CGFloat = bandVisible(
            movie: d.movie, tmdbURL: tmdbBackdropURL) ? -168 : 0
        return AnyView(VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                backdropBand(movie: d.movie, tmdbURL: tmdbBackdropURL)
                header(d)
                    .padding(.top, headerTopPadding)
            }
            // v2.0.8 (Phase 1): the header region (band +
            // poster + Play/Favourite) joins the section
            // system — composition and margins unchanged.
            .focusSection()
            sourceChips
                .padding(.top, 38)
            servers(d, heading: "Chọn tập", headingSize: 30)
                .padding(.top, 36)
        })
    }

    /// Ultra's fixed full-screen backdrop (v2.0.19): the same
    /// staged stack as the home hero — poster blur field,
    /// provider thumb, TMDB backdrop — behind the whole
    /// detail page, with the Sony scrims (left + a gentle
    /// vertical melt to the page background at the bottom).
    private var ultraBackdrop: AnyView {
        let m = detail?.movie ?? placeholderMovie()
        let previewOpacity: Double = preview.visible && !preview.fadingOut
            ? 1 : 0
        let previewFadeDuration: Double = preview.visible ? 0.8 : 0.15
        return AnyView(ZStack {
            // FIX-7 (2.1.1): for a TVB title both still
            // legs take .slice via stillPortraitMode (the
            // sharp still is the whole backdrop — no
            // trailer ever covers it); non-TVB keeps
            // .blurField exactly. Stacking order is the
            // existing best-variant ladder: poster (Movie
            // .poster, the provider's full poster field)
            // under thumb (Movie.thumb — the landscape
            // still; on Tủ Phim the posterPathOriginal, up
            // to 3840×2160) under the TMDB w1280 backdrop
            // on top. All legs at targetPixels 1920 (the
            // detail backdrop bucket).
            if let url = m.posterURL {
                JoeBandImage(url: url, targetPixels: 1920,
                             anchor: 0.16,
                             portraitMode: stillPortraitMode(nonTVB: .blurField))
            }
            if let url = m.thumbURL, url != m.posterURL {
                JoeBandImage(url: url, targetPixels: 1920,
                             anchor: 0.16,
                             portraitMode: stillPortraitMode(nonTVB: .blurField))
            }
            if let u = tmdbBackdropURL {
                JoeBandImage(url: u, targetPixels: 1920,
                             anchor: 0.16, portraitMode: .slice)
            }
            // 2.0.48 (Leg 3): the backdrop preview's video
            // layer — above the backdrop images, below
            // BOTH scrims (the design's one permitted new
            // element; nothing else in this stack moves).
            // Present only while a preview player exists;
            // opacity carries the 0.8 s crossfade IN at
            // first frame and the 0.8 s crossfade back
            // OUT at the segment's natural end (the
            // controller's fadingOut, 17:49 ruling). A
            // kill cuts instantly — the teardown removes
            // the player in the same update, per rule D1.
            if preview.player != nil {
                JoePreviewLayerView(controller: preview)
                    .opacity(previewOpacity)
                    .animation(.easeInOut(duration: previewFadeDuration),
                               value: preview.visible)
                    .animation(.easeInOut(duration: 0.8),
                               value: preview.fadingOut)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            LinearGradient(stops: [
                .init(color: .black.opacity(0.85), location: 0),
                .init(color: .black.opacity(0.40), location: 0.5),
                .init(color: .black.opacity(0.05), location: 1)
            ], startPoint: .leading, endPoint: .trailing)
            LinearGradient(stops: [
                .init(color: .black.opacity(0.30), location: 0),
                .init(color: .clear, location: 0.35),
                .init(color: theme.bg.opacity(0.88), location: 0.85),
                .init(color: theme.bg, location: 1)
            ], startPoint: .top, endPoint: .bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // v2.0.22 (owner photo verdict on 2.0.21: "Ko tràn
        // hết màn hình"): the frame above filled only the
        // SAFE-AREA rect — neither this layer nor the detail's
        // presenting layer in JoeRootView ignores the safe
        // area (only the theme.bg behind them does), so the
        // "full-screen" backdrop painted as an inset picture
        // with near-black bands on all four sides (80 pt
        // sides, 60 pt top/bottom) and the scroll's last rows
        // sat over its raw bottom edge. The backdrop layer
        // now bleeds edge-to-edge, the platform's own idiom
        // (background layers ignore, content respects): the
        // detailScroll beside it keeps the HIG inset exactly
        // as before, so no text moves. Ultra-only — this
        // layer exists for no other theme.
        .ignoresSafeArea())
    }

    /// Private Cinema's fixed full-screen backdrop
    /// (v2.1.0): modelled on ultraBackdrop — the same staged
    /// stack (poster slice, provider thumb, TMDB backdrop
    /// slice), the preview layer in the SAME placement
    /// (above the images, below both scrims), and left +
    /// vertical scrims whose stops read theme.bg, so the
    /// melt lands on this theme's own background. The layer
    /// bleeds edge-to-edge exactly as Ultra's does; the
    /// detailScroll beside it keeps the HIG inset.
    private var cinemaBackdrop: AnyView {
        let m = detail?.movie ?? placeholderMovie()
        let previewOpacity: Double = preview.visible && !preview.fadingOut
            ? 1 : 0
        let previewFadeDuration: Double = preview.visible ? 0.8 : 0.15
        return AnyView(ZStack {
            // FIX-7 (2.1.1): same TVB still rule as
            // ultraBackdrop — .slice for TVB via
            // stillPortraitMode, .blurField unchanged for
            // every other title; same ladder (poster under
            // thumb under the TMDB w1280 backdrop, all at
            // targetPixels 1920).
            if let url = m.posterURL {
                JoeBandImage(url: url, targetPixels: 1920,
                             anchor: 0.16,
                             portraitMode: stillPortraitMode(nonTVB: .blurField))
            }
            if let url = m.thumbURL, url != m.posterURL {
                JoeBandImage(url: url, targetPixels: 1920,
                             anchor: 0.16,
                             portraitMode: stillPortraitMode(nonTVB: .blurField))
            }
            if let u = tmdbBackdropURL {
                JoeBandImage(url: u, targetPixels: 1920,
                             anchor: 0.16, portraitMode: .slice)
            }
            // The backdrop preview's video layer — above
            // the backdrop images, below BOTH scrims, in
            // the same placement ultraBackdrop uses.
            // Present only while a preview player exists;
            // opacity carries the 0.8 s crossfade IN at
            // first frame and the 0.8 s crossfade back OUT
            // at the segment's natural end. A kill cuts
            // instantly, per rule D1.
            if preview.player != nil {
                JoePreviewLayerView(controller: preview)
                    .opacity(previewOpacity)
                    .animation(.easeInOut(duration: previewFadeDuration),
                               value: preview.visible)
                    .animation(.easeInOut(duration: 0.8),
                               value: preview.fadingOut)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            LinearGradient(stops: [
                .init(color: theme.bg.opacity(0.85), location: 0),
                .init(color: theme.bg.opacity(0.40), location: 0.5),
                .init(color: theme.bg.opacity(0.05), location: 1)
            ], startPoint: .leading, endPoint: .trailing)
            LinearGradient(stops: [
                .init(color: theme.bg.opacity(0.30), location: 0),
                .init(color: .clear, location: 0.35),
                .init(color: theme.bg.opacity(0.88), location: 0.85),
                .init(color: theme.bg, location: 1)
            ], startPoint: .top, endPoint: .bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea())
    }

    /// Ultra — the Sony detail composition (v2.0.19): no
    /// poster frame; one left column over the full-screen
    /// backdrop — logo art (or the text title), gold origin,
    /// gold meta with the IMDb pill, genre chips, the action
    /// row (play + favourite CIRCLE), synopsis, cast circles —
    /// then the shared source chips and episode servers.
    private func ultraDetail(_ d: Detail) -> AnyView {
        let hasGenres: Bool = !d.categories
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .isEmpty
        let hasSynopsis: Bool = !(tmdb?.overview.isEmpty ?? true)
            || !d.content.isEmpty
        let synopsisText: String = (tmdb?.overview.isEmpty ?? true)
            ? d.content : (tmdb?.overview ?? "")
        return AnyView(VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if !tmdbLogoURL.isEmpty,
                   let u = URL(string: tmdbLogoURL) {
                    JoeRemoteImage(url: u, targetPixels: 1000, fit: true) {
                        Color.clear
                    }
                    .frame(maxWidth: 640, maxHeight: 120, alignment: .leading)
                    .padding(.top, 30)
                } else {
                    Text(d.movie.name)
                        .font(.system(size: 60, weight: .heavy))
                        .foregroundStyle(theme.text)
                        .lineLimit(3)
                        .padding(.top, 30)
                }
                if tmdbLogoURL.isEmpty,
                   !d.movie.originName.isEmpty,
                   d.movie.originName != d.movie.name {
                    Text(d.movie.originName.uppercased())
                        .font(.system(size: 24, weight: .semibold))
                        .tracking(4)
                        .foregroundStyle(theme.heroMeta)
                        .lineLimit(1)
                        .padding(.top, 10)
                }
                HStack(spacing: 16) {
                    if !d.metaLine.isEmpty {
                        Text(d.metaLine)
                            .font(.system(size: 27, weight: .medium))
                            .foregroundStyle(theme.heroMeta)
                            .lineLimit(1)
                    }
                    if let r = tmdb?.voteAverage, r > 0 {
                        Text(String(format: "IMDb %.1f", r))
                            .font(.system(size: 23, weight: .bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 7)
                                .fill(Color(red: 0.961, green: 0.773, blue: 0.094)))
                    }
                }
                .padding(.top, 12)
                genreChips(d)
                    .padding(.top, hasGenres ? 14 : 0)
                HStack(spacing: 18) {
                    playButton(d)
                    ultraFavCircle(d)
                    followButton(d)
                }
                .padding(.top, 22)
                if hasSynopsis {
                    Text(synopsisText)
                        .font(.system(size: 27))
                        .foregroundStyle(theme.text.opacity(0.92))
                        .lineSpacing(8)
                        .lineLimit(4)
                        .frame(maxWidth: 1150, alignment: .leading)
                        .padding(.top, 20)
                }
                if let tmdb, !tmdb.cast.isEmpty {
                    castRow(tmdb.cast)
                        .padding(.top, 24)
                }
            }
            .focusSection()
            sourceChips
                .padding(.top, 38)
            servers(d, heading: "Chọn tập", headingSize: 30)
                .padding(.top, 36)
        })
    }

    /// Ultra's favourite: the reference's round heart button
    /// (favButton's action, a circle face).
    private func ultraFavCircle(_ d: Detail) -> some View {
        Button {
            ultraFavCircleAction(d)
        } label: {
            Text(isFav ? "♥" : "♡")
                .font(.system(size: 34))
                .foregroundStyle(isFav
                                 ? Color(red: 0.878, green: 0.169, blue: 0.227)
                                 : theme.text)
                .frame(width: 76, height: 76)
                .background(Circle().fill(theme.surface2))
                .overlay(Circle().strokeBorder(
                    focusedFav ? theme.focus : theme.stroke,
                    lineWidth: focusedFav ? theme.ringWidth : 1.5))
        }
        .joeCardButton()
        .focused($focusedFav)
    }

    /// ultraFavCircle's press, extracted from its
    /// Button action closure (2.0.48 sweep): the
    /// original body verbatim.
    private func ultraFavCircleAction(_ d: Detail) {
        // D1 (2.0.48): a Select press with focus
        // already resting here changes no hooked
        // state — the press itself kills the preview.
        preview.kill(reason: "input")
        var e = WatchStore.Entry()
        e.kind = Providers.kindOf(provider)
        e.key = favKey
        e.title = d.movie.name
        e.poster = d.movie.poster
        e.year = d.movie.year
        e.slug = slug
        e.source = provider
        // v2.0.38 (Sony 2.3.41 parity, item 3): stamp
        // the stable ids, exactly as the progress
        // saves do (makeDirector) — a favourite saved
        // without them reopens fail-open under the
        // wrong-film gate, because its tvbRouteContext
        // rebuilds from these stamps (the gap the
        // 2.0.37 round named and left).
        e.imdbId = d.movie.imdbId
        e.tmdbId = d.movie.tmdbId
        // The payload → launch fallback (Sony's
        // knownTmdbId order): a TVB payload can stand
        // by an id-matched holder with no ids of its
        // own — the route's snapshot context still
        // knows the title's identity (the torrent
        // rung's pinned construction reads it the
        // same way), and the stamp must not come out
        // empty for exactly the titles the gate
        // exists for.
        if e.tmdbId.isEmpty, let ctx = route.tvb {
            e.tmdbId = "\(ctx.tmdbId)"
        }
        if e.imdbId.isEmpty, let ctx = route.tvb {
            e.imdbId = ctx.imdbId
        }
        e.ts = Int64(Date().timeIntervalSince1970 * 1000)
        watch.toggleFavorite(e)
    }

    /// D — Poster Wall: everything centred (poster, title, meta,
    /// genre chips, synopsis, actions); cast and servers follow
    /// as full-width blocks.
    ///
    /// UI-6 defect D-14 — DECLARED ADDITIONS (UI-6's own
    /// recommendation): two elements on this composition are
    /// not in D's render fingerprint and are kept deliberately
    /// — the origin-name line under the title (the wall cards
    /// carry origin names everywhere else in the app; dropping
    /// it here would make D the only surface that hides a
    /// film's original title) and the providerChip in the
    /// action row (the current source's name, the same status
    /// the other themes' Nguồn phát blocks show). Declared,
    /// not silent.
    private func wallDetail(_ d: Detail) -> AnyView {
        // Design-D detail (design-D/detail.html): a CENTRED
        // column whose elements carry the drawing's own
        // margins — title 24 below the poster, meta 10, genre
        // chips 16, synopsis 18, buttons 26 (row gap 18),
        // source chips 30, episode chips 16 — so the column
        // runs at spacing 0 with per-element top paddings
        // (absent elements collapse with their margin, like
        // CSS). The origin line and the cast row are app-only
        // elements (kept); they ride the same rhythm.
        let hasGenres: Bool = !d.categories
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .isEmpty
        let hasSynopsis: Bool = !(tmdb?.overview.isEmpty ?? true)
            || !d.content.isEmpty
        let synopsisText: String = (tmdb?.overview.isEmpty ?? true)
            ? d.content : (tmdb?.overview ?? "")
        return AnyView(VStack(alignment: .center, spacing: 0) {
            // v2.0.8 (Phase 1): the header region (poster
            // through the Play/Favourite row) is its own
            // focus section. The Group is layout-transparent,
            // so the centred column's composition, spacing
            // and per-element margins are unchanged.
            Group {
            posterArt(d.movie)
            Text(d.movie.name)
                .font(.system(size: 56, weight: .heavy))
                .foregroundStyle(theme.text)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.top, 24)
            if !d.movie.originName.isEmpty {
                Text(d.movie.originName)
                    .font(.system(size: 29))
                    .foregroundStyle(theme.meta)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .padding(.top, 10)
            }
            if !d.metaLine.isEmpty {
                // UI-6 defect D-14: D's detail meta reads in
                // the theme's heroMeta (the render's meta
                // colour), not the dimmer rail meta. Design
                // size: .hero-meta, 27px medium.
                Text(d.metaLine)
                    .font(.system(size: 27, weight: .medium))
                    .foregroundStyle(theme.heroMeta)
                    .padding(.top, 10)
            }
            genreChips(d)
                .padding(.top, hasGenres ? 16 : 0)
            if hasSynopsis {
                // Design .hero-syn under D: 27px, white at
                // .92 (the base rule's opacity survives D's
                // size override), max-width 920, centred.
                Text(synopsisText)
                    .font(.system(size: 27))
                    .foregroundStyle(theme.text.opacity(0.92))
                    .lineSpacing(8)
                    .lineLimit(5)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 920)
                    .padding(.top, 18)
            }
            HStack(spacing: 18) {
                playButton(d)
                favButton(d)
                followButton(d)
                providerChip
            }
            .padding(.top, 26)
            }
            .focusSection()
            if let tmdb, !tmdb.cast.isEmpty {
                // v2.0.29 (cluster A, item 1b): the cast row
                // is its own declared focus region here — in
                // D it stood between the header section and
                // the source section in NO section at all,
                // while every other block on the page (header,
                // sources, episodes) declares one. (Ultra's
                // cast row rides inside its header section and
                // A's actors line inside its header section;
                // neither needs this.)
                castRow(tmdb.cast)
                    .focusSection()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 26)
            }
            // The Nguồn phát row is unconditional in D too —
            // it carries the policy's Tự động chip even when
            // this film has no alternative source. Design-D
            // centres the row (justify-content: center) — no
            // leading frame.
            altChips
                .padding(.top, 30)
            servers(d, centered: true)
                .padding(.top, 16)
        }
        .frame(maxWidth: .infinity))
    }

    /// F — Source Board: compact meta head, then the Nguồn phát
    /// source rows as the PRIMARY block (the current source,
    /// the alternatives as switch actions, the torrent rung's
    /// state), episode chips under them, cast, and the synopsis
    /// demoted to a small 2-line tail.
    private func boardDetail(_ d: Detail) -> AnyView {
        // Design-F detail (design-F/detail.html): the column
        // carries the drawing's own margins — content row gap
        // 36; title → meta 10, meta → genre chips 16, chips →
        // buttons 22 (button gap 18); the "Nguồn phát" heading
        // margin-top 30; the episode row margin-top 6 below
        // the source rows; the synopsis margin-top 16 — so the
        // column runs at spacing 0 with per-element top
        // paddings (absent elements collapse with their
        // margin, like CSS). The meta line is the drawing's
        // .hero-meta: 27 medium in the heroMeta colour.
        let hasGenres: Bool = d.categories.split(separator: ",")
            .contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let hasSynopsis: Bool = !(tmdb?.overview.isEmpty ?? true)
            || !d.content.isEmpty
        let synopsisText: String = (tmdb?.overview.isEmpty ?? true)
            ? d.content : (tmdb?.overview ?? "")
        return AnyView(VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 36) {
                posterArt(d.movie)
                VStack(alignment: .leading, spacing: 0) {
                    Text(d.movie.name)
                        .font(.system(size: 54, weight: .heavy))
                        .foregroundStyle(theme.text)
                        .lineLimit(3)
                    if !d.movie.originName.isEmpty {
                        Text(d.movie.originName)
                            .font(.system(size: 27))
                            .foregroundStyle(theme.meta)
                            .lineLimit(1)
                            .padding(.top, 10)
                    }
                    if !d.metaLine.isEmpty {
                        Text(d.metaLine)
                            .font(.system(size: 27, weight: .medium))
                            .foregroundStyle(theme.heroMeta)
                            .padding(.top, 10)
                    }
                    genreChips(d)
                        .padding(.top, hasGenres ? 16 : 0)
                    HStack(spacing: 18) {
                        playButton(d)
                        favButton(d)
                        followButton(d)
                    }
                    .padding(.top, 22)
                }
                Spacer(minLength: 0)
            }
            // v2.0.8 (Phase 1): the header region (poster +
            // Play/Favourite block) joins the section
            // system — composition and margins unchanged.
            .focusSection()
            sourceRows(d)
                .padding(.top, 30)
            // UI-6 defect D-11: in F the "Chọn tập" heading is
            // the render's INLINE label beside the chip rows,
            // not a block heading above them.
            HStack(alignment: .top, spacing: 14) {
                Text("Chọn tập")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(theme.text)
                    .padding(.top, 8)
                serverGroups(d)
            }
            .padding(.top, 6)
            // UI-6 defect D-17: F's fingerprint has NO cast
            // row (D keeps its own) — the castRow call that
            // stood here is removed.
            // FIX4 (fix 3) — labelled DEVIATION from D-17:
            // the owner tested 2.0.27 and found no cast
            // anywhere in this theme, so the actor pages
            // (idea 20) were unreachable from every F detail.
            // The shared focusable cast row (the Ultra/D
            // construction) is restored at exactly the slot
            // D-17 emptied, with D's own top margin. The F
            // drawing gains this one row; nothing else in
            // the board changes.
            if let tmdb, !tmdb.cast.isEmpty {
                // v2.0.29 (cluster A, item 1b): its own
                // declared focus region, as in D — the row
                // stood in no section between the source rows'
                // section and the episode block's section.
                castRow(tmdb.cast)
                    .focusSection()
                    .padding(.top, 26)
            }
            if hasSynopsis {
                Text(synopsisText)
                    .font(.system(size: 23))
                    .foregroundStyle(theme.meta)
                    .lineSpacing(6)
                    .lineLimit(2)
                    .frame(maxWidth: 1500, alignment: .leading)
                    .padding(.top, 16)
            }
        })
    }

    /// Private Cinema — the cinema detail composition
    /// (v2.1.0): one left column over the full-screen
    /// cinemaBackdrop — NO panel or card is painted behind
    /// the header, so the backdrop (and the trailer
    /// preview over it) stays uncovered. Eyebrow = the
    /// genres joined " / " uppercased + the type word;
    /// a letterspaced serif title; the origin-name line;
    /// the meta row; the synopsis; then a text-only
    /// credits block — the first three cast names as
    /// tappable buttons (the actorNameAction pattern,
    /// JoeCinemaNameLabel dress), with NO photo cast row
    /// under this theme. There is NO "ĐẠO DIỄN" column:
    /// neither Detail, Movie nor TMDBInfo carries a
    /// director field, so the column is omitted rather
    /// than invented. The genreChips row is NOT used
    /// here — the eyebrow carries the genres in this
    /// design.
    /// v2.1.1 (WS-C, fidelity audit §3): the action row
    /// is now the design's MINIMAL row (pcActionRow: the
    /// shared pale playButton + a plain quality/sub text
    /// + fav/follow as plain-text actions — no pills),
    /// and below the header a Divider + the "Chọn nguồn
    /// phát" heading over the NUMBERED source cards
    /// (pcSourceBlock: Panel #182024 cards over the
    /// shared sourceEntries membership, the chips' own
    /// actions and focus binding) with the shared
    /// servers(…) episode block under them — the
    /// episode-first flow for series is exactly the
    /// shipped one. Between header and source block sits
    /// the trailer sign-in prompt (pcTrailerSignInPrompt,
    /// DIAG-2050 §1c), present only after a trailer
    /// attempt ended in needsIdentity.
    private func privateCinemaDetail(_ d: Detail) -> AnyView {
        let genres: [String] = d.categories
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let typeWord: String = isSeries(d) ? "PHIM BỘ" : "PHIM ĐIỆN ẢNH"
        let eyebrow: String = (genres.map { $0.uppercased() }
                               + [typeWord])
            .joined(separator: " / ")
        let hasSynopsis: Bool = !(tmdb?.overview.isEmpty ?? true)
            || !d.content.isEmpty
        let synopsisText: String = (tmdb?.overview.isEmpty ?? true)
            ? d.content : (tmdb?.overview ?? "")
        var metaParts: [String] = []
        if !d.movie.year.isEmpty { metaParts.append(d.movie.year) }
        if let r = tmdb?.voteAverage, r > 0 {
            metaParts.append("★ " + String(format: "%.1f", r))
        }
        if !d.movie.time.isEmpty { metaParts.append(d.movie.time) }
        let metaText: String = metaParts.joined(separator: " · ")
        return AnyView(VStack(alignment: .leading, spacing: 0) {
            pcBackRow
            VStack(alignment: .leading, spacing: 0) {
                Text(eyebrow)
                    .font(JoePCType.outfit(15, weight: .medium))
                    .tracking(3.6)
                    .foregroundStyle(theme.heroMeta)
                    .lineLimit(1)
                    .padding(.top, 30)
                Text(d.movie.name)
                    // FIX-10b / F5: spec type sheet — Detail
                    // title 100/500, tracking −3.
                    .font(JoePCType.display(100))
                    .tracking(-3)
                    .foregroundStyle(theme.text)
                    .lineLimit(2)
                    .padding(.top, 16)
                if !d.movie.originName.isEmpty,
                   d.movie.originName != d.movie.name {
                    Text(d.movie.originName.uppercased())
                        .font(JoePCType.outfit(20, weight: .medium))
                        .tracking(6)
                        // FIX-214 (FULL-THEME-AUDIT-214
                        // B10): the drawn origin line is
                        // IVORY (the heroes' heroMeta use
                        // is correct; this detail leg alone
                        // drifted to the meta colour).
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                        .padding(.top, 10)
                }
                if !metaText.isEmpty || !d.movie.quality.isEmpty {
                    HStack(spacing: 16) {
                        if !metaText.isEmpty {
                            Text(metaText)
                                .font(JoePCType.outfit(20))
                                .foregroundStyle(theme.heroMeta)
                                .lineLimit(1)
                        }
                        if !d.movie.quality.isEmpty {
                            // FIX-10b / F7: the meta line's
                            // quality chip takes the hero meta
                            // chips' small dressing (cinema
                            // HeroMetaRow in JoePhimHome):
                            // 14 regular on black 0.35, r4,
                            // stroke 1 — no oversized label.
                            Text(d.movie.quality)
                                .font(JoePCType.outfit(14))
                                .foregroundStyle(theme.text)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.black.opacity(0.35)))
                                .overlay(RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(theme.stroke, lineWidth: 1))
                        }
                    }
                    .padding(.top, 12)
                }
                if hasSynopsis {
                    // FIX-10b / F2: spec type sheet — Detail
                    // synopsis 21/400, line height 1.55
                    // (lineSpacing = 21 × 1.55 − 21 = 11.55),
                    // max width 720; the drawing shows 3
                    // lines at that width, so the limit is 3.
                    Text(synopsisText)
                        .font(JoePCType.outfit(21))
                        .foregroundStyle(theme.text.opacity(0.92))
                        .lineSpacing(11.55)
                        .lineLimit(3)
                        .frame(maxWidth: 720, alignment: .leading)
                        .padding(.top, 20)
                }
                pcActionRow(d)
                    .padding(.top, 22)
                if let tmdb, !tmdb.cast.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        // FIX-214 (FULL-THEME-AUDIT-214
                        // B10): the drawing carries NO
                        // cast heading — only the small
                        // column label at 15. The shipped
                        // 23 pt semibold "DIỄN VIÊN" block
                        // heading is removed; the drawn
                        // small-caps label stands in its
                        // place (design-team call per the
                        // audit's fix text).
                        Text("DIỄN VIÊN")
                            .font(JoePCType.outfit(15, weight: .medium))
                            .tracking(3)
                            .foregroundStyle(theme.heroMeta)
                        HStack(spacing: 18) {
                            ForEach(Array(tmdb.cast.prefix(3))) { member in
                                Button {
                                    actorNameAction(member)
                                } label: {
                                    JoeCinemaNameLabel(name: member.name)
                                }
                                .joeCardButton()
                                .focused($focusedCast, equals: member.id)
                            }
                        }
                    }
                    .padding(.top, 28)
                }
            }
            .focusSection()
            pcTrailerSignInPrompt
            // FIX-214 (FULL-THEME-AUDIT-214 B10): the
            // source block ANCHORS to the stage's bottom
            // zone — when the header content is short,
            // this spacer stretches so the block's bottom
            // lands at the drawn bottom 101 of the 1080
            // stage (the composition's frame below is
            // 1080 − 101 − 60 safe-area top = 919 tall at
            // minimum); when the content is long, the
            // spacer collapses and the block flows
            // naturally under the header, as before.
            Spacer(minLength: 0)
            Divider()
                .padding(.top, 38)
            pcSourceBlock(d)
                .padding(.top, 20)
        }
        .frame(minHeight: 919, alignment: .top))
    }

    // MARK: - Private Cinema detail pieces (v2.1.1, WS-C)

    /// v2.1.1 fix round (Lens C F2): the Detail drawing's
    /// header row — "← Quay lại" at the top-left, over the
    /// backdrop, no panel and no tab strip (the strip is
    /// the mockup's shell nav; the shell carries it). The
    /// row is the PC composition's FIRST focus section, so
    /// focus reaches it by moving up from the header
    /// section; the declared default focus stays on Play
    /// (the covers stage's .defaultFocus is untouched),
    /// and the row is a plain button — no trap.
    private var pcBackRow: some View {
        HStack(spacing: 0) {
            Button {
                pcBackTapped()
            } label: {
                PCDetailBackLabel()
            }
            .joeCardButton()
            .focused($focusedBack)
            Spacer(minLength: 0)
        }
        .focusSection()
    }

    /// The back row's press: the SAME dismiss the Menu
    /// handler's closing branch performs (handleExitCommand
    /// — kill the preview, clear nav.movie), preceded by
    /// the standard press discipline every button on this
    /// screen runs (rule D1: a press is owner input).
    private func pcBackTapped() {
        killPreviewOnInput()
        nav.movie = nil
    }

    /// The design's plain quality/sub line beside the
    /// play button ("Vietsub · 4K UHD" in the drawing):
    /// built ONLY from the record's own fields — Movie
    /// .lang (the payload's subtitle/audio descriptor)
    /// and Movie.quality, each verbatim, empty parts
    /// dropped. No per-source or expanded values exist
    /// in the record, so none are invented here.
    private func pcPlayInfoText(_ d: Detail) -> String {
        joinParts([cleanField(d.movie.lang),
                   cleanField(d.movie.quality)], " · ")
    }

    /// The PC minimal action row (fidelity audit §3):
    /// ONE pale "▶ Xem ngay" — the shared playButton,
    /// its action, disabled rule and $focusedPlay binding
    /// untouched (under PC tokens JoePrimaryLabel's fill
    /// is the pale accent2) — then the plain quality/sub
    /// text, then favourite/follow as compact PLAIN-TEXT
    /// actions (pcFavTextButton / pcFollowTextButton):
    /// same actions and focus bindings as the pill
    /// buttons, no pill faces. Nothing here paints over
    /// the backdrop — the row is text and the one pale
    /// button, so the 2.0.49 trailer contract (preview
    /// playing behind uncovered UI) is unchanged.
    private func pcActionRow(_ d: Detail) -> some View {
        let infoText = pcPlayInfoText(d)
        return HStack(spacing: 26) {
            playButton(d)
            if !infoText.isEmpty {
                Text(infoText)
                    // FIX-214 (FULL-THEME-AUDIT-214 B10):
                    // the drawn info line is ≈20, not 25.
                    .font(JoePCType.outfit(20))
                    .foregroundStyle(theme.meta)
                    .lineLimit(1)
            }
            pcFavTextButton(d)
            pcFollowTextButton(d)
        }
    }

    /// The favourite toggle as a plain-text action (PC
    /// arm only): favButton's own action (favButtonAction)
    /// and $focusedFav binding, the same label strings,
    /// focus read value-only through the binding exactly
    /// as favButton reads it for its ring — text colour
    /// only, no capsule, no plate, geometry never moves.
    private func pcFavTextButton(_ d: Detail) -> some View {
        Button {
            favButtonAction(d)
        } label: {
            Text(isFav ? "♥ Đã thích" : "♡ Yêu thích")
                .font(JoePCType.outfit(25, weight: .semibold))
                .foregroundStyle(focusedFav
                    ? theme.focusTitle
                    : (isFav ? JoeTheme.accentRed : theme.text))
                .lineLimit(1)
                // Fault 11 fix round: the unfavourited
                // resting colour IS the focus colour under
                // this theme (text ≈ focusTitle), so the
                // colour swap alone was the Fault-2 disease
                // — the focused state also raises the Panel
                // plate, exactly as the F2 name labels do.
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                // claude/opt-2 (FL-422 sweep; RECALC-SPEC R6):
                // the focused Panel plate is gone — focus is
                // the chip-family ivory outset outline (2/4),
                // exactly as the PC cast-name labels already
                // carry it, driven by this button's binding.
                .overlay(JoeOutsetRing(
                    shape: RoundedRectangle(cornerRadius: 8),
                    color: JoeCinemaFocus.ivory,
                    lineWidth: 2, offset: 4, forced: focusedFav))
        }
        .joeCardButton()
        .focused($focusedFav)
    }

    /// The follow toggle as a plain-text action (PC arm
    /// only): followButton's own action, $focusedFollow
    /// binding, label strings and series-only rule
    /// (isSeries) — followButton's @ViewBuilder condition
    /// mirrored, so a movie shows no follow action here
    /// either. Plain text, value-only focus colour.
    @ViewBuilder
    private func pcFollowTextButton(_ d: Detail) -> some View {
        if isSeries(d) {
            Button {
                followButtonAction(d)
            } label: {
                Text(isFollowing(d) ? "Đang theo dõi" : "Theo dõi")
                    .font(JoePCType.outfit(25, weight: .semibold))
                    .foregroundStyle(focusedFollow
                        ? theme.focusTitle
                        : (isFollowing(d)
                           ? JoeTheme.accentRed : theme.text))
                    .lineLimit(1)
                    // Fault 11 fix round: the focused
                    // Panel plate, as pcFavTextButton.
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    // claude/opt-2 (FL-422 sweep; R6): ring,
                    // no plate — as pcFavTextButton.
                    .overlay(JoeOutsetRing(
                        shape: RoundedRectangle(cornerRadius: 8),
                        color: JoeCinemaFocus.ivory,
                        lineWidth: 2, offset: 4, forced: focusedFollow))
            }
            .joeCardButton()
            .focused($focusedFollow)
        }
    }

    /// The PC source block (fidelity audit §3 — the
    /// audit's worst Detail deviation): the "Chọn nguồn
    /// phát" heading over the drawing's horizontal row
    /// of NUMBERED Panel cards (pcSourceCardGrid: 3 per
    /// row, wrapping) over the SAME membership the chips
    /// render (sourceEntries), then the shared servers(…)
    /// episode block — a series still picks its episode
    /// first from the shipped chips, exactly as every
    /// other composition. The heading's right-aligned
    /// design note ("Chất lượng tốt nhất trước") is NOT
    /// painted: the entry order is the source-priority
    /// order (Tự động → YouTube → current → alternatives
    /// → Torrent) and every entry shares the one record
    /// quality — no per-source quality exists to sort
    /// by, so the note would be a false claim. Flagged
    /// in the WS-C report.
    private func pcSourceBlock(_ d: Detail) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Text("Chọn nguồn phát")
                    // FIX-214 (FULL-THEME-AUDIT-214 B10 —
                    // the ONE unified source-heading
                    // decision for all three details): the
                    // chain drawing's heading is a modest
                    // ≈27–30 Outfit; the 34 Bricolage
                    // pane-title reading the TVB/Torrent
                    // details were matched against is
                    // inference, not a drawing — the
                    // drawing wins, so all three details
                    // take outfit(28, .semibold).
                    .font(JoePCType.outfit(28, weight: .semibold))
                    .foregroundStyle(theme.text)
                if switching {
                    ProgressView().tint(theme.text)
                }
                Spacer(minLength: 0)
            }
            pcSourceCardGrid(d)
            // No torrentUnresolvedNote here: the Torrent
            // card's own name line carries the entry state
            // as a suffix (pcCardStateSuffix) — the chip
            // anatomies need the note because a chip has
            // no state slot.
            servers(d, heading: "Chọn tập", headingSize: 30)
                .padding(.top, 20)
        }
    }

    /// FIX-10b / F6: the drawing's source-card layout —
    /// a HORIZONTAL row of cards, 3 per row, wrapping to
    /// a second row when the membership carries more
    /// (the app carries up to ~6 entries).
    /// OWNER OVERRIDE 2026-11-22 12:15 CST ("Thanh vẫn
    /// còn rất dài làm vừa đủ cho cân bằng bố cục thôi";
    /// RECALC-SPEC §3.10): the cards are sized to their
    /// CONTENT — the old three flexible columns stretched
    /// every card to the column width, so the grid is now
    /// leading-aligned HStacks of up to 3 cards, each
    /// card .fixedSize(horizontal:) so it hugs its one
    /// line, with the design's 18 pt horizontal gap and
    /// the grid's existing 20 pt vertical rhythm. The
    /// card anatomy (pcSourceCard), ordering and actions
    /// are unchanged; the servers/episode block below
    /// the block stays exactly as it was.
    private func pcSourceCardGrid(_ d: Detail) -> some View {
        let rowCount = (sourceEntries.count + 2) / 3
        return VStack(alignment: .leading, spacing: 20) {
            ForEach(0..<rowCount, id: \.self) { row in
                HStack(spacing: 18) {
                    ForEach((row * 3)..<min(row * 3 + 3,
                                            sourceEntries.count),
                            id: \.self) { index in
                        pcSourceCard(sourceEntries[index],
                                     detail: d, index: index)
                            .fixedSize(horizontal: true,
                                       vertical: false)
                    }
                }
            }
        }
        .focusSection()
    }

    /// One entry's card name — the same names the chips
    /// and F's rows carry (sourceChip / sourceRowEntry).
    private func pcCardName(_ entry: SourceEntry) -> String {
        switch entry {
        case .auto: return "Tự động"
        case .youtube: return "YouTube"
        case .current: return Providers.displayName(provider)
        case .alternative(let code, _):
            return Providers.displayName(code)
        case .torrent: return "Torrent"
        }
    }

    /// One entry's press — the CHIP actions verbatim
    /// (autoChipAction / youtubeChipAction /
    /// currentChipAction / alternativeChipAction /
    /// torrentChipAction): each already kills the
    /// preview itself (the D1 rule) and drives the same
    /// state (autoSource / ytMode / ytChainPinned /
    /// provider+slug switch / torrent handoff), so a
    /// card tap selects exactly as a chip tap does.
    private func pcCardAction(_ entry: SourceEntry) -> () -> Void {
        switch entry {
        case .auto: return { autoChipAction() }
        case .youtube: return { youtubeChipAction() }
        case .current: return { currentChipAction() }
        case .alternative(let code, let altSlug):
            return { alternativeChipAction(code: code, altSlug: altSlug) }
        case .torrent: return { torrentChipAction() }
        }
    }

    /// FIX-213 (Faults 3+4, DIAG-20261122): the ONE
    /// state that still rides the compact card's face —
    /// a Torrent state that BLOCKS use, as a short suffix
    /// on the name line (without it the card would look
    /// pressable when it is not). The transient (.pending)
    /// and ready states paint nothing. This replaces the
    /// old sub-line construction (pcCardSubLine, removed):
    /// under the owner's compact ruling ("Làm nút nhỏ
    /// nguồn ghi tắt nhỏ ít thông tin được rồi") the
    /// descriptive sub-lines — server names, episode
    /// counts, the Torrent card's "Nguồn thay thế tự
    /// động…" sentence — are dropped from the card face.
    private func pcCardStateSuffix(_ entry: SourceEntry) -> String {
        guard case .torrent = entry else { return "" }
        switch torrentEntryState {
        case .notConfigured: return "Cần token"
        case .unresolved: return "Chưa tìm được mã IMDb"
        case .pending, .ready: return ""
        }
    }

    /// The card's right-aligned quality text: the
    /// record's Movie.quality verbatim for the chain
    /// entries (the only quality the record carries —
    /// per-source quality does not exist, so every chain
    /// card honestly shows the same value, or nothing
    /// when the field is empty). FIX-10b / F9: the slot
    /// is quality-only, as drawn — the Torrent entry
    /// returns EMPTY here (a torrent quality is not
    /// known on this screen and is never invented); its
    /// entry state rides the card's name line instead
    /// (pcCardStateSuffix).
    private func pcCardRightText(_ entry: SourceEntry,
                                 detail d: Detail) -> String {
        switch entry {
        case .torrent:
            return ""
        case .auto, .youtube, .current, .alternative:
            return cleanField(d.movie.quality)
        }
    }

    /// One numbered PC source card: Panel #182024 face
    /// (the design token, spelt out — the theme's
    /// surface gradient is NOT the design's flat Panel).
    /// FIX-213 (Faults 3+4, DIAG-20261122; owner ruling
    /// 2026-11-22 10:25 CST — "Làm nút nhỏ nguồn ghi tắt
    /// nhỏ ít thông tin được rồi", which OVERRIDES the
    /// drawing for these cards): the face is now ONE
    /// line — the number (24 pt), the short source name
    /// (25 pt semibold), a blocking-state suffix for the
    /// Torrent entry only (pcCardStateSuffix), and the
    /// quality right-aligned. The role line (ĐỀ XUẤT /
    /// NGUỒN DỰ PHÒNG), the sub/audio line, the play
    /// glyph and the chevron are gone; vertical padding
    /// 22 → 10. Focus is the shipped construction: a
    /// Button over $focusedAlt with the entry's own id
    /// (the chips' binding); the label's focus treatment
    /// is the design's source-row state (Fault 11 fix
    /// round: celadon outset outline via JoeDesignRing +
    /// the #304039DF focused face via JoeSourceRowFace,
    /// over the resting stroke). The unconfigured
    /// Torrent entry stays a non-focusable status card,
    /// exactly as F's "Cần token" row.
    /// OWNER OVERRIDE 2026-11-22 12:15 CST (§3.10): the
    /// card's width is its content's width — never the
    /// column's or the frame's (see pcSourceCardGrid).
    @ViewBuilder
    private func pcSourceCard(_ entry: SourceEntry, detail d: Detail,
                              index: Int) -> some View {
        let panel = Color(red: 0.094, green: 0.125, blue: 0.141)
        let numberText = String(format: "%02d", index + 1)
        let nameText = pcCardName(entry)
        let stateText = pcCardStateSuffix(entry)
        let rightText = pcCardRightText(entry, detail: d)
        let cardBase = HStack(alignment: .center, spacing: 16) {
            Text(numberText)
                .font(JoePCType.editorial(24))
                .foregroundStyle(theme.meta)
            Text(nameText)
                .font(JoePCType.outfit(25, weight: .semibold))
                .foregroundStyle(theme.text)
                .lineLimit(1)
            if !stateText.isEmpty {
                Text(stateText)
                    .font(JoePCType.outfit(22))
                    .foregroundStyle(theme.meta)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if !rightText.isEmpty {
                Text(rightText)
                    .font(JoePCType.outfit(25, weight: .medium))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
            }
        }
        let cardPadded = cardBase
            // RECALC-213: horizontal padding takes the
            // drawing's card value 25 (§3.10); the compact
            // override set only the vertical (10).
            .padding(.horizontal, 25)
            .padding(.vertical, 10)
        // OWNER OVERRIDE 2026-11-22 12:15 CST (§3.10):
        // no full-width frame — the card hugs its one
        // line (the Spacer above collapses to its 0
        // minimum at the card's ideal width, which
        // pcSourceCardGrid pins with .fixedSize).
        let cardFilled = cardPadded
            // Fault 11 fix round: the face is JoeSourceRowFace —
            // Panel at rest, the spec sheet's #304039DF when
            // focused (the design's source-row state).
            // FIX-214 (FULL-THEME-AUDIT-214 A3): the
            // source-card radius is the Geometry 7, not
            // the Settings-field rField 12.
            .background(JoeSourceRowFace(
                shape: RoundedRectangle(cornerRadius: 7),
                restFill: panel))
        let card = cardFilled
            .overlay(RoundedRectangle(cornerRadius: 7)
                .strokeBorder(theme.stroke, lineWidth: 1.5))
        if case .torrent = entry,
           case .notConfigured = torrentEntryState {
            card
        } else {
            Button(action: pcCardAction(entry)) {
                card.overlay(JoeDesignRing(
                    shape: RoundedRectangle(cornerRadius: 7)))
            }
            .joeCardButton()
            .focused($focusedAlt, equals: entry.id)
        }
    }

    /// The trailer sign-in prompt (DIAG-2050 §1c, PC arm
    /// only): when a trailer attempt in this detail ends
    /// in needsIdentity, the preview's silent rule would
    /// leave the owner with a dead headline feature and
    /// no signal — so the PC composition surfaces the
    /// EXISTING device-code activation here instead.
    /// Boundary (flagged in the WS-C report): the
    /// router's own surface, JoeYtDeviceCodeView, is
    /// built around a JoeYtPlayRequest (its footer,
    /// resume-on-approval and Menu-cancel all belong to
    /// a pending EPISODE playback) and cannot be
    /// presented honestly for a trailer attempt from
    /// this file — so this prompt mirrors its pattern
    /// (same heading family, code block, error + retry,
    /// spinner) over JoeYtIdentity's public API, driven
    /// by the same published state. It is in-flow text
    /// and buttons — NO panel over the backdrop, so the
    /// trailer area stays uncovered. Ordinary preview
    /// failures never reach here: only the
    /// trailer-needs-identity ending sets the flag (see
    /// startTrailerPreview).
    @ViewBuilder
    private var pcTrailerSignInPrompt: some View {
        if trailerSignInPrompt {
            VStack(alignment: .leading, spacing: 14) {
                Text("Trailer cần đăng nhập YouTube")
                    .font(JoePCType.outfit(30, weight: .bold))
                    .foregroundStyle(theme.text)
                Text("Trailer phát qua YouTube nên cần anh duyệt mã kích hoạt một lần trên điện thoại — không gõ mật khẩu trên TV. Duyệt xong, trailer của các phim sau tự chạy.")
                    .font(JoePCType.outfit(25))
                    .foregroundStyle(theme.meta)
                    .frame(maxWidth: 1150, alignment: .leading)
                if let code = ytIdentity.userCode {
                    Text("MÃ KÍCH HOẠT")
                        .font(JoePCType.outfit(22, weight: .semibold))
                        .tracking(2)
                        .foregroundStyle(theme.meta)
                    Text(code)
                        .font(JoePCType.outfit(54, weight: .bold))
                        .foregroundStyle(theme.text)
                    Text("Mở \(ytIdentity.verificationURL) trên iPhone → nhập mã này → duyệt bằng tài khoản của anh.")
                        .font(JoePCType.outfit(25))
                        .foregroundStyle(theme.meta)
                } else if let error = ytIdentity.flowError {
                    Text(error)
                        .font(JoePCType.outfit(25))
                        .foregroundStyle(theme.text)
                        .frame(maxWidth: 1150, alignment: .leading)
                    Button {
                        ytIdentity.beginDeviceCodeFlow()
                    } label: {
                        JoeSecondaryLabel(title: "Thử lại")
                    }
                    .joeCardButton()
                    .focused($focusedSignIn, equals: "retry")
                } else {
                    HStack(spacing: 12) {
                        ProgressView().tint(theme.text)
                        Text("Đang lấy mã kích hoạt…")
                            .font(JoePCType.outfit(25))
                            .foregroundStyle(theme.meta)
                    }
                }
                Button {
                    ytIdentity.cancelDeviceCodeFlow()
                    trailerSignInPrompt = false
                } label: {
                    JoeSecondaryLabel(title: "Để sau")
                }
                .joeCardButton()
                .focused($focusedSignIn, equals: "dismiss")
            }
            .padding(.top, 26)
            .focusSection()
            .onChange(of: ytIdentity.flowFinished) { _, finished in
                if finished == true { trailerSignInPrompt = false }
            }
        }
    }

    /// F's source rows: one row per source family, over the
    /// shared membership model (v2.0.5, D1). The policy's
    /// Tự động row leads (owner source-priority policy,
    /// 2026-11-15); the current provider's row pins that
    /// source when tapped; alternative rows are Buttons
    /// performing the same provider switch the alt chips
    /// perform in A/D (with the C-9 revert behind load()) —
    /// every specific-source tap PINS (autoSource off). The
    /// Torrent row (v2.0.5, D2) is a control now, like the
    /// chip anatomies' Torrent chip: pressing it in the
    /// .ready state opens the film's torrent detail; the
    /// substitution rung still fires automatically inside
    /// the director exactly as before.
    private func sourceRows(_ d: Detail) -> some View {
        // Design-F detail: the heading is the .rail-title at
        // the detail's inline 30px (margin-top 30 — applied by
        // boardDetail), margin-bottom 18 to the first row;
        // rows follow at the .srcrow margin-bottom 16. The
        // stack runs at 16 with the heading carrying the extra
        // 2 of bottom margin.
        VStack(alignment: .leading, spacing: 16) {
            Text("Nguồn phát — chọn là xem")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(theme.text)
                .padding(.bottom, 2)
            ForEach(sourceEntries) { entry in
                sourceRowEntry(entry, detail: d)
            }
            if switching {
                HStack(spacing: 12) {
                    ProgressView().tint(theme.text)
                    Text("Đang đổi nguồn…")
                        .font(.system(size: 25))
                        .foregroundStyle(theme.meta)
                }
            }
        }
        // v2.0.5 (N1, pair h): F's source block — the same
        // declared region as the chip anatomies'.
        .focusSection()
    }

    /// The current-source row's state text (was an
    /// inline ternary in sourceRowEntry's call —
    /// hoisted by the 2.0.48 sweep).
    private var currentRowState: String {
        ytActiveMode == nil
            ? (autoSource ? "Sẵn sàng" : "● Đang phát")
            : "Sẵn sàng"
    }

    /// The current-source row's state colour (same
    /// hoist).
    private var currentRowStateColor: Color {
        ytActiveMode == nil && !autoSource
            ? JoeTheme.okGreen : theme.meta
    }

    /// The current-source row's state weight (same
    /// hoist).
    private var currentRowStateWeight: Font.Weight {
        ytActiveMode == nil && !autoSource
            ? .semibold : .regular
    }

    /// One row-anatomy entry (F's half of the shared
    /// membership model).
    @ViewBuilder
    private func sourceRowEntry(_ entry: SourceEntry, detail d: Detail) -> some View {
        switch entry {
        case .auto:
            sourceRow(name: "Tự động",
                      meta: "Phim Âu Mỹ chiếu rạp: ưu tiên Torrent chất lượng cao · còn lại theo thứ tự nguồn",
                      state: ytAutoActive ? "● Đang chọn" : "Sẵn sàng",
                      stateColor: ytAutoActive ? JoeTheme.okGreen : theme.meta,
                      stateWeight: ytAutoActive ? .semibold : .regular,
                      focusID: "auto") {
                autoSource = true
                ytChainPinned = false
                ytMode = .auto
            }
        case .youtube:
            sourceRow(name: "YouTube",
                      meta: "TVB Vietnam trên YouTube · \(ytMatch?.eps.count ?? 0) tập · \(ytMatch?.tierLabel ?? "")",
                      state: ytActiveMode == .youtube ? "● Đang chọn" : "Sẵn sàng",
                      stateColor: ytActiveMode == .youtube ? JoeTheme.okGreen : theme.meta,
                      stateWeight: ytActiveMode == .youtube ? .semibold : .regular,
                      focusID: "youtube") {
                ytChainPinned = false
                ytMode = .youtube
                autoSource = false
            }
        case .current:
            sourceRow(name: Providers.displayName(provider),
                      meta: d.servers.map { $0.name }.filter { !$0.isEmpty }
                        .joined(separator: " · "),
                      state: currentRowState,
                      stateColor: currentRowStateColor,
                      stateWeight: currentRowStateWeight,
                      focusID: "current") {
                autoSource = false
                ytChainPinned = true
            }
        case .alternative(let code, let altSlug):
            sourceRow(name: Providers.displayName(code),
                      meta: "Nguồn khác của phim này",
                      state: "Sẵn sàng", stateColor: theme.meta,
                      focusID: code) {
                switchNotice = nil
                autoSource = false
                ytChainPinned = true
                provider = code
                slug = altSlug
            }
        case .torrent:
            torrentRow
        }
    }

    /// F's Torrent row, by entry state (v2.0.5, D2). The
    /// meta line is unchanged (the rung still substitutes
    /// automatically); what changed is the row's agency:
    /// .ready → a Button opening the film's torrent detail;
    /// .pending / .unresolved → a Button whose press is a
    /// no-op, the state text saying why (never a vanished
    /// row, never a dead press into nowhere); .notConfigured
    /// keeps the shipped status-only "Cần token" row.
    @ViewBuilder
    private var torrentRow: some View {
        switch torrentEntryState {
        case .notConfigured:
            // Design-F detail: the Torrent row's "Cần token"
            // state is the plain .st (meta colour, regular
            // weight) — no warning colour in the drawing.
            sourceRow(name: "Torrent",
                      meta: "Nguồn thay thế tự động khi các nguồn trên đều chết",
                      state: "Cần token",
                      stateColor: theme.meta,
                      action: nil)
        case .pending:
            sourceRow(name: "Torrent",
                      meta: "Nguồn thay thế tự động khi các nguồn trên đều chết",
                      state: "Đang tìm mã IMDb…",
                      stateColor: theme.meta,
                      focusID: "torrent") { }
        case .unresolved:
            sourceRow(name: "Torrent",
                      meta: "Nguồn thay thế tự động khi các nguồn trên đều chết",
                      state: "Chưa tìm được mã IMDb",
                      stateColor: .orange,
                      focusID: "torrent") { }
        case .ready:
            sourceRow(name: "Torrent",
                      meta: "Nguồn thay thế tự động khi các nguồn trên đều chết",
                      state: "Sẵn sàng",
                      stateColor: theme.meta,
                      focusID: "torrent") {
                openTorrentDetail()
            }
        }
    }

    /// One source row (UI-6 defect D-6): SINGLE line — name and
    /// meta inline on one row (the render's .srcrow: name 30
    /// bold, meta 24 in the meta colour, state 25 — regular at
    /// rest, semibold only in the .st.ok / .st.bad variants —
    /// padding 22/30, radius theme.rField, the theme's
    /// surface-gradient fill, and the resting inset stroke 1.5
    /// under the focus ring).
    /// v2.0.5 (N1, pair h): a row with an action AND a focusID
    /// joins the detail's focus system (focusedAlt, the same
    /// binding the chip anatomies use). v2.0.8 (Phase 1):
    /// movement is the focus engine's geometric search — no
    /// hand-written routing. The status-only row
    /// (action nil — "Cần token") stays non-focusable text.
    @ViewBuilder
    private func sourceRow(name: String, meta: String, state: String,
                           stateColor: Color,
                           stateWeight: Font.Weight = .regular,
                           focusID: String? = nil,
                           action: (() -> Void)?) -> some View {
        // Stepwise since run #34 (see detailScrollTasks):
        // the row's five styling modifiers compose one per
        // let binding, not in a single expression over the
        // HStack subtree.
        let rowBase = HStack(alignment: .center, spacing: 20) {
            Text(name)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(theme.text)
            if !meta.isEmpty {
                Text(meta)
                    .font(.system(size: 24))
                    .foregroundStyle(theme.meta)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(state)
                .font(.system(size: 25, weight: stateWeight))
                .foregroundStyle(stateColor)
        }
        let rowPadded = rowBase
            .padding(.horizontal, 30)
        let rowSpaced = rowPadded
            .padding(.vertical, 22)
        // RECALC-213 note: the 2026-11-22 12:15 CST
        // content-hug override was refined the same day
        // (12:28 CST) — a VERTICALLY STACKED source list
        // keeps ONE uniform bar width, never ragged
        // per-bar widths. This legacy row's uniform form
        // is its established full-width frame (state
        // pinned right), so it is restored unchanged;
        // the refinement's fitted uniform width applies
        // to the torrent stream rows (§3.12).
        let rowFramed = rowSpaced
            .frame(maxWidth: .infinity, alignment: .leading)
        let rowFilled = rowFramed
            .background(RoundedRectangle(cornerRadius: theme.rField)
                .fill(theme.surfaceGradient))
        let row = rowFilled
            .overlay(RoundedRectangle(cornerRadius: theme.rField)
                .strokeBorder(theme.stroke, lineWidth: 1.5))
        if let action {
            // D1 (2.0.48): EVERY row built here kills the
            // preview in its press — several row actions
            // (the mode rows, the torrent row's no-op
            // states) change no hooked value, so the kill
            // lives at this single construction point and
            // no row action can miss it.
            let button = Button(action: {
                killPreviewOnInput()
                action()
            }) {
                row.overlay(JoeFocusRing(shape: RoundedRectangle(cornerRadius: theme.rField)))
            }
            .joeCardButton()
            if let focusID {
                button
                    .focused($focusedAlt, equals: focusID)
            } else {
                button
            }
        } else {
            row
        }
    }

    /// Genre chips from the detail's categories string (shared
    /// by all three heads; non-focusable decoration).
    @ViewBuilder
    private func genreChips(_ d: Detail) -> some View {
        let genres: [String] = d.categories
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if !genres.isEmpty {
            // Design .chip geometry (all three detail drawings):
            // 24px medium, padding 11px 22px, surface2 capsule
            // with the resting inset stroke 1.5 theme.stroke;
            // row gap 12. Non-focusable decoration, so the stroke
            // is unconditional (never the focus ring).
            HStack(spacing: 12) {
                ForEach(genres, id: \.self) { genre in
                    Text(genre)
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(theme.text)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 11)
                        .background(Capsule().fill(theme.surface2))
                        .overlay(Capsule().strokeBorder(theme.stroke,
                                                        lineWidth: 1.5))
                }
            }
        }
    }

    // MARK: - Header (design A composition; pieces shared by D/F heads)

    private func header(_ d: Detail) -> some View {
        // Design-A detail (design-A/detail.html): content row
        // gap 44; the info column's elements carry the drawing's
        // own margins — title margin-top 8 below the origin line,
        // meta 10, genre chips 18, synopsis 18, cast line 14,
        // buttons 26 with gap 18 — so the column runs at
        // spacing 0 with per-element top paddings (absent
        // elements collapse with their margin, like CSS).
        let hasGenres: Bool = d.categories.split(separator: ",")
            .contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let hasSynopsis: Bool = !(tmdb?.overview.isEmpty ?? true)
            || !d.content.isEmpty
        let synopsisText: String = (tmdb?.overview.isEmpty ?? true)
            ? d.content : (tmdb?.overview ?? "")
        return HStack(alignment: .top, spacing: 44) {
            posterArt(d.movie)
            // OWNER FIDELITY RULE (design A render, 2026-11-15):
            // the info column's order is the render's — origin
            // name, title, meta line, genre chips, synopsis,
            // actors line, action buttons.
            VStack(alignment: .leading, spacing: 0) {
                if !d.movie.originName.isEmpty {
                    Text(d.movie.originName)
                        .font(.system(size: 24))
                        .foregroundStyle(theme.meta)
                        .lineLimit(1)
                }
                Text(d.movie.name)
                    .font(.system(size: 60, weight: .heavy))
                    .foregroundStyle(theme.text)
                    .lineLimit(3)
                    .padding(.top, 8)
                if !d.metaLine.isEmpty {
                    Text(d.metaLine)
                        .font(.system(size: 27, weight: .medium))
                        .foregroundStyle(theme.heroMeta)
                        .padding(.top, 10)
                }
                genreChips(d)
                    .padding(.top, hasGenres ? 18 : 0)
                if hasSynopsis {
                    Text(synopsisText)
                        .font(.system(size: 26))
                        .foregroundStyle(theme.text.opacity(0.92))
                        .lineSpacing(8)
                        .lineLimit(5)
                        .frame(maxWidth: 1020, alignment: .leading)
                        .padding(.top, 18)
                }
                actorsLine
                HStack(spacing: 18) {
                    playButton(d)
                    favButton(d)
                    followButton(d)
                }
                .padding(.top, 26)
            }
            Spacer(minLength: 0)
        }
    }

    /// The render's actors line (design A): the TMDB cast as one
    /// text line inside the info column, between the synopsis
    /// and the buttons. (Designs D and F keep the photo cast
    /// row; in A the line is the render's own presentation.)
    ///
    /// FIX4 (fix 3): the names are BUTTONS now — each opens
    /// its actor page, exactly like the castRow cells in
    /// Ultra/D. Pre-fix the line was one plain Text: visible
    /// but not focusable, so idea 20 was unreachable in this
    /// theme and the owner reported the cast as missing. The
    /// line keeps its slot, prefix, 24 pt size and meta
    /// colour; the separators ride between the buttons as
    /// plain text, and focus paints the name alone (see
    /// JoeActorNameLabel) — at rest the line renders as the
    /// drawing's line.
    ///
    /// v2.0.30 (FIX6): the drawing's separators are " · "
    /// (design-A/detail.html), and its names are WHOLE —
    /// the pre-fix line fed six names into the 1050-pt
    /// column and SwiftUI compressed every label, so the
    /// owner's photo shows each name cut mid-word ("Paul
    /// Betta...", "James Spa..."). The line now admits
    /// whole names only, while they fit (fittedActors);
    /// the names left off stay reachable through the
    /// shown names' actor pages and the other themes'
    /// photo rows.
    @ViewBuilder
    private var actorsLine: some View {
        if let tmdb, !tmdb.cast.isEmpty {
            // Design-A detail cast line: 24px in the meta colour,
            // margin-top 14 (the padding lives inside the
            // conditional so an absent cast collapses fully).
            HStack(spacing: 2) {
                Text("Diễn viên: ")
                    .font(.system(size: 24))
                    .foregroundStyle(theme.meta)
                ForEach(Array(Self.fittedActors(tmdb.cast).enumerated()),
                        id: \.offset) { index, member in
                    if index > 0 {
                        Text(" · ")
                            .font(.system(size: 24))
                            .foregroundStyle(theme.meta)
                    }
                    Button {
                        actorNameAction(member)
                    } label: {
                        JoeActorNameLabel(name: member.name)
                    }
                    .joeCardButton()
                    .focused($focusedCast, equals: member.id)
                }
            }
            .frame(maxWidth: 1050, alignment: .leading)
            .padding(.top, 14)
        }
    }

    /// The actors line's name-button press, extracted
    /// from its Button action closure (2.0.48 sweep):
    /// the original body verbatim.
    private func actorNameAction(_ member: TMDBCastMember) {
        // D1 (2.0.48): the press itself
        // kills the preview (see castCell).
        preview.kill(reason: "input")
        actorRoute = .tmdb(personId: member.id,
                            name: member.name,
                            photoURL: member.photoURL)
    }

    /// v2.0.30 (FIX6): which of the cast the design-A line
    /// shows — whole names, in order, while they fit the
    /// line's 1050-pt column at the drawing's own values:
    /// the "Diễn viên: " prefix and each name at 24 pt,
    /// " · " separators, plus each name button's 16 pt of
    /// horizontal plate inset (JoeActorNameLabel's 8 + 8)
    /// and the HStack's 2-pt inter-element gaps.
    /// Measured with the real font (NSString/UIFont), not
    /// estimated. The walk stops at the first name that
    /// would not fit whole — a later, shorter name never
    /// jumps the queue — and the first name always rides,
    /// even if it alone overflows (it then truncates as a
    /// single label, the least-bad state). The standing
    /// six-name presentation cap is kept.
    private static func fittedActors(_ cast: [TMDBCastMember]) -> [TMDBCastMember] {
        let font = UIFont.systemFont(ofSize: 24)
        func width(_ string: String) -> CGFloat {
            (string as NSString).size(withAttributes: [.font: font]).width
        }
        var used = width("Diễn viên: ")
        var fitted: [TMDBCastMember] = []
        for member in cast.prefix(6) {
            // Each name also pays the HStack's 2-pt gaps:
            // one before its button, plus one before its
            // separator when it has one.
            let extra = (fitted.isEmpty ? 2 : 4 + width(" · "))
                + width(member.name) + 16
            guard used + extra <= 1050 else { break }
            used += extra
            fitted.append(member)
        }
        if fitted.isEmpty, let first = cast.first {
            fitted = [first]
        }
        return fitted
    }

/// FIX4 (fix 3): one actor name inside design A's cast
/// line. At rest it IS the drawing's line — 24 pt, meta
/// colour, no chrome. Focused, the name alone gains a
/// quiet plate and semibold weight (the house value-only
/// focus convention for text, JoeChipLabel's family):
/// the line's geometry and resting colours never change.
private struct JoeActorNameLabel: View {
    let name: String
    @Environment(\.isFocused) private var isFocused
    @Environment(\.joeTheme) private var theme

    var body: some View {
        Text(name)
            .font(.system(size: 24,
                          weight: isFocused ? .semibold : .regular))
            .foregroundStyle(isFocused ? theme.text : theme.meta)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(isFocused ? theme.surface2 : Color.clear))
    }
}

/// One cast name in the Private Cinema detail credits
/// (privateCinemaDetail) — a plain text name, identical
/// in dress to JoeTorNameLabel (JoeTorrent.swift) so the
/// chain and torrent PC credits render as the same
/// element (the deviation table's "same text-line
/// credits"): 25 pt, theme.text at rest.
/// RECALC-213 R6 (RECALC-SPEC §4) SUPERSEDES the
/// FIX-213 Fault-2 plate treatment recorded here
/// before: the font is the theme's own family —
/// Outfit 25 (the size is the app's; the drawing does
/// not measure it) — and focus is semibold + an IVORY
/// outset ring (the chip family: JoeChipRing, 2 px,
/// offset 4), with NO plate and NO fill. The resting
/// dress (Outfit 25 regular, theme.text, no ring, no
/// plate) and the lineLimit/padding are unchanged, so
/// the resting text line does not move.
private struct JoeCinemaNameLabel: View {
    let name: String
    @Environment(\.isFocused) private var isFocused
    @Environment(\.joeTheme) private var theme

    var body: some View {
        Text(name)
            .font(JoePCType.outfit(25, weight: isFocused ? .semibold : .regular))
            .foregroundStyle(isFocused ? theme.focusTitle : theme.text)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .overlay(JoeChipRing(shape: RoundedRectangle(cornerRadius: 8)))
    }
}

/// The PC detail back row's label (v2.1.1 fix round,
/// Lens C F2): the drawing's plain "← Quay lại" text —
/// the same element the PC Settings top row carries
/// (PCBackLabel, JoeSettings.swift): arrow glyph +
/// "Quay lại", focus recolours the text to theme.focus,
/// value-only — no plate, no ring of its own, no scale;
/// the button's native kit treatment is the focus
/// rendering, exactly as on the Settings row.
private struct PCDetailBackLabel: View {
    @Environment(\.isFocused) private var isFocused
    @Environment(\.joeTheme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.left")
                .font(.system(size: 24, weight: .medium))
            Text("Quay lại")
                .font(JoePCType.outfit(26))
        }
        .foregroundStyle(isFocused ? theme.focus : theme.text)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

    // MARK: - Nguồn phát membership (ONE shared model, v2.0.5)

    /// ONE membership model for the Nguồn phát block
    /// (v2.0.5, D1): the ordered source entries every detail
    /// anatomy renders — Tự động, the current provider, one
    /// entry per alternative provider, and the Torrent
    /// entry LAST, always. Until now each anatomy kept a
    /// private builder and D's never created a Torrent
    /// element at all (the owner's yellow-theme photo: the
    /// chip missing for every title); with membership
    /// computed HERE, an anatomy owns only its layout (A/D
    /// chips, F rows) and cannot silently drop an entry —
    /// the Torrent entry's absence from a layout is now a
    /// compile-visible choice, not an omission.
    private enum SourceEntry: Identifiable {
        case auto
        /// TVB YouTube feature: the YouTube mode entry —
        /// present in the membership ONLY when this detail's
        /// TVB title has a YouTube match (see sourceEntries),
        /// so every anatomy gains it by construction and no
        /// anatomy can silently drop it (the D1 rule).
        case youtube
        case current
        case alternative(code: String, slug: String)
        case torrent

        var id: String {
            switch self {
            case .auto: return "auto"
            case .youtube: return "youtube"
            case .current: return "current"
            case .alternative(let code, _): return "alt|" + code
            case .torrent: return "torrent"
            }
        }
    }

    private var sourceEntries: [SourceEntry] {
        var entries: [SourceEntry] = [.auto]
        if ytMatch != nil { entries.append(.youtube) }
        entries.append(.current)
        entries += alternatives.map {
            .alternative(code: $0.code, slug: $0.slug)
        }
        entries.append(.torrent)
        return entries
    }

    /// The YouTube series matched to THIS detail's TVB
    /// title (the fail-closed snapshot match, design §1.4),
    /// or nil. TVB-route details only: the snapshot's ids
    /// are 803-snapshot ids, pinned to route.tvb exactly as
    /// the enrichment task pins its TMDB identity (the
    /// fault-c rule) — a non-TVB detail never sees YouTube.
    private var ytMatch: JoeYtSeries? {
        guard let ctx = route.tvb else { return nil }
        return ytStore.snapshot?.matchByTmdbId[ctx.tmdbId]
    }

    /// The YouTube mode in force for this detail, or nil
    /// when YouTube is not in play (no match, or the owner
    /// pinned a chain source with a specific-source tap).
    private var ytActiveMode: JoeYtSourceMode? {
        guard ytMatch != nil, !ytChainPinned else { return nil }
        return ytMode
    }

    /// The Tự động entry's selected state across anatomies:
    /// the YouTube-first Auto when a match is in force;
    /// with no match, exactly the pre-feature autoSource.
    private var ytAutoActive: Bool {
        ytActiveMode == .auto || (ytMatch == nil && autoSource)
    }

    /// The chain's episode names for the shared grid: the
    /// flattened server lists de-duplicated by name, in
    /// order — the same universe startEpisode resolves over.
    private func chainEpisodeNames(_ d: Detail) -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for ep in d.servers.flatMap({ $0.episodes }) {
            if seen.insert(ep.name).inserted { names.append(ep.name) }
        }
        return names
    }

    /// The Torrent entry's state (D1/D2): configuration from
    /// TorrentSettings, identity from the detail-time ladder
    /// (filmIdentity). `.pending` = the ladder has not landed
    /// for this record; `.unresolved` = it landed EMPTY — the
    /// honest end state, rendered visibly, never a vanished
    /// entry.
    private enum TorrentEntryState {
        case notConfigured
        case pending
        case ready(imdbId: String)
        case unresolved
    }

    private var torrentEntryState: TorrentEntryState {
        guard TorrentSettings.isConfigured else { return .notConfigured }
        guard let filmIdentity else { return .pending }
        return filmIdentity.imdbId.isEmpty
            ? .unresolved : .ready(imdbId: filmIdentity.imdbId)
    }

    /// The Torrent entry pressed in its .ready state (D2):
    /// open THIS film's torrent detail — the torrent tab's
    /// own screen (JoeTorrentDetail), layered over this
    /// detail by the root (nav.tor, zIndex above the movie
    /// layer), so its own-root Menu handler closes back to
    /// this page with this page's state intact. The meta is
    /// keyed by the resolved IMDb id and addressed through
    /// Cinemeta (the FIX9b lesson: Torrentio serves no
    /// metadata — its base must never be a meta base). Any
    /// other state: the press is a no-op and the entry's
    /// state stays on screen.
    private func openTorrentDetail() {
        guard case .ready(let imdbId) = torrentEntryState,
              let d = detail else { return }
        var meta = TorMeta()
        meta.id = imdbId
        meta.type = torrentMetaType(d)
        meta.name = d.movie.name
        meta.poster = d.movie.poster
        meta.background = tmdb?.backdropURL ?? ""
        meta.year = d.movie.year
        meta.desc = (tmdb?.overview.isEmpty ?? true)
            ? d.content : (tmdb?.overview ?? "")
        nav.tor = TorRoute(meta: meta, base: TorrentSettings.cinemeta)
    }

    /// Movie vs series for the torrent meta: the TMDB type
    /// when any record carries one (the detail's own first,
    /// then the ladder's — the ladder may hold the type the
    /// opened record lacked); with no type on record, a
    /// multi-episode detail is a series (the substitution
    /// rung's own test).
    private func torrentMetaType(_ d: Detail) -> String {
        var type = d.movie.tmdbType
        if type.isEmpty, let resolved = filmIdentity?.tmdbType,
           !resolved.isEmpty {
            type = resolved
        }
        if type == "tv" { return "series" }
        if type.isEmpty {
            let episodeCount = d.servers.reduce(0) { $0 + $1.episodes.count }
            if episodeCount > 1 { return "series" }
        }
        return "movie"
    }

    /// The Torrent entry in the chip anatomies (A + D),
    /// v2.0.5 (D2): a real focusable control now — until now
    /// A rendered a bare non-focusable label and D rendered
    /// nothing. Configured → the button stands (press opens
    /// the torrent detail when the identity is .ready; the
    /// press is a no-op while .pending / .unresolved, with
    /// the state note under the row saying why). Unconfigured
    /// → no chip: design A's shipped treatment (F carries
    /// the "Cần token" row for that state instead).
    @ViewBuilder
    private var torrentChip: some View {
        if TorrentSettings.isConfigured {
            Button {
                torrentChipAction()
            } label: {
                JoeChipLabel(title: "Torrent", selected: false)
            }
            .joeCardButton()
            .focused($focusedAlt, equals: "torrent")
        }
    }

    /// torrentChip's press, extracted from its
    /// Button action closure (2.0.48 sweep): the
    /// original body verbatim.
    private func torrentChipAction() {
        // D1 (2.0.48): the press is a no-op while
        // the identity is .pending / .unresolved —
        // it still counts as input, so it kills
        // the preview itself (see sourceChip).
        preview.kill(reason: "input")
        openTorrentDetail()
    }

    /// One chip-anatomy entry (shared by A's sourceChips and
    /// D's altChips — the two rows' buttons were byte-identical
    /// copies; they are one builder now, over the shared
    /// membership model).
    @ViewBuilder
    private func sourceChip(_ entry: SourceEntry) -> some View {
        switch entry {
        case .auto:
            Button {
                autoChipAction()
            } label: {
                JoeChipLabel(title: "Tự động",
                             selected: ytAutoActive)
            }
            .joeCardButton()
            .focused($focusedAlt, equals: "auto")
        case .youtube:
            Button {
                youtubeChipAction()
            } label: {
                JoeChipLabel(title: "YouTube",
                             selected: ytActiveMode == .youtube)
            }
            .joeCardButton()
            .focused($focusedAlt, equals: "youtube")
        case .current:
            Button {
                currentChipAction()
            } label: {
                JoeChipLabel(title: Providers.displayName(provider),
                             selected: ytActiveMode == nil && !autoSource)
            }
            .joeCardButton()
            .focused($focusedAlt, equals: "current")
        case .alternative(let code, let altSlug):
            Button {
                alternativeChipAction(code: code, altSlug: altSlug)
            } label: {
                JoeChipLabel(title: Providers.displayName(code), selected: false)
            }
            .joeCardButton()
            .focused($focusedAlt, equals: code)
        case .torrent:
            torrentChip
        }
    }

    /// The Tự động chip's press, extracted from its
    /// Button action closure (2.0.48 sweep): the
    /// original body verbatim.
    private func autoChipAction() {
        // D1 (2.0.48): these actions set only
        // unhooked mode state — a Select with
        // focus already resting here changes no
        // hooked value, so the press itself kills
        // the preview (the fav/follow rule).
        preview.kill(reason: "input")
        autoSource = true
        // TVB YouTube: Tự động is the YouTube-first
        // mode when a match exists (the owner's law);
        // with no match this is exactly the old tap.
        ytChainPinned = false
        ytMode = .auto
    }

    /// The YouTube chip's press, extracted the same
    /// way: the original body verbatim.
    private func youtubeChipAction() {
        preview.kill(reason: "input")
        ytChainPinned = false
        ytMode = .youtube
        autoSource = false
    }

    /// The current-source chip's press, extracted
    /// the same way: the original body verbatim.
    private func currentChipAction() {
        preview.kill(reason: "input")
        autoSource = false
        ytChainPinned = true
    }

    /// An alternative-source chip's press, extracted
    /// the same way: the original body verbatim.
    private func alternativeChipAction(code: String, altSlug: String) {
        preview.kill(reason: "input")
        switchNotice = nil
        autoSource = false
        ytChainPinned = true
        provider = code
        slug = altSlug
    }

    /// The unresolved-identity note under a chip row: the
    /// row's own meta text treatment (25 pt, theme.meta —
    /// the size/style D's "Nguồn phát:" label already uses).
    @ViewBuilder
    private var torrentUnresolvedNote: some View {
        if case .unresolved = torrentEntryState {
            Text("Chưa tìm được mã IMDb")
                .font(.system(size: 25))
                .foregroundStyle(theme.meta)
        }
    }

    /// Design A's Nguồn phát block (UI-6 defects D-11 + D-12;
    /// owner source-priority policy): the render's bold
    /// "Nguồn phát" block heading over the chip row — Tự động
    /// FIRST (the policy's default), the current source's chip
    /// (tapping PINS it), one chip per alternative source
    /// (tapping switches AND pins — C-9 revert behind load()),
    /// and the Torrent chip (v2.0.5: a real control over the
    /// shared membership model — see sourceChip/torrentChip).
    private var sourceChips: some View {
        // Design-A: the heading→chips gap is the rail-title
        // margin-bottom, 18.
        VStack(alignment: .leading, spacing: 18) {
            Text("Nguồn phát")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(theme.text)
            HStack(spacing: 14) {
                if switching {
                    ProgressView().tint(theme.text)
                }
                ForEach(sourceEntries) { entry in
                    sourceChip(entry)
                }
            }
            torrentUnresolvedNote
        }
        // v2.0.5 (N1, pair h): the source block is a declared
        // focus region between the header pair and the
        // episode block.
        .focusSection()
    }

    /// Poster size per design (A frame 288×432, D 300×450,
    /// F compact 160×240, Private Cinema 288×432 v2.1.0).
    private var posterSize: CGSize {
        switch theme.id {
        case .billboard: return CGSize(width: 288, height: 432)
        case .posterWall: return CGSize(width: 300, height: 450)
        case .sourceBoard: return CGSize(width: 160, height: 240)
        case .ultra: return CGSize(width: 288, height: 432)
        case .privateCinema: return CGSize(width: 288, height: 432)
        }
    }

    /// The poster, pipeline-backed (v2.0.0 — AsyncImage is gone
    /// from every poster path). A and F set it in a painted
    /// frame (surface fill + padding, the renders' posterframe);
    /// D shows the bare art with a hairline stroke.
    /// IMAGE INTEGRITY (owner rule, 2026-11-15): the slot is an
    /// exact 2:3 frame in every theme (288×432 / 300×450 /
    /// 160×240) and the image is FIT into it — the whole poster
    /// visible, aspect preserved; the painted frame/surface is
    /// the fallback when a poster is missing.
    @ViewBuilder
    private func posterArt(_ m: Movie) -> some View {
        let size = posterSize
        let posterRadius: CGFloat = theme.id == .billboard
            ? 2
            : (theme.id == .posterWall
               ? 18
               : max(theme.rCard - theme.artInset, 0))
        let image = ZStack {
            Color.black.opacity(0.45)
            JoeRemoteImage(url: m.posterURL,
                           targetPixels: theme.id == .sourceBoard ? 480 : 960,
                           fit: true,
                           slotClass: .portrait,
                           fallbackProvider: {
                               await JoeImagePipeline.shared.tmdbPosterURL(
                                   tmdbId: m.tmdbId, type: m.tmdbType)
                           }) {
                Text(m.name)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(18)
            }
        }
        .frame(width: size.width, height: size.height)
        // Concentric radii — the art's clip follows the frame it
        // sits in. Design values (posterframe img radius):
        // A 2px (the approved drawing — an earlier "A: square 0,
        // accepted" note is superseded by the drawing itself);
        // D: the wall's 18 stroke radius; F: rCard − artInset.
        .clipShape(RoundedRectangle(cornerRadius: posterRadius))
        if theme.id == .posterWall {
            // Design-D detail: the poster's frame line is a
            // 2px OUTSET shadow — box-shadow: 0 0 0 2px
            // rgba(255,255,255,.38) — and theme.stroke carries
            // exactly that colour under D.
            image
                .overlay(RoundedRectangle(cornerRadius: 18)
                    .joeOutsetStrokeBorder(theme.stroke, lineWidth: 2))
        } else {
            image
                .padding(theme.artInset)
                .background(RoundedRectangle(cornerRadius: theme.rCard)
                    .fill(theme.surfaceGradient))
                .overlay(RoundedRectangle(cornerRadius: theme.rCard)
                    .strokeBorder(theme.stroke, lineWidth: 1.5))
        }
    }

    private var tmdbBackdropURL: URL? {
        (tmdb?.backdropURL).flatMap { $0.isEmpty ? nil : URL(string: $0) }
    }

    /// FIX-7 (2.1.1): the portrait treatment for one
    /// backdrop leg. A TVB title (route.tvb != nil — the
    /// same discriminator runPreview's FIX-7 guard uses)
    /// gets .slice ALWAYS: its backdrop is a still (no
    /// trailer preview ever starts), and the sharp
    /// full-bleed slice is the WS-D path — the .blurField
    /// / .treatment blurred field must never smear a TVB
    /// still. A non-TVB title keeps its surface's
    /// existing mode byte-for-byte (the parameter).
    private func stillPortraitMode(
        nonTVB: JoeBandImage.PortraitMode
    ) -> JoeBandImage.PortraitMode {
        route.tvb != nil ? .slice : nonTVB
    }

    /// The band exists whenever ANY band art can paint: the
    /// TMDB backdrop, the provider thumb, or — v2.0.1 — the
    /// poster itself (the portrait treatment is a real band,
    /// so a poster-only film no longer opens on a missing
    /// band while its TMDB search is still in flight).
    private func bandVisible(movie: Movie, tmdbURL: URL?) -> Bool {
        movie.thumbURL != nil || tmdbURL != nil || movie.posterURL != nil
    }

    /// Design A's backdrop band (430 tall), v2.0.1 — the
    /// Android v2.3 backdrop pipeline expressed natively.
    /// Three image stages in one stack, each painting the
    /// moment its bitmap is on the device, higher stages
    /// covering lower ones as they land (the declarative form
    /// of the Android stage guards — the TMDB layer sits on
    /// top, so nothing can ever paint over the final):
    ///   1. the poster treatment (JoeBandImage): blurred
    ///      field + the whole poster at band height — fed
    ///      from the decoded cache the tapped card warmed,
    ///      so the band's first frame is instant (FIX4 peek);
    ///   2. the provider's landscape thumb as a full-size
    ///      top-anchored slice (FIX round 1 — the centred
    ///      slice cut faces);
    ///   3. the TMDB w1280 backdrop, same slice.
    /// The fade over the whole composite is the design's own
    /// (design-A/detail.html .fade, verbatim):
    /// linear-gradient(0deg, #0A0A0A 5%, rgba(10,10,10,.25)
    /// 60%, rgba(10,10,10,.45)) — read top→bottom: 45% shade
    /// at the top, 25% at 40% of the height, solid foundation
    /// from 95% down, so the poster copy's foot and the
    /// overlapping header text melt into the foundation
    /// exactly as the render has them (this replaces the UI-3
    /// scrim-floor approximation with the design's literal
    /// stops — the same stops the Android build ships).
    /// Pure decoration — no focusable elements. Hidden
    /// entirely when no art exists at all (the header then
    /// renders un-overlapped).
    @ViewBuilder
    private func backdropBand(movie: Movie, tmdbURL: URL?) -> some View {
        let previewOpacity: Double = preview.visible && !preview.fadingOut
            ? 1 : 0
        let previewFadeDuration: Double = preview.visible ? 0.8 : 0.15
        if bandVisible(movie: movie, tmdbURL: tmdbURL) {
            // Stepwise since run #34 (see detailScrollTasks):
            // the band's four trailing modifiers compose one
            // per let binding below, not in a single
            // expression over the ZStack subtree.
            let bandStack = ZStack {
                Color.black.opacity(0.45)
                if let url = movie.posterURL {
                    // FIX-7 (2.1.1): a TVB title's poster leg
                    // takes .slice (sharp still, no trailer
                    // covers the band); non-TVB keeps the
                    // .treatment construction exactly.
                    JoeBandImage(url: url, targetPixels: 1920,
                                 anchor: 0.16,
                                 portraitMode: stillPortraitMode(nonTVB: .treatment))
                }
                if let url = movie.thumbURL {
                    JoeBandImage(url: url, targetPixels: 1920,
                                 anchor: 0.16, portraitMode: .slice)
                }
                if let url = tmdbURL {
                    JoeBandImage(url: url, targetPixels: 1920,
                                 anchor: 0.16, portraitMode: .slice)
                }
                // 2.0.48 (Leg 3): the backdrop preview's
                // video layer, inside the band's own stack
                // (above the TMDB slice, below the fade) —
                // the band's clip shape and stroke overlay
                // apply to it exactly as to the images.
                // Crossfade in 0.8 s, crossfade back out
                // at the natural end (fadingOut); a kill
                // cuts instantly (same rule as the Ultra
                // layer).
                if preview.player != nil {
                    JoePreviewLayerView(controller: preview)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .opacity(previewOpacity)
                        .animation(.easeInOut(duration: previewFadeDuration),
                                   value: preview.visible)
                        .animation(.easeInOut(duration: 0.8),
                                   value: preview.fadingOut)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                LinearGradient(stops: [
                    .init(color: theme.bg.opacity(0.45), location: 0),
                    .init(color: theme.bg.opacity(0.25), location: 0.40),
                    .init(color: theme.bg, location: 0.95),
                    .init(color: theme.bg, location: 1)
                ], startPoint: .top, endPoint: .bottom)
            }
            let bandWide = bandStack
                .frame(maxWidth: .infinity)
            let bandSized = bandWide
                .frame(height: 430)
            let bandClipped = bandSized
                // v2.0.5 (N5 — design fidelity): DESIGN-SPEC-V19
                // §7.4 specifies this strip with corner radius 18
                // and a white @ 0.14 stroke at 2 pt, and
                // acceptance shot 16 requires the radius VISIBLE;
                // the shipped band was square-cornered (the
                // owner's "Backdrop của theme ko có bo góc").
                // Applied on the band's EXISTING geometry: the
                // height stays 430 — §7.4's frozen 540 predates
                // the approved composition this page was built
                // from (the render + Android pipeline both run
                // 430), so the dimension is flagged in the wave
                // report rather than silently changed here.
                .clipShape(RoundedRectangle(cornerRadius: 18))
            bandClipped
                .overlay(RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 2))
        }
    }

    // MARK: - Cast (TMDB)

    /// "Diễn viên" row (v1.6): placed right after the header's
    /// overview/meta block, before the alternative-source chips
    /// and the episode servers. Idea 20 (owner-approved): the
    /// cells are now focusable buttons presenting the actor
    /// page — the house .joeCardButton() construction, with
    /// the cell's visuals byte-identical to the non-button
    /// form they replace. (Design A's actorsLine was a plain
    /// text line until v2.0.28 (FIX4 fix 3): its names are
    /// buttons in the line's own dress now — see actorsLine.)
    private func castRow(_ cast: [TMDBCastMember]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Diễn viên")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(theme.text.opacity(0.9))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 24) {
                    ForEach(cast) { member in
                        castCell(member)
                    }
                }
            }
        }
    }

    private func castCell(_ member: TMDBCastMember) -> some View {
        Button {
            castCellAction(member)
        } label: {
            JoeCastCellLabel(member: member)
        }
        .joeCardButton()
        .focused($focusedCast, equals: member.id)
    }

    /// castCell's press, extracted from its Button
    /// action closure (2.0.48 sweep): the original
    /// body verbatim.
    private func castCellAction(_ member: TMDBCastMember) {
        // D1 (2.0.48): the press itself kills the
        // preview — presenting the actor cover must
        // not leave it playing behind the cover.
        preview.kill(reason: "input")
        actorRoute = .tmdb(personId: member.id, name: member.name,
                            photoURL: member.photoURL)
    }

/// v2.0.29 (cluster A, item 1a): one cast cell's label.
/// Until now this label painted NO focus state at all —
/// .joeCardButton() suppresses the system focus effect
/// centrally, and every other focusable surface in the app
/// survives that by reading its own focus from the
/// environment and painting a value-only ring (PosterCard,
/// JoeChipLabel, JoePrimaryLabel). The cast cell never did,
/// so a focused cast cell was pixel-identical to an
/// unfocused one and the owner could not tell which actor
/// held focus ("không có focus"). The label now reads
/// \.isFocused exactly like PosterCard does: focused, the
/// photo gains the theme's ring (ringWidth, theme.focus —
/// the cell carries no selected fill, so the posterWall
/// white-ring exception for yellow-filled items does not
/// apply) and the name takes the focus title colour.
/// Every resting value (110 pt circle, white .10 fill,
/// white .14 / 1.2 resting stroke, 23 pt name/character,
/// 120 width) is byte-identical to the pre-fix label.
private struct JoeCastCellLabel: View {
    let member: TMDBCastMember
    @Environment(\.isFocused) private var isFocused
    @Environment(\.joeTheme) private var theme

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().fill(Color.white.opacity(0.10))
                if !member.photoURL.isEmpty, let url = URL(string: member.photoURL) {
                    JoeRemoteImage(url: url, targetPixels: 240) {
                        initial
                    }
                } else {
                    initial
                }
            }
            .frame(width: 110, height: 110)
            .clipShape(Circle())
            .overlay(Circle()
                .strokeBorder(isFocused ? theme.focus
                                        : Color.white.opacity(0.14),
                              lineWidth: isFocused ? theme.ringWidth : 1.2))
            Text(member.name)
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(isFocused ? theme.focusTitle : theme.text)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            if !member.character.isEmpty {
                Text(member.character)
                    .font(.system(size: 23))
                    .foregroundStyle(theme.meta)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(width: 120)
    }

    private var initial: some View {
        Text(String(member.name.prefix(1)))
            .font(.system(size: 38, weight: .bold))
            .foregroundStyle(.white.opacity(0.8))
    }
}

    // MARK: - Franchise strip (Idea 21)

    /// The collection strip at the END of the detail: the
    /// house Rail over the matched parts' PosterCards. A
    /// tap opens that part's Movie through the navigator —
    /// the detail's own route is cleared and re-minted, the
    /// same fresh-detail build a rail tap gets (this detail's
    /// @State was built from ITS route and cannot retarget
    /// in place).
    @ViewBuilder
    private var franchiseStrip: some View {
        if !franchiseMovies.isEmpty {
            Rail(title: "🎞️ Thuộc bộ phim: \(franchiseName)") {
                ForEach(franchiseMovies) { movie in
                    Button { openFranchise(movie) } label: {
                        PosterCard(
                            title: movie.name,
                            posterURL: movie.posterURL,
                            tmdbId: movie.tmdbId,
                            tmdbType: movie.tmdbType,
                            meta: movie.cardMeta,
                            badge: Providers.badge(movie.provider),
                            form: .rail)
                    }
                    .joeCardButton()
                    .focused($focusedFranchise, equals: movie.id)
                }
            }
        }
    }

    private func openFranchise(_ movie: Movie) {
        let movieRoute = MovieRoute(
            provider: movie.provider, slug: movie.slug,
            name: movie.name, poster: movie.poster, year: movie.year)
        nav.movie = nil
        Task { @MainActor in nav.movie = movieRoute }
    }

    /// Resolve the loaded TMDBInfo's collection into
    /// PLAYABLE parts. Each part is searched by title across
    /// the providers (priority order) and accepted ONLY on a
    /// TMDB-id match — a title lookalike is not the part.
    /// Bounded: at most one search pass per part, at most 8
    /// cards. The current title's own part is EXCLUDED (the
    /// owner is already on its detail; a "Đang xem" card for
    /// it would be a dead-end duplicate). Unmatched parts
    /// are dropped silently. Fail-soft throughout.
    private func loadFranchise() async {
        franchiseName = ""
        franchiseMovies = []
        guard let info = tmdb, info.collectionId > 0 else { return }
        let parts = await TMDBClient.fetchCollection(id: info.collectionId)
        let selfKey = detail?.movie.tmdbId ?? ""
        var matched: [Movie] = []
        for part in parts {
            if Task.isCancelled { return }
            if matched.count >= 8 { break }
            let partKey = part.tmdbId
            if !selfKey.isEmpty, partKey == selfKey { continue }
            if matched.contains(where: { $0.tmdbId == partKey }) { continue }
            for code in Providers.priority {
                guard let results = try? await Providers.search(
                    code, keyword: part.title)
                else { continue }
                if let hit = results.first(where: {
                    $0.tmdbId == partKey && !$0.slug.isEmpty
                        && ($0.tmdbType.isEmpty || $0.tmdbType == "movie")
                }) {
                    matched.append(hit)
                    break
                }
            }
        }
        guard !Task.isCancelled else { return }
        franchiseName = info.collectionName
        franchiseMovies = matched
    }

    // MARK: - Play now

    /// The episode the big play button starts: the route's
    /// preselected episode, else the stored Continue Watching
    /// episode for this title, else the first playable episode.
    private func startEpisode(_ d: Detail) -> String? {
        let all = d.servers.flatMap { $0.episodes }
        func exists(_ name: String) -> Bool {
            all.contains { $0.name == name
                && Providers.isPlayable(code: provider, episode: $0) }
        }
        if !route.preselectEp.isEmpty, exists(route.preselectEp) {
            return route.preselectEp
        }
        if let e = watch.progressForTitle(slug: slug, provider: provider,
                                          title: d.movie.name,
                                          year: d.movie.year), exists(e.ep) {
            return e.ep
        }
        return all.first { Providers.isPlayable(code: provider, episode: $0) }?.name
    }

    private func playButton(_ d: Detail) -> some View {
        let isResume: Bool = !route.preselectEp.isEmpty
            || watch.progressForTitle(slug: slug, provider: provider,
                                      title: d.movie.name,
                                      year: d.movie.year) != nil
        let playDisabled: Bool = (ytActiveMode != nil
                   ? (ytMatch?.eps.isEmpty ?? true)
                   : startEpisode(d) == nil) || switching
        return Button {
            playButtonTapped(d)
        } label: {
            JoePrimaryLabel(title: isResume ? "Xem tiếp" : "Xem ngay",
                            systemImage: "play.fill")
        }
        .joeCardButton()
        .focused($focusedPlay)
        .disabled(playDisabled)
        // v2.0.8 (Phase 1): no hand-written exits — the
        // header sits in its own .focusSection() (see the
        // themed compositions) and the focus engine moves
        // geometrically from here.
    }

    /// The Play button's press, extracted from its
    /// action closure (2.0.48 sweep): the original
    /// if/else-if verbatim.
    private func playButtonTapped(_ d: Detail) {
        if ytActiveMode != nil, let yt = ytMatch {
            ytPlayButtonAction(d, yt: yt)
        } else if let ep = startEpisode(d) { play(d, epName: ep) }
    }

    private func favButton(_ d: Detail) -> some View {
        Button {
            favButtonAction(d)
        } label: {
            // UI-6 defect D-10: built on the shared label
            // metrics (JoeSecondaryLabel — design .btn: 29 pt
            // semibold, padding 17 vertical / 36 horizontal,
            // resting inset stroke 1.5 theme.stroke, focused
            // ring inside at ringWidth) so the favourite toggle
            // can never drift from the other action labels
            // again. The ring reads this button's own
            // focusedFav binding — the same focus value the
            // environment ring would see.
            Text(isFav ? "♥ Đã thích" : "♡ Yêu thích")
                .font(.system(size: 29, weight: .semibold))
                .foregroundStyle(isFav ? JoeTheme.accentRed : theme.text)
                .padding(.horizontal, 36)
                .padding(.vertical, 17)
                .background(Capsule().fill(theme.surface2))
                .overlay(Capsule().strokeBorder(
                    focusedFav ? theme.focus : theme.stroke,
                    lineWidth: focusedFav ? theme.ringWidth : 1.5))
        }
        .joeCardButton()
        // v2.0.5 (N1, pair h): the favourite button's binding
        // (see focusedFav). v2.0.8 (Phase 1): its exits are
        // the focus engine's geometric moves — no
        // hand-written routing.
        .focused($focusedFav)
    }

    /// favButton's press, extracted from its
    /// Button action closure (2.0.48 sweep): the
    /// original body verbatim.
    private func favButtonAction(_ d: Detail) {
        // D1 (2.0.48): a Select press with focus
        // already resting here changes no hooked
        // state — the press itself kills the preview.
        preview.kill(reason: "input")
        var e = WatchStore.Entry()
        e.kind = Providers.kindOf(provider)
        e.key = favKey
        e.title = d.movie.name
        e.poster = d.movie.poster
        e.year = d.movie.year
        e.slug = slug
        e.source = provider
        // v2.0.38 (Sony 2.3.41 parity, item 3): the
        // stable-id stamps — see ultraFavCircle.
        e.imdbId = d.movie.imdbId
        e.tmdbId = d.movie.tmdbId
        if e.tmdbId.isEmpty, let ctx = route.tvb {
            e.tmdbId = "\(ctx.tmdbId)"
        }
        if e.imdbId.isEmpty, let ctx = route.tvb {
            e.imdbId = ctx.imdbId
        }
        e.ts = Int64(Date().timeIntervalSince1970 * 1000)
        watch.toggleFavorite(e)
    }

    /// Idea 7a: is this detail a SERIES? Counted over the
    /// SAME episode lists the episode UI renders
    /// (serverGroups over d.servers), playable-only — the
    /// test startEpisode applies to the same lists. More
    /// than one playable episode across all servers =
    /// series; a "Full" / single-episode movie is not, and
    /// shows no follow toggle at all.
    private func isSeries(_ d: Detail) -> Bool {
        d.servers.flatMap { $0.episodes }
            .filter { Providers.isPlayable(code: provider, episode: $0) }
            .count > 1
    }

    private func isFollowing(_ d: Detail) -> Bool {
        followStore.isFollowing(provider: provider, slug: d.movie.slug)
    }

    /// Idea 7a: the "Theo dõi" (follow) toggle — SERIES
    /// titles only (see isSeries), standing beside the
    /// favourite control in every detail anatomy. Built
    /// EXACTLY as favButton is built (the same Text label
    /// construction: 29 pt semibold, 36/17 padding,
    /// surface2 capsule, the label's stroke reading this
    /// button's own focus binding, .joeCardButton()) — no
    /// new visual language. The selected-state treatment
    /// matches the favourite button's: the accent-red
    /// foreground while following, theme.text otherwise.
    /// Tapping toggles through FollowStore.shared; the
    /// current episode count is parsed from the detail
    /// movie's episodeCurrent string by the store's own
    /// parser.
    @ViewBuilder
    private func followButton(_ d: Detail) -> some View {
        if isSeries(d) {
            Button {
                followButtonAction(d)
            } label: {
                Text(isFollowing(d) ? "Đang theo dõi" : "Theo dõi")
                    .font(.system(size: 29, weight: .semibold))
                    .foregroundStyle(isFollowing(d)
                                     ? JoeTheme.accentRed : theme.text)
                    .padding(.horizontal, 36)
                    .padding(.vertical, 17)
                    .background(Capsule().fill(theme.surface2))
                    .overlay(Capsule().strokeBorder(
                        focusedFollow ? theme.focus : theme.stroke,
                        lineWidth: focusedFollow ? theme.ringWidth : 1.5))
            }
            .joeCardButton()
            .focused($focusedFollow)
        }
    }

    /// followButton's press, extracted from its
    /// Button action closure (2.0.48 sweep): the
    /// original body verbatim.
    private func followButtonAction(_ d: Detail) {
        // D1 (2.0.48): a Select press with focus
        // already resting here changes no hooked
        // state — the press itself kills the
        // preview.
        preview.kill(reason: "input")
        _ = FollowStore.shared.toggle(
            provider: provider,
            slug: d.movie.slug,
            title: d.movie.name,
            poster: d.movie.poster,
            currentEpisodes: FollowStore.episodeCount(
                from: d.movie.episodeCurrent))
    }

    // MARK: - Nguồn phát chips (design D)

    /// Design D's Nguồn phát row (owner source-priority
    /// policy): Tự động first, the current source (tap pins),
    /// then the alternative sources (tap switches + pins) —
    /// and, since v2.0.5, the Torrent chip: D's private
    /// builder used to end at the alternatives, so the chip
    /// was missing here for EVERY title (the owner's
    /// yellow-theme photo). Membership comes from the shared
    /// model now (sourceEntries/sourceChip); D keeps only
    /// its inline "Nguồn phát:" label and the centred
    /// composition around the row.
    private var altChips: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                if switching {
                    ProgressView().tint(theme.text)
                }
                Text("Nguồn phát:")
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(theme.meta)
                ForEach(sourceEntries) { entry in
                    sourceChip(entry)
                }
            }
            torrentUnresolvedNote
        }
        // v2.0.5 (N1, pair h): D's source block — the same
        // declared region as A's (see sourceChips).
        .focusSection()
    }

    // MARK: - Servers & episodes

    /// Episode block with an optional block heading (design
    /// A: "Chọn tập" at 30 — UI-6 defect D-11; design D: no
    /// heading, the render's call). Design F uses
    /// serverGroups directly beside its inline label.
    private func servers(_ d: Detail, heading: String? = nil,
                         headingSize: CGFloat = 34,
                         centered: Bool = false) -> some View {
        // Design-A: heading→groups gap = rail-title
        // margin-bottom 18 (with no heading the stack has a
        // single child and the spacing never paints).
        // Design-D centres the block (its detail column is
        // centred end to end); A and F keep the leading form.
        VStack(alignment: centered ? .center : .leading, spacing: 18) {
            if let heading {
                Text(heading)
                    .font(theme.id == .privateCinema
                          ? JoePCType.outfit(headingSize, weight: .bold)
                          : .system(size: headingSize, weight: .bold))
                    .foregroundStyle(theme.text)
            }
            serverGroups(d, centered: centered)
        }
    }

    /// The per-server episode groups. UI-6 defect D-4: the
    /// chips are content-sized CAPSULES in a wrapping flow row
    /// (the renders' shape, and the owner's photo of the
    /// shipped design) — no stretched grid cells.
    private func serverGroups(_ d: Detail, centered: Bool = false) -> some View {
        VStack(alignment: centered ? .center : .leading, spacing: 34) {
            // v2.0.33 (item 2a): the no-source notice — when
            // the TVB probe found no playable source for
            // this title, say so at the TOP of the episode
            // block (every theme feeds its episode block
            // through here: A/Ultra/D via servers(), F
            // directly), in the themes' existing type
            // styles. TVB-gated: non-TVB pages and TVB
            // pages with a playable source render nothing
            // here, exactly as before.
            // v2.0.33 (item 2b): the notice container is
            // FOCUSABLE — with no playable source the
            // servers list is empty, so this .focusSection()
            // otherwise has zero focusable children and
            // focus-following scroll dies below the source
            // row; a focusable landing inside the section
            // lets Down from the source row reach it and
            // the ScrollView scroll the section into view.
            // A plain focusable text shows no chrome, so
            // this changes no pixels.
            if route.tvb != nil && tvbNoPlayableSource {
                VStack(alignment: centered ? .center : .leading, spacing: 8) {
                    Text("Không có nguồn phát cho phim này.")
                        .font(theme.id == .privateCinema
                              ? JoePCType.outfit(25, weight: .semibold)
                              : .system(size: 25, weight: .semibold))
                        .foregroundStyle(theme.text)
                        .multilineTextAlignment(centered ? .center : .leading)
                    Text("Không nguồn TVB nào phát được phim này — anh thử lại sau, hoặc chọn phim khác.")
                        .font(theme.id == .privateCinema
                              ? JoePCType.outfit(25) : .system(size: 25))
                        .foregroundStyle(theme.meta)
                        .multilineTextAlignment(centered ? .center : .leading)
                }
                .focusable(true)
            }
            // TVB YouTube feature: with a match in force, the
            // episode block is ONE shared grid (the owner's
            // ruling) — the union group below replaces the
            // per-server groups; without a match (or with a
            // chain source pinned) the groups render exactly
            // as before.
            if let yt = ytMatch, ytActiveMode != nil {
                ytUnifiedGroup(d, yt: yt, centered: centered)
            } else {
            ForEach(Array(d.servers.enumerated()), id: \.offset) { serverIndex, server in
                VStack(alignment: centered ? .center : .leading, spacing: 14) {
                    if d.servers.count > 1 || !server.name.isEmpty {
                        Text(server.name)
                            .font(theme.id == .privateCinema
                                  ? JoePCType.outfit(25, weight: .semibold)
                                  : .system(size: 25, weight: .semibold))
                            .foregroundStyle(theme.meta)
                    }
                    // Design chip-row gap: 14 (design-A detail
                    // episode chips; the flow layout's spacing is
                    // both the horizontal and vertical gap).
                    // Design-D centres each row.
                    FlowLayout(spacing: 14, centered: centered) {
                        ForEach(Array(server.episodes.enumerated()), id: \.offset) { epIndex, ep in
                            epChip(d, ep: ep, serverIndex: serverIndex,
                                   episodeIndex: epIndex)
                        }
                    }
                }
            }
            }
        }
        // v2.0.5 (N1, pair h): the episode block is a
        // declared focus region in every anatomy (it is the
        // Dark Waters "link list" the owner's video starts
        // from).
        .focusSection()
    }

    private func epChip(_ d: Detail, ep: Episode, serverIndex: Int,
                        episodeIndex: Int) -> some View {
        let focusKey: String = "\(serverIndex)|\(ep.name)"
        let playable: Bool = Providers.isPlayable(code: provider, episode: ep)
        let storedEp = watch.progressForTitle(slug: slug, provider: provider,
                                              title: d.movie.name,
                                              year: d.movie.year)?.ep
        let preselectTarget: String? = !route.preselectEp.isEmpty
            ? route.preselectEp : storedEp
        let preselected: Bool = ep.name == preselectTarget
        // F4: focus identity is "<serverIndex>|<episodeName>" —
        // every server has its own "Tập 1", and keying by name
        // alone lit up one chip per server at once (C-3).
        let focused: Bool = focusedEp == focusKey
        // Fault 11 fix round: under Private Cinema the
        // inset stroke rests (the focus moves to the
        // outset outline below); every other theme keeps
        // the expression value-for-value.
        let chipStroke: Color = focused && theme.id != .privateCinema
            ? (theme.id == .posterWall && preselected
               ? Color.white : theme.focus)
            : (preselected && !focused ? Color.clear : theme.stroke)
        let chipLineWidth: CGFloat = focused && theme.id != .privateCinema
            ? theme.ringWidth : 1.5
        let chipForeground: Color = !playable
            ? theme.text.opacity(0.35)
            : (preselected && !focused ? theme.onAccent : theme.text)
        return Button {
            play(d, epName: ep.name)
        } label: {
            // UI-6 defect D-4: the renders' capsule chip —
            // content-sized, 24 pt, 22/11 padding; the
            // preselected episode is a SOLID accent fill with
            // onAccent text (not a 30% tint); focus is the
            // theme ring value inside the always-installed
            // capsule stroke.
            Text(ep.name)
                .font(theme.id == .privateCinema
                      ? JoePCType.outfit(24, weight: preselected ? .semibold : .medium)
                      : .system(size: 24, weight: preselected ? .semibold : .medium))
                .foregroundStyle(chipForeground)
                .lineLimit(1)
                .padding(.horizontal, 22)
                .padding(.vertical, 11)
                // claude/opt-2 (FL-422): the preselected fill
                // only while NOT focused; focus is ring-only.
                .background(Capsule()
                    .fill(preselected && !focused ? theme.accent : theme.surface2))
                // v2.0.9 (owner defect, theme D only): the same
                // colour collision as JoeChipLabel — in D the
                // preselected episode's fill (accent #FFD60A)
                // and the focus ring (focus #FFD60A) are one
                // colour, so focus on the preselected chip was
                // invisible. The owner's ruling applies here
                // too: preselected + focused in D wears the
                // opaque-white (trắng đục) frame; every other
                // state and theme keeps the expression below
                // unchanged.
                .overlay(Capsule()
                    .strokeBorder(chipStroke, lineWidth: chipLineWidth))
                // Fault 11 fix round: the Private Cinema
                // chip focus — the ivory outset outline
                // (the JoeChipRing family), driven by this
                // chip's own focus value; forced off on
                // every other theme.
                .overlay(JoeOutsetRing(
                    shape: Capsule(), color: JoeCinemaFocus.ivory,
                    lineWidth: 2, offset: 4,
                    forced: theme.id == .privateCinema ? focused : false))
        }
        .joeCardButton()
        .focused($focusedEp, equals: focusKey)
        .disabled(!playable || switching)
        // v2.0.8 (Phase 1): geometric movement only — the
        // episode block is a .focusSection() and the engine
        // crosses it (and leaves it in every direction)
        // without hand-written routing.
    }

    // MARK: - TVB YouTube shared grid

    /// The 2.0.41 gate notices that used to head this
    /// grid (a Super VIP verdict shown after a blocked
    /// press; a "sign into the web door" line keyed on
    /// the WEB session) are REMOVED with the gates
    /// themselves (design §4.1): entitlement is read
    /// from the live /player signal by the router, whose
    /// surfaces (device-code activation, the honest
    /// above-tier slate) carry both messages now. A
    /// label-driven notice here would assert an
    /// entitlement this screen has not measured.

    /// The ONE shared episode grid (owner ruling,
    /// 2026-11-19): the union of both sources in the chain
    /// groups' own grammar (a named group + flow chips) —
    /// episode i plays YouTube when YouTube has it and the
    /// chain when it does not; episodes only YouTube has
    /// play YouTube. No episode is stranded on either side.
    private func ytUnifiedGroup(_ d: Detail, yt: JoeYtSeries,
                                centered: Bool) -> some View {
        let names = chainEpisodeNames(d)
        let count = max(names.count, yt.eps.count)
        return VStack(alignment: centered ? .center : .leading, spacing: 14) {
            Text("YouTube · \(yt.tierLabel)")
                .font(theme.id == .privateCinema
                      ? JoePCType.outfit(25, weight: .semibold)
                      : .system(size: 25, weight: .semibold))
                .foregroundStyle(theme.meta)
            FlowLayout(spacing: 14, centered: centered) {
                ForEach(0..<count, id: \.self) { i in
                    ytEpChip(d, yt: yt, names: names, index: i)
                }
            }
        }
    }

    /// One shared-grid chip — epChip's capsule construction
    /// (same type, paddings, preselected fill and focus
    /// ring, incl. the design-D white-frame rule), with the
    /// per-episode source resolution as its action.
    private func ytEpChip(_ d: Detail, yt: JoeYtSeries,
                          names: [String], index: Int) -> some View {
        let storedEp = watch.progressForTitle(slug: slug, provider: provider,
                                              title: d.movie.name,
                                              year: d.movie.year)?.ep
        let preselectTarget: String? = !route.preselectEp.isEmpty
            ? route.preselectEp : storedEp
        let preselected: Bool = index < names.count
            && names[index] == preselectTarget
        let focused: Bool = ytEpFocus == index
        let label: String = index < names.count
            ? names[index]
            : (yt.epTitle(at: index).isEmpty
               ? "Tập \(index + 1)" : yt.epTitle(at: index))
        // Fault 11 fix round: as epChip — under Private
        // Cinema the inset stroke rests and the outset
        // outline below carries the focus.
        let chipStroke: Color = focused && theme.id != .privateCinema
            ? (theme.id == .posterWall && preselected
               ? Color.white : theme.focus)
            : (preselected && !focused ? Color.clear : theme.stroke)
        let chipLineWidth: CGFloat = focused && theme.id != .privateCinema
            ? theme.ringWidth : 1.5
        return Button {
            ytPlayEpisode(d, yt: yt, names: names, index: index)
        } label: {
            Text(label)
                .font(theme.id == .privateCinema
                      ? JoePCType.outfit(24, weight: preselected ? .semibold : .medium)
                      : .system(size: 24, weight: preselected ? .semibold : .medium))
                .foregroundStyle(preselected && !focused ? theme.onAccent : theme.text)
                .lineLimit(1)
                .padding(.horizontal, 22)
                .padding(.vertical, 11)
                // claude/opt-2 (FL-422): the preselected fill
                // only while NOT focused; focus is ring-only.
                .background(Capsule()
                    .fill(preselected && !focused ? theme.accent : theme.surface2))
                .overlay(Capsule()
                    .strokeBorder(chipStroke, lineWidth: chipLineWidth))
                // Fault 11 fix round: the Private Cinema
                // chip focus (ivory outset outline), as
                // epChip.
                .overlay(JoeOutsetRing(
                    shape: Capsule(), color: JoeCinemaFocus.ivory,
                    lineWidth: 2, offset: 4,
                    forced: theme.id == .privateCinema ? focused : false))
        }
        .joeCardButton()
        .focused($ytEpFocus, equals: index)
        .disabled(switching)
    }

    /// The shared grid's per-episode resolution (identical
    /// for Tự động and YouTube modes — the mode governs only
    /// the player's failure policy, never the grid's
    /// coverage):
    /// - an index YouTube lacks → the chain plays it, via
    ///   the chain's own play() exactly;
    /// - any index YouTube has → the YouTube ROUTER,
    ///   whatever the tier (design §4.1 — the single-route
    ///   ruling superseded the 2.0.41 label gates that used
    ///   to sit here): the router reads the LIVE signal —
    ///   no identity → the device-code surface; a tier
    ///   above the account → the honest slate from
    ///   /player's own UNPLAYABLE reason; playable → the
    ///   native player. The request carries the chain
    ///   hand-back for Auto (total YouTube failure returns
    ///   THIS episode to this detail, which plays it via
    ///   the chain — the "always ready" standard).
    private func ytPlayEpisode(_ d: Detail, yt: JoeYtSeries,
                               names: [String], index: Int) {
        if index >= yt.eps.count {
            play(d, epName: names[index])
            return
        }
        let mode = ytActiveMode ?? .auto
        nav.ytPlayer = JoeYtPlayRequest(
            pid: yt.pid,
            videoIds: yt.eps,
            startIndex: index,
            mode: mode,
            tier: yt.tier,
            seriesTitle: d.movie.name,
            tmdbId: yt.tmdbId,
            chainRoute: nil,
            chainPlay: (mode == .auto && index < names.count)
                ? JoeYtChainPlay(route: route, epName: names[index],
                                 nonce: UUID())
                : nil)
    }

    /// The big Play button in a YouTube mode: the start
    /// episode (preselection / progress / first) resolved
    /// through the shared grid's own rule.
    private func ytPlayButtonAction(_ d: Detail, yt: JoeYtSeries) {
        let names = chainEpisodeNames(d)
        var index = 0
        if let start = startEpisode(d),
           let i = names.firstIndex(of: start) {
            index = i
        }
        ytPlayEpisode(d, yt: yt, names: names, index: index)
    }

    // MARK: - Loading + playing

    /// v2.0.29 (cluster A, items 1b + 4): write the detail's
    /// initial focus ONCE, at its first paint. The page's
    /// only other landing declaration is the appearance-time
    /// .defaultFocus($focusedPlay, true) on detailScroll —
    /// but the play button does not exist while the
    /// placeholder stands, and when the loaded detail has NO
    /// playable episode (a movie whose provider detail
    /// carries no playable server/episode — TpClient and
    /// KkClient both append a server only when its episodes
    /// are non-empty, so such a detail's servers list is
    /// empty and startEpisode is nil) the play button is
    /// DISABLED, i.e. not focusable at all. The declared
    /// landing then resolves to nothing the owner can see
    /// or move: the page sits on its header block with no
    /// focus anywhere, no remote press can move, and the
    /// ScrollView — which scrolls by following focus — can
    /// never scroll (the owner's poster-wall photo: a movie
    /// detail showing poster/title/meta/genres/synopsis and
    /// nothing reachable below; series, whose play button is
    /// enabled, land and scroll normally on the same code).
    /// Writing the landing at first paint — the same
    /// mechanism the error branch already uses
    /// (focusedRetry = true) — makes it deterministic:
    /// Xem ngay when it can take focus, Yêu thích when it
    /// cannot (the favourite button is never disabled, so
    /// the page always has a live focus and can scroll to
    /// its source chips, cast and episode blocks).
    private func landInitialFocus(on d: Detail) {
        guard !didLandInitialFocus else { return }
        didLandInitialFocus = true
        if startEpisode(d) != nil {
            focusedPlay = true
        } else {
            focusedFav = true
        }
    }

    private func load() async {
        // First open: the placeholder header carries the page.
        // Provider switch: the CURRENT detail stays on screen
        // until the new one lands — v1.1 blanked the page back
        // to a spinner, which read as "another sources page".
        let hadDetail = detail != nil
        let attemptedProvider = provider
        let attemptedSlug = slug
        if !hadDetail { loadFailed = false }
        switching = hadDetail
        // v2.0.8 (Phase 3g): warm the loopback proxy as the
        // detail opens — a play tap from here is predictable,
        // so the listener's port is ready before it. This is
        // the SAME entry point the tap path uses (playlistURL
        // calls start()); start() is idempotent. App launch
        // stays unwarmed (the standing decision in JoeTVApp).
        JoeProxy.shared.start()
        if hadDetail {
            // Provider switch: the pre-v2.0.8 behaviour,
            // exactly — no cache read, the current detail
            // stays on screen through the fetch, the
            // alternatives/identity chain is awaited inline,
            // and the C-9 revert below is unchanged in
            // behaviour. (v2.0.8 adds only the TP probe merge
            // and the PerfLog paint marks — diagnostics, not
            // behaviour.)
            do {
                // v2.0.33 (item 3): consume a kept probe
                // detail instead of refetching — when the
                // I1 probe already fetched and
                // identity-gated this exact holder (same
                // provider AND same slug), its payload IS
                // the detail to paint, so the switch lands
                // instantly with the winning source's
                // episodes already expanded. The kept
                // detail was identity-gated by the probe
                // and load()'s own tvbGate still runs on it
                // below; consuming (removing) it means a
                // later manual switch back refetches fresh,
                // and the play path re-resolves stream URLs
                // at tap time regardless (the standing
                // rule on this file). When no kept detail
                // exists — every non-TVB switch, and any
                // TVB holder the probe did not keep — the
                // fetch below is exactly the pre-v2.0.33
                // behaviour, and everything downstream
                // (cache write, tvbGate, paint,
                // alternatives, identity) runs identically
                // for both sources of `d`.
                let d: Detail
                if route.tvb != nil,
                   let kept = tvbKeptDetails[attemptedProvider],
                   kept.slug == attemptedSlug {
                    tvbKeptDetails[attemptedProvider] = nil
                    d = kept.detail
                } else {
                    d = try await Providers.detail(provider, slug: slug)
                }
                JoeDetailCache.write(d, provider: attemptedProvider,
                                     slug: attemptedSlug)
                // v2.0.31 (L7): the TVB identity gate — a
                // payload that is not the snapshot's film
                // never paints (see tvbGate). Non-TVB
                // routes pass straight through.
                guard tvbGate(d, attemptedProvider: attemptedProvider) else {
                    switching = false
                    return
                }
                detail = d
                // v2.0.33 (item 2a): a painted detail with
                // a playable start episode clears the
                // no-source notice (see tvbNoPlayableSource).
                if route.tvb != nil, startEpisode(d) != nil {
                    tvbNoPlayableSource = false
                }
                PerfLog.mark("detail.networkPaint")
                switching = false
                lastGoodProvider = provider
                lastGoodSlug = slug
                launchTPProbe(painted: d,
                              paintedProvider: attemptedProvider,
                              paintedSlug: attemptedSlug)
                // v2.0.31 (L7): a TVB page's alternatives
                // are the snapshot's own holders, never a
                // name search (see tvbOrderedAlternatives);
                // every other route keeps findAlternatives.
                if route.tvb != nil {
                    alternatives = await tvbOrderedAlternatives(playable: nil)
                } else {
                    alternatives = await Providers.findAlternatives(
                        fromCode: provider, name: d.movie.name,
                        origin: d.movie.originName, year: d.movie.year,
                        tmdbId: d.movie.tmdbId)
                }
                PerfLog.mark("detail.alternativesPaint")
                // v2.0.5 (D3): the detail-time identity ladder
                // runs alongside the alternatives lookup and lands
                // in view state, so the source row re-renders with
                // the Torrent entry's state the moment it resolves.
                // v2.0.31 (L7): for a TVB session the ladder's
                // answer is pinned to the snapshot's ids.
                filmIdentity = tvbPinnedIdentity(
                    await Providers.resolveIdentity(
                        movie: d.movie, fromCode: provider,
                        alternatives: alternatives))
                PerfLog.mark("detail.identityPaint")
            } catch {
                switching = false
                if attemptedProvider != lastGoodProvider
                    || attemptedSlug != lastGoodSlug {
                    // C-9: the switch failed — REVERT to the provider
                    // whose detail is actually on screen and say so.
                    // (v1.8 left provider/slug pointing at the new
                    // source over the old source's data: a silent
                    // hybrid page whose favourite key and playability
                    // checks belonged to a different film.) The
                    // revert re-fires this task for the good provider;
                    // its success path leaves switchNotice standing.
                    provider = lastGoodProvider
                    slug = lastGoodSlug
                    switchNotice = "Không tải được nguồn \(Providers.displayName(attemptedProvider)) — vẫn dùng nguồn \(Providers.displayName(lastGoodProvider))"
                }
            }
            return
        }
        // First open (v2.0.8, Phase 2): the cache read and the
        // network fetch RACE. v2.0.1 DetailCache (Android FIX2
        // parity): a cached payload paints the full detail as
        // soon as the read lands — now via readAsync, off the
        // view's synchronous path, and only if the fetch has
        // not painted first. The fetch then acts as a refresh:
        // it writes the cache as always and repaints only when
        // the payload actually changed (fingerprint); a failed
        // fetch never errors over a cache-filled screen.
        // The race bookkeeping lives in a reference box
        // (DetailLoadRace): both racers run on the main actor,
        // so each paint block executes atomically between
        // awaits and the flags can never tear.
        let race = DetailLoadRace()
        let cacheTask = Task {
            if let cached = await JoeDetailCache.readAsync(
                provider: attemptedProvider, slug: attemptedSlug),
               !race.networkPainted {
                // v2.0.31 (L7): the TVB identity gate covers
                // the cache paint too — a cached payload for
                // a name-fallback slug can be a different
                // film, and the owner's complaint is exactly
                // that the wrong film OPENS.
                guard tvbGate(cached, attemptedProvider: attemptedProvider)
                else { return }
                detail = cached
                // v2.0.33 (item 2a): a painted detail with
                // a playable start episode clears the
                // no-source notice (see tvbNoPlayableSource).
                if route.tvb != nil, startEpisode(cached) != nil {
                    tvbNoPlayableSource = false
                }
                landInitialFocus(on: cached)
                race.cachedPaint = cached
                PerfLog.mark("detail.cachePaint")
                launchTPProbe(painted: cached,
                              paintedProvider: attemptedProvider,
                              paintedSlug: attemptedSlug)
            }
        }
        do {
            let d = try await Providers.detail(provider, slug: slug)
            JoeDetailCache.write(d, provider: attemptedProvider,
                                 slug: attemptedSlug)
            race.networkPainted = true
            // v2.0.31 (L7): the TVB identity gate (see
            // tvbGate). A strike here advances provider/slug
            // and the .task(id:) re-fire loads the next
            // holder; nothing of this payload paints.
            guard tvbGate(d, attemptedProvider: attemptedProvider) else {
                switching = false
                return
            }
            if let cachedPaint = race.cachedPaint {
                if JoeDetailCache.fingerprint(d)
                    != JoeDetailCache.fingerprint(cachedPaint) {
                    detail = d
                    // v2.0.33 (item 2a): a painted detail
                    // with a playable start episode clears
                    // the no-source notice (see
                    // tvbNoPlayableSource).
                    if route.tvb != nil, startEpisode(d) != nil {
                        tvbNoPlayableSource = false
                    }
                    landInitialFocus(on: d)
                    PerfLog.mark("detail.networkPaint")
                    launchTPProbe(painted: d,
                                  paintedProvider: attemptedProvider,
                                  paintedSlug: attemptedSlug)
                }
                // Same payload: the cached render stands. The
                // fresh copy's stream URLs are NOT needed —
                // the play path re-resolves them fresh at tap
                // time (makeDirector's ladder resolves stream
                // URLs through the memoised resolver), so
                // nothing stale can reach the player from
                // either copy.
            } else {
                detail = d
                // v2.0.33 (item 2a): a painted detail with
                // a playable start episode clears the
                // no-source notice (see tvbNoPlayableSource).
                if route.tvb != nil, startEpisode(d) != nil {
                    tvbNoPlayableSource = false
                }
                landInitialFocus(on: d)
                PerfLog.mark("detail.networkPaint")
                launchTPProbe(painted: d,
                              paintedProvider: attemptedProvider,
                              paintedSlug: attemptedSlug)
            }
            switching = false
            lastGoodProvider = provider
            lastGoodSlug = slug
            // Progressive alternatives + identity (Phase 2):
            // launched, not awaited — the source row and the
            // Torrent entry's state fill in as they land, and
            // neither blocks this return, the paint above, or
            // the switching transition.
            launchAlternativesAndIdentity(movie: d.movie,
                                          fromCode: provider,
                                          forSlug: slug)
        } catch {
            switching = false
            // The fetch failed: if the cache read is still in
            // flight, wait for its verdict before deciding —
            // its paint (if any) runs inside cacheTask before
            // the value lands here.
            if race.cachedPaint == nil {
                _ = await cacheTask.value
            }
            if let cachedPaint = race.cachedPaint {
                // The cache-filled screen stays — no error
                // surface, no revert (the painted detail IS
                // the attempted provider's own). Alternatives
                // and identity still run off the cached
                // payload: the source row must not wait on a
                // detail fetch that already failed once.
                launchAlternativesAndIdentity(
                    movie: cachedPaint.movie,
                    fromCode: attemptedProvider,
                    forSlug: attemptedSlug)
            } else if route.tvb != nil,
                      attemptedProvider == provider,
                      attemptedSlug == slug,
                      tvbStrikeAndAdvance(reason: "không tải được") {
                // v2.0.31 (I1/L7): a TVB holder that fails
                // to LOAD at all is struck like a
                // contradicting one — the page walks the
                // snapshot's holders before it gives up,
                // instead of dying on the first source.
                // The provider/slug change re-fires this
                // task for the next holder. Exhaustion
                // (tvbStrikeAndAdvance returning false) has
                // already set the no-exact-source state and
                // falls through to the plain error below.
                // The attempted==current guard keeps a
                // CANCELLED fetch (the owner switched
                // provider mid-flight) from striking the
                // provider he just chose.
            } else {
                loadFailed = true
                focusedRetry = true
            }
        }
    }

    /// The TP CacheVideo probe merge (v2.0.8, Phase 2):
    /// Providers.detail for TP now returns WITHOUT the
    /// CacheVideo server (the probe is TpClient
    /// .probeCacheVideoServer, a separate call), so after any
    /// successful paint of a TP detail — fresh, cache-painted
    /// or failure-path cache paint — the probe runs as its
    /// own task and its server is appended to the CURRENT
    /// detail when it lands, provided the view still shows
    /// the painted provider/slug and no server of that name
    /// is present yet (a second paint's probe therefore
    /// cannot duplicate the row).
    private func launchTPProbe(painted: Detail, paintedProvider: String,
                               paintedSlug: String) {
        guard paintedProvider == Providers.TP else { return }
        Task {
            guard let server = await TpClient.probeCacheVideoServer(
                detail: painted, slug: paintedSlug) else { return }
            guard provider == paintedProvider, slug == paintedSlug,
                  let current = detail,
                  !current.servers.contains(where: { $0.name == server.name })
            else { return }
            var updated = current
            updated.servers.append(server)
            detail = updated
        }
    }

    /// Progressive alternatives + identity (v2.0.8, Phase 2):
    /// findAlternatives assigns `alternatives` the moment it
    /// lands; resolveIdentity runs after it (it consumes the
    /// alternatives — a true data dependency) and assigns
    /// `filmIdentity` when it lands. The task is detached
    /// from load()'s return; the provider/slug guards keep a
    /// late landing from a previous film (or a switched
    /// provider) from overwriting the current screen's state.
    private func launchAlternativesAndIdentity(movie: Movie,
                                               fromCode: String,
                                               forSlug: String) {
        Task {
            // v2.0.31 (L7 + I1): a TVB session's alternatives
            // are the snapshot's own holders (never a name
            // search), ordered by whether their ladders
            // actually resolve (I1 — see tvbPlayableHolders);
            // when the CURRENT holder does not resolve and
            // another does, the page auto-picks the playable
            // holder — Tự động mode only (a pinned source is
            // never overridden), never once playback has
            // started, and at most once per page.
            if route.tvb != nil {
                // v2.0.33 (item 3): the probe now returns an
                // outcome — the playable set (used exactly
                // as before) PLUS the kept Details of the
                // playable holders it fetched, stored in
                // tvbKeptDetails so the auto-pick switch
                // below (and a later manual switch to a
                // probed holder) paints from the probe's
                // payload instead of refetching.
                // v2.0.33 (item 2a): an empty playable set
                // is the no-source verdict — the episode
                // section's notice keys off it (see
                // serverGroups); a non-empty set clears it.
                let outcome = await tvbPlayableHolders()
                guard provider == fromCode, slug == forSlug else { return }
                tvbKeptDetails = outcome.kept
                tvbNoPlayableSource = outcome.playable.isEmpty
                alternatives = await tvbOrderedAlternatives(playable: outcome.playable)
                PerfLog.mark("detail.alternativesPaint")
                if !outcome.playable.contains(provider), autoSource,
                   playerHolder == nil, !tvbAutoPickDone,
                   let pick = alternatives.first(where: {
                       outcome.playable.contains($0.code)
                   }) {
                    tvbAutoPickDone = true
                    switchNotice = "Nguồn \(Providers.displayName(provider)) không phát được tập này — đã tự chọn nguồn \(Providers.displayName(pick.code))"
                    provider = pick.code
                    slug = pick.slug
                    return
                }
                let identity = await Providers.resolveIdentity(
                    movie: movie, fromCode: fromCode,
                    alternatives: alternatives)
                guard provider == fromCode, slug == forSlug else { return }
                filmIdentity = tvbPinnedIdentity(identity)
                PerfLog.mark("detail.identityPaint")
                return
            }
            let alts = await Providers.findAlternatives(
                fromCode: fromCode, name: movie.name,
                origin: movie.originName, year: movie.year,
                tmdbId: movie.tmdbId)
            guard provider == fromCode, slug == forSlug else { return }
            alternatives = alts
            PerfLog.mark("detail.alternativesPaint")
            // v2.0.5 (D3): the identity ladder's result lands
            // in view state, so the source row re-renders with
            // the Torrent entry's state the moment it resolves.
            let identity = await Providers.resolveIdentity(
                movie: movie, fromCode: fromCode, alternatives: alts)
            guard provider == fromCode, slug == forSlug else { return }
            filmIdentity = identity
            PerfLog.mark("detail.identityPaint")
        }
    }

    // MARK: - v2.0.31 TVB identity + auto-pick (L7 / I1)
    //
    // Everything below serves ONLY routes carrying a TVB
    // snapshot context (route.tvb != nil); the non-TVB
    // flows never reach it (tvbGate passes straight
    // through, the alternatives builders are only called
    // behind the same condition).

    /// The identity gate every TVB paint passes through
    /// (L7): the payload must be ACCEPTED by the snapshot
    /// context for the provider it was fetched from
    /// (TVBRouteContext.accepts). A rejected payload
    /// strikes its holder and advances the page to the
    /// next one — the change re-fires load() through
    /// .task(id:) — or lands on the no-exact-source state
    /// at exhaustion. A landing for a provider the page
    /// has already left (attempted != current) is dropped
    /// silently: never painted, never struck twice — the
    /// current holder's own load is deciding.
    private func tvbGate(_ d: Detail, attemptedProvider: String) -> Bool {
        guard let ctx = route.tvb else { return true }
        guard attemptedProvider == provider else { return false }
        if ctx.accepts(d.movie, provider: attemptedProvider) { return true }
        _ = tvbStrikeAndAdvance(reason: "không khớp đúng phim này")
        return false
    }

    /// Strike the CURRENT holder and move the page to the
    /// next unstruck snapshot holder, if one remains.
    /// Returns true when it advanced. At exhaustion: with
    /// a detail on screen (a switch-path strike-out) the
    /// page reverts to the last-good holder — the C-9
    /// shape — and says so; with nothing on screen (a
    /// first-open strike-out) it sets the no-exact-source
    /// error state. Either way it returns false. The
    /// notice names the providers so the owner sees the
    /// move and its reason (§8).
    @discardableResult
    private func tvbStrikeAndAdvance(reason: String) -> Bool {
        guard let ctx = route.tvb else { return false }
        tvbStruck.insert(provider)
        if let next = ctx.holders.first(where: {
            $0.provider != provider && !tvbStruck.contains($0.provider)
        }) {
            switchNotice = "Nguồn \(Providers.displayName(provider)) \(reason) — đã chuyển sang nguồn \(Providers.displayName(next.provider))"
            provider = next.provider
            slug = next.slug
            return true
        }
        if detail != nil {
            provider = lastGoodProvider
            slug = lastGoodSlug
            switchNotice = "Không nguồn nào khớp đúng phim này — vẫn dùng nguồn \(Providers.displayName(lastGoodProvider))"
            return false
        }
        tvbNoExactSource = true
        loadFailed = true
        focusedRetry = true
        return false
    }

    /// The error slate's Retry: for a TVB page that
    /// exhausted its holders, a retry first clears the
    /// strikes and restarts from the snapshot's primary
    /// holder (a changed provider/slug re-fires load()
    /// through .task(id:) by itself; an unchanged pair
    /// runs load() here). Every other page retries
    /// exactly as before.
    private func retryLoad() async {
        guard route.tvb != nil else { await load(); return }
        tvbStruck = []
        tvbNoExactSource = false
        loadFailed = false
        if let first = route.tvb?.holders.first,
           first.provider != provider || first.slug != slug {
            provider = first.provider
            slug = first.slug
        } else {
            await load()
        }
    }

    /// For a TVB session the SNAPSHOT is the identity
    /// authority: the ladder's answer is pinned to its
    /// ids, so the Torrent entry and the substitution
    /// rung address the snapshot's series, never an
    /// identity a name search drifted to.
    private func tvbPinnedIdentity(
        _ id: Providers.FilmIdentity
    ) -> Providers.FilmIdentity {
        guard let ctx = route.tvb else { return id }
        var pinned = id
        if !ctx.imdbId.isEmpty { pinned.imdbId = ctx.imdbId }
        pinned.tmdbId = "\(ctx.tmdbId)"
        pinned.tmdbType = "tv"
        return pinned
    }

    /// The TVB alternatives list, built from the
    /// snapshot's holders only (excluding the current
    /// provider and any struck holder): with a
    /// playability verdict (the first-open evaluation),
    /// resolving holders lead in snapshot order with
    /// SourceHealth-demoted providers behind healthy
    /// ones (the standing orderedAlternatives
    /// discipline), and non-resolving holders follow in
    /// snapshot order — the manual source chips list
    /// every surviving holder either way, so manual
    /// selection is untouched. Without a verdict
    /// (provider switches) the order is plain snapshot
    /// order — the chain's TP → KK → VS priority. The
    /// Film4K leg — found by Providers.findSlug, whose
    /// Film4K acceptance is a TMDB-id detail match —
    /// closes the list when Film4K is not itself a
    /// holder: the chain's standing last rung.
    private func tvbOrderedAlternatives(
        playable: Set<String>?
    ) async -> [(code: String, slug: String)] {
        guard let ctx = route.tvb else { return [] }
        let others = ctx.holders.filter {
            $0.provider != provider && !tvbStruck.contains($0.provider)
        }
        let ordered: [TVBRouteContext.Holder]
        if let playable {
            let resolving = others.filter { playable.contains($0.provider) }
            ordered = resolving.filter {
                !SourceHealth.providerDemoted($0.provider)
            } + resolving.filter {
                SourceHealth.providerDemoted($0.provider)
            } + others.filter { !playable.contains($0.provider) }
        } else {
            ordered = others
        }
        var result = ordered.map { (code: $0.provider, slug: $0.slug) }
        if !ctx.holders.contains(where: { $0.provider == Providers.F4K }),
           !tvbStruck.contains(Providers.F4K),
           let f4kSlug = await Providers.findSlug(
               code: Providers.F4K, name: route.name, origin: "",
               year: route.year, tmdbId: "\(ctx.tmdbId)",
               requireIdVerified: true) {
            result.append((code: Providers.F4K, slug: f4kSlug))
        }
        return result
    }

    /// v2.0.33 (item 3): a holder's OWN first playable
    /// episode, in server order — dwellTarget's fallback
    /// loop, parameterised by provider code (dwellTarget
    /// itself reads the CURRENT provider and the focus
    /// state, neither of which applies to another
    /// holder's payload). Static so the probe's
    /// task-group children can call it without capturing
    /// the view. `nonisolated` is load-bearing: a member
    /// of a View type is MainActor-isolated by default in
    /// Swift 6, so without it the children cannot call
    /// this synchronous helper at all (joetv-tvos CI
    /// run #7's only error). The body is pure — parameters
    /// plus Providers' nonisolated statics only — so the
    /// opt-out is exact, not a workaround. Nil when the
    /// holder's detail carries no playable episode at all.
    private nonisolated static func tvbOwnTarget(
        code: String, detail d: Detail
    ) -> (name: String, num: Int)? {
        for server in d.servers {
            for ep in server.episodes
            where Providers.isPlayable(code: code, episode: ep) {
                return (ep.name, Providers.episodeNumber(ep.name))
            }
        }
        return nil
    }

    /// I1's playability verdict: which of the snapshot's
    /// holders can actually play this title's start
    /// episode, judged by the app's own resolution
    /// machinery — each holder's detail is fetched and
    /// Providers.ladderFor must produce at least one
    /// entry, the same ladder the player would build,
    /// with SourceHealth's server gates inside it. The
    /// CURRENT holder is judged from the detail already
    /// on screen (no second fetch). A holder whose
    /// payload fails the L7 identity verdict is never
    /// playable. All other holders are judged
    /// concurrently; a failed fetch or empty ladder
    /// simply reads unplayable (fail-soft). The
    /// resolutions land in the resolver memo, so the
    /// Play tap that follows starts warm.
    /// v2.0.33 (item 3): the probe now returns a
    /// TVBProbeOutcome, not just the playable set — the
    /// Details it fetched for playable OTHER holders are
    /// KEPT (tvbKeptDetails, via the caller) so the
    /// winning source's detail paints and expands in
    /// load()'s switch path without a refetch. Three
    /// judging changes ride along: (1) when the shared
    /// target is NIL (the current detail has no playable
    /// episode, so there is no episode to match across
    /// holders — the pre-fix probe passed epName=nil /
    /// epNum=0, Providers.ladderTarget could match
    /// nothing in a multi-episode holder, and EVERY
    /// series holder read unplayable), a holder is
    /// judged against its OWN first playable episode
    /// (tvbOwnTarget) instead; with a shared target the
    /// judging is exactly as before. (2) Film4K is now
    /// probed too — it was never a holder, so it never
    /// entered the probe at all and only reached the
    /// alternatives through tvbOrderedAlternatives'
    /// findSlug leg; the leg below resolves and judges
    /// it the same way, so a playable Film4K can be the
    /// auto-pick (and be kept) like any other source.
    /// (3) The current holder needs no kept entry — its
    /// detail is already on screen.
    private func tvbPlayableHolders() async -> TVBProbeOutcome {
        guard let ctx = route.tvb, let current = detail else { return TVBProbeOutcome() }
        let target = dwellTarget(detail: current)
        var outcome = TVBProbeOutcome()
        if let target {
            let ladder = await Providers.ladderFor(
                code: provider, detail: current,
                filmTitle: current.movie.name,
                epName: target.name, epNum: target.num)
            if !ladder.entries.isEmpty { outcome.playable.insert(provider) }
        }
        let others = ctx.holders.filter {
            $0.provider != provider && !tvbStruck.contains($0.provider)
        }
        if !others.isEmpty {
            let epName = target?.name
            let epNum = target?.num ?? 0
            let found = await withTaskGroup(
                of: (String, TVBKeptDetail)?.self
            ) { group in
                for holder in others {
                    group.addTask {
                        guard let d = try? await Providers.detail(
                            holder.provider, slug: holder.slug)
                        else { return nil }
                        guard ctx.accepts(d.movie, provider: holder.provider)
                        else { return nil }
                        // v2.0.33 (item 3): the shared
                        // target when one exists (the
                        // pre-existing behaviour); when it
                        // is nil, this holder's OWN first
                        // playable episode — no own target
                        // means no playable episode, so the
                        // holder reads unplayable.
                        let judgeName: String
                        let judgeNum: Int
                        if let epName {
                            judgeName = epName
                            judgeNum = epNum
                        } else if let own = JoeMovieDetail.tvbOwnTarget(
                            code: holder.provider, detail: d) {
                            judgeName = own.name
                            judgeNum = own.num
                        } else {
                            return nil
                        }
                        let ladder = await Providers.ladderFor(
                            code: holder.provider, detail: d,
                            filmTitle: d.movie.name,
                            epName: judgeName, epNum: judgeNum)
                        return ladder.entries.isEmpty ? nil
                            : (holder.provider,
                               TVBKeptDetail(slug: holder.slug,
                                             detail: d))
                    }
                }
                var collected: [(String, TVBKeptDetail)] = []
                for await r in group { if let r { collected.append(r) } }
                return collected
            }
            for entry in found {
                outcome.playable.insert(entry.0)
                outcome.kept[entry.0] = entry.1
            }
        }
        // v2.0.33 (item 3): the Film4K leg — sequential,
        // after the holder group. Only when Film4K is not
        // itself a snapshot holder and has not been
        // struck on this page. Its slug is resolved with
        // the SAME findSlug call tvbOrderedAlternatives
        // uses (ID-verified), its detail is gated with
        // ctx.accepts (which already handles non-holder
        // providers via the affirm rule), and it is judged
        // with the shared target if present, else its own
        // — exactly like a holder above. Fail-soft
        // throughout: no slug, a failed fetch, a rejected
        // payload or an empty ladder simply leaves
        // Film4K out of both collections.
        if !ctx.holders.contains(where: { $0.provider == Providers.F4K }),
           !tvbStruck.contains(Providers.F4K),
           let f4kSlug = await Providers.findSlug(
               code: Providers.F4K, name: route.name, origin: "",
               year: route.year, tmdbId: "\(ctx.tmdbId)",
               requireIdVerified: true),
           let f4kDetail = try? await Providers.detail(
               Providers.F4K, slug: f4kSlug),
           ctx.accepts(f4kDetail.movie, provider: Providers.F4K),
           let judgeTarget = target ?? Self.tvbOwnTarget(
               code: Providers.F4K, detail: f4kDetail) {
            let ladder = await Providers.ladderFor(
                code: Providers.F4K, detail: f4kDetail,
                filmTitle: f4kDetail.movie.name,
                epName: judgeTarget.name, epNum: judgeTarget.num)
            if !ladder.entries.isEmpty {
                outcome.playable.insert(Providers.F4K)
                outcome.kept[Providers.F4K] = TVBKeptDetail(
                    slug: f4kSlug, detail: f4kDetail)
            }
        }
        return outcome
    }

    /// TMDB backdrop hunt for the staged TMDB task (Phase 2):
    /// the search runs only when a backdrop is still needed
    /// after fetchInfo; the async-let gate keeps the call
    /// itself inside the concurrent leg.
    /// Swift 6 round (fault c): a TVB session NEVER runs
    /// the name search — a search-by-name backdrop is
    /// unverifiable against the snapshot identity, so the
    /// hunt's leg is the snapshot's OWN backdrop path for
    /// this title (carried in the route context), or
    /// nothing. The provider thumb / poster stages behind
    /// the band are unaffected.
    private func backdropHunt(needed: Bool, movie: Movie) async -> String? {
        guard needed else { return nil }
        if let tvbCtx = route.tvb {
            let path = tvbCtx.backdropPath
            guard !path.isEmpty else { return nil }
            return "https://image.tmdb.org/t/p/w1280"
                + (path.hasPrefix("/") ? path : "/" + path)
        }
        return await TMDBClient.searchBackdrop(
            name: movie.name, origin: movie.originName,
            year: Providers.yearOf(movie))
    }

    /// TMDB cast for the staged TMDB task (Phase 2): cast
    /// exists only when a TMDB id exists — the same rule the
    /// serial chain applied.
    /// Swift 6 round (fault c): a TVB session's cast is
    /// fetched by the snapshot pin (its TMDB id, as "tv"),
    /// like the enrichment above — never by the provider
    /// payload's stamps.
    private func castIfAvailable(movie: Movie) async -> [TMDBCastMember] {
        if let tvbCtx = route.tvb {
            return await TMDBClient.fetchCast(
                tmdbId: "\(tvbCtx.tmdbId)", type: "tv")
        }
        guard !movie.tmdbId.isEmpty else { return [] }
        return await TMDBClient.fetchCast(
            tmdbId: movie.tmdbId, type: movie.tmdbType)
    }

    // MARK: - Backdrop preview (v2.0.49: trailer only)
    //
    // The driver for JoePreviewController (JoePreview
    // .swift holds the rules and the player). v2.0.49
    // redesign (owner contract 2026-11-21 22:34–22:39
    // CST, convicted by the exported DiagLog
    // joetv-diag_13: 16 shipped attempts, ALL episode
    // legs, ZERO trailer attempts): the preview is the
    // title's TRAILER and nothing else. The episode
    // legs (the YouTube-episode leg and the chain
    // ladder leg) are DELETED — no episode resolve, no
    // chain fall-through, no measured-ceiling pre-skip
    // (that block went with them; the quality gate now
    // judges this attempt's resolved height only).
    // Trailer source order: TMDB's trailer for the
    // title first; the title's own source trailer (the
    // provider payload's trailer URL, Movie.trailerUrl)
    // as fallback. Neither → no attempt, the static
    // backdrop stays. Torrent titles never reach here —
    // this detail's torrent entry hands off to the
    // torrent detail, whose backdrop is a STATIC image
    // by the 2026-11-21 22:39 ruling (no preview
    // machinery for torrent titles, full stop).
    // FIX-7 (2.1.1, owner 2026-11-22 02:40 CST): TVB
    // titles (route.tvb != nil) never reach the trailer
    // attempt either — runPreview returns at its FIX-7
    // guard and the backdrop stays the title's
    // highest-quality still (see stillPortraitMode).

    private func runPreview() async {
        // The same ~1.5 s dwell as the pre-resolve: an
        // owner who backs straight out costs nothing.
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        guard !Task.isCancelled, let d = detail else { return }
        // FIX-7 (2.1.1, owner decision 2026-11-22 02:40
        // CST): a TVB title NEVER starts the Option-C
        // trailer preview here — its YouTube trailers are
        // ~all 480p and died at the <720p quality gate, so
        // the owner replaced them with the title's
        // highest-quality STILL as the backdrop. The TVB
        // discriminator is the route's snapshot context:
        // `route.tvb != nil` (TVBRouteContext — non-nil
        // ONLY on TVB-tab routes; see JoePhimHome.swift's
        // TVBRouteContext and this file's tvbGate, which
        // keys on the same value). The guard sits BEFORE
        // every trailer path, so startTrailerPreview (and
        // with it the PC trailer sign-in prompt's
        // needsIdentity surfacing) can never fire for a
        // TVB title. Non-TVB titles fall through to the
        // unchanged Option-C behaviour below.
        guard route.tvb == nil else {
            DiagLog.write("PREVIEW", "preview skipped rule=tvb-still-backdrop")
            return
        }
        guard JoePreviewSettings.enabled else {
            DiagLog.write("PREVIEW", "preview skipped rule=settings-off")
            return
        }
        guard !UIAccessibility.isReduceMotionEnabled else {
            DiagLog.write("PREVIEW", "preview skipped rule=reduce-motion")
            return
        }
        // Only the surfaces that HAVE a backdrop layer:
        // Ultra (full-screen) and Billboard (the band).
        // Poster Wall / Source Board details have none —
        // adding one would break the design freeze.
        // v2.1.0 (Private Cinema): PC joins the gate — its
        // detail carries the full-screen cinemaBackdrop.
        guard theme.id == .ultra || theme.id == .billboard
            || theme.id == .privateCinema else {
            DiagLog.write("PREVIEW", "preview skipped rule=no-backdrop-surface")
            return
        }
        await startTrailerPreview(d)
    }

    /// The trailer attempt (v2.0.49): find the title's
    /// trailer as a YouTube video key, resolve it
    /// through JoeYtResolver (the player's own route)
    /// and hand the playable to the preview player at
    /// startFraction 0 — a trailer plays from its own
    /// start. Identity: a TVB session pins the snapshot
    /// identity (its TMDB id, as "tv"), exactly like the
    /// enrichment; otherwise the payload's own TMDB
    /// id/type. The keys are tried IN ORDER — TMDB's
    /// trailer first, the title's own source trailer
    /// (mined from Movie.trailerUrl) as the fallback —
    /// and the fallback covers a TMDB key that fails to
    /// RESOLVE as well as one that is absent (gate R1,
    /// lens C: "TMDB first, source as fallback" read
    /// whole). One attempt covers the whole key list;
    /// it aborts once, with the last key's reason, only
    /// when every key failed. The static backdrop stays.
    /// No JoeYtQualityMap banking here: a trailer's
    /// height is not the series' measured ceiling, and
    /// the map feeds the honest badge only.
    private func startTrailerPreview(_ d: Detail) async {
        let identity: (id: String, type: String)?
        if let tvbCtx = route.tvb {
            identity = ("\(tvbCtx.tmdbId)", "tv")
        } else if !d.movie.tmdbId.isEmpty {
            identity = (d.movie.tmdbId, d.movie.tmdbType)
        } else {
            identity = nil
        }
        var keys: [String] = []
        if let identity,
           let tmdbKey = await TMDBClient.fetchTrailerKey(
               tmdbId: identity.id, type: identity.type),
           !tmdbKey.isEmpty {
            keys.append(tmdbKey)
        }
        // v2.0.49 fix round (Lens B F-B1): the key fetch
        // above runs BEFORE beginAttempt, so a dismissal
        // during the fetch must not let this orphaned
        // task go on to begin an attempt on a dead view.
        guard !Task.isCancelled else { return }
        if let sourceKey = youtubeVideoId(
               fromTrailerURL: d.movie.trailerUrl),
           !keys.contains(sourceKey) {
            keys.append(sourceKey)
        }
        guard !keys.isEmpty else {
            DiagLog.write("PREVIEW", "preview skipped rule=no-trailer")
            return
        }
        guard preview.beginAttempt(kind: "trailer") else { return }
        var lastReason = "trailer-unresolved"
        for key in keys {
            if let reason = await attemptTrailerKey(key) {
                lastReason = reason
                continue
            }
            return
        }
        preview.abortAttempt(reason: lastReason)
        // v2.1.1 (WS-C, DIAG-2050 §1c): a needsIdentity
        // ending is NOT an ordinary preview failure — the
        // whole install lacks a YouTube session, and the
        // silent rule left the owner no signal across two
        // builds. Under Private Cinema ONLY (every other
        // theme keeps the silent behaviour byte-for-byte),
        // surface the existing device-code activation on
        // this detail: the prompt (pcTrailerSignInPrompt)
        // goes up and the flow starts, exactly as the
        // router's goldPlaybackSurface starts it on a
        // playback .needsIdentity. One approval serves
        // both playback and trailers — no resolver or
        // store change.
        if lastReason == "trailer-needs-identity",
           theme.id == .privateCinema {
            await MainActor.run {
                trailerSignInPrompt = true
                JoeYtIdentity.shared.beginDeviceCodeFlow()
            }
            DiagLog.write("PREVIEW",
                          "trailer sign-in prompt surfaced (PC, needsIdentity)")
        }
    }

    /// One trailer key's resolve + hand-over. Returns
    /// nil when the playable was handed to the preview
    /// player (the attempt is under way); otherwise the
    /// abort reason for this key — the caller decides
    /// whether another key remains before aborting.
    private func attemptTrailerKey(_ videoKey: String) async -> String? {
        let result = await JoeYtResolver.shared.resolve(videoId: videoKey)
        switch result {
        case .playable(let playable, _):
            // The playable handling mirrors the retired
            // YouTube-episode leg's shape exactly (the
            // assembly through the HLS server, the muxed
            // fallback, the direct forms), with trailer-
            // prefixed reasons and NO ceiling-map banking.
            switch playable.kind {
            case .assembly:
                // QUALITY GATE (17:50 ruling): the
                // resolver already KNOWS this variant's
                // height — a known sub-720 height
                // suppresses HERE, before any hand-over.
                // An unknown height (0) proceeds; the
                // controller's item-level gates still
                // apply.
                if playable.height > 0, playable.height < 720 {
                    return "trailer-low-quality-\(playable.height)p"
                }
                if let session = await JoeYtHlsServer.shared.makeSession(
                    playable: playable,
                    userAgent: JoeYtClientSpec.tvSamsung.userAgent) {
                    DiagLog.write("PREVIEW", "preview resolve kind=trailer-assembly")
                    preview.play(url: session.url, headers: [:],
                                 startFraction: 0)
                    return nil
                }
                if let direct = playable.fallbackDirectURL {
                    // The muxed fallback's OWN known
                    // height gates it the same way.
                    if playable.fallbackHeight > 0, playable.fallbackHeight < 720 {
                        return "trailer-low-quality-muxed-\(playable.fallbackHeight)p"
                    }
                    DiagLog.write("PREVIEW", "preview resolve kind=trailer-muxed-fallback")
                    preview.play(url: direct, headers: [:],
                                 startFraction: 0)
                    return nil
                }
                return "trailer-assembly-failed"
            case .muxed, .hlsManifest:
                // Known-height gate, same as the assembly
                // branch.
                if playable.height > 0, playable.height < 720 {
                    return "trailer-low-quality-\(playable.height)p"
                }
                if let direct = playable.directURL {
                    DiagLog.write("PREVIEW", "preview resolve kind=trailer-direct")
                    preview.play(url: direct, headers: [:],
                                 startFraction: 0)
                    return nil
                }
                return "trailer-no-direct-url"
            }
            // Unreachable — every kind path above returns;
            // present so the compiler sees the case return.
            return "trailer-unresolved"
        case .needsIdentity:
            return "trailer-needs-identity"
        case .membersRequired(let reason):
            return "trailer-members-required \(reason)"
        case .unplayable(let status, let reason):
            return "trailer-unplayable \(status) \(reason)"
        case .httpFailure(let status):
            return "trailer-http-\(status)"
        case .transportFailure(let message):
            return "trailer-transport \(message)"
        case .solverFailed(let step, let message):
            return "trailer-solver \(step) \(message)"
        }
    }

    /// Mine a YouTube video id out of a source trailer
    /// URL (v2.0.49): the shapes the provider payloads
    /// carry — watch?v=…, youtu.be/…, /embed/…, /shorts/…
    /// The id is the run of id characters right after
    /// the marker; anything else (a non-YouTube URL, an
    /// empty field) yields nil and the caller treats it
    /// as "no source trailer". The URL itself is never
    /// logged — only the extracted key is used.
    private func youtubeVideoId(fromTrailerURL raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let markers = ["youtu.be/", "watch?v=", "/embed/", "/shorts/"]
        for marker in markers {
            guard let r = s.range(of: marker) else { continue }
            let tail = s[r.upperBound...]
            let id = tail.prefix {
                $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_"
            }
            if !id.isEmpty { return String(id) }
        }
        return nil
    }

    /// Dwell pre-resolve (v2.0.8, Phase 2/3): after ~1.5 s
    /// resting on one episode context, speculatively resolve
    /// that episode's first server through Providers
    /// .preResolve — the result lands in the resolver memo,
    /// so the Play tap that follows starts from a warm
    /// ladder. The driving .task(id:) is keyed on
    /// provider|slug|focusedEp|detail-arrival, so SwiftUI
    /// cancels this and restarts it as focus moves, the
    /// provider switches, or the view exits — speculative
    /// work never outlives its context. preResolve is cheap
    /// when nothing needs the network (direct-m3u8 providers
    /// resolve instantly; a memo hit is a dictionary read).
    private func dwellPreResolve() async {
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        guard !Task.isCancelled, let d = detail,
              let target = dwellTarget(detail: d) else { return }
        await Providers.preResolve(code: provider, detail: d,
                                   epName: target.name,
                                   epNum: target.num)
        // Idea 23: VSMOV / Tủ Phim dwell warm — their first
        // ladder entries are PROXY entries, so the warm
        // builds the playable proxy URL EXACTLY as the play
        // path in makeDirector's resolveLadder does (the
        // JoeProxy.shared.playlistURL conversion) and warms
        // THAT through warmUpcoming: the tap's first
        // candidate is then the warmed item, and the
        // StreamWarmer's take() can hand it over. If the
        // proxy conversion fails (proxy down), the warm is
        // skipped — never warm the direct URL behind the
        // proxy's back. Film4K is EXCLUDED by law: its
        // tokens rotate per API call, so a warmed F4K URL
        // would be stale on arrival; F4K keeps only the
        // URL-level pre-resolve above.
        if provider == Providers.VS || provider == Providers.TP {
            guard !Task.isCancelled else { return }
            let ladder = await Providers.ladderFor(
                code: provider, detail: d, filmTitle: d.movie.name,
                epName: target.name, epNum: target.num)
            if let first = ladder.entries.first, first.proxy,
               let proxyURL = JoeProxy.shared.playlistURL(
                   for: first.url, headers: first.headers) {
                StreamWarmer.shared.warmUpcoming(
                    url: proxyURL, headers: first.headers)
            }
            return
        }
        // v2.0.24 (Sony D2's tvOS shape): for KK only, the
        // dwell warm now extends from the resolved URL to
        // the media itself. Build this episode's ladder —
        // cheap on the memo hit preResolve just landed —
        // and hand its first entry to the StreamWarmer,
        // which loads that stream's playlists and initial
        // segments into a paused AVPlayer while the owner
        // keeps browsing; the Play tap then starts from
        // warm bytes (see JoeStreamWarmer.swift for the
        // mechanism and its honest bounds). KK only here:
        // its entries are direct m3u8 from this session's
        // fresh detail payload. VS/TP warm through the
        // proxy in the Idea 23 branch above; F4K stays
        // excluded (rotating tokens). A proxy entry is
        // skipped too (KK never proxies; the guard keeps
        // the warm honest if that ever changes). Fail-soft
        // throughout: a missed or stale warm leaves the
        // tap's cold path exactly as it was.
        guard !Task.isCancelled, provider == Providers.KK
        else { return }
        let ladder = await Providers.ladderFor(
            code: provider, detail: d, filmTitle: d.movie.name,
            epName: target.name, epNum: target.num)
        if let first = ladder.entries.first, !first.proxy,
           let url = URL(string: first.url) {
            StreamWarmer.shared.warm(url: url, headers: first.headers)
        }
    }

    /// The dwell target: the focused episode when focus rests
    /// on an episode chip (the focus key is
    /// "<serverIndex>|<name>", matched back against the
    /// servers exactly), else the default first playable
    /// episode in server order.
    private func dwellTarget(detail d: Detail) -> (name: String, num: Int)? {
        if let focusedEp {
            for (si, server) in d.servers.enumerated() {
                for ep in server.episodes
                where "\(si)|\(ep.name)" == focusedEp {
                    return (ep.name, Providers.episodeNumber(ep.name))
                }
            }
        }
        for server in d.servers {
            for ep in server.episodes
            where Providers.isPlayable(code: provider, episode: ep) {
                return (ep.name, Providers.episodeNumber(ep.name))
            }
        }
        return nil
    }

    /// Idea 6 (checkpoint 2.0.25): the NEXT episode after
    /// `epName` in the episode list this detail already
    /// holds, or nil when there is none (a movie / single-
    /// episode session, or the last episode). The successor
    /// in the SAME server's list wins — that is the list the
    /// owner tapped through; when that slot is missing or
    /// unplayable, the episode numbered N+1 anywhere in the
    /// detail (server order) is the fallback, mirroring the
    /// ladder's own number matching. Playable-only: an
    /// unplayable "next" is no next at all.
    private func nextEpisodeName(in d: Detail, after epName: String) -> String? {
        for server in d.servers {
            if let idx = server.episodes.firstIndex(where: { $0.name == epName }) {
                if idx + 1 < server.episodes.count {
                    let candidate = server.episodes[idx + 1]
                    if Providers.isPlayable(code: provider, episode: candidate) {
                        return candidate.name
                    }
                }
                break
            }
        }
        let currentNum = Providers.episodeNumber(epName)
        guard currentNum >= 1 else { return nil }
        for server in d.servers {
            for ep in server.episodes
            where Providers.episodeNumber(ep.name) == currentNum + 1
                && Providers.isPlayable(code: provider, episode: ep) {
                return ep.name
            }
        }
        return nil
    }

    private func play(_ d: Detail, epName: String) {
        PerfLog.mark("play.tap")
        // Owner source-priority policy: in Tự động mode a US
        // theatrical film probes the torrent rung FIRST (the
        // probe itself decides — only a high-quality release
        // answers); every other film, and every pinned session,
        // keeps the current ladder order exactly.
        let torrentFirst = autoSource && Self.isUSTheatrical(d.movie)
        let sourceLine = autoSource
            ? (torrentFirst ? "Nguồn: Tự động · ưu tiên Torrent chất lượng cao"
                            : "Nguồn: Tự động")
            : "Nguồn: \(Providers.displayName(provider)) · đã ghim"
        let director = Self.makeDirector(
            provider: provider, detail: d, epName: epName,
            watch: watch, torrentFirst: torrentFirst,
            tvb: route.tvb, tvbHopList: alternatives)
        // Idea 6 (checkpoint 2.0.25) — Up Next wiring,
        // EPISODE sessions only. Every play in this file is
        // built from the detail's CURRENT provider state
        // (episode chips and the big Play button alike; an
        // alternative-source tap switches + pins the detail
        // itself before any play, it never starts a one-off
        // cross-provider session), so the guard is exactly:
        // a next episode exists in this same detail. Movie
        // (single-episode) sessions find no next and wire
        // nothing. The factory and the warm below capture
        // the session's OWN provider code and torrentFirst
        // flag as plain values — no new source decision is
        // ever taken for the next episode, so a user-pinned
        // source (autoSource off, torrentFirst false) stays
        // the lead source there too, and the director's own
        // failover machinery is unchanged.
        if let nextName = nextEpisodeName(in: d, after: epName) {
            let sessionProvider = provider
            let sessionDetail = d
            let sessionWatch = watch
            // v2.0.31 (L7/I1): the next-episode session
            // inherits the TVB context + hop list exactly
            // as it inherits the provider (see above).
            let sessionTVB = route.tvb
            let sessionHopList = alternatives
            let nextNum = Providers.episodeNumber(nextName)
            director.nextEpisodeTitle = nextName
            director.nextEpisodeFactory = {
                Self.makeDirector(
                    provider: sessionProvider, detail: sessionDetail,
                    epName: nextName, watch: sessionWatch,
                    torrentFirst: torrentFirst,
                    tvb: sessionTVB, tvbHopList: sessionHopList)
            }
            director.onPlayingStarted = {
                // Playback has started: prepare episode N+1
                // off the critical path. Every provider gets
                // the resolver-memo pre-resolve; KK additionally
                // warms the media itself, via the same ladder +
                // first-entry pattern (and the same proxy guard)
                // as the dwell warm in dwellPreResolve() — KK
                // entries are direct m3u8. VSMOV / Tủ Phim warm
                // through the proxy instead (Idea 23, the branch
                // below — the same conversion the dwell warm
                // performs); Film4K keeps the URL-level
                // preparation only (rotating tokens). Fail-soft
                // throughout.
                Task.detached {
                    await Providers.preResolve(
                        code: sessionProvider, detail: sessionDetail,
                        epName: nextName, epNum: nextNum)
                    // Idea 23: the VS/TP proxy warm for the
                    // NEXT episode — the first ladder entry is
                    // a proxy entry, so the playable proxy URL
                    // is built exactly as makeDirector's
                    // resolveLadder builds the play candidate
                    // (JoeProxy.shared.playlistURL); a failed
                    // conversion skips the warm.
                    if sessionProvider == Providers.VS
                        || sessionProvider == Providers.TP {
                        let ladder = await Providers.ladderFor(
                            code: sessionProvider, detail: sessionDetail,
                            filmTitle: sessionDetail.movie.name,
                            epName: nextName, epNum: nextNum)
                        if let first = ladder.entries.first, first.proxy,
                           let proxyURL = JoeProxy.shared.playlistURL(
                               for: first.url, headers: first.headers) {
                            StreamWarmer.shared.warmUpcoming(
                                url: proxyURL, headers: first.headers)
                        }
                        return
                    }
                    guard sessionProvider == Providers.KK else { return }
                    let ladder = await Providers.ladderFor(
                        code: sessionProvider, detail: sessionDetail,
                        filmTitle: sessionDetail.movie.name,
                        epName: nextName, epNum: nextNum)
                    if let first = ladder.entries.first, !first.proxy,
                       let url = URL(string: first.url) {
                        StreamWarmer.shared.warmUpcoming(
                            url: url, headers: first.headers)
                    }
                }
            }
        }
        playerHolder = DirectorHolder(
            director: director,
            title: d.movie.name, episode: epName, sourceLine: sourceLine)
    }

    /// The policy's US-theatrical test, from the detail
    /// payload's own fields: the Âu Mỹ country bucket (the
    /// same name mapping the browse filter's country facet
    /// uses) AND a single/theatrical signal — the KK/VS
    /// `chieurap` flag or a single-class type (phim lẻ).
    static func isUSTheatrical(_ m: Movie) -> Bool {
        let western = m.country
            .components(separatedBy: "·")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .contains { JoeBrowseFilter.countryBucket(ofName: $0) == .auMy }
        guard western else { return false }
        return m.chieurap
            || m.type == "single" || m.type == "phim-le" || m.type == "movie"
    }

    /// The session factory: identity + fresh-resolution ladder +
    /// one cross-provider hop (KK ↔ Film4K ↔ VSMOV), with the
    /// resume position carried from the stored entry. Mirrors
    /// the Android player wiring.
    /// v2.0.31 (L7): `tvb` carries the TVB snapshot context
    /// for TVB sessions (nil otherwise) — the hop then walks
    /// only the snapshot's holders (`tvbHopList` first: the
    /// detail's evaluated alternatives) under the identity
    /// verdict, and the torrent rung is pinned to the
    /// snapshot's IMDb id. Non-TVB sessions are unchanged.
    static func makeDirector(provider: String, detail: Detail,
                             epName: String, watch: WatchStore,
                             torrentFirst: Bool = false,
                             tvb: TVBRouteContext? = nil,
                             tvbHopList: [(code: String, slug: String)] = [])
        -> PlayDirector {
        let m = detail.movie
        var entry = WatchStore.Entry()
        entry.kind = Providers.kindOf(provider)
        entry.key = Providers.progressKey(provider, slug: m.slug, epName: epName)
        entry.ep = epName
        entry.epLabel = "Đang xem: \(epName)"
        entry.title = m.name
        entry.poster = m.poster
        entry.year = m.year
        entry.slug = m.slug
        entry.source = provider
        // v2.0.29 (cluster C, §4.3 O1): stamp the stable
        // ids so a later torrent-side save of the same
        // title can canonical-match this entry by id even
        // when the two catalogues title it differently.
        entry.imdbId = m.imdbId
        entry.tmdbId = m.tmdbId
        // v2.0.38 (Sony 2.3.41 parity, item 3): the
        // payload → launch fallback, Sony's knownTmdbId
        // order — a TVB payload can stand by an
        // id-matched holder with no ids of its own, and
        // an unstamped progress entry would reopen
        // fail-open under the gate; the session's TVB
        // context (this function's own parameter) still
        // knows the title's identity.
        if entry.tmdbId.isEmpty, let tvb {
            entry.tmdbId = "\(tvb.tmdbId)"
        }
        if entry.imdbId.isEmpty, let tvb {
            entry.imdbId = tvb.imdbId
        }
        let resume = watch.progressFor(matching: entry)?.pos ?? 0
        // v2.0.8 (Phase 3): the resolveLadder closure's FIRST
        // invocation for the origin identity builds its ladder
        // from the detail already on screen (the `detail`
        // value captured here) instead of re-fetching the
        // metadata — the screen paid for that payload once.
        // Only the stream-URL resolve inside ladderFor runs at
        // tap time, through the memoised resolver, so the
        // fresh-resolution rule's substance (URLs resolved at
        // tap, never stored) is untouched. Every later
        // invocation — the failover refresh rung, post-hop
        // identities — fetches fresh exactly as before. The
        // flag lives in a reference box because the closure is
        // escaping and called many times over the session.
        let originBox = LadderFirstCallBox()
        return PlayDirector(
            store: watch,
            identity: PlayIdentity(entry: entry),
            resumeMs: resume,
            resolveLadder: { identity in
                // Owner source-priority policy: torrentFirst
                // (Auto + US-theatrical) probes the torrent
                // rung FIRST. The probe is the rung's own
                // stream fetch inside its existing budget
                // (TorrentClient's 15 s cap): a qualifying
                // high-quality release leads the ladder; no
                // qualifying stream — or an unconfigured /
                // unreachable rung — answers empty and the
                // streaming ladder runs in the normal order.
                // Auto never dead-ends on this rule.
                var first: [PlayCandidate] = []
                if torrentFirst {
                    first = await JoeMovieDetail.torrentFallbackCandidates(
                        identity: identity, originDetail: detail,
                        originProvider: provider, highQualityOnly: true,
                        pinnedImdbId: tvb?.imdbId ?? "",
                        pinnedTmdbId: tvb.map { "\($0.tmdbId)" } ?? "")
                }
                // First call for the ORIGIN identity: the
                // on-screen detail IS the metadata (see the
                // originBox note at the factory head). Any
                // other call — refresh rung, post-hop identity,
                // or an identity that is not the origin — takes
                // the fresh fetch exactly as before.
                let d: Detail
                if identity.entry.source == provider,
                   identity.entry.slug == detail.movie.slug,
                   originBox.claim() {
                    d = detail
                } else if let fresh = try? await Providers.detail(
                    identity.entry.source, slug: identity.entry.slug) {
                    d = fresh
                } else {
                    return first
                }
                let ladder = await Providers.ladderFor(
                    code: identity.entry.source, detail: d,
                    filmTitle: identity.entry.title,
                    epName: identity.entry.ep,
                    epNum: Providers.episodeNumber(identity.entry.ep))
                let streaming = ladder.entries.compactMap { entry in
                    // v2.0.36 (FIX 1, AUDIT-2034 §4): every
                    // candidate is stamped with its UPSTREAM
                    // host — the host of entry.url, the stream
                    // the provider actually serves — BEFORE any
                    // proxy wrapping, so the director's
                    // never-ready failure memory can key on the
                    // provider that died even when the play URL
                    // is the house proxy's loopback address
                    // (whose host names every proxied provider
                    // at once and can never be a key). This one
                    // builder serves the initial ladder, the
                    // failover refresh rung and the hop rung
                    // alike — they all re-run this closure — so
                    // no rung can mint an unstamped candidate.
                    let upstreamHost = URL(string: entry.url)?.host
                    // PNG-disguised / header-gated streams reach
                    // AVPlayer through the in-app cleaning proxy;
                    // if the proxy is somehow down, fall back to
                    // the direct URL rather than no candidate.
                    if entry.proxy,
                       let local = JoeProxy.shared.playlistURL(
                           for: entry.url, headers: entry.headers) {
                        var candidate = PlayCandidate(url: local,
                                                      label: entry.title)
                        candidate.upstreamHost = upstreamHost
                        return candidate
                    }
                    return URL(string: entry.url).map {
                        var candidate = PlayCandidate(
                            url: $0, headers: entry.headers,
                            label: entry.title)
                        candidate.upstreamHost = upstreamHost
                        return candidate
                    }
                }
                var seen = Set<String>()
                return (first + streaming).filter {
                    seen.insert($0.url.absoluteString).inserted
                }
            },
            hopIdentity: { identity in
                // v2.0.31 (L7): a TVB session hops ONLY
                // inside the snapshot's holders — the
                // detail's evaluated hop list first, then
                // any remaining holders — and every
                // candidate payload must pass the snapshot
                // identity verdict before it is adopted.
                // The name-search hop below never runs for
                // TVB: a same-named different film is not a
                // failover target, it is the fault itself.
                let hopCandidates: [(code: String, slug: String)]
                if let tvb {
                    var order = tvbHopList
                    for holder in tvb.holders
                    where !order.contains(where: {
                        $0.code == holder.provider
                    }) {
                        order.append((code: holder.provider,
                                      slug: holder.slug))
                    }
                    hopCandidates = order.filter {
                        $0.code != identity.entry.source
                    }
                } else {
                    guard let cur = try? await Providers.detail(
                        identity.entry.source, slug: identity.entry.slug)
                    else { return nil }
                    let alts = await Providers.findAlternatives(
                        fromCode: identity.entry.source, name: cur.movie.name,
                        origin: cur.movie.originName, year: cur.movie.year,
                        tmdbId: cur.movie.tmdbId)
                    // 1.9.2 (Team 9 item 2): iterate the alternatives
                    // in failover order (up to 3) instead of trying
                    // only alts.first — a first alternative whose
                    // detail fetch fails no longer ends the hop while
                    // a second carrier of the same film stands ready.
                    hopCandidates = Array(alts.prefix(3))
                }
                for alt in hopCandidates {
                    guard let d = try? await Providers.detail(alt.code, slug: alt.slug)
                    else { continue }
                    if let tvb, !tvb.accepts(d.movie, provider: alt.code) {
                        continue
                    }
                    let epNum = Providers.episodeNumber(identity.entry.ep)
                    var newEp = identity.entry.ep
                    outer: for s in d.servers {
                        for e in s.episodes where Providers.episodeNumber(e.name) == epNum {
                            newEp = e.name
                            break outer
                        }
                    }
                    var e2 = WatchStore.Entry()
                    e2.kind = Providers.kindOf(alt.code)
                    e2.key = Providers.progressKey(alt.code, slug: alt.slug, epName: newEp)
                    e2.ep = newEp
                    e2.epLabel = "Đang xem: \(newEp)"
                    e2.title = d.movie.name
                    e2.poster = d.movie.poster
                    e2.year = d.movie.year
                    e2.slug = alt.slug
                    e2.source = alt.code
                    // v2.0.29 (cluster C, §4.3 O2): the hop
                    // identity carries the same stable ids.
                    e2.imdbId = d.movie.imdbId
                    e2.tmdbId = d.movie.tmdbId
                    // v2.0.38: the identity fallback — a
                    // hop payload with no ids of its own
                    // (accepted above on the snapshot's
                    // affirm rule or an id-matched stand)
                    // must not strip the identity the
                    // session already carries: the hop row
                    // reopens under the same gate as the
                    // origin row.
                    if e2.imdbId.isEmpty {
                        e2.imdbId = identity.entry.imdbId
                    }
                    if e2.tmdbId.isEmpty {
                        e2.tmdbId = identity.entry.tmdbId
                    }
                    return PlayIdentity(entry: e2)
                }
                return nil
            },
            fallbackCandidates: { identity in
                // When the torrent rung already probed FIRST
                // (torrentFirst), it has had its chance at the
                // front of this session's ladder — probing it
                // again as the last resort would only repeat
                // the same fetch against the same title.
                if torrentFirst { return [] }
                return await JoeMovieDetail.torrentFallbackCandidates(
                    identity: identity, originDetail: detail,
                    originProvider: provider,
                    pinnedImdbId: tvb?.imdbId ?? "",
                    pinnedTmdbId: tvb.map { "\($0.tmdbId)" } ?? "")
            })
    }

    /// The substitution rung's candidate hunt (owner law,
    /// v1.9): every Phim source for this title is dead, so find
    /// the SAME title on the torrent side and offer its streams
    /// as the replacement — the director plays them under the
    /// CURRENT identity, so resume and Continue Watching stay
    /// on the Phim entry (one CW row per title, as the owner
    /// expects). Identity is by ID only, never by title text:
    /// the detail's own IMDB id when a provider carried one
    /// (Tủ Phim does); else — v2.0.5 — the detail-time
    /// ladder's cached identity (Providers.resolveIdentity:
    /// external_ids, every alternative's detail, the strict
    /// TMDB title search), consumed first, negatives
    /// included; only when that ladder never ran for the
    /// film does the rung fall back to its original
    /// derivation (TMDB id → TMDB external_ids → IMDB id,
    /// with the TMDB id hunted through the KK alternative
    /// when this provider's detail lacks one). Series
    /// episodes address Torrentio as imdbId:season:episode.
    /// Fail-soft end to end: any gap returns [] and the
    /// director shows its exhausted slate — the honest end
    /// state.
    /// `highQualityOnly` is the source-priority policy's
    /// front-probe form: only streams whose release passes
    /// TorStream.isHighQualityRelease may lead the ladder;
    /// the last-resort rung (false) keeps its historic
    /// any-stream behaviour.
    private static func torrentFallbackCandidates(
        identity: PlayIdentity, originDetail: Detail,
        originProvider: String,
        highQualityOnly: Bool = false,
        pinnedImdbId: String = "",
        pinnedTmdbId: String = "") async -> [PlayCandidate] {
        guard let base = TorrentSettings.effectiveBase else { return [] }

        // After a hop the session lives on another provider:
        // read THAT detail (fresh, like the ladder and hop do);
        // the origin detail otherwise, and as the fallback if
        // the fresh fetch fails.
        var d = originDetail
        if identity.entry.source != originProvider
            || identity.entry.slug != originDetail.movie.slug,
           let fresh = try? await Providers.detail(
               identity.entry.source, slug: identity.entry.slug) {
            d = fresh
        }

        var imdbId = d.movie.imdbId
        var tmdbType = d.movie.tmdbType
        var tmdbSeason = d.movie.tmdbSeason
        // v2.0.31 (L7): a TVB session's snapshot IMDb id,
        // when the spine carries one, outranks every
        // derivation below — the rung addresses the
        // snapshot's series directly, as a TV series, and
        // the derivation block (which contains the
        // name-search KK leg) is skipped entirely.
        if !pinnedImdbId.isEmpty {
            imdbId = pinnedImdbId
            tmdbType = "tv"
        }
        if pinnedImdbId.isEmpty, !pinnedTmdbId.isEmpty {
            // Swift 6 specialist-review fix (SF4): with a
            // snapshot TMDB id pinned but no snapshot IMDb
            // id, the payload's OWN imdbId is unverified —
            // a different series' id rides exactly this
            // field, and nothing downstream can contradict
            // an IMDb id the snapshot has nothing to compare
            // against. Discard it: the derivation below
            // runs on the snapshot's TMDB id alone, so the
            // rung addresses the snapshot's own series, or
            // nothing.
            imdbId = ""
        }
        if imdbId.isEmpty, !pinnedTmdbId.isEmpty {
            // Swift 6 round (fault c): a TVB session whose
            // snapshot carries no IMDb id derives one ONLY
            // from the snapshot's TMDB id (TMDB external_ids,
            // as "tv") — the cache / name-search derivation
            // below never runs for TVB, so the substitution
            // rung can only ever address the snapshot's own
            // series, or nothing.
            imdbId = await TMDBClient.imdbId(
                tmdbId: pinnedTmdbId, type: "tv") ?? ""
            tmdbType = "tv"
        }
        if imdbId.isEmpty, pinnedTmdbId.isEmpty {
            // v2.0.5 (D3): consume the detail-time ladder's
            // result FIRST. The ladder (Providers
            // .resolveIdentity, run when this film's detail
            // page loaded) is a superset of the derivation
            // below — own ids, external_ids, EVERY
            // alternative's detail, the strict TMDB title
            // search — and its answer is session-cached,
            // negatives included. A cached NEGATIVE is
            // consumed as-is: re-running the weaker derivation
            // could only repeat its answer, slower. Only a
            // cache MISS (the ladder never ran for this film —
            // a programmatic director entry) falls back to the
            // derivation below.
            if let cached = Providers.identityCacheGet(
                Providers.identityKey(name: originDetail.movie.name,
                                      year: originDetail.movie.year,
                                      fromCode: originProvider)) {
                imdbId = cached.imdbId
                if tmdbType.isEmpty { tmdbType = cached.tmdbType }
                if tmdbSeason <= 0 { tmdbSeason = cached.tmdbSeason }
            } else {
                var tmdbId = d.movie.tmdbId
                if tmdbId.isEmpty {
                    let alts = await Providers.findAlternatives(
                        fromCode: identity.entry.source,
                        name: d.movie.name, origin: d.movie.originName,
                        year: d.movie.year,
                        tmdbId: d.movie.tmdbId)
                    if let kk = alts.first(where: { $0.code == Providers.KK }),
                       let kd = try? await Providers.detail(kk.code, slug: kk.slug) {
                        tmdbId = kd.movie.tmdbId
                        imdbId = kd.movie.imdbId
                        if tmdbType.isEmpty { tmdbType = kd.movie.tmdbType }
                        if tmdbSeason <= 0 { tmdbSeason = kd.movie.tmdbSeason }
                    }
                }
                if imdbId.isEmpty, !tmdbId.isEmpty {
                    imdbId = await TMDBClient.imdbId(
                        tmdbId: tmdbId, type: tmdbType) ?? ""
                }
            }
        }
        guard !imdbId.isEmpty else { return [] }

        // Movie vs series for the Torrentio address: the TMDB
        // type when known; with no type on record, a numbered
        // episode inside a multi-episode detail reads as a
        // series (a movie's "Full" never numbers).
        let epNum = Providers.episodeNumber(identity.entry.ep)
        let episodeCount = d.servers.reduce(0) { $0 + $1.episodes.count }
        let isSeries = tmdbType == "tv"
            || (tmdbType.isEmpty && epNum >= 1 && episodeCount > 1)
        let streamId: String
        if isSeries {
            // Season: an explicit marker in the episode name
            // wins; else the detail's TMDB season (the house
            // rule — TpClient addresses CacheVideo the same
            // way); else 1.
            let season = Providers.seasonNumber(identity.entry.ep)
                ?? (tmdbSeason > 0 ? tmdbSeason : 1)
            streamId = "\(imdbId):\(season):\(max(epNum, 1))"
        } else {
            streamId = imdbId
        }
        // Gate round 3 (C3-1): the primary fetch is
        // fail-soft to an empty list — NOT a guard —
        // because the user addon's streams below must
        // join even when Torrentio has nothing for this
        // title: that is precisely the case a backup
        // link exists for. The merged list's own
        // emptiness gate (the `usable` guard below) is
        // the only one.
        let primary = (try? await TorrentClient.fetchStreams(
            addonBase: base, type: isSeries ? "series" : "movie",
            id: streamId)) ?? []
        var streams = primary
        // v2.0.45 (leg 3): the user addon's streams for
        // this same title join the rung as backup
        // candidates — the design's merge point for a
        // matched Phim title (the addon's base joins the
        // per-title stream fetch beside Torrentio /
        // MediaFusion), independently of the primary's
        // outcome. Fail-soft: an addon failure or empty
        // answer changes nothing.
        if let addonBase = TorrentSettings.userAddonBase {
            // Awaited hop (gate round 6, A6-1): the
            // store is @MainActor and this builder is a
            // nonisolated async context (the director's
            // fallbackCandidates closure type carries no
            // isolation) — the name is read THROUGH the
            // hop, never synchronously (the A3-1 rule).
            let addonName = await JoeAddonStore.shared.addonName
            let extra = (try? await TorrentClient.fetchStreams(
                addonBase: addonBase,
                type: isSeries ? "series" : "movie", id: streamId,
                gateway: addonName.isEmpty ? "ADDON" : addonName)) ?? []
            streams += extra
        }
        let usable = highQualityOnly
            ? streams.filter { $0.isHighQualityRelease }
            : streams
        guard !usable.isEmpty else { return [] }
        // The shared builder: Torrentio's own top-ranked stream
        // leads (and earns the one RD resolution if it is a
        // bare hash), the B-5 container rule filters, and the
        // "Torrent" prefix tells the owner which source family
        // is playing in the player's status capsule.
        return await TorrentClient.playCandidates(
            streams: usable, preferred: nil, labelPrefix: "Torrent")
    }
}

/// Shared state for load()'s first-open cache/network race
/// (v2.0.8, Phase 2). Both racers run on the main actor, so
/// the flags are only ever touched between awaits; the box
/// exists because the cache racer is an escaping Task
/// closure and needs a reference to write back through.
/// `networkPainted` flips the moment the fetch lands (win or
/// lose the paint decision, the fetch has spoken);
/// `cachedPaint` records the payload the cache racer
/// actually painted, for the fingerprint comparison and the
/// failure path.
/// Swift 6: @unchecked Sendable is justified by that same
/// construction — the box is created inside load() (a view
/// task, main actor) and is only ever touched by load()
/// itself and its child cache Task, which inherits the
/// main actor; no other task, queue or thread can reach
/// it, so the flags can never be touched concurrently.
private final class DetailLoadRace: @unchecked Sendable {
    var cachedPaint: Detail?
    var networkPainted = false
}

/// v2.0.33 (item 3): one Detail the TVB probe fetched
/// and identity-gated for a playable holder, kept under
/// that holder's slug so load()'s switch path can paint
/// it without refetching (see tvbPlayableHolders and
/// tvbKeptDetails). A plain Sendable value — Detail,
/// Movie, Server and Episode are all Sendable value
/// types, so a kept Detail can be returned from the
/// probe's task-group children with no unchecked
/// conformance.
private struct TVBKeptDetail: Sendable {
    var slug: String
    var detail: Detail
}

/// v2.0.33 (item 3): the TVB probe's whole result —
/// `playable` is the I1 verdict exactly as the probe
/// has always produced it (the set the alternatives
/// ordering and the auto-pick condition consume), and
/// `kept` carries the fetched Detail of every playable
/// holder OTHER than the current one (whose detail is
/// already on screen), keyed by provider code.
private struct TVBProbeOutcome: Sendable {
    var playable: Set<String> = []
    var kept: [String: TVBKeptDetail] = [:]
}

/// First-call flag for makeDirector's resolveLadder closure
/// (v2.0.8, Phase 3): reference type because the escaping
/// closure must mutate it across invocations. `consumed`
/// flips on the first origin-identity invocation; every
/// later invocation fetches its detail fresh.
/// Swift 6: @unchecked Sendable is justified by the lock,
/// not by invocation serialisation. The earlier claim on
/// file — that PlayDirector awaits each ladder invocation
/// to completion before issuing the next — is FALSE:
/// PlayDirector.failoverStep() runs a hedged pair, two
/// concurrent tasks awaiting the same resolveLadder
/// closure at once, so two invocations CAN reach this
/// flag simultaneously. The flag is therefore only ever
/// touched through the box's NSLock, and the test-and-set
/// is a single atomic claim(): exactly one invocation —
/// the first origin-identity one — is told it may serve
/// the on-screen detail; every other invocation fetches
/// fresh, whichever executor the closure body runs on.
private final class LadderFirstCallBox: @unchecked Sendable {
    private let lock = NSLock()
    private var consumed = false

    /// Atomically test-and-set: true exactly once, for
    /// the first caller; false for every later caller.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if consumed { return false }
        consumed = true
        return true
    }
}
