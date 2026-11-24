import SwiftUI

/// Trang chủ — its OWN screen (owner ruling 2026-11-22
/// 11:41 CST: "Trang home của app ko phải của tvb" /
/// "Không phải trang home của bất kỳ tab nào";
/// RECALC-SPEC §3.1; DESIGN-PASS-214 §1g). The Home
/// drawing (11 rails) is a composition of its own, and
/// since FIX-214 this file carries it as one: an
/// independent copy of the proven home core with every
/// screen branch resolved to the Trang chủ arm — its own
/// @State / @FocusState instances, its own hero state
/// machine and focus memory, its own DiagLog surface
/// ("trangchu-home"). It is NOT a wrapper over the Phim
/// screen and shares no page core with JoePhimHomeCore;
/// the atoms both screens legitimately share (the hero
/// resolved types, the rail specs, the card views) are
/// file-scope types in JoePhimHome.swift. The two
/// compositions evolve independently from here — a fix
/// that must land on both is a sweep item, recorded in
/// SWEEP-VERIFY-214.

struct JoeHomeScreen: View {
    // FIX-214 (DESIGN-PASS-214 §1g): NO screen identity
    // and NO branches — this struct IS Trang chủ, its own
    // composition with its own @State / @FocusState (its
    // own hero state machine and focus memory), built as
    // an independent copy of the proven home core with
    // every screen branch resolved to the Trang chủ arm.
    // It is not a wrapper over the Phim screen and shares
    // no page core with it; the shared atoms (the hero
    // resolved types, the rail specs, the card views)
    // live at file scope in JoePhimHome.swift.

    @EnvironmentObject private var watch: WatchStore
    @EnvironmentObject private var nav: JoeNavigator
    @EnvironmentObject private var phim: PhimStore
    @Environment(\.joeTheme) private var theme
    /// IDEA 7a: the follow store (singleton) — observed so the
    /// "Đang theo dõi" rail and its new-episode badges re-render
    /// the moment the followed list or its counts change.
    @ObservedObject private var followStore = FollowStore.shared
    /// FL-352 (2.0.45, leg 5): the TVB catalogue store —
    /// observed so the TVB Continue Watching rail below
    /// can resolve each row's poster by pid (the YT rows
    /// themselves carry no poster).
    @ObservedObject private var ytStore = JoeYtStore.shared
    /// v2.0.45 (leg 3): the user addon's library store —
    /// observed so its section below renders the moment
    /// the rails land.
    @ObservedObject private var addonStore = JoeAddonStore.shared
    // v2.0.8 (Phase 1 — focus memory): these seven @FocusState
    // values are the home's focus MEMORY and nothing else. The
    // engine writes them as focus moves; the move handlers
    // that used to write landings are retired, and nothing
    // resets them: this file has no .onAppear, its two .task
    // blocks write only `attempted` / catalogue state and
    // heroDetail / heroBackdropURL, and the root presents the
    // detail as a ZStack overlay over this still-living view —
    // so the card the owner left is the card focus returns to
    // when the detail closes. The .focused bindings below are
    // what keep each card's identity stable for that return.
    // ONE sanctioned write remains: the browse layer SWAPS
    // this home out of the tree (it is not an overlay), so on
    // browse close the browse-return observer in `body` writes
    // the invoking browse entry's state back (F5 restoration —
    // see browseReturnTarget).
    @FocusState private var focusedMovie: Movie.ID?
    @FocusState private var focusedEntry: String?
    @FocusState private var headerFocused: Bool
    @FocusState private var heroPlayFocused: Bool
    @FocusState private var heroBrowseFocused: Bool
    /// v2.1.1 (WS-B): focus memory for the Private Cinema
    /// hero's second action ("ⓘ Thông tin phim") — the PC
    /// hero's pair is Chọn nguồn phát + Thông tin phim, so the
    /// browse button's state no longer has a PC hero user;
    /// it still serves the A/F heroes exactly as before.
    @FocusState private var heroInfoFocused: Bool
    @FocusState private var bandFocused: String?
    @FocusState private var retryFocused: Bool
    /// v2.0.8 (Phase 5/F5): which of this home's three browse
    /// entries opened the browse layer — the hero's "Tất cả
    /// phim" button, the slim header's "Tất cả phim" button, or
    /// a source band's "Xem tất cả ›" (by rail scope). Recorded
    /// in the entry's own action, consumed by the browse-close
    /// observer in `body`, which restores focus to exactly
    /// that entry. (Design F's slim-header entry was already
    /// the .defaultFocus landing; the hero's entry and the
    /// band entries were not — returning from browse landed on
    /// Play / the header button instead of the invoking box.)
    @State private var browseReturnTarget: BrowseReturnTarget?
    private enum BrowseReturnTarget {
        case heroBrowse
        case header
        case band(String)
    }
    /// Team 4 fix-round minor: the state surfaces (G3/G5) are
    /// gated on "a load has been attempted" so they cannot flash
    /// for a frame at cold entry, before the first loadIfNeeded
    /// has even run (at that instant loading == false and the
    /// catalogue is trivially empty).
    @State private var attempted = false
    @State private var exitConfirm = false
    /// v2.0.49 (item 7, fix round): bumped by the root
    /// Menu handler to make the rail/Ultra homes'
    /// ScrollViewReaders jump to the top of the page
    /// (owner order 2026-11-21).
    @State private var topScrollSignal = 0
    /// UI-6 defect D-2: the featured film's DETAIL, fetched
    /// fail-soft for the hero's synopsis (the list payloads
    /// carry no synopsis) and as the fallback source for the
    /// meta fields a sparse list item left empty.
    @State private var heroDetail: Detail?
    /// Hero forensics fix (2026-11-15): the featured film's
    /// TMDB w1280 backdrop URL, resolved by the hero task.
    /// The list thumb cannot be the hero's only art source —
    /// for many KK titles it is a 780×438 marketing composite
    /// with the title logo baked into the art, and no window
    /// of it reads as a backdrop in the 668-tall hero (the
    /// owner's "hầu như hư hết" photos). The detail screen
    /// already holds the owner's standard — TMDB backdrop
    /// first, provider art as fallback; the hero now mirrors
    /// it (see the stage stack in `hero`).
    @State private var heroBackdropURL: URL?
    /// Ultra hero (v2.0.19): the featured film's TMDB logo
    /// art and vote average, resolved by the same task.
    @State private var heroLogoURL: URL?
    @State private var heroRating: Double = 0
    /// IDEA 5 → FIX-214 (lag package): the in-app Trending
    /// rail's resolved, PLAYABLE movies (TMDB trending/week
    /// order, catalogue-matched) are PhimStore state now
    /// (JoeStores.swift, `trendingMovies`) — the view @State
    /// copy died with the view at every section switch and
    /// re-ran the pipeline unthrottled on every enter. The
    /// rail renders only when the store's copy is non-empty,
    /// so an unmatched trending title can never surface as
    /// a dead card.
    /// v2.1.1 (WS-H): the torrent home's store — a root
    /// environment object (JoeTVApp) — observed ONLY for
    /// the Private Cinema home's torrent-provider rails
    /// (design rails 9–11); no other arm reads it.
    @EnvironmentObject private var torStore: TorHomeStore
    /// v2.1.1 (WS-H): the TVB bundled catalogue, loaded
    /// once for the PC home's two TVB rails (design rails
    /// 7–8: dangHot / moiCapNhat). PC-only state; the
    /// by-id map is built once at load, like JoeTVBView's.
    @State private var pcTVBCatalog: TVBCatalog?
    @State private var pcTVBById: [Int: TVBTitle] = [:]
    /// v2.1.1 (WS-I): the Private Cinema home's
    /// focus-follows-backdrop controller (the shared
    /// JoeCinemaBackdropController, JoePrivateCinema
    /// .swift). PC-only: seeded with the featured item,
    /// then fed by cinemaHeroFocusMoved() from the SAME
    /// focusedMovie / focusedEntry focus memory the
    /// context strip derives from — no second tracker.
    @StateObject private var cinemaBackdrop =
        JoeCinemaBackdropController()
    /// v2.1.1 (WS-I): the last hero resolved from an
    /// ACTUAL card focus. When focus leaves the cards
    /// for the hero's own action buttons (or the
    /// header), focusedMovie / focusedEntry read nil —
    /// the hero must NOT snap back to the featured
    /// title in that transaction, or its two actions
    /// would lose the focused title they exist to open
    /// (the spec: hero actions target the FOCUSED title
    /// once focus has moved). cinemaHeroFocusMoved
    /// maintains this; the hero text renders it whenever
    /// no card is focused.
    @State private var cinemaHeroMemory: CinemaHeroResolved?

    /// v2.1.1 (FIX-10a / RECON-POWERMAX point 6): the
    /// context strip's memory — the last RESOLVED strip
    /// tuple, recorded in cinemaHeroFocusMoved while a
    /// card is focused. When focus moves up to the tab
    /// bar (no card focused) the strip RETAINS this
    /// context instead of resetting to the featured
    /// title; nil before any card has ever been focused
    /// (the featured/rest behaviour is unchanged).
    @State private var cinemaStripMemory: (title: String, meta: String, railName: String, railLine: String)?

    var body: some View {
        Group {
            if nav.searchOpen {
                JoeSearchView()
            } else if theme.id == .posterWall {
                // v2.0.11: theme D's wall stays mounted and
                // switches between its home shelves and the
                // "Tất cả phim" panel on nav.browseOpen
                // internally (see JoeWallHomeView in
                // JoeBrowse.swift), so the posterWall branch
                // must win over the browse branch — with the
                // old order, opening the panel in D would swap
                // in the A/F browse surface instead. For A/F
                // nothing changes: their posterWall check is
                // false and the browse branch follows as before.
                JoeWallHomeView(exitConfirm: $exitConfirm)
            } else if nav.browseOpen {
                JoeBrowseView()
            } else if theme.id == .ultra {
                ultraHome
            } else if theme.id == .privateCinema {
                // v2.1.0 (Private Cinema): the cinema home —
                // after the ultra arm, before the railHome
                // fallback; the posterWall-first and browse
                // arms above are unchanged.
                cinemaHome
            } else {
                railHome
            }
        }
        .task {
            attempted = true
            phim.loadIfNeeded()
        }
        // IDEA 5 → FIX-214: the Trending rail load is
        // PhimStore.loadTrendingIfNeeded, ridden by the
        // loadIfNeeded call in the .task above (store
        // state, 900 s attempt throttle — no per-appearance
        // re-run).
        // v2.1.1 (WS-H): PC-only data offers — the TVB
        // bundled catalogue for the PC home's TVB rails and
        // the torrent store's load for its provider rails.
        // Guarded on the PC theme so every other arm's
        // launch path is byte-for-byte what it was.
        .task {
            guard theme.id == .privateCinema else { return }
            torStore.loadIfNeeded()
            if pcTVBCatalog == nil {
                let loaded = await Task.detached(priority: .userInitiated) {
                    TVBCatalogStore.load()
                }.value
                if let loaded {
                    pcTVBCatalog = loaded
                    pcTVBById = Dictionary(
                        uniqueKeysWithValues: loaded.titles
                            .filter { $0.isDisplayed }
                            .map { ($0.tmdbId, $0) })
                }
            }
        }
        // v2.0.45 (leg 3): offer the addon store its load
        // until it takes — the matcher runs against the
        // app catalogues, which may still be filling when
        // this view first appears (the store refuses to
        // latch on an empty movie pool). Bounded: ~40
        // offers over ~2 minutes, then the section simply
        // stays absent this appearance.
        .task {
            var tries = 0
            while !Task.isCancelled && addonStore.hasAddon
                    && !addonStore.loaded && tries < 40 {
                ytStore.ensureLoaded()
                addonStore.ensureLoaded(
                    phim: phim,
                    tvbSeries: ytStore.snapshot?.series ?? [])
                if addonStore.loaded { break }
                tries += 1
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        // CONVERGENCE (spec item 3, 2026-11-15): no programmatic
        // focus writes on the launch path. DOWN from the pills
        // lands on the home's top element geometrically.
        //
        // EXIT DIALOG (UI-5, handler #8 of the 8 in
        // JoeTV/*.swift — the compiled target also carries the
        // shared TV player's own cover handler in
        // DaBanhTV/TVPlayerView.swift:47; inventory wording per
        // UI-7 F-3 / APPLE-CONFORMANCE G-EXIT-2): always
        // installed on the Phim section root; the state check
        // lives INSIDE the closure, so the handler's
        // installation never depends on any state (the D4-safe
        // shape). Search has its own nearer handler while it is
        // open; details and the player are nearer still.
        .onExitCommand {
            if nav.browseOpen {
                nav.browseOpen = false
            } else if !nav.searchOpen {
                // v2.0.49 (item 7, fix round — owner order
                // 2026-11-21 22:32): Menu jumps straight
                // to the top of the page first. This jump
                // covers the rail and Ultra homes, whose
                // ScrollViews live in this file; focus on
                // either home's declared top element (the
                // hero's Play button, or the slim header's
                // browse button when no hero is on screen)
                // keeps the existing exit confirmation.
                // Anywhere deeper, Menu scrolls to the top
                // and lands focus on that top element,
                // swallowing the exit. (The poster-wall
                // home is a separate view — JoeWallHomeView
                // — which since fix round 2 carries its
                // own nearer Menu handler and reader, with
                // this view's exit confirmation bound into
                // it, so this branch serves the rail/Ultra
                // homes; a press that still reaches this
                // handler under the poster-wall theme
                // keeps the confirmation.)
                if theme.id != .posterWall
                    && !heroPlayFocused && !heroBrowseFocused
                    && !heroInfoFocused
                    && !headerFocused {
                    if heroMovie != nil {
                        topScrollSignal += 1
                        heroPlayFocused = true
                    } else if theme.id == .privateCinema {
                        // GATE-213 R6 Lens 2 F3: under
                        // Private Cinema with no hero on
                        // screen (the loading / error /
                        // empty states), $headerFocused is
                        // bound only by slimHeader's browse
                        // button, which never renders under
                        // PC — writing it made this press
                        // visibly dead, and only the SECOND
                        // press (the flag now reading true)
                        // reached the exit confirmation.
                        // Fall through to that confirmation
                        // on the first press.
                        exitConfirm = true
                    } else {
                        topScrollSignal += 1
                        headerFocused = true
                    }
                } else {
                    exitConfirm = true
                }
            }
        }
        // v2.0.5 (N3): delivery for the presses this handler
        // cannot see. Exit commands only reach ANCESTORS of
        // the focused view, and the shell's topBar is a
        // sibling of this subtree — a Menu press with focus
        // on a pill never arrives here. JoeRootView's root
        // handler runs the shell state machine for those
        // presses and, when only the exit confirmation
        // remains, sets nav.exitRequested; this observer
        // presents THIS view's one confirmation for it (the
        // root never grows a second alert). The state checks
        // mirror the handler above exactly.
        .onChange(of: nav.exitRequested) { _, requested in
            guard requested else { return }
            nav.exitRequested = false
            if nav.browseOpen {
                nav.browseOpen = false
            } else if !nav.searchOpen {
                exitConfirm = true
            }
        }
        // v2.0.8 (Phase 5/F5): browse-return focus restoration.
        // The browse layer swaps this home out of the tree, so
        // the persisting-@FocusState return the detail overlay
        // gets for free does not happen here — without this
        // write, focus re-enters at the home's .defaultFocus
        // (the hero's Play button, or the slim header's browse
        // button), not at the entry that opened browse. On the
        // true→false transition, restore focus to the recorded
        // invoking entry (browseReturnTarget). The guards keep
        // the write honest: it fires only when the home is
        // actually coming back on screen (Phim section current,
        // search not open) — a browse closed as a side effect
        // of leaving the section restores nothing. This is a
        // restoration write on layer close, not a landing
        // write on appear; it changes no structure (law D4).
        .onChange(of: nav.browseOpen) { wasOpen, isOpen in
            guard wasOpen, !isOpen else { return }
            let target = browseReturnTarget
            browseReturnTarget = nil
            // FIX-213 (Fault 13): the browse surface is
            // hosted by this view under BOTH the Trang
            // chủ and Phim sections since the split.
            guard let target, nav.section == .phim || nav.section == .home,
                  !nav.searchOpen else { return }
            switch target {
            case .heroBrowse:
                heroBrowseFocused = true
            case .header:
                headerFocused = true
            case .band(let scope):
                bandFocused = scope
            }
        }
        .alert("Thoát Joe TV?", isPresented: $exitConfirm) {
            Button("Thoát", role: .destructive) {
                exitConfirm = false
                DispatchQueue.main.async { exit(0) }
            }
            Button("Ở lại", role: .cancel) { }
        } message: {
            Text("Phim đang xem dở vẫn được lưu lại cho lần mở sau.")
        }
    }

    // MARK: - Rail home (designs A and F)

    private var railHome: some View {
        // v2.0.49 (item 7, fix round): the ScrollView sits
        // inside a ScrollViewReader so Menu can jump
        // straight to the top of the page (see the root
        // .onExitCommand).
        ScrollViewReader { proxy in
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 40) {
                if theme.id == .billboard {
                    if heroMovie != nil {
                        hero
                    } else {
                        slimHeader
                    }
                } else {
                    slimHeader
                }
                cwRail
                tvbCwRail
                favRail
                followRail
                addonSection
                ForEach(railSpecs) { spec in
                    if !spec.movies.isEmpty {
                        if let band = spec.bandName {
                            bandHeader(name: band, note: spec.bandNote ?? "", scope: spec.scope)
                        }
                        if spec.scope.hasPrefix("fileTrending:") {
                            fileTrendingRail(spec)
                        } else {
                            movieRail(spec.title, spec.movies, badges: spec.badges, scope: spec.scope)
                        }
                    }
                }
                // §8/G1: the spinner exists only while a load
                // is running, nothing has landed, and the 20 s
                // store deadline has not fired — never longer.
                if catalogueEmpty && phim.loading && !phim.loadTimedOut {
                    ProgressView("Đang tải thư viện phim…")
                        .font(.system(size: 29))
                        .foregroundStyle(theme.text)
                        .tint(theme.text)
                        .padding(.top, 30)
                }
                // §8/G3 + C-8 + BLOCK-2: the error surface
                // shows ONLY when no catalogue rail has data
                // (never under healthy rails), and only in
                // Team 4's two failure states — the deadline
                // fired, or the load ended with real provider
                // errors. An all-empty SUCCESS is G5 below,
                // not an error (spec-wins ruling (d)).
                if showPhimError {
                    errorSurface
                }
                // §8/G5: every provider answered, nothing
                // failed, the catalogue is simply empty —
                // message only, no spinner, no Retry.
                if showPhimEmpty {
                    Text("Thư viện chưa có dữ liệu.")
                        .font(.system(size: 29))
                        .foregroundStyle(theme.meta)
                        .padding(.top, 30)
                }
                // §8/G4: partial failure — content renders,
                // one non-focusable warning line at the very
                // bottom names the providers with no content.
                if phim.hasData && !failedProviders.isEmpty {
                    Text("Chưa tải được: " + failedProviders.joined(separator: ", "))
                        .font(.system(size: 25))
                        .foregroundStyle(.orange)
                }
            }
            .id("joePhimHomeTop")
        }
        // v2.0.49 (item 7, fix round): the Menu-to-top
        // jump's scroll hook, inside the reader.
        .onChange(of: topScrollSignal) { _, _ in
            proxy.scrollTo("joePhimHomeTop", anchor: .top)
        }
        }
        // v2.0.8 (Phase 1 — navigation freedom): routing between
        // the header/hero and the rails is FULLY geometric. The
        // first rail's arithmetic .onMoveCommand handler
        // (handleFirstRailMove) is RETIRED: an attached handler
        // owns every direction and swallows the directions it
        // does not declare, which is what trapped movement on a
        // single axis. Every rail is its own .focusSection()
        // (the shared Rail view), so the focus engine's
        // geometric search over the declared sections owns all
        // movement here — the deeper rails' long-standing shape
        // (see the focus-memory note at the @FocusState block),
        // now the whole home's shape.
    }

    // MARK: - Ultra home (v2.0.19 — the Sony Ultra port; v2.0.21 composition fix)

    /// Ultra's home (v2.0.21): the SAME composition as the
    /// proven railHome — a bare vertical ScrollView whose
    /// LazyVStack opens with a self-contained hero BLOCK and
    /// continues with the shared rails; everything below the
    /// hero sits over the root's solid theme.bg. The v2.0.19
    /// shape instead wrapped the page in a ZStack whose first
    /// child was a FIXED full-screen backdrop stack (poster
    /// blurField + thumb blurField + TMDB slice, framed
    /// maxWidth/maxHeight .infinity) behind the ScrollView:
    /// the featured photo stayed pinned behind every rail
    /// while scrolling and washed the whole page (owner clip,
    /// 2026-11-17). The backdrop now lives INSIDE the hero
    /// block, clipped to the block, and scrolls away with
    /// it — design A's hero discipline, Ultra's art direction
    /// (600 stage, its own two scrims, logo-first text column)
    /// unchanged.
    private var ultraHome: some View {
        // v2.0.49 (item 7, fix round): the ScrollView sits
        // inside a ScrollViewReader so Menu can jump
        // straight to the top of the page (see the root
        // .onExitCommand).
        ScrollViewReader { proxy in
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 40) {
                if heroMovie != nil {
                    ultraHeroBlock
                } else {
                    slimHeader
                }
                cwRail
                tvbCwRail
                favRail
                followRail
                addonSection
                ForEach(railSpecs) { spec in
                    if !spec.movies.isEmpty {
                        if let band = spec.bandName {
                            bandHeader(name: band, note: spec.bandNote ?? "", scope: spec.scope)
                        }
                        if spec.scope.hasPrefix("fileTrending:") {
                            fileTrendingRail(spec)
                        } else {
                            movieRail(spec.title, spec.movies, badges: spec.badges, scope: spec.scope)
                        }
                    }
                }
                if catalogueEmpty && phim.loading && !phim.loadTimedOut {
                    ProgressView("Đang tải thư viện phim…")
                        .font(.system(size: 29))
                        .foregroundStyle(theme.text)
                        .tint(theme.text)
                        .padding(.top, 30)
                }
                if showPhimError {
                    errorSurface
                }
                if showPhimEmpty {
                    Text("Thư viện chưa có dữ liệu.")
                        .font(.system(size: 29))
                        .foregroundStyle(theme.meta)
                        .padding(.top, 30)
                }
                if phim.hasData && !failedProviders.isEmpty {
                    Text("Chưa tải được: " + failedProviders.joined(separator: ", "))
                        .font(.system(size: 25))
                        .foregroundStyle(.orange)
                }
            }
            .id("joePhimHomeTop")
        }
        // v2.0.49 (item 7, fix round): the Menu-to-top
        // jump's scroll hook, inside the reader.
        .onChange(of: topScrollSignal) { _, _ in
            proxy.scrollTo("joePhimHomeTop", anchor: .top)
        }
        }
    }

    // MARK: - Private Cinema home (v2.1.0)

    /// Private Cinema's home (v2.1.0): ultraHome's composition
    /// mirrored exactly — a bare vertical ScrollView inside a
    /// ScrollViewReader (the same Menu-to-top participation as
    /// ultraHome: the root .onExitCommand bumps topScrollSignal
    /// and this reader's hook below scrolls to the page top;
    /// focus lands on the hero's Play button via heroPlayFocused,
    /// or the slim header's button via headerFocused, exactly as
    /// on the other homes) — opening with the cinema hero block
    /// (or slimHeader when there is no featured film), then the
    /// Trending rail directly under the hero, then the shared
    /// owner rails and the catalogue rails as the provisional
    /// stack (cinemaRailStack). Loading / error / empty tails
    /// are ultraHome's, verbatim.
    private var cinemaHome: some View {
        ScrollViewReader { proxy in
        ScrollView(.vertical, showsIndicators: false) {
            // v2.1.1 (WS-H): the Many-Rails composition —
            // the hero stays the scroll's first element;
            // the rails move into a Section whose header is
            // the 88 px context strip, pinned by the OS
            // (pinnedViews: [.sectionHeaders]) once the
            // scroll passes it, so from the second rail
            // onward the strip rides under the shell's
            // fixed tab bar exactly as the design draws.
            // No scroll-offset APIs are used anywhere.
            LazyVStack(alignment: .leading, spacing: 8,
                       pinnedViews: [.sectionHeaders]) {
                if heroMovie != nil {
                    cinemaHeroBlock
                } else if theme.id != .privateCinema {
                    slimHeader
                }
                // GATE-213 R3 Lens 3 Finding 4: under
                // Private Cinema the no-hero state renders
                // NO substitute header — slimHeader is the
                // legacy Design-F chrome (system 44 heavy +
                // browse button) and the drawing set has
                // no such element (§3.1/§3.3: hero + rails
                // only). The rails below render as usual;
                // the hero takes its place when the
                // featured title lands.
                Section {
                // v2.1.1 (WS-H): below the hero, the home is
                // a discrete ordered array of rail builders
                // (cinemaRailStack) in the MANY-RAIL design
                // order. See the note on cinemaRailStack.
                // FIX-213 (Fault 13): the array is the
                // ACTIVE section's — the Phim section
                // renders its own 7-rail stack.
                ForEach(cinemaActiveRailStack, id: \.self) { item in
                    cinemaRailStackItem(item)
                }
                } header: {
                    cinemaContextStrip
                        // claude/opt-2 (FL-427): Ink above the
                        // strip while it is pinned.
                        .joePCPinnedBandCover()
                }
                if catalogueEmpty && phim.loading && !phim.loadTimedOut {
                    ProgressView("Đang tải thư viện phim…")
                        .font(JoePCType.outfit(29))
                        .foregroundStyle(theme.text)
                        .tint(theme.text)
                        .padding(.top, 30)
                }
                if showPhimError {
                    errorSurface
                }
                if showPhimEmpty {
                    Text("Thư viện chưa có dữ liệu.")
                        .font(JoePCType.outfit(29))
                        .foregroundStyle(theme.meta)
                        .padding(.top, 30)
                }
                if phim.hasData && !failedProviders.isEmpty {
                    Text("Chưa tải được: " + failedProviders.joined(separator: ", "))
                        .font(JoePCType.outfit(25))
                        .foregroundStyle(.orange)
                }
            }
            .id("joePhimHomeTop")
            // FIX-213 (Fault 16): the stack rides up by
            // the bar's height to cancel the scroll
            // view's bar-clearance inset (joePCBarInset
            // on the ScrollView below) — rest geometry is
            // unchanged (the hero still paints behind
            // the transparent bar), but the pinned
            // context strip now pins BELOW the bar
            // instead of inside its band.
            .padding(.top, -joePCBarHeight)
            // FIX-213 (Fault 7): the design's library block
            // ends 64 above the frame's bottom edge (spec:
            // library y485 + h531 = 1016 of 1080); the
            // stack previously ended flush, so the last
            // rail sat cut at the frame's bottom.
            .padding(.bottom, 64)
        }
        .joePCBarInset()
        // claude/opt-2 (FL-457): the full-screen backdrop behind
        // the whole page (Private Cinema only; see JoePrivateCinema).
        .joePCPageBackdrop(cinemaBackdrop)
        // v2.1.0 (Private Cinema): the Menu-to-top jump's
        // scroll hook, inside the reader — ultraHome's hook,
        // unchanged.
        .onChange(of: topScrollSignal) { _, _ in
            proxy.scrollTo("joePhimHomeTop", anchor: .top)
        }
        }
        // v2.1.1 (WS-I): focus-follows backdrop — the
        // backdrop leg is driven from the SAME focus
        // memory the context strip reads (focusedMovie /
        // focusedEntry), plus the featured item's own
        // arrivals (the catalogue landing, the hero
        // task's TMDB backdrop). These hooks only call
        // the resolver + the controller's focusChanged
        // (FL-017: the debounce task inside the
        // controller is the only scheduled work).
        .onAppear { cinemaHeroFocusMoved() }
        .onChange(of: focusedMovie) { _, new in
            // FIX-214 (DESIGN-PASS-214 §3.3): the focus
            // breadcrumb for this surface — through
            // 2.1.3 the TVB hook was DiagLog.noteFocus's
            // ONLY caller, so Phim/Home steps produced
            // stalls labelled focus=none (16 of log
            // 17's 42).
            DiagLog.noteFocus(surface: "trangchu-home", key: new)
            cinemaHeroFocusMoved()
        }
        .onChange(of: focusedEntry) { _, new in
            DiagLog.noteFocus(surface: "trangchu-home", key: new)
            cinemaHeroFocusMoved()
        }
        .onChange(of: heroMovie?.id) { _, _ in cinemaHeroFocusMoved() }
        .onChange(of: heroBackdropURL) { _, _ in cinemaHeroFocusMoved() }
    }

    // MARK: - Private Cinema rail stack (v2.1.1, WS-B)

    /// One slot in the Private Cinema home's rail stack.
    /// The stack is a discrete ordered array of these slots
    /// (cinemaRailStack), each rendered by its own named
    /// builder (cinemaRailStackItem), so a later spec can
    /// re-order or re-skin the stack by editing the array
    /// alone — no restructuring of cinemaHome.
    private enum CinemaRailStackItem: Hashable {
        case continueWatching
        case trending
        case providerNewest(String)
        case tvbHot
        case tvbNew
        case torrentProviders
        case tvbContinueWatching
        case favourites
        case following
        case addon
        case catalogue
        /// FIX-213 (Fault 13): the Phim screen's seventh
        /// rail (single movies) — Phim stack only.
        case phimLe
    }

    /// v2.1.1 (WS-H): the MANY-RAIL order (owner-ordered
    /// design amendment, 2026-11-22 02:03 CST) — the
    /// design's 11 rails first: Xem tiếp → Trending →
    /// KKPhim · Mới cập nhật → VSMOV · Mới cập nhật →
    /// Film4K · Mới cập nhật → Tủ Phim · Mới cập nhật →
    /// TVB · Đang được quan tâm → TVB · Mới trong thư
    /// viện → the torrent-provider rails. The app's extra
    /// rails (TVB CW, Favourites, Following, addon, the
    /// remaining catalogue) APPEND after the design's
    /// rails in their existing relative order — never
    /// interleaved, never dropped (WS-H mapping §3).
    private var cinemaRailStack: [CinemaRailStackItem] {
        // FIX-214 (DESIGN-PASS-214 §1d): Favourites moves
        // from position 11 to position 2 — the owner's
        // shelf rides directly under Continue Watching,
        // where a returning viewer looks for it (it was
        // buried below nine catalogue rails). Every other
        // rail keeps its relative order.
        [.continueWatching, .favourites, .trending,
         .providerNewest("kkNew"), .providerNewest("vsNew"),
         .providerNewest("f4kNew"), .providerNewest("tpNew"),
         .tvbHot, .tvbNew, .torrentProviders,
         .tvbContinueWatching, .following,
         .addon, .catalogue]
    }

    /// FIX-213 (Fault 13): the Phim screen's own stack —
    /// the design's seven rails (PhimManyRails): Xem
    /// tiếp → Trending → the four named sources
    /// (KKPhim / VSMOV / Film4K / Tủ Phim · Mới cập
    /// nhật) → Phim lẻ.
    private var cinemaPhimRailStack: [CinemaRailStackItem] {
        // FIX-214 (DESIGN-PASS-214 §1d): the Phim screen
        // gains the Favourites slot it never had, at the
        // same position 2 (the rail itself is the shared
        // favRail; its data widens to kindTor below).
        [.continueWatching, .favourites, .trending,
         .providerNewest("kkNew"), .providerNewest("vsNew"),
         .providerNewest("f4kNew"), .providerNewest("tpNew"),
         .phimLe]
    }

    /// The stack the surface renders: the Phim screen's
    /// own under the Phim section, the Home stack under
    /// Trang chủ (and anywhere else this surface is
    /// hosted).
    private var cinemaActiveRailStack: [CinemaRailStackItem] {
        cinemaRailStack
    }

    /// FIX-213 (Fault 13): the Phim screen's seventh
    /// rail's data — single movies from the first
    /// non-empty movies spec the catalogue load built
    /// (the provider movie shelves / the VN single
    /// shelf, in railSpecs order).
    private var cinemaPhimLeSpec: JoeRailSpec? {
        railSpecs.first {
            ["kkMovies", "f4kMovies", "tpMovies", "vnSingle"].contains($0.scope)
                && !$0.movies.isEmpty
        }
    }

    /// The "Phim lẻ" rail itself, on the PC movie-rail
    /// construction (cinemaMovieRail) under its own
    /// focus scope.
    @ViewBuilder
    private var cinemaPhimLeRail: some View {
        if let spec = cinemaPhimLeSpec {
            cinemaMovieRail(title: "Phim lẻ", movies: spec.movies, scope: "phimLe")
        }
    }

    /// Render one stack slot. Every builder is a named
    /// rail view — this switch adds no rendering of its
    /// own.
    @ViewBuilder
    private func cinemaRailStackItem(_ item: CinemaRailStackItem) -> some View {
        switch item {
        case .continueWatching:
            cinemaCwRail
        case .trending:
            cinemaTrendingStackRail
        case .providerNewest(let scope):
            cinemaProviderStackRail(scope)
        case .tvbHot:
            cinemaTVBStackRail(hot: true)
        case .tvbNew:
            cinemaTVBStackRail(hot: false)
        case .torrentProviders:
            cinemaTorrentStackRails
        // FIX-213 (Fault 7) + GATE-213 R5 Lens 2 F1:
        // the appended slots below are app-extra rails
        // (not in the design's eleven) on the SHARED Rail
        // construction. Since the R4 gate fix the shared
        // Rail carries the design's 94 frame itself under
        // Private Cinema (heading +14 inside, track
        // 94/94 over a −80 bleed) — no wrapper inset is
        // applied here any more (the old +14 wrappers
        // double-inset the slots to 108).
        case .tvbContinueWatching:
            tvbCwRail
        case .favourites:
            favRail
        case .following:
            followRail
        case .addon:
            addonSection
        case .catalogue:
            cinemaCatalogueRails
        case .phimLe:
            cinemaPhimLeRail
        }
    }

    /// The stack's Trending slot: the railSpecs entry whose
    /// scope is "trending" (the TMDB trending/week rail,
    /// catalogue-matched in loadTrending), rendered through
    /// cinemaTrendingRail — design rail 2, directly under
    /// Continue Watching.
    @ViewBuilder
    private var cinemaTrendingStackRail: some View {
        if let railSpec = railSpecs.first(where: { $0.scope == "trending" }),
           !railSpec.movies.isEmpty {
            cinemaTrendingRail(railSpec)
        }
    }

    /// One per-provider "Mới cập nhật" slot (design rails
    /// 3–6): the railSpecs entry for the scope, presented
    /// under the design's provider title and rendered with
    /// the PC local poster card (cinemaMovieRail).
    @ViewBuilder
    private func cinemaProviderStackRail(_ scope: String) -> some View {
        if let railSpec = railSpecs.first(where: { $0.scope == scope }),
           !railSpec.movies.isEmpty {
            cinemaMovieRail(title: cinemaProviderRailTitle(scope),
                            movies: railSpec.movies, scope: scope)
        }
    }

    /// The design's provider rail titles, by scope.
    private func cinemaProviderRailTitle(_ scope: String) -> String {
        switch scope {
        case "kkNew": return "KKPhim · Mới cập nhật"
        case "vsNew": return "VSMOV · Mới cập nhật"
        case "f4kNew": return "Film4K · Mới cập nhật"
        case "tpNew": return "Tủ Phim · Mới cập nhật"
        default: return "Mới cập nhật"
        }
    }

    /// The stack's catalogue slot: every railSpecs entry
    /// EXCEPT the ones with their own design slots above
    /// (trending + the four provider-newest scopes), in
    /// railSpecs order — band headers, the trending file
    /// rails (fileTrendingRail) and the provider / genre /
    /// country rails (movieRail). Appended extras keep the
    /// shared construction (WS-H mapping §3).
    @ViewBuilder
    private var cinemaCatalogueRails: some View {
        ForEach(railSpecs) { railSpec in
            if !railSpec.movies.isEmpty,
               !cinemaDesignScopes.contains(railSpec.scope) {
                if let band = railSpec.bandName {
                    bandHeader(name: band, note: railSpec.bandNote ?? "", scope: railSpec.scope)
                }
                if railSpec.scope.hasPrefix("fileTrending:") {
                    fileTrendingRail(railSpec)
                } else {
                    movieRail(railSpec.title, railSpec.movies, badges: railSpec.badges, scope: railSpec.scope)
                }
            }
        }
    }

    /// The railSpecs scopes that hold design slots 2–6 of
    /// the PC stack (rendered by their own builders above,
    /// so the appended catalogue slot must skip them).
    private var cinemaDesignScopes: Set<String> {
        ["trending", "kkNew", "vsNew", "f4kNew", "tpNew"]
    }

    // MARK: - Private Cinema Many-Rails builders (v2.1.1, WS-H)

    /// The PC rail shell (WS-H): the shared Rail's
    /// construction mirrored (own horizontal ScrollView +
    /// LazyHStack, scrollClipDisabled, .focusSection()) at
    /// the design's rhythm — heading 27 pt medium, card
    /// gap 25, side margin 94 total (the shell's 80 pt
    /// safe area + the 14 pt leading padding here).
    /// Per-card focus identity stays the caller's stable
    /// .focused binding, so the focus engine's per-rail
    /// horizontal memory works exactly as on the shared
    /// rails (WS-H mapping §6).
    private func cinemaRailShell<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(JoePCType.display(27, weight: .medium))
                .tracking(-0.3)
                .foregroundStyle(theme.text)
                // FIX-213 (Fault 7): the heading keeps the
                // design's 94 pt inset (the shell's 80 +
                // 14 here); the card track below now OWNS
                // the design's frame instead of borrowing
                // the ambient inset.
                .padding(.leading, 14)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 25) { content() }
                    // FIX-213 (Fault 7): the design's rail
                    // track spans the full 1920 width (spec
                    // track padding "16px 94px 11px"): the
                    // first card rests at exactly x94, the
                    // last card's rest position ends 94
                    // short of the right edge, and scrolled
                    // cards paint to both bezels, as drawn.
                    // The ScrollView bleeds across the
                    // shell's 80 pt ambient inset (the
                    // negative padding below cancels it
                    // exactly), so these insets are the
                    // design's own 94 / 94.
                    .padding(.leading, 94)
                    .padding(.trailing, 94)
                    // FIX-4 / C5 + FIX-213 (Fault 14): the
                    // design's vertical track air is the
                    // SUM of its track padding (16 top /
                    // 11 bottom) and its row padding
                    // (8 top / 9 bottom) — with both, the
                    // design's own numbers reproduce its
                    // measured rows exactly (poster row
                    // 395, landscape row 312). The build
                    // carried only the row padding, which
                    // compressed every rail by ~26 and
                    // made the theme read cramped (owner
                    // 2026-11-22: "Cách làm làm chật chội
                    // hẳn cái theme").
                    .padding(.top, 24)
                    .padding(.bottom, 20)
            }
            .scrollClipDisabled()
            .padding(.horizontal, -80)
        }
        .focusSection()
    }

    /// Design rail 1 (WS-H): Continue Watching FIRST, as
    /// landscape cards 320×180 with progress bars; the
    /// rail's total height is the design's 312 (heading +
    /// 180 art + title/subline lines + the shell's
    /// vertical padding). Data + tap + context menu are
    /// cwRail's own (movieProgress); only the PC card is
    /// local (JoeCinemaCwCard).
    @ViewBuilder
    private var cinemaCwRail: some View {
        if !movieProgress.isEmpty {
            cinemaRailShell(title: "Xem tiếp") {
                ForEach(movieProgress) { entry in
                    Button { nav.movie = MovieRoute(
                        provider: entry.source, slug: entry.slug,
                        name: entry.title, poster: entry.poster,
                        year: entry.year, preselectEp: entry.ep,
                        tvb: entry.tvbRouteContext) } label: {
                        JoeCinemaCwCard(entry: entry)
                    }
                    .joeCardButton()
                    .focused($focusedEntry, equals: "cw|" + entry.key)
                    .contextMenu {
                        Button(role: .destructive) {
                            watch.removeProgress(key: entry.key)
                        } label: {
                            Text("Xoá khỏi Đang xem dở")
                        }
                    }
                }
            }
        }
    }

    /// A PC poster rail over catalogue movies (design
    /// rails 3–6): the local 205×263 card (JoeCinemaPoster
    /// Card), NO provider badge (the drawing's posters are
    /// bare), the movieRail tap and focus binding verbatim.
    private func cinemaMovieRail(title: String, movies: [Movie],
                                 scope: String) -> some View {
        cinemaRailShell(title: title) {
            ForEach(movies) { movie in
                Button {
                    nav.movie = MovieRoute(
                    provider: movie.provider, slug: movie.slug,
                    name: movie.name, poster: movie.poster, year: movie.year) } label: {
                    JoeCinemaPosterCard(movie: movie)
                }
                .joeCardButton()
                .focused($focusedMovie, equals: scope + "|" + movie.id)
            }
        }
    }

    /// Design rails 7–8 (WS-H): the TVB bundled
    /// catalogue's dangHot ("TVB · Đang được quan tâm")
    /// and moiCapNhat ("TVB · Mới trong thư viện") rails,
    /// resolved through the PC-only catalogue load; the
    /// tap is JoeTVBView.open's own mint (routeTarget).
    @ViewBuilder
    private func cinemaTVBStackRail(hot: Bool) -> some View {
        if let catalog = pcTVBCatalog {
            let ids = hot ? catalog.rails.dangHot : catalog.rails.moiCapNhat
            let titles = ids.compactMap { pcTVBById[$0] }
            if !titles.isEmpty {
                cinemaRailShell(title: hot ? "TVB · Đang được quan tâm"
                                           : "TVB · Mới trong thư viện") {
                    ForEach(titles) { title in
                        Button {
                            if let target = title.routeTarget {
                                nav.movie = MovieRoute(
                                    provider: target.provider, slug: target.slug,
                                    name: title.titleVi, poster: title.posterURLString,
                                    year: title.yearString,
                                    tvb: title.routeContext)
                            }
                        } label: {
                            JoeCinemaTVBCard(title: title)
                        }
                        .joeCardButton()
                        .focused($focusedMovie,
                                 equals: (hot ? "tvbHot|" : "tvbNew|") + "\(title.tmdbId)")
                    }
                }
            }
        }
    }

    /// Design rails 9–11 (WS-H): the torrent-provider
    /// rails — the first three TorHomeStore catalogues
    /// with landed rails, in store order, each under its
    /// catalogue's own name; the tap is the torrent
    /// home's own TorRoute mint.
    @ViewBuilder
    private var cinemaTorrentStackRails: some View {
        ForEach(Array(cinemaTorrentCatalogs.enumerated()), id: \.offset) { _, cat in
            if let metas = torStore.rails[cat.id + "|" + cat.type], !metas.isEmpty {
                cinemaRailShell(title: cat.name) {
                    ForEach(metas) { meta in
                        Button { nav.tor = TorRoute(meta: meta, base: cat.base) } label: {
                            JoeCinemaTorCard(meta: meta)
                        }
                        .joeCardButton()
                        .focused($focusedMovie,
                                 equals: "torCat:\(cat.id)|\(cat.type)|" + meta.id)
                    }
                }
            }
        }
    }

    /// The first three landed torrent catalogues (design
    /// rails 9–11's feeders).
    private var cinemaTorrentCatalogs: [TorCatalog] {
        Array(torStore.catalogs.filter {
            !(torStore.rails[$0.id + "|" + $0.type]?.isEmpty ?? true)
        }.prefix(3))
    }

    // MARK: - Private Cinema context strip (v2.1.1, WS-H)

    /// The 88 px context strip (WS-H): the Section header
    /// the OS pins once the hero scrolls away — title ·
    /// year · duration · source rail name · "Dãy NN/TT ·
    /// ↑ để trở lại", derived from the EXISTING focus
    /// memory (the last focused card), falling back to
    /// the hero title at rest. Height 88 pt (FIX-3: the
    /// settled convention is design px = pt 1:1 and the
    /// many-rails spec gives the strip h88 — WS-H's 44 pt
    /// was a ÷2 value), Panel-family bar over the Ink
    /// background so the pinned strip stays legible over
    /// scrolling art.
    private var cinemaContextStrip: some View {
        let info = cinemaContextInfo
        return HStack(alignment: .center, spacing: 14) {
            // FIX-8 / C-R4-2: the drawn composition
            // (delivery-joetv-PhimManyRails-browse.png) —
            // left column: the surface eyebrow in small
            // caps ABOVE the title, the meta riding the
            // title's baseline beside it.
            VStack(alignment: .leading, spacing: 4) {
                // FIX-214 (FULL-THEME-AUDIT-214 B3): the
                // eyebrow names the SCREEN — the Phim
                // screen's strip hard-coded the Trang chủ
                // line (the shared-core fault family).
                Text("TRANG CHỦ / ĐANG KHÁM PHÁ")
                    .font(JoePCType.outfit(15, weight: .medium))
                    .tracking(3.6)
                    .foregroundStyle(theme.heroMeta)
                    .lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    // FIX-4 / C4: the spec's strip title is 34/500.
                    // GATE-213 R1 Lens 3: the family is
                    // Bricolage (RECALC-SPEC §2.3), meta
                    // Outfit 20/400.
                    Text(info.title)
                        .font(JoePCType.display(34, weight: .medium))
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                    if !info.meta.isEmpty {
                        Text(info.meta)
                            .font(JoePCType.outfit(20))
                            .foregroundStyle(theme.meta)
                            .lineLimit(1)
                    }
                }
            }
            .background(alignment: .leading) {
                JoeCinemaStreak()
                    .padding(.vertical, -14)
                    .padding(.leading, -100)
                    .padding(.trailing, -460)
            }
            .background {
                GeometryReader { g in
                    Color.clear
                        .preference(key: JoePCStripTextWidthKey.self, value: g.size.width)
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 14)
        .frame(height: 88)
        .frame(maxWidth: .infinity, alignment: .leading)  // Cach C fix: strip content hugs the left edge (Spacer removed with the right block)
        // claude/opt-2 (owner: glass bar, not a black bar over
        // the full-screen backdrop): JoeCinemaGlass, drawn edge
        // to edge (background only, -80 over the safe-area inset;
        // no layout change).
    }

    /// The strip's content: (title, meta line, rail line)
    /// for the currently focused card, resolved from the
    /// focus-memory values — a catalogue card
    /// ("scope|provider|slug"), a CW/favourite entry
    /// ("cw|key" / "fav|key"), or the hero at rest.
    private var cinemaContextInfo: (title: String, meta: String, railName: String, railLine: String) {
        // claude/opt-2 (FL-447 R1): the visible-rail list is
        // built once here and handed to the position helpers.
        let visibleTitles = cinemaActiveRailTitles
        let total = visibleTitles.count
        if let focusedMovie {
            let parts = focusedMovie.split(separator: "|", maxSplits: 1)
            let scope = parts.isEmpty ? "" : String(parts[0])
            let remainder = parts.count > 1 ? String(parts[1]) : ""
            if let movie = railSpecs.flatMap({ $0.movies })
                .first(where: { $0.id == remainder }) {
                let rail = cinemaRailPosition(ofScope: scope, titles: visibleTitles)
                var meta: [String] = []
                if !movie.year.isEmpty { meta.append(movie.year) }
                if !movie.time.isEmpty { meta.append(movie.time) }
                return (movie.name, meta.joined(separator: " · "),
                        rail.name,
                        "Dãy \(rail.pos) / \(total) · ↑ để trở lại")
            }
            if let title = joePCTVBTitle(forFocus: focusedMovie, in: pcTVBById) {
                let rail = cinemaRailPosition(ofScope: scope, titles: visibleTitles)
                return (title.titleVi, title.cardMeta,
                        rail.name,
                        "Dãy \(rail.pos) / \(total) · ↑ để trở lại")
            }
            if let meta = torStore.rails.values.flatMap({ $0 })
                .first(where: { focusedMovie.hasSuffix("|" + $0.id) }) {
                // FIX-4 / B1: the rail is the focused meta's
                // OWN catalogue (its "torCat:" focus ID),
                // resolved by name in the visible-rail list
                // — never the literal "Torrent".
                let rail = cinemaTorrentRailPosition(forFocusedMovie: focusedMovie, titles: visibleTitles)
                return (meta.name, meta.year,
                        rail.name,
                        "Dãy \(rail.pos) / \(total) · ↑ để trở lại")
            }
            // FIX-5 / Lens B Finding 1: Following-rail cards
            // bind "following|<movie.id>", but followedMovies
            // are FollowStore copies — a followed title need
            // not appear in any catalogue rail above, so it
            // fell through to the hero fallback. Resolve the
            // scope against followedMovies itself (its own
            // entry list, as CW/Favourites do), in the
            // Following branch's position before the hero
            // fallback; cinemaRailPosition already names the
            // "following" scope "Đang theo dõi".
            if scope == "following",
               let movie = followedMovies.first(where: { $0.id == remainder }) {
                let rail = cinemaRailPosition(ofScope: scope, titles: visibleTitles)
                return (movie.name, movie.cardMeta,
                        rail.name,
                        "Dãy \(rail.pos) / \(total) · ↑ để trở lại")
            }
        }
        if let focusedEntry {
            if let entry = movieProgress.first(where: { "cw|" + $0.key == focusedEntry }) {
                let rail = cinemaRailPosition(ofScope: "cw", titles: visibleTitles)
                return (entry.title, entry.epLabel,
                        rail.name,
                        "Dãy \(rail.pos) / \(total) · ↑ để trở lại")
            }
            if let entry = movieFavorites.first(where: { "fav|" + $0.key == focusedEntry }) {
                let rail = cinemaRailPosition(ofScope: "favourites", titles: visibleTitles)
                return (entry.title, entry.year,
                        rail.name,
                        "Dãy \(rail.pos) / \(total) · ↑ để trở lại")
            }
            // FIX-4 / B2: the appended TVB Continue Watching
            // rail binds "tvbcw|<key>" — resolve it to its
            // own rail instead of falling through to the hero.
            if let entry = tvbProgress.first(where: { "tvbcw|" + $0.key == focusedEntry }) {
                let rail = cinemaRailPosition(ofScope: "tvbCw", titles: visibleTitles)
                return (entry.title, entry.epLabel,
                        rail.name,
                        "Dãy \(rail.pos) / \(total) · ↑ để trở lại")
            }
            // FIX-4 / B2: addon rails bind
            // "addon|<rail>|<metaId>" — resolve the meta and
            // its rail's catalogue name.
            if focusedEntry.hasPrefix("addon|"),
               let resolved = cinemaAddonFocus(focusedEntry) {
                return (resolved.meta.name, resolved.meta.year,
                        resolved.railName,
                        "Dãy \(resolved.pos) / \(total) · ↑ để trở lại")
            }
        }
        // FIX-10a / RECON-POWERMAX point 6 (+ Pass-2
        // Lens B F2): no card focused — return the last
        // resolved strip tuple when one exists, so the
        // strip agrees with cinemaHeroMemory (the hero
        // keeps the last focused title in this state).
        // Before any focus ever, memory is nil and the
        // featured/rest behaviour below is unchanged.
        if focusedMovie == nil, focusedEntry == nil,
           let memory = cinemaStripMemory {
            return memory
        }
        if let hero = heroMovie {
            var meta: [String] = []
            if !hero.year.isEmpty { meta.append(hero.year) }
            if !hero.time.isEmpty { meta.append(hero.time) }
            return (hero.name, meta.joined(separator: " · "),
                    "",
                    "Dãy 01 / \(total) · ↑ để trở lại")
        }
        return ("", "", "", "Dãy 01 / \(total) · ↑ để trở lại")
    }

    // MARK: - Focus-follows hero (v2.1.1, WS-I)

    /// Feed the backdrop controller from the current
    /// focus memory (WS-I): called by cinemaHome's
    /// onAppear / onChange hooks ONLY (never in body —
    /// the controller's debounce task is the only work
    /// this schedules, FL-017). A card focus resolves +
    /// remembers the hero; NO card focus keeps the
    /// remembered hero (focus is on the hero's actions
    /// or the header — the hero stays on the last
    /// focused title), except that a remembered FEATURED
    /// hero refreshes when the hero task's enrichment
    /// (TMDB backdrop / detail) lands.
    private func cinemaHeroFocusMoved() {
        if focusedMovie != nil || focusedEntry != nil {
            if let resolved = cinemaHeroResolved() {
                // FIX-12 / R7 B-1: record the strip's
                // resolved tuple ONLY when the hero
                // resolution actually resolved the FOCUSED
                // card (this existing hook only — FL-017;
                // no new per-focus work). The focused
                // branches key the resolved item by the
                // focus ID itself; cinemaHeroResolved()
                // falls back to the FEATURED title when a
                // focused card no longer resolves (a reload
                // removed it), and letting any of the
                // three writes through then would
                // overwrite that memory with the featured
                // tuple. FIX-13 / R8 Lens B B-1: the hero
                // write and the backdrop push are gated on
                // the SAME key test as the strip record, so
                // the hero and strip memories can never
                // disagree — in the fallback case this
                // branch now writes nothing at all and both
                // memories keep the last focused title.
                if resolved.item.key == focusedMovie
                    || resolved.item.key == focusedEntry {
                    cinemaStripMemory = cinemaContextInfo
                    cinemaHeroMemory = resolved
                    cinemaBackdrop.focusChanged(to: resolved.item)
                }
            }
            return
        }
        if let memory = cinemaHeroMemory {
            if case .movie(let remembered, _) = memory.target,
               remembered.id == heroMovie?.id,
               let resolved = cinemaHeroResolved() {
                cinemaHeroMemory = resolved
                cinemaBackdrop.focusChanged(to: resolved.item)
            }
            return
        }
        if let resolved = cinemaHeroResolved() {
            cinemaHeroMemory = resolved
            cinemaBackdrop.focusChanged(to: resolved.item)
        }
    }

    /// The hero the block renders: the live resolution
    /// while a card is focused; the remembered hero once
    /// focus has left the cards (see cinemaHeroMemory);
    /// the featured resolution before either exists.
    private func cinemaHeroDisplayResolved() -> CinemaHeroResolved? {
        if focusedMovie != nil || focusedEntry != nil {
            return cinemaHeroResolved()
        }
        return cinemaHeroMemory ?? cinemaHeroResolved()
    }

    /// The hero for the current focus, resolved from the
    /// SAME focus memory + lookups cinemaContextInfo
    /// uses (its branches, in its order), extended with
    /// each surface's art ladder and tap target:
    ///  - chain titles (Movie): the current hero's own
    ///    backdrop ladder — TMDB backdrop slice first
    ///    (heroBackdropURL, resolved by the hero task —
    ///    the featured title is the only one whose TMDB
    ///    backdrop is resolved, the focus path fetches
    ///    NOTHING), then the provider thumb, then the
    ///    poster;
    ///  - TVB titles: the snapshot's TMDB backdrop path
    ///    at w1280 (the TMDBClient backdrop convention),
    ///    then the title's posterURL (the art its cards
    ///    carry);
    ///  - torrent titles (TorMeta): background, then
    ///    poster;
    ///  - WatchStore entries: the entry's own background,
    ///    then its poster (TVB-CW rows: the YT series'
    ///    poster by pid, as tvbCwRail resolves it);
    ///  - addon metas: background, then poster.
    /// Synopsis comes only from fields the record
    /// carries (the featured detail's content, a
    /// TorMeta/entry desc) — never fetched on focus.
    private func cinemaHeroResolved() -> CinemaHeroResolved? {
        if let focusedMovie {
            let parts = focusedMovie.split(separator: "|", maxSplits: 1)
            let scope = parts.isEmpty ? "" : String(parts[0])
            let remainder = parts.count > 1 ? String(parts[1]) : ""
            if let movie = railSpecs.flatMap({ $0.movies })
                .first(where: { $0.id == remainder }) {
                let isFeatured = movie.id == heroMovie?.id
                let item = JoeCinemaHeroItem(
                    key: focusedMovie,
                    title: movie.name,
                    meta: isFeatured ? cinemaHeroMetaLine(movie)
                        : [movie.year, movie.time]
                            .filter { !$0.isEmpty }
                            .joined(separator: " · "),
                    synopsis: isFeatured
                        ? (heroDetail?.content ?? "") : "",
                    backdropURL: isFeatured
                        ? (heroBackdropURL ?? movie.thumbURL)
                        : movie.thumbURL,
                    posterURL: movie.posterURL)
                if scope.hasPrefix("fileTrending:") {
                    return CinemaHeroResolved(
                        item: item, target: .fileTrending(movie))
                }
                return CinemaHeroResolved(
                    item: item, target: .movie(movie, scope: scope))
            }
            if let title = joePCTVBTitle(forFocus: focusedMovie, in: pcTVBById) {
                return CinemaHeroResolved(
                    item: JoeCinemaHeroItem(
                        key: focusedMovie,
                        title: title.titleVi,
                        meta: title.cardMeta,
                        synopsis: "",
                        backdropURL: title.cinemaBackdropURL,
                        posterURL: title.posterURL),
                    target: .tvb(title))
            }
            if let meta = torStore.rails.values.flatMap({ $0 })
                .first(where: { focusedMovie.hasSuffix("|" + $0.id) }) {
                let base = cinemaTorrentCatalogs.first(where: { cat in
                    torStore.rails[cat.id + "|" + cat.type]?
                        .contains(where: { $0.id == meta.id }) == true
                })?.base ?? TorrentSettings.cinemeta
                return CinemaHeroResolved(
                    item: JoeCinemaHeroItem(
                        key: focusedMovie,
                        title: meta.name,
                        meta: meta.year,
                        synopsis: meta.desc,
                        backdropURL: meta.background.isEmpty
                            ? nil : URL(string: meta.background),
                        posterURL: meta.posterURL),
                    target: .tor(meta, base: base))
            }
            if scope == "following",
               let movie = followedMovies.first(where: { $0.id == remainder }) {
                return CinemaHeroResolved(
                    item: JoeCinemaHeroItem(
                        key: focusedMovie,
                        title: movie.name,
                        meta: [movie.year, movie.time]
                            .filter { !$0.isEmpty }
                            .joined(separator: " · "),
                        synopsis: "",
                        backdropURL: movie.thumbURL,
                        posterURL: movie.posterURL),
                    target: .movie(movie, scope: scope))
            }
        }
        if let focusedEntry {
            if let entry = movieProgress.first(where: { "cw|" + $0.key == focusedEntry }) {
                return CinemaHeroResolved(
                    item: JoeCinemaHeroItem(
                        key: focusedEntry,
                        title: entry.title,
                        meta: entry.epLabel,
                        synopsis: entry.desc,
                        backdropURL: entry.background.isEmpty
                            ? nil : URL(string: entry.background),
                        posterURL: entry.posterURL),
                    target: .movieEntry(entry, preselect: true))
            }
            if let entry = movieFavorites.first(where: { "fav|" + $0.key == focusedEntry }) {
                return CinemaHeroResolved(
                    item: JoeCinemaHeroItem(
                        key: focusedEntry,
                        title: entry.title,
                        meta: entry.year,
                        synopsis: entry.desc,
                        backdropURL: entry.background.isEmpty
                            ? nil : URL(string: entry.background),
                        posterURL: entry.posterURL),
                    target: .movieEntry(entry, preselect: false))
            }
            if let entry = tvbProgress.first(where: { "tvbcw|" + $0.key == focusedEntry }) {
                let poster = entry.posterURL
                    ?? ytStore.snapshot?.byPid[entry.slug]?.posterURL
                return CinemaHeroResolved(
                    item: JoeCinemaHeroItem(
                        key: focusedEntry,
                        title: entry.title,
                        meta: entry.epLabel,
                        synopsis: entry.desc,
                        backdropURL: entry.background.isEmpty
                            ? nil : URL(string: entry.background),
                        posterURL: poster),
                    target: .tvbEntry(entry))
            }
            if focusedEntry.hasPrefix("addon|"),
               let resolved = cinemaAddonFocus(focusedEntry) {
                let meta = resolved.meta
                return CinemaHeroResolved(
                    item: JoeCinemaHeroItem(
                        key: focusedEntry,
                        title: meta.name,
                        meta: meta.year,
                        synopsis: meta.desc,
                        backdropURL: meta.background.isEmpty
                            ? nil : URL(string: meta.background),
                        posterURL: meta.posterURL),
                    target: .addon(meta))
            }
        }
        if let featured = heroMovie {
            return CinemaHeroResolved(
                item: JoeCinemaHeroItem(
                    key: "hero|" + featured.id,
                    title: featured.name,
                    meta: cinemaHeroMetaLine(featured),
                    synopsis: heroDetail?.content ?? "",
                    backdropURL: heroBackdropURL ?? featured.thumbURL,
                    posterURL: featured.posterURL),
                target: .movie(featured, scope: ""))
        }
        return nil
    }

    /// The hero actions' tap (WS-I): perform the focused
    /// title's OWN card tap — the identical route mint
    /// each rail builder above performs, nothing new.
    private func cinemaOpenHeroTarget(_ target: CinemaHeroTarget) {
        switch target {
        case .movie(let movie, let scope):
            if scope == "following" {
                FollowStore.shared.markSeen(provider: movie.provider,
                                            slug: movie.slug)
            }
            nav.movie = MovieRoute(
                provider: movie.provider, slug: movie.slug,
                name: movie.name, poster: movie.poster,
                year: movie.year)
        case .fileTrending(let movie):
            Task { await resolveFileTrendingTap(movie) }
        case .tvb(let title):
            if let route = title.routeTarget {
                nav.movie = MovieRoute(
                    provider: route.provider, slug: route.slug,
                    name: title.titleVi, poster: title.posterURLString,
                    year: title.yearString,
                    tvb: title.routeContext)
            }
        case .tor(let meta, let base):
            nav.tor = TorRoute(meta: meta, base: base)
        case .addon(let meta):
            if let base = addonStore.servingBase {
                nav.addonDetail = JoeAddonRoute(
                    base: base,
                    type: meta.type,
                    metaId: meta.id,
                    name: meta.name,
                    poster: meta.poster,
                    year: meta.year,
                    addonName: addonStore.addonName)
            }
        case .movieEntry(let entry, let preselect):
            if entry.kind == WatchStore.kindTor {
                // FIX-214 (gate R1 Lens 2): a TORRENT
                // favourite reaches the hero through the
                // widened favourites filter (§1d) — its
                // reopen is the TorRoute (TorMeta +
                // reopenBase), exactly as the rail card's
                // own tap mints it; a torrent entry's
                // source/slug are empty by construction,
                // so the MovieRoute below would open a
                // chain detail with no title to load.
                nav.tor = TorRoute(
                    meta: TorMeta(
                        id: entry.metaId, type: entry.metaType,
                        name: entry.title, poster: entry.poster,
                        background: entry.background,
                        year: entry.year, desc: entry.desc,
                        isLive: entry.isLive),
                    base: entry.reopenBase)
            } else {
                nav.movie = MovieRoute(
                    provider: entry.source, slug: entry.slug,
                    name: entry.title, poster: entry.poster,
                    year: entry.year,
                    preselectEp: preselect ? entry.ep : "",
                    tvb: entry.tvbRouteContext)
            }
        case .tvbEntry(let entry):
            nav.ytDetail = JoeYtRoute(pid: entry.slug)
        }
    }

    /// The visible PC rails' titles in stack order — the
    /// strip's NN/TT denominator and the rail-name source.
    /// A rail counts only when it would render (non-empty
    /// data), mirroring each builder's own gate.
    private var cinemaVisibleRailTitles: [String] {
        // claude/opt-2 (FL-447 R1): one railSpecs build per call
        // (it was rebuilt at every read below).
        let specs = railSpecs
        var titles: [String] = []
        if !movieProgress.isEmpty { titles.append("Xem tiếp") }
        if let railSpec = specs.first(where: { $0.scope == "trending" }),
           !railSpec.movies.isEmpty { titles.append("Trending") }
        for scope in ["kkNew", "vsNew", "f4kNew", "tpNew"] {
            if let railSpec = specs.first(where: { $0.scope == scope }),
               !railSpec.movies.isEmpty {
                titles.append(cinemaProviderRailTitle(scope))
            }
        }
        if let catalog = pcTVBCatalog {
            if !catalog.rails.dangHot.compactMap({ pcTVBById[$0] }).isEmpty {
                titles.append("TVB · Đang được quan tâm")
            }
            if !catalog.rails.moiCapNhat.compactMap({ pcTVBById[$0] }).isEmpty {
                titles.append("TVB · Mới trong thư viện")
            }
        }
        for cat in cinemaTorrentCatalogs {
            titles.append(cat.name)
        }
        if !tvbProgress.isEmpty { titles.append("TVB · Đang xem dở") }
        if !movieFavorites.isEmpty { titles.append("Yêu thích") }
        if !followStore.followed.isEmpty { titles.append("Đang theo dõi") }
        for rail in addonStore.rails where !rail.metas.isEmpty {
            titles.append(rail.catalog.name)
        }
        for railSpec in specs
        where !railSpec.movies.isEmpty && !cinemaDesignScopes.contains(railSpec.scope) {
            titles.append(railSpec.title)
        }
        return titles
    }

    /// FIX-213 (Fault 13): the Phim screen's visible
    /// rails, mirroring cinemaPhimRailStack's builders'
    /// own gates — the strip's denominator and the
    /// tagline's count while the Phim section is active.
    private var cinemaPhimVisibleRailTitles: [String] {
        // claude/opt-2 (FL-447 R1): one railSpecs build per call
        // (it was rebuilt at every read below).
        let specs = railSpecs
        var titles: [String] = []
        if !movieProgress.isEmpty { titles.append("Xem tiếp") }
        if let railSpec = specs.first(where: { $0.scope == "trending" }),
           !railSpec.movies.isEmpty { titles.append("Trending") }
        for scope in ["kkNew", "vsNew", "f4kNew", "tpNew"] {
            if let railSpec = specs.first(where: { $0.scope == scope }),
               !railSpec.movies.isEmpty {
                titles.append(cinemaProviderRailTitle(scope))
            }
        }
        if cinemaPhimLeSpec != nil { titles.append("Phim lẻ") }
        return titles
    }

    /// The visible-rail list of the section actually on
    /// screen — the strip and the tagline read this, so
    /// their counts always name the rails on the page.
    private var cinemaActiveRailTitles: [String] {
        cinemaVisibleRailTitles
    }

    /// A scope's (position, name) inside the visible PC
    /// rail list, for the strip's "Dãy NN/TT" line.
    private func cinemaRailPosition(ofScope scope: String,
                                    titles known: [String]? = nil)
        -> (pos: String, name: String) {
        // claude/opt-2 (FL-447 R1): a caller that already
        // holds the visible-rail list passes it in.
        let titles = known ?? cinemaActiveRailTitles
        let name: String
        switch scope {
        case "trending": name = "Trending"
        case "phimLe": name = "Phim lẻ"
        case "kkNew", "vsNew", "f4kNew", "tpNew":
            name = cinemaProviderRailTitle(scope)
        case "tvbHot": name = "TVB · Đang được quan tâm"
        case "tvbNew": name = "TVB · Mới trong thư viện"
        case "cw": name = "Xem tiếp"
        case "tvbCw": name = "TVB · Đang xem dở"
        case "favourites": name = "Yêu thích"
        // FIX-4 / B2: the Following rail has no railSpecs
        // entry — name it from the visible list directly.
        case "following": name = "Đang theo dõi"
        default: name = railSpecs.first(where: { $0.scope == scope })?.title ?? ""
        }
        if let idx = titles.firstIndex(of: name) {
            return (String(format: "%02d", idx + 1), name)
        }
        return ("01", name)
    }

    /// FIX-4 / B1 (Gate R2 Lens B): a torrent rail's
    /// (position, name) for the strip — the focused meta's
    /// OWN catalogue, parsed from its "torCat:<id>|<type>"
    /// focus ID and looked up by the catalogue's real name
    /// in the visible-rail list, mirroring the Torrent
    /// home's own strip resolution (JoeTorrent's
    /// torContextInfo). The pre-fix code looked the literal
    /// "Torrent" up in a list that only ever carries
    /// catalogue names, so rails 9–11 always painted
    /// "Dãy 01 · Torrent".
    private func cinemaTorrentRailPosition(forFocusedMovie focused: String,
                                           titles known: [String]? = nil)
        -> (pos: String, name: String) {
        let titles = known ?? cinemaActiveRailTitles
        if focused.hasPrefix("torCat:") {
            let catId = focused.dropFirst("torCat:".count)
                .split(separator: "|").first.map(String.init) ?? ""
            if let cat = cinemaTorrentCatalogs.first(where: { $0.id == catId }),
               let idx = titles.firstIndex(of: cat.name) {
                return (String(format: "%02d", idx + 1), cat.name)
            }
        }
        return ("01", cinemaTorrentCatalogs.first?.name ?? "")
    }

    /// FIX-4 / B2: resolve an addon focus ID
    /// ("addon|<rail>|<metaId>") to its meta and its rail's
    /// (position, catalogue name) in the visible-rail list.
    /// Matched by prefix per rail — a rail's own id itself
    /// contains a "|" ("type|catalogId"), so the ID cannot
    /// be split on a fixed segment count.
    private func cinemaAddonFocus(_ focused: String)
        -> (meta: TorMeta, pos: String, railName: String)? {
        for rail in addonStore.rails where !rail.metas.isEmpty {
            let prefix = "addon|" + rail.id + "|"
            guard focused.hasPrefix(prefix) else { continue }
            let metaId = String(focused.dropFirst(prefix.count))
            guard let meta = rail.metas.first(where: { $0.id == metaId })
            else { continue }
            let titles = cinemaActiveRailTitles
            let idx = titles.firstIndex(of: rail.catalog.name)
            return (meta, String(format: "%02d", (idx ?? 0) + 1),
                    rail.catalog.name)
        }
        return nil
    }

    /// The Private Cinema hero block (v2.1.0; v2.1.1 WS-B
    /// full-bleed stage; v2.1.1 WS-I focus-follows
    /// backdrop): the backdrop layer is the shared
    /// controller's crossfade stack (JoeCinemaBackdrop
    /// Layer — it replaced WS-B's three-stage JoeBandImage
    /// stack of the featured title's poster field / thumb
    /// / TMDB slice, whose art ladder the controller's
    /// load now carries for every focused title) as the
    /// home scroll's first, full-width stage — every layer framed maxWidth
    /// .infinity with no inset, so the art bleeds edge to
    /// edge across the whole content width and, the block
    /// being the scroll's first element with no top padding,
    /// paints from the very top of the scroll under the
    /// shell bar (WS-A makes the PC bar a transparent
    /// overlay; the top scrim below seats the bar's
    /// legibility over the art). The stage is 485 tall
    /// (FIX-3, many-rails spec: hero x94 y158 w850, the
    /// first rail — Dãy 0 — starts at library y485, so the
    /// hero zone ends where the first rail starts).
    /// The text block follows the drawing (hero x93 w850 at
    /// 1920 wide — the shell's 80 pt safe-area inset plus
    /// the 13 pt leading padding below): the static
    /// eyebrow in letterspaced caps, the typeset title (the app's
    /// serif display face at the design's 72/500 scale with
    /// wide tracking — the design face itself is not
    /// available in-app, the standing substitution), the
    /// original-name line in letterspaced caps when the
    /// record carries one, the meta row (year · ★ · runtime
    /// + the quality chip; the design's age chip has no app
    /// data and is omitted, never invented), the VN
    /// synopsis (≤2 lines), and EXACTLY TWO actions — the
    /// design's pair: pale "▶ Chọn nguồn phát" and dark
    /// "ⓘ Thông tin phim", both wired to the hero's
    /// existing detail-open call (the one nav.movie
    /// MovieRoute every hero in this file mints; the
    /// detail screen is where playback and the favourite
    /// toggle live — see the WS-B report for where the
    /// removed hero favourite / browse entries remain
    /// reachable). Its resolve task is ultraHeroBlock's
    /// task verbatim, so heroDetail / heroBackdropURL /
    /// heroRating publish identically.
    @ViewBuilder
    private var cinemaHeroBlock: some View {
        if let featured = heroMovie {
            // FIX-214 (DESIGN-PASS-214 §1a): the stage is
            // 560 (485 in 2.1.3 — the 394 text zone inside
            // a 485 stage put the text top at y91, INSIDE
            // the old 132 band: the collision family of
            // the whole 2.1.3 round). The HomeTVBFocus
            // form's own stage is 600 — its text budget
            // (428) needs the extra 40. One stage value
            // drives both the backdrop frame and the
            // block frame.
            let displayed = cinemaHeroDisplayResolved()
            let stage: CGFloat = (displayed.map(cinemaIsTVBTarget)
                                  ?? false) ? 600 : 560
            ZStack(alignment: .bottomLeading) {
                // v2.1.1 (WS-I): the hero's backdrop is the
                // focus-follows layer now — the shared
                // controller's two-layer crossfade stack
                // (JoeCinemaBackdropLayer, JoePrivateCinema
                // .swift), fed from the focus memory by
                // cinemaHeroFocusMoved(). The pre-WS-I
                // three-stage JoeBandImage stack (poster
                // field / thumb / TMDB slice of the FEATURED
                // title only) is replaced by it: the
                // controller's load ladder carries the same
                // art (TMDB backdrop → thumb/poster, hedged)
                // for EVERY focused title, the previous
                // backdrop stays up while the next loads,
                // and a title with no art leaves plain Ink
                // under the scrims below. The hero task
                // below still resolves the featured title's
                // TMDB backdrop / detail / rating — the
                // resolver reads them for the featured item.
                // claude/opt-2 (FL-457): the stage is TEXT-ONLY — the
                // backdrop and its scrims moved to page level
                // (joePCPageBackdrop on the scroll view). This clear
                // spacer keeps the stage's full-width frame, so the
                // text, the tagline anchor and the strip below sit
                // exactly where they did.
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: stage)
                // FIX-214 (FULL-THEME-AUDIT-214 Phần C họ
                // 1): the design's TWO scrims — the Ink
                // stop ramps (JoeCinemaScrims), shared by
                // all three heroes. The shipped pair (a
                // five-stop BLACK left gradient + a
                // clear→bg bottom ramp) was a different
                // colour family from the drawing.
                // FIX-213 (Fault 8): NO top scrim — the
                // design draws exactly two scrims on this
                // stage (left + bottom); the third one that
                // stood here (bg 0.55 → clear at 0.35) was
                // added by the build to keep the OLD bar's
                // pills legible, and it darkened the art
                // under the bar zone ("Làm che luôn
                // backdrop"). The design's own bar is
                // transparent text over the art and needs
                // no such darkening.
                // v2.1.1 (WS-I): the hero text follows the
                // FOCUSED title (cinemaHeroResolved — the
                // featured title before any focus), rendered
                // from the focus derivation in body, so it
                // changes in the same transaction as the
                // focus move, ahead of the debounced
                // backdrop swap.
                if let displayed {
                    cinemaHeroText(displayed)
                }
            }
            .frame(height: stage)
            // FIX-213 (Fault 7): the design's hero stage
            // is FULL-BLEED (backdrop x0, w1920) — the
            // block bleeds across the shell's 80 pt
            // ambient inset on both sides (negative
            // padding cancels it exactly), so the
            // backdrop + scrims span the whole frame
            // while the hero text (leading 94 inside
            // cinemaHeroText) and the tagline (trailing
            // 94 below) keep the design's insets.
            .padding(.horizontal, -80)
            // v2.1.1 (FIX-6): the drawing's right-side
            // tagline block — it was MISSING from the
            // built hero (checked first-hand: no tagline
            // text existed anywhere in this file); added
            // here at the same geometry as the TVB /
            // Torrent heroes built in the same round.
            .overlay(alignment: .bottomTrailing) {
                cinemaHeroTagline
                    .padding(.trailing, 94)
                    .padding(.bottom, 72)
            }
            .defaultFocus($heroPlayFocused, true)
            .task(id: featured.id) {
                heroDetail = nil
                heroBackdropURL = nil
                heroLogoURL = nil
                heroRating = 0
                async let detailFetch = Providers.detail(
                    featured.provider, slug: featured.slug)
                async let earlyInfo = TMDBClient.fetchInfo(
                    tmdbId: featured.tmdbId, type: featured.tmdbType)
                async let earlyLogo = TMDBClient.fetchLogo(
                    tmdbId: featured.tmdbId, type: featured.tmdbType)
                heroDetail = try? await detailFetch
                guard !TMDBClient.apiKey.isEmpty else { return }
                let m = heroDetail?.movie ?? featured
                var backdrop = ""
                var heroInfo: TMDBInfo?
                if !m.tmdbId.isEmpty {
                    if m.tmdbId == featured.tmdbId,
                       m.tmdbType == featured.tmdbType {
                        heroInfo = await earlyInfo
                        if let info = heroInfo {
                            backdrop = info.backdropURL
                        }
                    } else {
                        heroInfo = await TMDBClient.fetchInfo(
                            tmdbId: m.tmdbId, type: m.tmdbType)
                        backdrop = heroInfo?.backdropURL ?? ""
                    }
                }
                if backdrop.isEmpty {
                    backdrop = await TMDBClient.searchBackdrop(
                        name: m.name, origin: m.originName,
                        year: Providers.yearOf(m)) ?? ""
                }
                if !backdrop.isEmpty {
                    heroBackdropURL = URL(string: backdrop)
                }
                if let info = heroInfo, info.voteAverage > 0 {
                    heroRating = info.voteAverage
                }
                if !m.tmdbId.isEmpty {
                    let logo: String
                    if m.tmdbId == featured.tmdbId,
                       m.tmdbType == featured.tmdbType {
                        logo = await earlyLogo
                    } else {
                        logo = await TMDBClient.fetchLogo(
                            tmdbId: m.tmdbId, type: m.tmdbType)
                    }
                    if !logo.isEmpty {
                        heroLogoURL = URL(string: logo)
                    }
                }
            }
        }
    }

    /// The Private Cinema hero's text block (v2.1.1, WS-B —
    /// a named helper per FL-390, not an inline chain in
    /// cinemaHeroBlock): eyebrow, typeset title, original
    /// name, meta row, synopsis and the design's TWO
    /// actions, in the design's order and scale.
    /// v2.1.1 (WS-I): the block renders the RESOLVED item
    /// — the focused title once focus has moved, the
    /// featured title before that — and both actions open
    /// that title through cinemaOpenHeroTarget (the
    /// focused card's own tap mint per surface; for a
    /// chain title that is the hero's existing detail-open
    /// MovieRoute, exactly as the pre-WS-I hero wired its
    /// featured title).
    /// GATE-213 R2 Lens 3 F3 (RECALC-SPEC §3.2): the
    /// HomeTVBFocus eyebrow is the title's OWN TVB line —
    /// "TVB · <genre>" from the catalogue title's first
    /// category. A .tvb target carries its TVBTitle
    /// directly; a .tvbEntry (Continue Watching) links
    /// through its YouTube series (byPid[entry.slug]) to
    /// the series' tmdbId and the same pcTVBById map the
    /// resolver uses. Only a target with NO category
    /// anywhere (unmatched YouTube-only entries) falls
    /// back to the drawing's static §3.5 line.
    private func cinemaTVBEyebrowLine(_ target: CinemaHeroTarget) -> String {
        let category: String?
        switch target {
        case .tvb(let title):
            category = title.categories.first
        case .tvbEntry(let entry):
            if let series = ytStore.snapshot?.byPid[entry.slug],
               series.tmdbId != 0 {
                category = pcTVBById[series.tmdbId]?.categories.first
            } else {
                category = nil
            }
        default:
            category = nil
        }
        if let category, !category.isEmpty {
            return "TVB · \(category.uppercased())"
        }
        return "MỘT THỜI HỒNG KÔNG / TVB"
    }

    private func cinemaHeroText(_ resolved: CinemaHeroResolved) -> some View {
        // R7 (RECALC-SPEC §3.2): the HomeTVBFocus form is
        // its own standalone view (JoeHomeTVBFocus.swift);
        // this function renders ONLY the movie form and
        // delegates a TVB target to it.
        if cinemaIsTVBTarget(resolved) {
            return AnyView(JoeHomeTVBFocusHero(
                resolved: resolved,
                eyebrowLine: cinemaTVBEyebrowLine(resolved.target),
                heroPlayFocused: $heroPlayFocused,
                heroInfoFocused: $heroInfoFocused,
                openTarget: { cinemaOpenHeroTarget($0) }))
        }
        let item = resolved.item
        // FIX-214 (DESIGN-PASS-214 §1a): the text zone is
        // the stage's bottom 394 — text top at y166 of
        // the 560 stage, ≥ +18 clear of the 148 band in
        // the worst legal case (2.1.3's geometry put it
        // inside the band). The variable rows are
        // MEASURED with the bundled fonts themselves
        // (JoeHeroMeasure) and compressed in the pass's
        // order: the synopsis collapses 2→1→0 lines,
        // then the origin-name row hides. Eyebrow ·
        // title (≤2 lines) · meta · actions always stay.
        // The drawing's own case (1-line title, 2-line
        // synopsis, every row) measures exactly the
        // budget — nothing compresses.
        let titleLines = min(2, JoeHeroMeasure.lines(
            of: item.title,
            postScriptName: "BricolageGrotesque-Medium",
            size: 72, width: 850))
        let hasOrigin: Bool = {
            if case .movie(let movie, _) = resolved.target {
                return !movie.originName.isEmpty
                    && movie.originName != movie.name
            }
            return false
        }()
        let hasMeta: Bool = {
            if !item.meta.isEmpty { return true }
            switch resolved.target {
            case .movie(let movie, _), .fileTrending(let movie):
                return !movie.quality.isEmpty
            default:
                return false
            }
        }()
        var synopsisLimit = item.synopsis.isEmpty ? 0
            : min(2, JoeHeroMeasure.lines(
                of: item.synopsis, postScriptName: "Outfit-Regular",
                size: 20, width: 665))
        var showOrigin = hasOrigin
        func heroBlockHeight() -> CGFloat {
            var h: CGFloat = 72 // .vertical 36 × 2
            h += JoeHeroMeasure.lineHeight(
                postScriptName: "Outfit-Medium", size: 15)
            h += 12 + JoeHeroMeasure.lineHeight(
                postScriptName: "BricolageGrotesque-Medium",
                size: 72) * CGFloat(titleLines)
            if showOrigin {
                h += 10 + JoeHeroMeasure.lineHeight(
                    postScriptName: "Outfit-Medium", size: 20)
            }
            if hasMeta {
                h += 12 + JoeHeroMeasure.lineHeight(
                    postScriptName: "Outfit-Regular", size: 20)
            }
            if synopsisLimit > 0 {
                h += 10 + JoeHeroMeasure.lineHeight(
                    postScriptName: "Outfit-Regular", size: 20)
                    * CGFloat(synopsisLimit)
                    + 10 * CGFloat(synopsisLimit - 1)
            }
            h += 16 + 55 // actions gap + button height
            return h
        }
        while heroBlockHeight() > 394 && synopsisLimit > 0 {
            synopsisLimit -= 1
        }
        if heroBlockHeight() > 394 { showOrigin = false }
        return AnyView(VStack(alignment: .leading, spacing: 0) {
            // FIX-10a / ADJUDICATION F1: the many-rail
            // drawing's hero eyebrow is the STATIC line
            // below (the same pattern as the TVB /
            // Torrent heroes' static eyebrows) — NOT the
            // resolved title's genres.
            // FIX-213 (Fault 13): the static line is now
            // per-screen (cinemaHeroEyebrow): the Phim
            // screen's own "PHIM · ĐANG CHỌN", the Home
            // line otherwise. (A TVB hero target never
            // reaches this form — it is delegated to
            // JoeHomeTVBFocusHero above.)
            Text(cinemaHeroEyebrow(resolved))
                .font(JoePCType.outfit(15, weight: .medium))
                .tracking(3.6)
                .foregroundStyle(theme.heroMeta)
                .lineLimit(1)
            Text(item.title)
                .font(JoePCType.display(72))
                .tracking(-3)
                .foregroundStyle(theme.text)
                .lineLimit(2)
                .padding(.top, 12)
            if showOrigin, case .movie(let movie, _) = resolved.target {
                Text(movie.originName.uppercased())
                    .font(JoePCType.outfit(20, weight: .medium))
                    .tracking(6)
                    .foregroundStyle(theme.heroMeta)
                    .lineLimit(1)
                    .padding(.top, 10)
            }
            cinemaHeroMetaRow(resolved)
            if synopsisLimit > 0 {
                Text(item.synopsis)
                    // FIX-214 (FULL-THEME-AUDIT-214 B2):
                    // the audit re-measured the drawing
                    // first-hand — synopsis 20/400, line
                    // 1.5 (spacing 10), clamp 2, max width
                    // 665 — superseding the RECALC-SPEC
                    // adjudication of 18 that FIX-12
                    // followed. The clamp is the budget's
                    // measured limit (heroBlockHeight).
                    .font(JoePCType.outfit(20))
                    .foregroundStyle(theme.text.opacity(0.92))
                    .lineSpacing(10)
                    .lineLimit(synopsisLimit)
                    .frame(maxWidth: 665, alignment: .leading)
                    // FIX-4 / C6: spec synopsis margin-top 10.
                    .padding(.top, 10)
            }
            // FIX-4 / C6: spec actions gap 16.
            // v2.1.1 (WS-I): BOTH actions open the FOCUSED
            // title (cinemaOpenHeroTarget — the focused
            // card's own tap mint); before any focus, the
            // featured title, exactly as the pre-WS-I hero.
            // FIX-213 (Fault 13): the action SET is
            // cinemaHeroActions' movie pair (the TVB
            // target's episode-first set lives in
            // JoeHomeTVBFocusHero).
            cinemaHeroActions(resolved)
            // FIX-4 / C6: spec actions margin-top 16.
            .padding(.top, 16)
        }
        // FIX-213 (Fault 7): the hero block now bleeds
        // to the frame's edges (see cinemaHeroBlock), so
        // this inset is the design's own hero x94
        // (many-rail spec: hero x94, w850).
        // FIX-214 (FULL-THEME-AUDIT-214 B2): the frame is
        // 94 + 850 = 944 wide — the shipped 900 left the
        // content at ≈806, short of the drawn 850.
        .padding(.leading, 94)
        .padding(.vertical, 36)
        .frame(maxWidth: 944, alignment: .leading))
    }

    /// FIX-213 (Fault 13): is the resolved hero target
    /// a TVB one (catalogue title or continue-watching
    /// entry)? The HomeTVBFocus form keys on this.
    private func cinemaIsTVBTarget(_ resolved: CinemaHeroResolved) -> Bool {
        switch resolved.target {
        case .tvb, .tvbEntry: return true
        default: return false
        }
    }

    /// The hero eyebrow by screen (FIX-213, Fault 13;
    /// R7): the Phim screen's own line under the fixed
    /// .phim identity (its drawing: "PHIM · ĐANG
    /// CHỌN"), the Home line otherwise. The TVB line
    /// for a TVB hero target moved with the HomeTVBFocus
    /// form to JoeHomeTVBFocusHero.
    private func cinemaHeroEyebrow(_ resolved: CinemaHeroResolved) -> String {
        return "TỐI NAY, XEM GÌ? / TRANG CHỦ · ĐANG CHỌN"
    }

    /// The hero's action set (movie form): the built
    /// pair verbatim ("Chọn nguồn phát" / "Thông tin
    /// phim"). The TVB target's EPISODE-FIRST set moved
    /// with the HomeTVBFocus form to
    /// JoeHomeTVBFocusHero (JoeHomeTVBFocus.swift).
    @ViewBuilder
    private func cinemaHeroActions(_ resolved: CinemaHeroResolved) -> some View {
        HStack(spacing: 16) {
            Button {
                cinemaOpenHeroTarget(resolved.target)
            } label: {
                JoePrimaryLabel(title: "Chọn nguồn phát", systemImage: "play.fill")
            }
            .joeCardButton()
            .focused($heroPlayFocused)
            Button {
                cinemaOpenHeroTarget(resolved.target)
            } label: {
                JoeSecondaryLabel(title: "Thông tin phim",
                                  systemImage: "info.circle")
            }
            .joeCardButton()
            .focused($heroInfoFocused)
        }
    }

    /// The hero's right-side tagline block (v2.1.1,
    /// FIX-6 — the Home/Phim drawings' block, shared by
    /// all three PC heroes): the italic line over the
    /// caps line with THIS home's real visible rail
    /// count (cinemaVisibleRailTitles — the strip's own
    /// list, so the number is the rails actually on the
    /// page, never the drawing's sample count).
    private var cinemaHeroTagline: some View {
        // FIX-214 (FULL-THEME-AUDIT-214 B2): the drawn
        // copy — italic "Phim đang được chọn" over the
        // caps line "<TITLE> · <N> DÃY PHIM": the
        // currently displayed hero's own title + THIS
        // home's real visible rail count. The shipped
        // "Một buổi tối. Một thế giới khác." and
        // "↓ TIẾP TỤC KHÁM PHÁ" were invented copy —
        // the drawing carries neither.
        let heroTitle = (cinemaHeroDisplayResolved()?.item.title
                         ?? heroMovie?.name ?? "").uppercased()
        return VStack(alignment: .trailing, spacing: 8) {
            Text("Phim đang được chọn")
                .font(JoePCType.editorial(28, italic: true))
                .foregroundStyle(theme.text)
                .lineLimit(1)
            Text("\(heroTitle) · \(cinemaActiveRailTitles.count) DÃY PHIM")
                .font(JoePCType.outfit(14, weight: .medium))
                .tracking(3)
                .foregroundStyle(theme.heroMeta)
                .lineLimit(1)
        }
    }

    // FIX-10a: cinemaHeroEyebrow is DELETED — its only
    // caller was cinemaHeroText, whose eyebrow is now
    // the drawing's static line. heroGenres itself is
    // NOT orphaned: the non-PC hero surfaces still read
    // it (see heroGenres' other callers).

    /// The Private Cinema hero meta row (v2.1.1): the meta
    /// line (year · ★ · runtime, cinemaHeroMetaLine) plus
    /// the design's quality chip when the record carries a
    /// quality value. The design's age chip is absent — the
    /// data model has no age field (RECONCILIATION-211:
    /// omitted, never invented).
    @ViewBuilder
    private func cinemaHeroMetaRow(_ resolved: CinemaHeroResolved) -> some View {
        // v2.1.1 (WS-I): the meta line is the resolved
        // item's own (year · ★ · runtime for a chain
        // title via cinemaHeroMetaLine, the strip's meta
        // for the other surfaces); the quality chip rides
        // only a chain title that carries a quality value.
        let quality: String = {
            switch resolved.target {
            case .movie(let movie, _), .fileTrending(let movie):
                return movie.quality
            default:
                return ""
            }
        }()
        if !resolved.item.meta.isEmpty || !quality.isEmpty {
            HStack(alignment: .center, spacing: 14) {
                if !resolved.item.meta.isEmpty {
                    // FIX-214 (FULL-THEME-AUDIT-214 B2):
                    // the drawn meta line is IVORY with
                    // only the ★ celadon — the shipped
                    // row painted the whole line celadon
                    // (theme.heroMeta). Shared renderer:
                    // JoeCinemaMetaText.
                    JoeCinemaMetaText(meta: resolved.item.meta)
                }
                if !quality.isEmpty {
                    Text(quality)
                        // FIX-4 / C6: design badges 14/400.
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
    }

    /// The Private Cinema hero meta line (v2.1.0): year ·
    /// ★ rating · runtime (the list item's runtime, the
    /// hero detail's behind it) — only the fields the
    /// record actually carries.
    private func cinemaHeroMetaLine(_ featured: Movie) -> String {
        var parts: [String] = []
        if !featured.year.isEmpty {
            parts.append(featured.year)
        }
        if heroRating > 0 {
            parts.append("★ " + String(format: "%.1f", heroRating))
        }
        let time = !featured.time.isEmpty
            ? featured.time : (heroDetail?.movie.time ?? "")
        if !time.isEmpty {
            parts.append(time)
        }
        return parts.joined(separator: " · ")
    }

    /// The Private Cinema trending rail (v2.1.0; v2.1.1
    /// WS-B — design presentation): the heading follows the
    /// drawing — "Trending" with the muted subtitle "Được
    /// yêu thích hôm nay" beside it and the position counter
    /// at the right (the spec's own data title stays the
    /// rail's identity in railSpecs; only the PC
    /// presentation follows the drawing). The rail body
    /// mirrors the shared Rail's construction exactly (same
    /// horizontal ScrollView + LazyHStack spacing/padding,
    /// scrollClipDisabled, .focusSection) because the
    /// heading is custom. Items are numbered 01, 02, …
    /// INSIDE the poster (cinemaTrendingCard) — owner
    /// ruling 2026-11-22: "Giữ số trong poster như bản
    /// vẽ". The tap is movieRail's own action and the focus
    /// binding copies movieRail's .focused($focusedMovie,
    /// equals:) pattern, so focus memory works identically.
    /// FIX-214: the trending counter's numerator — the
    /// focused card's 1-based position in THIS rail
    /// (cards bind "scope|id" into focusedMovie); 1 at
    /// rest or when focus is in another rail (the
    /// drawing's rest state pairs the hero with the
    /// first card).
    private func cinemaTrendingFocusIndex(_ railSpec: JoeRailSpec) -> Int {
        guard let focusedMovie,
              focusedMovie.hasPrefix(railSpec.scope + "|") else { return 1 }
        let id = String(focusedMovie.dropFirst(railSpec.scope.count + 1))
        return railSpec.movies.firstIndex(where: { $0.id == id })
            .map { $0 + 1 } ?? 1
    }

    private func cinemaTrendingRail(_ railSpec: JoeRailSpec) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text("Trending")
                    .font(JoePCType.display(27, weight: .medium))
                    .tracking(-0.3)
                    .foregroundStyle(theme.text)
                // FIX-214 (FULL-THEME-AUDIT-214 B3): the
                // drawn subtitle + a counter that FOLLOWS
                // focus (it was hard-coded "01 / NN" and
                // never moved).
                Text("Được quan tâm · thứ tự minh họa")
                    .font(JoePCType.outfit(14))
                    .foregroundStyle(theme.meta)
                Spacer()
                Text(String(format: "%02d / %02d",
                            cinemaTrendingFocusIndex(railSpec),
                            railSpec.movies.count))
                    .font(JoePCType.outfit(17))
                    .foregroundStyle(theme.meta)
            }
            // FIX-213 (Fault 7): the heading row spans the
            // design's inset pair — "Trending" at x94 and
            // the counter's right edge at 1826 (94 short
            // of the right edge), as drawn.
            .padding(.leading, 14)
            .padding(.trailing, 14)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 25) {
                    ForEach(Array(railSpec.movies.enumerated()), id: \.offset) { pair in
                        Button {
                            nav.movie = MovieRoute(
                            provider: pair.element.provider, slug: pair.element.slug,
                            name: pair.element.name, poster: pair.element.poster, year: pair.element.year) } label: {
                            cinemaTrendingCard(movie: pair.element,
                                               index: pair.offset)
                        }
                        .joeCardButton()
                        .focused($focusedMovie, equals: railSpec.scope + "|" + pair.element.id)
                    }
                }
                // FIX-213 (Fault 7): the design's track
                // insets, as in cinemaRailShell — first
                // card at x94, last card resting 94 short
                // of the right edge, scrolled cards
                // painting to both bezels.
                .padding(.leading, 94)
                .padding(.trailing, 94)
                // FIX-4 / C5 + FIX-213 (Fault 14): track
                // padding 16/11 + row padding 8/9, as in
                // cinemaRailShell — the design's measured
                // poster row (395) is their sum.
                .padding(.top, 24)
                .padding(.bottom, 20)
            }
            .scrollClipDisabled()
            .padding(.horizontal, -80)
        }
        .focusSection()
    }

    /// One Private Cinema trending card (v2.1.1): the
    /// shared PosterCard construction verbatim (same
    /// arguments and badge behaviour as movieRail's cards —
    /// the quality badge rides the art's top-left inside
    /// PosterCard, as drawn), plus the item's number as a
    /// translucent serif numeral INSIDE the poster, at the
    /// art's bottom-right corner (owner ruling 2026-11-22
    /// 01:47 CST: numerals inside the poster, as drawn —
    /// NOT beside the card). The numeral is a plain overlay
    /// on the card: the PC card's art starts at the card's
    /// top edge (cinemaBody, artInset 0) and spans
    /// theme.cardArtH, so a top-trailing overlay padded
    /// down by (cardArtH − numeral height) lands the
    /// numeral inside the art's bottom-right. It carries
    /// no focus treatment of its own — focus stays the
    /// card's native treatment (no scaleEffect, no
    /// hand-drawn focus layer).
    private func cinemaTrendingCard(movie: Movie, index: Int) -> some View {
        // v2.1.1 (WS-H): the PC local card at the design's
        // 205×263 geometry (JoeCinemaPosterCard) — and NO
        // provider badge: the drawing's Trending posters
        // carry none (Lens C finding F1; the pre-WS-H card
        // passed the shared PosterCard's badge through).
        // The numeral stays INSIDE the poster, bottom-
        // right, as drawn (owner ruling 2026-11-22).
        // FIX-3: the drawing's Trending posters DO carry a
        // type badge top-left ("PHIM LẺ" on the PNG's movie
        // cards) — passed to the local card, which paints
        // it in the F1 badge dressing in place of its
        // quality chip on this rail only.
        JoeCinemaPosterCard(movie: movie,
                            typeBadge: cinemaTrendingTypeBadge(movie))
        .overlay(alignment: .topTrailing) {
            Text(String(format: "%02d", index + 1))
                .font(JoePCType.display(46, weight: .bold))
                .foregroundStyle(.white.opacity(0.88))
                .shadow(color: .black.opacity(0.55), radius: 6, x: 0, y: 2)
                .padding(.top, 263 - 58)
                .padding(.trailing, 10)
        }
    }

    /// FIX-3: the trending card's type badge text, from
    /// the item's REAL type field — the sources spell it
    /// series/phim-bo (PHIM BỘ) and single/phim-le/movie
    /// (PHIM LẺ), the same spellings JoeBrowse.matchesType
    /// accepts; the item's TMDB type stamp is the fallback
    /// when the provider type carries none of those. Any
    /// other value is unknown: the badge is omitted,
    /// never guessed.
    private func cinemaTrendingTypeBadge(_ movie: Movie) -> String? {
        switch movie.type {
        case "series", "phim-bo": return "PHIM BỘ"
        case "single", "phim-le", "movie": return "PHIM LẺ"
        default: break
        }
        switch movie.tmdbType {
        case "tv": return "PHIM BỘ"
        case "movie": return "PHIM LẺ"
        default: return nil
        }
    }

    /// The hero backdrop's ONE source (v2.0.21): the resolved
    /// TMDB backdrop when the hero task has published it, else
    /// the featured film's provider thumb, else its poster —
    /// a single URL feeding a single JoeBandImage layer. The
    /// v2.0.19 stack raced at open and on hero change: three
    /// layers each held their own load state, so a previous
    /// film's TMDB slice could sit under the new film's title
    /// until its replacement landed. Here the layer is keyed
    /// by its URL and JoeBandImage only ever paints its own
    /// URL's bitmap, so a stale backdrop is impossible by
    /// construction; a source change cross-fades.
    private var ultraBackdropSource: (url: URL, isPoster: Bool)? {
        guard let featured = heroMovie else { return nil }
        if let heroBackdropURL { return (heroBackdropURL, false) }
        if let thumb = featured.thumbURL { return (thumb, false) }
        if let poster = featured.posterURL { return (poster, true) }
        return nil
    }

    /// The Ultra hero block: a 600-tall stage INSIDE the
    /// scroll flow — the single-source backdrop clipped to
    /// the block, Ultra's two scrims over the art only, and
    /// the hero text column at the lower left. The poster
    /// source takes the blurred-field treatment; landscape
    /// sources take the top-anchored slice (the detail band's
    /// chooser discipline).
    @ViewBuilder
    private var ultraHeroBlock: some View {
        if let featured = heroMovie {
            ZStack(alignment: .bottomLeading) {
                if let source = ultraBackdropSource {
                    JoeBandImage(url: source.url, targetPixels: 1920,
                                 anchor: 0.20,
                                 portraitMode: source.isPoster ? .blurField : .slice)
                    .frame(maxWidth: .infinity)
                    .frame(height: 600)
                    .clipped()
                    .id(source.url)
                    .transition(.opacity)
                }
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.88), location: 0),
                    .init(color: .black.opacity(0.45), location: 0.45),
                    .init(color: .black.opacity(0.10), location: 0.75),
                    .init(color: .black.opacity(0.05), location: 1)
                ], startPoint: .leading, endPoint: .trailing)
                LinearGradient(stops: [
                    .init(color: .clear, location: 0.42),
                    .init(color: theme.bg.opacity(0.85), location: 0.62),
                    .init(color: theme.bg, location: 0.78)
                ], startPoint: .top, endPoint: .bottom)
                ultraHeroText(featured)
            }
            .frame(height: 600)
            .animation(.easeInOut(duration: 0.45),
                       value: ultraBackdropSource?.url)
            .defaultFocus($heroPlayFocused, true)
            // The Billboard hero's resolve task, extended to
            // publish the logo + rating. 2.0.25 (3c): the logo
            // no longer rides fetchInfo (which now returns
            // without it) — it is fetched IN PARALLEL via
            // fetchLogo from the start, alongside the detail
            // and info fetches, and is only awaited AFTER the
            // backdrop and rating have been applied, so it
            // never delays the hero backdrop/info application;
            // heroLogoURL is set when it lands.
            .task(id: featured.id) {
                heroDetail = nil
                heroBackdropURL = nil
                heroLogoURL = nil
                heroRating = 0
                async let detailFetch = Providers.detail(
                    featured.provider, slug: featured.slug)
                async let earlyInfo = TMDBClient.fetchInfo(
                    tmdbId: featured.tmdbId, type: featured.tmdbType)
                async let earlyLogo = TMDBClient.fetchLogo(
                    tmdbId: featured.tmdbId, type: featured.tmdbType)
                heroDetail = try? await detailFetch
                guard !TMDBClient.apiKey.isEmpty else { return }
                let m = heroDetail?.movie ?? featured
                var backdrop = ""
                var heroInfo: TMDBInfo?
                if !m.tmdbId.isEmpty {
                    if m.tmdbId == featured.tmdbId,
                       m.tmdbType == featured.tmdbType {
                        heroInfo = await earlyInfo
                        if let info = heroInfo {
                            backdrop = info.backdropURL
                        }
                    } else {
                        heroInfo = await TMDBClient.fetchInfo(
                            tmdbId: m.tmdbId, type: m.tmdbType)
                        backdrop = heroInfo?.backdropURL ?? ""
                    }
                }
                if backdrop.isEmpty {
                    backdrop = await TMDBClient.searchBackdrop(
                        name: m.name, origin: m.originName,
                        year: Providers.yearOf(m)) ?? ""
                }
                if !backdrop.isEmpty {
                    heroBackdropURL = URL(string: backdrop)
                }
                if let info = heroInfo, info.voteAverage > 0 {
                    heroRating = info.voteAverage
                }
                if !m.tmdbId.isEmpty {
                    let logo: String
                    if m.tmdbId == featured.tmdbId,
                       m.tmdbType == featured.tmdbType {
                        logo = await earlyLogo
                    } else {
                        logo = await TMDBClient.fetchLogo(
                            tmdbId: m.tmdbId, type: m.tmdbType)
                    }
                    if !logo.isEmpty {
                        heroLogoURL = URL(string: logo)
                    }
                }
            }
        }
    }

    /// The Ultra hero text column: logo art first with the
    /// Vietnamese title under it (v2.0.22 — the drawing's
    /// arrangement; the v2.0.19 "logo replaces the title"
    /// rule was the Sony port's, not the drawing's), the
    /// drawing's white meta row, synopsis up to 4 lines, then
    /// the action row.
    private func ultraHeroText(_ featured: Movie) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            if let heroLogoURL {
                JoeRemoteImage(url: heroLogoURL, targetPixels: 1000, fit: true) {
                    Color.clear
                }
                .frame(maxWidth: 640, maxHeight: 120, alignment: .leading)
                // v2.0.22 (Ultra fidelity — the Phim4K home
                // drawing, caps p4k-1/p4k-2): the Vietnamese
                // title stands UNDER the logo art, white bold
                // caps. The v2.0.19 column let the logo REPLACE
                // the title (the Sony port's rule); the drawing
                // carries both, logo over title.
                Text(featured.name.uppercased())
                    .font(.system(size: 40, weight: .bold))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                    .padding(.top, 14)
            } else {
                // Drawing fallback (ULTRA-DIFF row 2): the
                // Vietnamese title in bold caps when the film
                // has no logo art.
                Text(featured.name.uppercased())
                    .font(.system(size: 68, weight: .heavy))
                    .foregroundStyle(theme.text)
                    .lineLimit(2)
            }
            if heroLogoURL == nil, !featured.originName.isEmpty,
               featured.originName != featured.name {
                Text(featured.originName.uppercased())
                    .font(.system(size: 24, weight: .semibold))
                    .tracking(4)
                    .foregroundStyle(theme.heroMeta)
                    .lineLimit(1)
                    .padding(.top, 10)
            }
            // v2.0.22: the drawing's meta row (see ultraMetaRow
            // below) replaces the shared heroMetaLine here —
            // and the genres line the v2.0.19 column carried
            // under it is GONE: the drawing's home hero block
            // is logo / title / meta / synopsis, no genre line
            // (genres belong to the detail screen's block).
            ultraMetaRow(featured)
                .padding(.top, 12)
            if let synopsis = heroDetail?.content, !synopsis.isEmpty {
                Text(synopsis)
                    .font(.system(size: 26))
                    .foregroundStyle(theme.text.opacity(0.92))
                    .lineSpacing(6)
                    .lineLimit(4)
                    .frame(maxWidth: 1000, alignment: .leading)
                    .padding(.top, 16)
            }
            HStack(spacing: 18) {
                Button {
                    nav.movie = MovieRoute(provider: featured.provider,
                                           slug: featured.slug,
                                           name: featured.name,
                                           poster: featured.poster,
                                           year: featured.year)
                } label: {
                    JoePrimaryLabel(title: "Xem ngay", systemImage: "play.fill")
                }
                .joeCardButton()
                .focused($heroPlayFocused)
                Button {
                    toggleHeroFavorite(featured)
                } label: {
                    JoeSecondaryLabel(title: isHeroFavorite(featured)
                                      ? "♥ Đã thích" : "♡ Yêu thích")
                }
                .joeCardButton()
                Button {
                    browseReturnTarget = .heroBrowse
                    nav.browseOpen = true
                } label: {
                    JoeSecondaryLabel(title: "Tất cả phim",
                                      systemImage: "square.grid.2x2")
                }
                .joeCardButton()
                .focused($heroBrowseFocused)
            }
            .padding(.top, 26)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The Ultra hero meta row (v2.0.22 — the drawing's line,
    /// caps p4k-1/p4k-2): quality · year · IMDb badge + score
    /// · runtime, in WHITE. The v2.0.19 column painted the
    /// whole line in the gold heroMeta token and folded the
    /// score INTO the gold pill ("IMDb 8.2" as one black-on-
    /// gold chip); the drawing's line is white text, the
    /// yellow badge carries only the word "IMDb", and the
    /// score stands in white after it. Ultra-only — design
    /// A's hero keeps the shared heroMetaLine verbatim.
    private func ultraMetaRow(_ featured: Movie) -> some View {
        let time = !featured.time.isEmpty
            ? featured.time : (heroDetail?.movie.time ?? "")
        let head = [featured.quality, featured.year]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        return HStack(spacing: 10) {
            if !head.isEmpty {
                Text(head)
            }
            if heroRating > 0 {
                if !head.isEmpty {
                    Text("·")
                }
                Text("IMDb")
                    .font(.system(size: 23, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5)
                        .fill(Color(red: 0.961, green: 0.773, blue: 0.094)))
                Text(String(format: "%.1f", heroRating))
            }
            if !time.isEmpty {
                if !head.isEmpty || heroRating > 0 {
                    Text("·")
                }
                Text(time)
            }
        }
        .font(.system(size: 27, weight: .medium))
        .foregroundStyle(theme.text)
        .lineLimit(1)
    }

    // MARK: - Rail specs (single source of truth for order)

    /// The rail list lives at file scope (joeRailSpecs below)
    /// since UI-6 defect D-1: design D's wall renders the same
    /// category shelves as titled wall sections, driven by this
    /// one list — the completeness A/F have, from one source.
    private var railSpecs: [JoeRailSpec] {
        var specs = joeRailSpecs(phim: phim, themeID: theme.id)
        // IDEA 5: the Trending rail sits right after the
        // "Mới cập nhật" group — after the merged rail (A /
        // Ultra), or after the four banded newest rails in
        // design F (whose specs lead the list, in that order).
        // Only when the trending load resolved something.
        if !phim.trendingMovies.isEmpty {
            let newestScopes: Set<String> = ["merged", "kkNew", "f4kNew", "vsNew", "tpNew"]
            var insertAt = 0
            while insertAt < specs.count,
                  newestScopes.contains(specs[insertAt].scope) {
                insertAt += 1
            }
            specs.insert(JoeRailSpec(scope: "trending",
                                     title: "🔥 Đang thịnh hành",
                                     movies: phim.trendingMovies, badges: true),
                         at: insertAt)
        }
        // v2.1.1 (DIAG-2050 §4, steps 3–4): the trending
        // DATA FILE's rails (PhimStore.trendingFileSpecs —
        // Movie placeholders, no provider slug) join the
        // list here, so every home built on railSpecs
        // renders them after the WatchStore rails (the
        // homes render cw/tvbCw/fav/follow before this
        // list) and before the genre / country / provider
        // rails below this insertion point's tail. Dedupe
        // is LIVE, against every spec already in the list
        // (provider rails + the TMDB trending rail above):
        // an item whose normalised name + year
        // (Providers.filmKey over Providers.normalizeTitle)
        // already appears in a published rail is dropped —
        // the chain rails win, since they open natively.
        // A file rail deduped to nothing is dropped whole.
        if !phim.trendingFileSpecs.isEmpty {
            var publishedKeys = Set<String>()
            for spec in specs {
                for m in spec.movies {
                    publishedKeys.insert(Providers.filmKey(
                        name: m.name, year: Providers.yearOf(m)))
                    if !m.originName.isEmpty {
                        publishedKeys.insert(Providers.filmKey(
                            name: m.originName, year: Providers.yearOf(m)))
                    }
                }
            }
            let fileSpecs = phim.trendingFileSpecs.compactMap { spec -> JoeRailSpec? in
                let kept = spec.movies.filter { m in
                    if publishedKeys.contains(Providers.filmKey(
                        name: m.name, year: Providers.yearOf(m))) {
                        return false
                    }
                    if !m.originName.isEmpty, publishedKeys.contains(
                        Providers.filmKey(name: m.originName,
                                          year: Providers.yearOf(m))) {
                        return false
                    }
                    return true
                }
                guard !kept.isEmpty else { return nil }
                return JoeRailSpec(scope: spec.scope, title: spec.title,
                                   movies: kept, badges: spec.badges)
            }
            // Insertion point: after the "Mới cập nhật"
            // group and after the TMDB trending rail when
            // it landed — the same neighbourhood the IDEA 5
            // insertion above computes, recomputed here
            // because that computation is scoped to its own
            // `if` (and this block must also run when the
            // TMDB rail is absent).
            let headScopes: Set<String> = ["merged", "kkNew", "f4kNew",
                                           "vsNew", "tpNew", "trending"]
            var fileInsertAt = 0
            while fileInsertAt < specs.count,
                  headScopes.contains(specs[fileInsertAt].scope) {
                fileInsertAt += 1
            }
            specs.insert(contentsOf: fileSpecs, at: fileInsertAt)
        }
        // IDEA 7a: the Following rail is NOT a spec here.
        // v2.0.37 (cluster D): it used to be appended LAST,
        // after every catalogue / genre / country / provider
        // rail (~26 rails), so an owner who followed a title
        // on a detail page could not find the "Đang theo dõi"
        // section on the home screen (his 2.0.27 finding —
        // the same complaint the 2.0.28 fix 7 answered for
        // theme D by placing followWallRail beside Continue
        // Watching / Favourites). It now renders as the
        // dedicated owner shelf `followRail` directly under
        // favRail in railHome / ultraHome, in the same
        // position pattern as theme D. Side benefit: the
        // hero's candidate pool (railSpecs.flatMap) is
        // catalogue-only again, as it was before 7a.
        return specs
    }

    /// IDEA 7a: view-model copies of the followed titles for
    /// the Following rail ONLY (the store's records are never
    /// mutated). The badge text comes SOLELY from the store's
    /// episode-count comparison (hasNewEpisodes): "Tập mới"
    /// when the latest count passed the baseline, the plain
    /// count otherwise — never a fabricated day or date.
    private var followedMovies: [Movie] {
        followStore.followed.map { f in
            var m = Movie(name: f.title, slug: f.slug,
                          poster: f.poster, provider: f.provider)
            if f.hasNewEpisodes {
                m.episodeCurrent = "Tập mới · \(f.latestEpisodes) tập"
            } else if f.latestEpisodes > 0 {
                m.episodeCurrent = "\(f.latestEpisodes) tập"
            }
            return m
        }
    }

    // MARK: - Trending rail (IDEA 5)

    // FIX-214 (lag package): loadTrending /
    // catalogueByTmdbId / trendingSearchMatch moved
    // to PhimStore (JoeStores.swift, TMDB trending
    // MARK) — store state, 900 s attempt throttle.

    // MARK: - Design A hero

    /// The featured slot: the first thumb-bearing film in rail
    /// order (thumb-bearing sources only — UI-4's cost note),
    /// falling back to the first film's poster as the backdrop.
    private var heroMovie: Movie? {
        // v2.1.1: the trending file's placeholder movies are
        // NEVER hero candidates — they carry no provider
        // slug, so the hero's detail fetch could only fail
        // against them. The pool is the catalogue specs only.
        let all = railSpecs
            .filter { !$0.scope.hasPrefix("fileTrending:") }
            .flatMap { $0.movies }
        return all.first(where: { !$0.thumb.isEmpty }) ?? all.first
    }

    @ViewBuilder
    private var hero: some View {
        if let featured = heroMovie {
            ZStack(alignment: .bottomLeading) {
                // v2.0.1 (Android hero parity): the hero art
                // paints through the band layer — a landscape
                // thumb as a top-anchored slice (anchor 0.20,
                // the Android hero anchor) instead of the
                // centred fill that cut faces, and a poster-
                // only feature falls back to the blurred field
                // rather than a cropped poster. The scrims
                // below are untouched.
                //
                // Hero forensics fix (2026-11-15): the single
                // layer above became a three-stage stack — the
                // detail band's own discipline, each stage
                // painting the moment its bitmap lands, higher
                // stages covering lower ones:
                //   1. the poster as a blurred field — the
                //      stand-in. The rail card below already
                //      decoded this bitmap, so the hero never
                //      sits black while a usable image is on
                //      the device (the Android FIX4 lesson the
                //      port applied to the detail band but not
                //      to the hero: the old single layer's
                //      thumb URL is decoded nowhere else, so
                //      one failed load = an empty hero for the
                //      view's whole life — the owner's wide
                //      photo);
                //   2. the provider thumb slice (the v2.0.1
                //      art, kept as the fallback) — skipped
                //      when it is the same URL as the poster
                //      (the KK/VS poster fallback), which
                //      stage 1 already paints;
                //   3. the featured film's TMDB w1280 backdrop
                //      (heroBackdropURL, resolved by the task
                //      below) — the primary art, per the
                //      owner's backdrop standard.
                if let url = featured.posterURL {
                    JoeBandImage(url: url, targetPixels: 1920,
                                 anchor: 0.20, portraitMode: .blurField)
                    .frame(maxWidth: .infinity)
                    .frame(height: 668)
                    .clipped()
                }
                if let url = featured.thumbURL, url != featured.posterURL {
                    JoeBandImage(url: url, targetPixels: 1920,
                                 anchor: 0.20, portraitMode: .blurField)
                    .frame(maxWidth: .infinity)
                    .frame(height: 668)
                    .clipped()
                }
                if let heroBackdropURL {
                    JoeBandImage(url: heroBackdropURL, targetPixels: 1920,
                                 anchor: 0.20, portraitMode: .slice)
                    .frame(maxWidth: .infinity)
                    .frame(height: 668)
                    .clipped()
                }
                // UI-3 SCRIM FLOOR (hard requirement): the
                // horizontal scrim never drops below the token
                // floor (0.55 black) anywhere inside the text
                // zone (the left ~65% of the hero), so worst-case
                // text contrast is guaranteed by the TOKEN, not
                // by the backdrop's brightness. The bottom fade
                // only takes over below the text block.
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.92), location: 0),
                    .init(color: .black.opacity(0.80), location: 0.45),
                    .init(color: .black.opacity(theme.scrimFloor), location: 0.65),
                    .init(color: .black.opacity(0.15), location: 0.82),
                    .init(color: .black.opacity(0.05), location: 1)
                ], startPoint: .leading, endPoint: .trailing)
                LinearGradient(stops: [
                    .init(color: .clear, location: 0.55),
                    .init(color: theme.bg, location: 1)
                ], startPoint: .top, endPoint: .bottom)
                // Design-A home hero text column (design-A/home.html):
                // the drawing spaces its elements with per-element
                // margins, not a uniform gap — kicker →(0) title
                // →(12) meta →(10) genres →(16) synopsis →(26)
                // buttons — so the column runs at spacing 0 and each
                // element carries its own top padding (an absent
                // element collapses with its margin, like CSS).
                VStack(alignment: .leading, spacing: 0) {
                    Text("Nổi bật hôm nay")
                        .font(.system(size: 22, weight: .bold))
                        .tracking(4)
                        .foregroundStyle(theme.text)
                    Text(featured.name)
                        .font(.system(size: 68, weight: .heavy))
                        .foregroundStyle(theme.text)
                        .lineLimit(2)
                    // App-only line (the home drawing has no origin
                    // line; it sits between title and meta here).
                    if !featured.originName.isEmpty, featured.originName != featured.name {
                        Text(featured.originName)
                            .font(.system(size: 27))
                            .foregroundStyle(theme.heroMeta)
                            .lineLimit(1)
                            .padding(.top, 10)
                    }
                    Text(heroMetaLine(featured))
                        .font(.system(size: 27, weight: .medium))
                        .foregroundStyle(theme.heroMeta)
                        .padding(.top, 12)
                    // UI-6 D-2: the render's genres line and
                    // synopsis — genres from the list payload's
                    // own category names (heroDetail's parsed
                    // categories behind them), the synopsis from
                    // the featured film's detail fetch.
                    if !heroGenres.isEmpty {
                        Text(heroGenres.joined(separator: " · "))
                            .font(.system(size: 23))
                            .foregroundStyle(theme.heroMeta)
                            .lineLimit(1)
                            .padding(.top, 10)
                    }
                    if let synopsis = heroDetail?.content, !synopsis.isEmpty {
                        Text(synopsis)
                            .font(.system(size: 26))
                            .foregroundStyle(theme.text.opacity(0.92))
                            .lineSpacing(6)
                            .lineLimit(3)
                            .frame(maxWidth: 880, alignment: .leading)
                            .padding(.top, 16)
                    }
                    HStack(spacing: 18) {
                        Button {
                            nav.movie = MovieRoute(provider: featured.provider,
                                                   slug: featured.slug,
                                                   name: featured.name,
                                                   poster: featured.poster,
                                                   year: featured.year)
                        } label: {
                            JoePrimaryLabel(title: "Xem ngay", systemImage: "play.fill")
                        }
                        .joeCardButton()
                        .focused($heroPlayFocused)
                        Button {
                            toggleHeroFavorite(featured)
                        } label: {
                            JoeSecondaryLabel(title: isHeroFavorite(featured)
                                              ? "♥ Đã thích" : "♡ Yêu thích")
                        }
                        .joeCardButton()
                        Button {
                            browseReturnTarget = .heroBrowse
                            nav.browseOpen = true
                        } label: {
                            JoeSecondaryLabel(title: "Tất cả phim",
                                              systemImage: "square.grid.2x2")
                        }
                        .joeCardButton()
                        // v2.0.8 (Phase 5/F5): bound so the
                        // browse-close observer can restore focus
                        // to THIS button — the hero's .defaultFocus
                        // stays on Play (the section entry), which
                        // is exactly why the return needed its own
                        // restoration path.
                        .focused($heroBrowseFocused)
                    }
                    .padding(.top, 26)
                }
                // Design: hero content max-width 1000, starting at
                // the screen padding edge (the rails' left edge) —
                // no extra horizontal inset; the 40 vertical inset
                // keeps the bottom-anchored column off the band's
                // bottom edge.
                .padding(.vertical, 40)
                .frame(maxWidth: 1000, alignment: .leading)
            }
            .frame(height: 668)
            // v2.0.5 (N1/N2), v2.0.8: the hero's play button is
            // this section's DECLARED top element while a hero
            // is on screen — the content section's entry landing
            // when focus moves DOWN from the pill row (the
            // engine resolves that move between the two focus
            // sections; since v2.0.8 nothing resigns focus to
            // force it) and the section's entry when focus
            // re-resolves into the home. Static declaration,
            // the JoeSearchView shape.
            .defaultFocus($heroPlayFocused, true)
            // UI-6 D-2: fetch the featured film's detail for
            // the synopsis (fail-soft — a failed fetch simply
            // leaves the hero without one).
            //
            // Hero forensics fix (2026-11-15): the same task
            // then resolves the featured film's TMDB backdrop
            // for stage 3 of the hero stack — by the payload
            // TMDB id when one is carried (the detail's movie
            // first, the list item behind it: KK parses the
            // tmdb object in both), else the name + year hunt
            // — the detail screen's exact pattern
            // (JoeMovieDetail's TMDB task). Fail-soft end to
            // end: no key, no id and no match simply leave the
            // hero on its provider-art stages.
            //
            // v2.0.8 (S-A4 parallelised): fetchInfo's inputs
            // (tmdbId + tmdbType) are carried by the featured
            // LIST record itself, so when the list item carries
            // an id the TMDB call no longer queues behind the
            // provider detail fetch — both start together
            // (async let) and the backdrop waits only for the
            // slower of the two. What PUBLISHES is unchanged:
            // heroDetail still lands the moment the detail
            // returns (before any TMDB wait), and the backdrop
            // is still decided by the serial rule — the
            // authoritative record is the detail's movie when
            // the detail landed, the list item behind it. The
            // early fetchInfo result is used ONLY when its
            // inputs are exactly the authoritative record's;
            // when the detail supplies a different id (or the
            // list item carried none and only the detail has
            // one), fetchInfo runs then with the authoritative
            // inputs, as before. searchBackdrop stays exactly
            // where it was: conditional on fetchInfo yielding
            // no backdrop, with the authoritative record's
            // name/origin/year.
            .task(id: featured.id) {
                heroDetail = nil
                heroBackdropURL = nil
                async let detailFetch = Providers.detail(
                    featured.provider, slug: featured.slug)
                async let earlyInfo = TMDBClient.fetchInfo(
                    tmdbId: featured.tmdbId, type: featured.tmdbType)
                heroDetail = try? await detailFetch
                guard !TMDBClient.apiKey.isEmpty else { return }
                let m = heroDetail?.movie ?? featured
                var backdrop = ""
                if !m.tmdbId.isEmpty {
                    if m.tmdbId == featured.tmdbId,
                       m.tmdbType == featured.tmdbType {
                        if let info = await earlyInfo {
                            backdrop = info.backdropURL
                        }
                    } else {
                        backdrop = await TMDBClient.fetchInfo(
                            tmdbId: m.tmdbId, type: m.tmdbType)?.backdropURL ?? ""
                    }
                }
                if backdrop.isEmpty {
                    backdrop = await TMDBClient.searchBackdrop(
                        name: m.name, origin: m.originName,
                        year: Providers.yearOf(m)) ?? ""
                }
                if !backdrop.isEmpty {
                    heroBackdropURL = URL(string: backdrop)
                }
            }
        }
    }

    /// The render's full hero meta (UI-6 D-2): year · quality
    /// · lang · episode (with the total appended as
    /// "Tập x / y tập" when both are known) · runtime ·
    /// country. Sparse list items borrow the missing fields
    /// from the featured film's detail movie.
    private func heroMetaLine(_ m: Movie) -> String {
        var episode = m.episodeCurrent
        let total = !m.episodeTotal.isEmpty
            ? m.episodeTotal : (heroDetail?.movie.episodeTotal ?? "")
        if episode.hasPrefix("Tập"), !total.isEmpty, total != "0" {
            episode = "\(episode) / \(total) tập"
        }
        let time = !m.time.isEmpty ? m.time : (heroDetail?.movie.time ?? "")
        let country = !m.country.isEmpty
            ? m.country : (heroDetail?.movie.country ?? "")
        return [m.year, m.quality, m.lang, episode, time, country]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// The hero's genre names: the list item's own categories
    /// first (the payloads carry them — D-2), the detail's
    /// parsed categories behind them, its joined categories
    /// string last.
    private var heroGenres: [String] {
        if let featured = heroMovie, !featured.categories.isEmpty {
            return featured.categories
        }
        if let fromDetail = heroDetail?.movie.categories, !fromDetail.isEmpty {
            return fromDetail
        }
        guard let joined = heroDetail?.categories, !joined.isEmpty else { return [] }
        return joined.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func isHeroFavorite(_ m: Movie) -> Bool {
        watch.isFavorite(key: WatchStore.movieFavKey(provider: m.provider, slug: m.slug))
    }

    private func toggleHeroFavorite(_ m: Movie) {
        var e = WatchStore.Entry()
        e.kind = Providers.kindOf(m.provider)
        e.key = WatchStore.movieFavKey(provider: m.provider, slug: m.slug)
        e.title = m.name
        e.poster = m.poster
        e.year = m.year
        e.slug = m.slug
        e.source = m.provider
        // v2.0.38 (Sony 2.3.41 parity, item 3): the hero
        // favourite stamps the catalogue item's stable ids
        // when it carries them, like the detail saves —
        // Sony stamps its hero favourite too; an unstamped
        // favourite reopens fail-open under the wrong-film
        // gate (and canonical matching loses its id
        // shortcut for the row).
        e.imdbId = m.imdbId
        e.tmdbId = m.tmdbId
        e.ts = Int64(Date().timeIntervalSince1970 * 1000)
        watch.toggleFavorite(e)
    }

    // MARK: - Design F header + source bands

    /// F's slim header (the band stack carries the screen; the
    /// header keeps the "Tất cả phim" browse entry). Also
    /// design A's fallback when no catalogue film exists yet
    /// to feature.
    ///
    /// UI-6 defect D-16 — DECLARED RETENTION (UI-6's fix text
    /// offers "remove or declare"): this header is F's ONLY
    /// focusable element above the owner rails. UP from the
    /// first rail lands on its browse button geometrically —
    /// v2.0.8 retired the first-rail move handler whose UP
    /// branch used to write that landing (headerFocused); the
    /// button's .focused binding and its .defaultFocus entry
    /// declaration below are what remain, and they are enough:
    /// from the button the pills are one geometric UP away.
    /// Removing the header would leave nothing above the
    /// entry rails for that UP to land on. It stays, declared,
    /// in both roles.
    private var slimHeader: some View {
        HStack(alignment: .center, spacing: 28) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Thư viện phim")
                    .font(.system(size: 44, weight: .heavy))
                    .foregroundStyle(theme.text)
                Text("KKPhim · Film4K · VSMOV · Tủ Phim — link được lấy mới mỗi lần bấm xem")
                    .font(.system(size: 25))
                    .foregroundStyle(theme.meta)
            }
            Spacer()
            Button {
                browseReturnTarget = .header
                nav.browseOpen = true
            } label: {
                JoeSecondaryLabel(title: "Tất cả phim", systemImage: "square.grid.2x2")
            }
            .joeCardButton()
            .focused($headerFocused)
        }
        // v2.0.5 (N1/N2): with no hero on screen (design F, or
        // A before the catalogue lands) the header's browse
        // button is the section's DECLARED top element — the
        // same landing role the hero play button plays above.
        // Only one of the two headers ever renders at a time.
        .defaultFocus($headerFocused, true)
    }

    /// F's source band header (UI-6 defects D-15 + D-3): ONE
    /// row — source name and catalogue note inline on the same
    /// baseline row (the render's .band: gap 22, padding 28/18,
    /// radius 14, the flat surface2 fill with the inset stroke
    /// 1.5 over it). The "Xem tất cả ›" label is the drawing's
    /// plain cyan text (.band .all: 25 semibold, focus colour)
    /// — no capsule behind it (the old bg capsule was a
    /// system-platter defence from before .joeCardButton
    /// disabled that effect centrally); focus shows as the
    /// inside ring around the padded label, and the text stays
    /// cyan in every state, as drawn.
    private func bandHeader(name: String, note: String, scope: String) -> some View {
        HStack(alignment: .center, spacing: 22) {
            Text(name)
                .font(theme.id == .privateCinema
                      ? JoePCType.display(27, weight: .medium)
                      : .system(size: 34, weight: .heavy))
                .tracking(theme.id == .privateCinema ? -0.3 : 0)
                .foregroundStyle(theme.text)
            Text(note)
                .font(theme.id == .privateCinema
                      ? JoePCType.outfit(24) : .system(size: 24))
                .foregroundStyle(theme.meta)
                .lineLimit(1)
            Spacer()
            Button {
                browseReturnTarget = .band(scope)
                nav.browseOpen = true
            } label: {
                Text("Xem tất cả ›")
                    .font(theme.id == .privateCinema
                          ? JoePCType.outfit(25, weight: .semibold)
                          : .system(size: 25, weight: .semibold))
                    .foregroundStyle(theme.focusTitle)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .overlay(JoeFocusRing(shape: Capsule()))
            }
            .joeCardButton()
            .focused($bandFocused, equals: scope)
            // v2.0.8 (Phase 1): NO move handler on this button.
            // The v2.0.5 bandMove handler existed because the
            // button sits at the FAR RIGHT with its rail's cards
            // at the far left — the cross-column DOWN/UP pair
            // the beam was seen to drop — but the handler owned
            // every direction and made LEFT/RIGHT declared
            // no-ops (the band row's only focusable element
            // became a trap). Movement to and from the band is
            // now the focus engine's geometric search: the rail
            // below is its own .focusSection() (the shared Rail
            // view), so DOWN/UP cross between the band row and
            // the rail by geometry, like every other region
            // pair in the app.
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .background(RoundedRectangle(cornerRadius: 14).fill(theme.surface2))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .strokeBorder(theme.stroke, lineWidth: 1.5))
        // GATE-213 R5 Lens 2 F1: under Private Cinema the
        // band panel itself sits in the design's 94 frame
        // (the cinema catalogue stack's old +14 wrapper
        // is gone — the shared Rail carries its own frame
        // now, and this panel takes the same inset on
        // both edges so it aligns with the rails below).
        .padding(.horizontal, theme.id == .privateCinema ? 14 : 0)
    }

    // MARK: - Load states (§8)

    /// True when NO catalogue rail has anything — the C-8
    /// condition for the error surface (CW/Favourites are the
    /// owner's own data, not catalogue health). The predicate
    /// itself lives on the store (PhimStore.catalogueIsEmpty)
    /// so the poster wall's D-20 parity surfaces read the
    /// identical condition.
    private var catalogueEmpty: Bool { phim.catalogueIsEmpty }

    /// Team 4's BLOCK-2 predicate (spec-wins over the old board
    /// contract): G3 fires when the store deadline fired
    /// (loadTimedOut — possibly with jobs still in flight), OR
    /// when a load has ENDED with real provider errors on record.
    /// C-8 still applies: never while any catalogue rail has
    /// data. The attempted gate (fix-round minor) keeps the
    /// surface from flashing at cold entry, before the first
    /// load has run.
    private var showPhimError: Bool {
        attempted && catalogueEmpty
            && (phim.loadTimedOut
                || (!phim.loading && !phim.providerErrors.isEmpty))
    }

    /// §8/G5: the load ended, nothing timed out, NO provider
    /// errored, and the catalogue is still empty — every source
    /// answered empty-but-valid. Its own quiet surface: no
    /// spinner, no Retry (nothing failed, so there is nothing
    /// for a retry to fix).
    private var showPhimEmpty: Bool {
        attempted && catalogueEmpty && !phim.loading
            && !phim.loadTimedOut && phim.providerErrors.isEmpty
    }

    /// G4's failed-provider names, from the store's own error
    /// attribution: providerErrors holds an entry exactly while
    /// that provider's latest load failed (it clears when one of
    /// its rails lands). A provider that answered empty-but-valid
    /// has no entry and is correctly NOT named — the earlier
    /// rail-emptiness heuristic could not tell the two apart.
    /// The computation lives on the store (D-20 parity).
    private var failedProviders: [String] { phim.failedProviderNames }

    private func providerDisplayName(_ code: String) -> String {
        switch code {
        case "kk": return "KKPhim"
        case "f4k": return "Film4K"
        case "vsmov": return "VSMOV"
        case "tp": return "Tủ Phim"
        default: return code
        }
    }

    /// The one G3 error shape: warning icon, message, cause,
    /// Retry primary button.
    private var errorSurface: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text("Không tải được thư viện phim.")
                .font(theme.id == .privateCinema
                      ? JoePCType.outfit(29, weight: .semibold)
                      : .system(size: 29, weight: .semibold))
                .foregroundStyle(theme.text)
            Text(phim.loadTimedOut
                 ? "Quá 20 giây chưa có dữ liệu. Kiểm tra mạng và profile Sing-box trên Apple TV."
                 : "Các nguồn phim đều lỗi hoặc trả về trống. Kiểm tra mạng rồi thử lại.")
                .font(theme.id == .privateCinema
                      ? JoePCType.outfit(25) : .system(size: 25))
                .foregroundStyle(theme.meta)
            // G3: the cause line carries the store's REAL captured
            // errors (providerErrors — what each provider actually
            // threw; pre-v1.9 every error was discarded by try?).
            if !phim.providerErrors.isEmpty {
                Text(phim.providerErrors
                        .sorted { $0.key < $1.key }
                        .map { "\(providerDisplayName($0.key)): \($0.value)" }
                        .joined(separator: " · "))
                    .font(theme.id == .privateCinema
                          ? JoePCType.outfit(25) : .system(size: 25))
                    .foregroundStyle(theme.meta)
            }
            Button { phim.retry() } label: {
                JoePrimaryLabel(title: "Thử lại")
            }
            .joeCardButton()
            .focused($retryFocused)
        }
        .padding(.top, 30)
    }

    // MARK: - WatchStore rails

    private var movieProgress: [WatchStore.Entry] {
        Array(WatchStore.filterKinds(watch.progress(),
                                     [WatchStore.kindKK, WatchStore.kindF4K, WatchStore.kindVS, WatchStore.kindTP])
            .prefix(WatchStore.railCap))
    }

    private var movieFavorites: [WatchStore.Entry] {
        // FIX-214 (DESIGN-PASS-214 §1d): kindTor JOINS the
        // filter — a torrent favourite belongs on the
        // shelf like any other (the Torrent home keeps
        // its own tor-only rail; this shelf is the
        // cross-source one). TVB (kindYT) stays OUT: a YT
        // row's reopen identity is its pid and its poster
        // resolves from the TVB catalogue — a different
        // card family with its own rails.
        Array(WatchStore.filterKinds(watch.favorites(),
                                     [WatchStore.kindKK, WatchStore.kindF4K, WatchStore.kindVS, WatchStore.kindTP, WatchStore.kindTor])
            .prefix(WatchStore.railCap))
    }

    /// FL-352 (2.0.45, leg 5): the TVB (kindYT) progress
    /// rows. They were written by the player all along
    /// and read by NOBODY — both Homes whitelisted only
    /// the four movie kinds, so a half-watched TVB series
    /// never resurfaced. The rows get their OWN rail
    /// (below the movie rail, never folded into it): a
    /// YT row's reopen identity is its pid, not a
    /// provider route, and its poster lives in the TVB
    /// catalogue, not on the row.
    private var tvbProgress: [WatchStore.Entry] {
        Array(WatchStore.filterKinds(watch.progress(),
                                     [WatchStore.kindYT])
            .prefix(WatchStore.railCap))
    }

    // MARK: - Focus memory (v2.0.8, Phase 1)

    // The first-rail routing apparatus that lived here —
    // RailItem, phimRails, firstRailScope, setRailFocus,
    // handleFirstRailMove and bandMove — is DELETED. It existed
    // only to serve the per-card .onMoveCommand handlers and
    // the band header's .joeBoundaryMove, and an attached move
    // handler owns every direction: the presses it did not
    // declare were no-ops instead of geometric moves (the
    // single-axis trap). All rail cards are plain buttons now;
    // movement is the focus engine's geometric search over the
    // rails' .focusSection()s, and the @FocusState declarations
    // at the top of this view serve purely as focus memory for
    // the return trip.

    @ViewBuilder
    private var cwRail: some View {
        if !movieProgress.isEmpty {
            Rail(title: "▶ Đang xem dở") {
                ForEach(movieProgress) { entry in
                    Button { nav.movie = MovieRoute(
                        provider: entry.source, slug: entry.slug,
                        name: entry.title, poster: entry.poster,
                        year: entry.year, preselectEp: entry.ep,
                        tvb: entry.tvbRouteContext) } label: {
                        PosterCard(
                            title: entry.title,
                            posterURL: entry.posterURL,
                            meta: entry.epLabel,
                            badge: Providers.badge(entry.source),
                            progress: entry.fraction,
                            subline: "Còn \(WatchStore.fmtClock(entry.dur - entry.pos))",
                            form: .rail)
                    }
                    .joeCardButton()
                    .focused($focusedEntry, equals: "cw|" + entry.key)
                    .contextMenu {
                        Button(role: .destructive) {
                            watch.removeProgress(key: entry.key)
                        } label: {
                            Text("Xoá khỏi Đang xem dở")
                        }
                    }
                    // v2.0.8 (Phase 1): plain button — no move
                    // handler. This rail is the first rail
                    // whenever it renders; its cards used to carry
                    // the first-rail .onMoveCommand, now retired
                    // (see the focus-memory note above).
                }
            }
        }
    }

    /// FL-352 (2.0.45, leg 5): the TVB Continue Watching
    /// rail — the read side of the YT progress rows.
    /// Same PosterCard construction as the movie CW rail
    /// (poster + title + epLabel + progress bar), with
    /// the poster resolved from the TVB catalogue by pid
    /// and the tap reopening the series' detail (which
    /// preselects the saved episode; the player resumes
    /// the position itself).
    @ViewBuilder
    private var tvbCwRail: some View {
        if !tvbProgress.isEmpty {
            Rail(title: "▶ TVB · Đang xem dở") {
                ForEach(tvbProgress) { entry in
                    // FL-374 (2.0.48): the shared CW card —
                    // the poster resolves through
                    // JoeYtPosterResolver like every other
                    // TVB surface; the pre-fix construction
                    // fed PosterCard the raw 4:3 thumbnail
                    // behind its .portrait gate with no
                    // TMDB fallback, so every card was the
                    // placeholder by construction.
                    JoeYtCwPosterCard(
                        entry: entry,
                        series: ytStore.snapshot?.byPid[entry.slug],
                        focusID: "tvbcw|" + entry.key,
                        focus: $focusedEntry,
                        onTap: {
                            nav.ytDetail = JoeYtRoute(pid: entry.slug)
                        },
                        onRemove: {
                            watch.removeProgress(key: entry.key)
                        })
                }
            }
            .onAppear { ytStore.ensureLoaded() }
        }
    }

    @ViewBuilder
    private var favRail: some View {
        if !movieFavorites.isEmpty {
            Rail(title: "♥ Yêu thích") {
                ForEach(movieFavorites) { entry in
                    // FIX-214 (DESIGN-PASS-214 §1d): the tap
                    // is KIND-AWARE — a kindTor favourite
                    // reopens through the torrent route
                    // (the TorMeta + reopenBase mint, the
                    // Torrent home's own pattern); chain
                    // entries keep the MovieRoute.
                    Button {
                        if entry.kind == WatchStore.kindTor {
                            nav.tor = TorRoute(
                                meta: TorMeta(
                                    id: entry.metaId, type: entry.metaType,
                                    name: entry.title, poster: entry.poster,
                                    background: entry.background,
                                    year: entry.year, desc: entry.desc,
                                    isLive: entry.isLive),
                                base: entry.reopenBase)
                        } else {
                            nav.movie = MovieRoute(
                                provider: entry.source, slug: entry.slug,
                                name: entry.title, poster: entry.poster,
                                year: entry.year,
                                tvb: entry.tvbRouteContext)
                        }
                    } label: {
                        PosterCard(
                            title: entry.title,
                            posterURL: entry.posterURL,
                            meta: entry.year,
                            badge: Providers.badge(entry.source),
                            form: .rail)
                    }
                    .joeCardButton()
                    .focused($focusedEntry, equals: "fav|" + entry.key)
                    .contextMenu {
                        Button(role: .destructive) {
                            watch.removeFavorite(key: entry.key)
                        } label: {
                            Text("Bỏ yêu thích")
                        }
                    }
                    // v2.0.8 (Phase 1): plain button — no move
                    // handler (the conditional first-rail handler
                    // this spot carried when Continue Watching was
                    // empty is retired; see the focus-memory note
                    // above).
                }
            }
        }
    }

    /// IDEA 7a (v2.0.37, cluster D): the Following owner
    /// shelf for the rail homes (A / F) and the Ultra home —
    /// the third owner shelf, directly under Continue
    /// Watching / Favourites, exactly where theme D's
    /// followWallRail sits (JoeBrowse.swift). It renders
    /// through the SAME movieRail construction the rail
    /// previously used when it rode railSpecs (same Rail,
    /// same PosterCard, same "following|<id>" focus binding,
    /// and movieRail's existing scope == "following" tap
    /// rule clears the new-episode badge via markSeen) —
    /// only its POSITION changed, from last to the owner
    /// group. Visibility rule unchanged: only when the
    /// owner follows at least one title (followStore is the
    /// @ObservedObject FollowStore.shared, so it appears /
    /// disappears the moment a follow toggles).
    @ViewBuilder
    private var followRail: some View {
        if !followStore.followed.isEmpty {
            movieRail("📌 Đang theo dõi", followedMovies,
                      badges: true, scope: "following")
        }
    }

    /// v2.0.45 (leg 3): the user addon's Home section —
    /// one rail per non-search catalogue in manifest
    /// order, already match-filtered by the store
    /// (matched titles carry NO duplicate poster here;
    /// their streams join as backup links instead). The
    /// rails' own catalogue names head them — the owner's
    /// rails by content ("Phim Mới", "TVB", …). Renders
    /// nothing while no addon is in force or unloaded.
    /// The last card's appearance pages the next slice
    /// in (the store's skip= paging).
    @ViewBuilder
    private var addonSection: some View {
        ForEach(addonStore.rails) { rail in
            if !rail.metas.isEmpty {
                Rail(title: rail.catalog.name) {
                    ForEach(Array(rail.metas.enumerated()),
                            id: \.element.id) { pair in
                        Button {
                            if let base = addonStore.servingBase {
                                nav.addonDetail = JoeAddonRoute(
                                    base: base,
                                    type: pair.element.type,
                                    metaId: pair.element.id,
                                    name: pair.element.name,
                                    poster: pair.element.poster,
                                    year: pair.element.year,
                                    addonName: addonStore.addonName)
                            }
                        } label: {
                            PosterCard(
                                title: pair.element.name,
                                posterURL: pair.element.posterURL,
                                meta: pair.element.year,
                                form: .rail)
                        }
                        .joeCardButton()
                        .focused($focusedEntry,
                                 equals: "addon|" + rail.id + "|" + pair.element.id)
                        .onAppear {
                            if pair.offset == rail.metas.count - 1 {
                                addonStore.loadMore(railID: rail.id)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Catalogue rails

    private func movieRail(_ title: String, _ movies: [Movie], badges: Bool,
                           scope: String) -> some View {
        Rail(title: title) {
            ForEach(movies) { movie in
                Button {
                    // IDEA 7a: opening a Following-rail card
                    // clears its new-episode badge (the store's
                    // baseline catches up). Guarded strictly by
                    // scope — no other rail's tap path changes.
                    if scope == "following" {
                        FollowStore.shared.markSeen(provider: movie.provider,
                                                    slug: movie.slug)
                    }
                    nav.movie = MovieRoute(
                    provider: movie.provider, slug: movie.slug,
                    name: movie.name, poster: movie.poster, year: movie.year) } label: {
                    PosterCard(
                        title: movie.name,
                        posterURL: movie.posterURL,
                        tmdbId: movie.tmdbId,
                        tmdbType: movie.tmdbType,
                        meta: movie.cardMeta,
                        badge: badges ? Providers.badge(movie.provider) : nil,
                        quality: movie.quality,
                        timeBadge: movie.time,
                        yearBadge: movie.year,
                        form: .rail)
                }
                .joeCardButton()
                .focused($focusedMovie, equals: scope + "|" + movie.id)
                // v2.0.8 (Phase 1): plain button — no move
                // handler on ANY catalogue rail's cards (the
                // first rail's used to carry the retired
                // first-rail handler; see the focus-memory note
                // above).
            }
        }
    }

    // MARK: - Trending file rails (v2.1.1, DIAG-2050 §4)

    /// One trending DATA FILE rail (scope "fileTrending:…"):
    /// the same Rail + PosterCard construction as movieRail,
    /// except the tap — a placeholder Movie has no provider
    /// slug, so the tap runs resolveFileTrendingTap instead
    /// of minting a MovieRoute directly (DIAG-2050 §4 step
    /// 5: a placeholder must never mint a detail route).
    /// No provider badge: the placeholder's provider is
    /// empty and Providers.badge("") would lie ("KK").
    private func fileTrendingRail(_ spec: JoeRailSpec) -> some View {
        Rail(title: spec.title) {
            ForEach(spec.movies) { movie in
                Button {
                    Task { await resolveFileTrendingTap(movie) }
                } label: {
                    PosterCard(
                        title: movie.name,
                        posterURL: movie.posterURL,
                        tmdbId: movie.tmdbId,
                        tmdbType: movie.tmdbType,
                        meta: movie.cardMeta,
                        badge: nil,
                        quality: movie.quality,
                        timeBadge: movie.time,
                        yearBadge: movie.year,
                        form: .rail)
                }
                .joeCardButton()
                .focused($focusedMovie, equals: spec.scope + "|" + movie.id)
            }
        }
    }

    /// The file-trending tap resolution (DIAG-2050 §4 step
    /// 5), following the actor page's search-bridge pattern
    /// (JoeActorPage.resolveAndOpen): search the providers
    /// in Providers.priority order and open the matched
    /// record's normal MovieRoute — chain-first, the phim
    /// home's contract. The acceptance test here is
    /// Providers.sameFilm (normalised name/origin equality
    /// + year, the DIAG's name + year rule): the actor
    /// page's stricter TMDB-id acceptance cannot run —
    /// the file rail's TorMeta carries no TMDB id (see
    /// PhimStore.trendingFileSpec). If NO chain record
    /// matches, the tap falls through to the existing
    /// torrent route keyed by the item's IMDb id (every
    /// file item carries one — items without are skipped
    /// at parse), exactly as the title opens from the
    /// torrent home today. A tap is therefore never dead:
    /// chain detail when the chain carries the title,
    /// torrent detail otherwise.
    private func resolveFileTrendingTap(_ movie: Movie) async {
        for code in Providers.priority {
            guard let results = try? await Providers.search(
                code, keyword: movie.name)
            else { continue }
            if let hit = results.first(where: {
                !$0.slug.isEmpty && Providers.sameFilm(
                    $0, name: movie.name, origin: movie.originName,
                    year: movie.year)
            }) {
                nav.movie = MovieRoute(
                    provider: hit.provider, slug: hit.slug,
                    name: hit.name, poster: hit.poster, year: hit.year)
                return
            }
        }
        guard !movie.imdbId.isEmpty else { return }
        var meta = TorMeta()
        meta.id = movie.imdbId
        meta.imdbId = movie.imdbId
        meta.type = movie.type
        meta.name = movie.name
        meta.poster = movie.poster
        meta.year = movie.year
        nav.tor = TorRoute(meta: meta, base: TorrentSettings.cinemeta)
    }

}
