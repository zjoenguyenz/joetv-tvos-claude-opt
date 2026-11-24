import SwiftUI

/// Route into a torrent title.
struct TorRoute: Hashable {
    var meta: TorMeta
    /// The catalog base this meta came from (meta/videos source).
    var base: String
    /// Continue Watching taps: the episode stream id to preselect.
    var preselectStreamId: String = ""
}

/// Phim Torrent home: Cinemeta/Torrentio catalog rails + search +
/// the torrent Continue Watching rail — everything fetched live
/// at open, like the Android section. Streams come from the
/// owner's configured addon; nothing renders as playable until a
/// source is configured in Cài đặt.
struct JoeTorrentHome: View {
    @EnvironmentObject private var watch: WatchStore
    @EnvironmentObject private var nav: JoeNavigator
    @EnvironmentObject private var store: TorHomeStore
    @Environment(\.joeTheme) private var theme
    @State private var query = ""
    @State private var searchResults: [TorMeta] = []
    @State private var searching = false
    @State private var searchAttempted = false
    @State private var searchError: String?
    /// Team 4 fix-round minor: the home state surfaces (G3/G5)
    /// are gated on "a load has been attempted" so they cannot
    /// flash for a frame at cold entry, before the first
    /// loadIfNeeded has even run.
    @State private var torAttempted = false
    @FocusState private var focusedMeta: TorMeta.ID?
    @FocusState private var focusedEntry: String?
    @FocusState private var torRetryFocused: Bool
    @FocusState private var searchRetryFocused: Bool
    /// v2.1.1 (WS-I): the PC arm's focus-follows-backdrop
    /// controller (the shared JoeCinemaBackdropController,
    /// JoePrivateCinema.swift), fed from the SAME
    /// focusedMeta / focusedEntry memory torContextInfo
    /// derives from. Read only under the PC theme; every
    /// other theme ignores it.
    @StateObject private var torBackdrop =
        JoeCinemaBackdropController()
    /// v2.1.1 (FIX-6): the PC hero's action focus —
    /// while focus sits on the hero's own buttons
    /// focusedMeta / focusedEntry read nil, and
    /// torHeroMemory below is what keeps the hero on
    /// the last focused title (the JoePhimHome
    /// cinemaHeroMemory discipline).
    @FocusState private var torHeroPlayFocused: Bool
    @FocusState private var torHeroInfoFocused: Bool
    /// v2.1.1 (FIX-6): the last card-resolved hero, kept
    /// while focus is on the hero's actions or the
    /// search area (see torHeroFocusMoved).
    @State private var torHeroMemory: TorHeroResolved?

    /// v2.1.1 (FIX-10a / RECON-POWERMAX point 6): the
    /// context strip's memory — the last RESOLVED strip
    /// tuple, recorded in torHeroFocusMoved while a card
    /// is focused. When focus moves up to the tab bar
    /// (no card focused) the strip RETAINS this context
    /// instead of resetting to the section label; nil
    /// before any card has ever been focused (the rest
    /// behaviour is unchanged).
    @State private var torStripMemory: (title: String, meta: String, railName: String, railLine: String)?

    /// v2.1.1 (FIX-6): what the PC hero's two actions
    /// open for the currently resolved title — EXACTLY
    /// the focused card's own tap mint per surface (a
    /// catalogue / genre / search meta's TorRoute with
    /// its rail's base, a CW / favourite entry's
    /// TorRoute reopen mint).
    private enum TorHeroTarget {
        case meta(TorMeta, base: String)
        case entry(WatchStore.Entry, preselect: Bool)
    }

    /// v2.1.1 (FIX-6): a resolved torrent hero — the
    /// shared controller's item (text + art ladder) and
    /// the actions' target.
    private struct TorHeroResolved {
        var item: JoeCinemaHeroItem
        var target: TorHeroTarget
    }

    /// The search row's focusable elements, in visual order.
    /// Swift 6 round (fault (e)): the .field case is GONE —
    /// the row's field is a display, not a TextField (see
    /// searchRow), and typing lives on the letter strip,
    /// whose focus is keyFocus below.
    private enum SearchRowFocus: Hashable {
        case search, clear
    }
    @FocusState private var searchFocus: SearchRowFocus?
    /// The letter strip's focus (fault (e)): the same
    /// JoeSearchKeyFocus the Phim and TVB searches use.
    @FocusState private var keyFocus: JoeSearchKeyFocus?
    /// The debounced type-ahead driver (fault (e)): strip
    /// edits re-arm it, exactly as JoeSearchView's
    /// scheduleTypeAhead arms its rounds.
    @State private var searchTask: Task<Void, Never>?
    /// Search round generation (fault (e)): a new round —
    /// or a clear — supersedes any in-flight one, so a
    /// stale round's results can never land over a newer
    /// term's grid (JoeSearchView's roundID rule).
    @State private var searchRound = 0
    /// v2.0.49 (item 7): bumped by the section's Menu
    /// handler to make the home ScrollViewReader jump to
    /// the top of the page (owner order 2026-11-21).
    @State private var topScrollSignal = 0

    var body: some View {
        // GATE-213 R3 Lens 2 F1: the section's declared
        // initial landing is theme-branched — under
        // Private Cinema the letter strip does not exist
        // (R2 furniture gate), so the landing is the PC
        // hero's play button, as on the other PC homes;
        // every other theme keeps the strip landing
        // declared below torHomeContent's chain.
        if theme.id == .privateCinema {
            torHomeContent
                .defaultFocus($torHeroPlayFocused, true)
        } else {
            torHomeContent
                .defaultFocus($keyFocus, .key("a"))
        }
    }

    private var torHomeContent: some View {
            // v2.0.49 (item 7): the ScrollView sits inside
            // a ScrollViewReader so Menu can jump straight
            // to the top of the page (see .onExitCommand).
            ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 36,
                           pinnedViews: [.sectionHeaders]) {
                    // GATE-213 R2 Lens 3 F1 (RECALC-SPEC
                    // §3.6 + §5 closed ruling): under
                    // Private Cinema the Torrent home opens
                    // STRAIGHT with the hero — no furniture
                    // above it. The legacy header + in-home
                    // search row + letter strip render only
                    // on the legacy themes; under PC,
                    // torrent titles are found through the
                    // shell's Tìm phim (JoeSearchView routes
                    // to the torrent detail by IMDb id).
                    if theme.id != .privateCinema {
                        header
                        searchRow
                        // Fault (e): the in-app letter strip —
                        // typing lives here now, under the query
                        // display, exactly as on the Phim and TVB
                        // search screens (JoeSearchView /
                        // JoeTVBSearchView). The system TextField
                        // it replaces summoned Apple's full-screen
                        // keyboard and hid the home until "done".
                        JoeLetterStrip(query: $query, focus: $keyFocus)
                    }
                    if searching {
                        // C-10: searching is a visible state, not
                        // an empty grid.
                        ProgressView("Đang tìm…")
                            .font(.system(size: 29))
                            .foregroundStyle(theme.text)
                            .tint(.white)
                    } else if !searchResults.isEmpty {
                        searchGrid
                    } else if searchAttempted {
                        searchMessage
                    } else {
                        if theme.id == .privateCinema {
                            // v2.1.1 (FIX-6): the full PC
                            // hero (485 stage, the Phim
                            // hero's composition) above the
                            // rails — it supersedes WS-I's
                            // top-zone-only backdrop
                            // placement: the shared
                            // controller's layer now lives
                            // INSIDE the hero block, and
                            // the hero text + actions follow
                            // focus (torHeroResolved).
                            torHeroBlock
                        }
                        if theme.id == .privateCinema {
                            // v2.1.1 (WS-H): the Many-Rails
                            // PC arm — design order inside a
                            // Section whose header is the
                            // pinned context strip; the state
                            // surfaces below stay shared.
                            Section {
                                pcTorCwRail
                                pcTorProviderRails
                                pcTorExploreRails
                                // FIX-213 (Fault 7) + GATE-213
                                // R5 Lens 2 F1: favRail rides
                                // the shared Rail, which since
                                // the R4 gate fix carries the
                                // design's 94 frame itself
                                // under Private Cinema — no
                                // wrapper inset here (it
                                // double-inset the rail to
                                // 108).
                                favRail
                            } header: {
                                torContextStrip
                                    // claude/opt-2 (FL-427): Ink
                                    // above the strip while pinned.
                                    .joePCPinnedBandCover()
                            }
                            // claude/opt-2 (FL-457, owner
                            // ruling): the Section's plain
                            // Ink fill (v2.1.1 WS-I/FIX-6)
                            // is removed — it cut the
                            // full-screen page backdrop at
                            // the hero's foot. The rails
                            // now sit on the page scrim's
                            // near-full Ink, as on Trang
                            // chủ and Phim.
                            // FIX-213 (Fault 7): the
                            // design's bottom margin (64)
                            // — this shared stack's own
                            // spacing is 36, so a 28 pt
                            // clear tail lands the last
                            // rail exactly 64 above the
                            // frame's bottom edge.
                            Color.clear.frame(height: 28)
                        } else {
                        cwRail
                        favRail
                        ForEach(Array(store.catalogs.enumerated()), id: \.offset) { _, cat in
                            if let metas = store.rails[cat.id + "|" + cat.type], !metas.isEmpty {
                                metaRail(cat.name, metas, base: cat.base,
                                         scope: "torCat:\(cat.id)|\(cat.type)")
                            }
                        }
                        ForEach(Array(store.genreRails.enumerated()), id: \.offset) { _, rail in
                            if !rail.metas.isEmpty {
                                metaRail(rail.title, rail.metas, base: TorrentSettings.cinemeta,
                                         scope: "torGenre:\(rail.type):\(rail.genre)")
                            }
                        }
                        }
                        // C-4 + BLOCK-1: the torrent home's
                        // state surfaces are keyed on RAILS, not
                        // hasData — discoverCatalogs never returns
                        // empty (Cinemeta fallbacks), so hasData
                        // was always true and the old error
                        // surface could never fire in the
                        // dead-route case (~100 s of bare header).
                        // Spinner: bounded by the store's 20 s
                        // watchdog, and only while no catalogue
                        // rail has landed.
                        if store.loading && !store.loadTimedOut && torCatalogueEmpty {
                            ProgressView("Đang tải danh mục…")
                                .font(theme.id == .privateCinema
                                      ? JoePCType.outfit(29) : .system(size: 29))
                                .foregroundStyle(theme.text)
                                .tint(.white)
                        }
                        if torErrorVisible {
                            torErrorSurface
                        }
                        if torEmptyVisible {
                            Text("Chưa có danh mục nào.")
                                .font(theme.id == .privateCinema
                                      ? JoePCType.outfit(29) : .system(size: 29))
                                .foregroundStyle(theme.meta)
                        }
                        if !failedCatalogNames.isEmpty {
                            Text("Chưa tải được: " + failedCatalogNames.joined(separator: ", "))
                                .font(theme.id == .privateCinema
                                      ? JoePCType.outfit(25) : .system(size: 25))
                                .foregroundStyle(.orange)
                        }
                        if !TorrentSettings.isConfigured {
                            Text("Chưa cấu hình nguồn phát: vào Cài đặt nhập link Torrentio hoặc token Real-Debrid/TorBox của anh để lấy nguồn.")
                                .font(theme.id == .privateCinema
                                      ? JoePCType.outfit(25) : .system(size: 25))
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .id("joeTorHomeTop")
                // FIX-213 (Fault 16): under Private
                // Cinema the stack rides up by the bar's
                // height to cancel the scroll view's
                // bar-clearance inset (joePCBarInset
                // below) — rest geometry unchanged, but
                // the pinned context strip now pins
                // BELOW the bar instead of inside its
                // band. Other themes: no inset, no
                // compensation (their shell is a VStack).
                .padding(.top, theme.id == .privateCinema ? -joePCBarHeight : 0)
            }
            .joePCBarInset()
            // claude/opt-2 (FL-457): the full-screen backdrop behind
            // the whole page (Private Cinema only; see JoePrivateCinema).
            .joePCPageBackdrop(torBackdrop)
            // v2.1.1 (FIX-6): WS-I's ScrollView-background
            // backdrop placement is REMOVED — the shared
            // controller's layer now lives inside the PC
            // hero block (torHeroBlock), in-flow, exactly
            // like the Phim hero. Other themes never had
            // a background here and still do not.
            // v2.0.49 (item 7): the Menu-to-top jump's
            // scroll hook, inside the reader.
            .onChange(of: topScrollSignal) { _, _ in
                proxy.scrollTo("joeTorHomeTop", anchor: .top)
            }
            }
            // CONVERGENCE (Team 7 D4, 2026-11-15): the four
            // JoeMoveTrap modifiers that wrapped this ScrollView
            // (enabled by searchFocus / firstRailFocusIndex /
            // torRetryFocused / searchRetryFocused) are REMOVED —
            // each flip rebuilt the ENTIRE ScrollView subtree
            // under the focus engine.
            // v2.0.8 (Phase 1): the first rail's surviving
            // arithmetic handler (handleFirstRailMove) is now
            // REMOVED too, with the search grid's handler. An
            // attached .onMoveCommand owns EVERY direction and
            // undeclared directions die instead of falling
            // through to the focus engine, so routing is now
            // entirely the engine's geometric search: the
            // search row, the Retry buttons and the rails are
            // plain focusable elements in one stack, each rail
            // a .focusSection() via the shared Rail view, so
            // UP/DOWN/LEFT/RIGHT between them is geometric
            // (the search row's LEFT/RIGHT order — field → Tìm
            // → Xoá — is its visual order; a disabled Tìm
            // during search is skipped by the engine).
        .task {
            torAttempted = true
            store.loadIfNeeded()
        }
        // Fault (e): strip edits drive the search — the
        // onChange that used to sit on the TextField (the
        // JoeSearchView placement).
        .onChange(of: query) { _, _ in scheduleSearch() }
        // 1.9.2 (Team 9 items 4 + 8): Menu in this SECTION
        // returns to the Phim section — the app's main menu —
        // instead of exiting the app (the owner's Android
        // model: Back walks inside the app; exit only from the
        // Phim root, which carries no handler). Unconditional,
        // on this section's own root. And the search area is
        // the section's declared initial focus — the same
        // static .defaultFocus construction as JoeSearchView's
        // (the convergence round's geometric assumption left
        // the torrent search row with no declared landing).
        // Fault (e): the landing is the letter strip's first
        // key — the TextField this declaration used to name
        // (.field) no longer exists, exactly as in
        // JoeSearchView since v2.0.17. GATE-213 R3 Lens 2
        // F1: that .defaultFocus declaration now sits in
        // `body`, branched by theme (the hero play button
        // under Private Cinema, the strip key elsewhere).
        .onExitCommand {
            // v2.0.49 (item 7, owner order 2026-11-21
            // 22:32): Menu jumps straight to the top of
            // the page first. Focus anywhere on the
            // letter strip (keyFocus != nil — the strip
            // is the page's top region and its "a" key
            // the declared landing) keeps the existing
            // return to Phim; anywhere else, Menu scrolls
            // to the top and lands focus on the strip,
            // swallowing the exit.
            // GATE-213 R3 Lens 2 F1: the Private Cinema
            // arm mirrors the same two steps against the
            // hero — focus on either hero button returns
            // to Trang chủ; anywhere else, Menu scrolls
            // to the top and lands on the hero play
            // button. (The strip is not rendered under
            // PC, so keyFocus can never be set there.)
            if theme.id == .privateCinema {
                if torHeroDisplayResolved() == nil {
                    // GATE-213 R7 Lens 2 F1: no hero on
                    // screen (initial load, error and
                    // empty states — torHeroBlock renders
                    // nothing until a title resolves), so
                    // $torHeroPlayFocused has no holder:
                    // the body's .defaultFocus names it,
                    // but no view is bound to it, and the
                    // state surface's own control (the
                    // error surface's "Thử lại") holds the
                    // focus. The landing write below was
                    // a visibly dead press there — only a
                    // scroll to the top of an already-top
                    // page — and reaching Trang chủ
                    // depended on the state flip surviving
                    // to a second press. Mirror the R6
                    // fixes on the sibling PC homes
                    // (JoePhimHome / JoeTVB): go home on
                    // the first press.
                    nav.section = .home
                } else if torHeroPlayFocused || torHeroInfoFocused {
                    nav.section = .home
                } else {
                    topScrollSignal += 1
                    torHeroPlayFocused = true
                }
            } else if keyFocus != nil {
                nav.section = .home  // FIX-213 (Fault 13): return to Trang chủ (.home), the home surface since the split
            } else {
                topScrollSignal += 1
                keyFocus = .key("a")
            }
        }
        // v2.1.1 (WS-I): focus-follows backdrop, PC arm
        // only (the resolver no-ops under every other
        // theme): focusedMeta / focusedEntry are the
        // focus memory torContextInfo reads — every move
        // feeds the backdrop controller; the debounce
        // task inside the controller is the only
        // scheduled work (FL-017).
        .onChange(of: focusedMeta) { _, new in
            // FIX-214 (DESIGN-PASS-214 §3.3): the focus
            // breadcrumb for this surface (see the
            // JoePhimHome note — the TVB hook was the
            // only noteFocus caller through 2.1.3).
            DiagLog.noteFocus(surface: "torrent-home", key: new)
            torHeroFocusMoved()
        }
        .onChange(of: focusedEntry) { _, new in
            DiagLog.noteFocus(surface: "torrent-home", key: new)
            torHeroFocusMoved()
        }
        // v2.1.1 (FIX-6): the rails landing (or the CW
        // entries changing) re-seeds the hero's default
        // title — onAppear fires before the store's
        // first load lands.
        .onChange(of: store.rails.count) { _, _ in torHeroFocusMoved() }
        .onChange(of: torProgress.count) { _, _ in torHeroFocusMoved() }
        .onAppear { torHeroFocusMoved() }
    }

    /// Feed the torrent hero + backdrop controller
    /// from the focus memory (v2.1.1, WS-I; FIX-6 —
    /// the full hero): a card focus resolves +
    /// remembers the hero and pushes its item to the
    /// controller (text first — the block renders the
    /// same resolution in body — backdrop after the
    /// controller's debounce). NO card focus keeps
    /// the remembered hero (focus is on the hero's
    /// actions or the search area); before any focus
    /// the default resolution (the first title of the
    /// first visible rail) seeds both.
    private func torHeroFocusMoved() {
        guard theme.id == .privateCinema else { return }
        if focusedMeta != nil || focusedEntry != nil {
            if let resolved = torHeroResolved() {
                // FIX-12 / R7 B-1: record the strip's
                // resolved tuple ONLY when the hero
                // resolution actually resolved the FOCUSED
                // card (this existing hook only — FL-017;
                // no new per-focus work). torHeroResolved
                // returns nil when a focused card no
                // longer resolves (a reload removed it),
                // and its focused branches key the item
                // by the focus ID itself — the rest
                // fallback keys it "rest|…", so the key
                // test can never pass for a rest tuple.
                if resolved.item.key == focusedMeta
                    || resolved.item.key == focusedEntry {
                    torStripMemory = torContextInfo
                }
                torHeroMemory = resolved
                torBackdrop.focusChanged(to: resolved.item)
            }
            return
        }
        if torHeroMemory != nil { return }
        if let resolved = torHeroResolved() {
            torHeroMemory = resolved
            torBackdrop.focusChanged(to: resolved.item)
        }
    }

    /// The hero the block renders: the live resolution
    /// while a card is focused; the remembered hero
    /// once focus has left the cards; the default
    /// resolution before either exists.
    private func torHeroDisplayResolved() -> TorHeroResolved? {
        if focusedMeta != nil || focusedEntry != nil {
            return torHeroResolved()
        }
        return torHeroMemory ?? torHeroResolved()
    }

    /// The hero for the current focus, resolved from
    /// the SAME focus memory torContextInfo derives
    /// from (catalogue / genre / search metas, then CW
    /// / favourite entries); before any focus, the
    /// first title of the first VISIBLE rail in the PC
    /// stack's order (Xem tiếp → landed catalogues →
    /// genre rails → Yêu thích). Art ladder is WS-I's:
    /// a TorMeta's background then its poster; an
    /// entry's own background then its poster. The
    /// meta line and synopsis come only from fields
    /// TorMeta actually carries: year and desc — the
    /// model has NO rating, runtime, quality / age or
    /// localized-name field, so the drawing's ★ /
    /// duration / chips / Vietnamese sub-line are
    /// omitted, never invented (see the FIX-6 report).
    private func torHeroResolved() -> TorHeroResolved? {
        if let focusedMeta {
            if let meta = (store.rails.values.flatMap { $0 }
                           + store.genreRails.flatMap { $0.metas }
                           + searchResults)
                .first(where: { focusedMeta.hasSuffix("|" + $0.id) }) {
                return TorHeroResolved(
                    item: JoeCinemaHeroItem(
                        key: focusedMeta,
                        title: meta.name,
                        meta: meta.year,
                        synopsis: meta.desc,
                        backdropURL: meta.background.isEmpty
                            ? nil : URL(string: meta.background),
                        posterURL: meta.posterURL),
                    target: .meta(
                        meta,
                        base: torHeroBase(forFocusedMeta: focusedMeta,
                                          meta: meta)))
            }
        }
        if let focusedEntry {
            if let entry = torProgress.first(where: { "cw|" + $0.key == focusedEntry }) {
                return TorHeroResolved(
                    item: JoeCinemaHeroItem(
                        key: focusedEntry,
                        title: entry.title,
                        meta: entry.epLabel,
                        synopsis: entry.desc,
                        backdropURL: entry.background.isEmpty
                            ? nil : URL(string: entry.background),
                        posterURL: entry.posterURL),
                    target: .entry(entry, preselect: true))
            }
            if let entry = torFavorites.first(where: { "fav|" + $0.key == focusedEntry }) {
                return TorHeroResolved(
                    item: JoeCinemaHeroItem(
                        key: focusedEntry,
                        title: entry.title,
                        meta: entry.year,
                        synopsis: entry.desc,
                        backdropURL: entry.background.isEmpty
                            ? nil : URL(string: entry.background),
                        posterURL: entry.posterURL),
                    target: .entry(entry, preselect: false))
            }
        }
        if focusedMeta != nil || focusedEntry != nil { return nil }
        // Rest / default: the first title of the first
        // visible rail, in the PC stack's render order.
        if let entry = torProgress.first {
            return TorHeroResolved(
                item: JoeCinemaHeroItem(
                    key: "rest|cw|" + entry.key,
                    title: entry.title,
                    meta: entry.epLabel,
                    synopsis: entry.desc,
                    backdropURL: entry.background.isEmpty
                        ? nil : URL(string: entry.background),
                    posterURL: entry.posterURL),
                target: .entry(entry, preselect: true))
        }
        for cat in pcTorLandedCatalogs {
            if let meta = store.rails[cat.id + "|" + cat.type]?.first {
                return TorHeroResolved(
                    item: JoeCinemaHeroItem(
                        key: "rest|torCat:" + cat.id + "|" + cat.type
                            + "|" + meta.id,
                        title: meta.name,
                        meta: meta.year,
                        synopsis: meta.desc,
                        backdropURL: meta.background.isEmpty
                            ? nil : URL(string: meta.background),
                        posterURL: meta.posterURL),
                    target: .meta(meta, base: cat.base))
            }
        }
        for rail in store.genreRails where !rail.metas.isEmpty {
            if let meta = rail.metas.first {
                return TorHeroResolved(
                    item: JoeCinemaHeroItem(
                        key: "rest|torGenre:" + rail.type + ":"
                            + rail.genre + "|" + meta.id,
                        title: meta.name,
                        meta: meta.year,
                        synopsis: meta.desc,
                        backdropURL: meta.background.isEmpty
                            ? nil : URL(string: meta.background),
                        posterURL: meta.posterURL),
                    target: .meta(meta, base: TorrentSettings.cinemeta))
            }
        }
        if let entry = torFavorites.first {
            return TorHeroResolved(
                item: JoeCinemaHeroItem(
                    key: "rest|fav|" + entry.key,
                    title: entry.title,
                    meta: entry.year,
                    synopsis: entry.desc,
                    backdropURL: entry.background.isEmpty
                        ? nil : URL(string: entry.background),
                    posterURL: entry.posterURL),
                target: .entry(entry, preselect: false))
        }
        return nil
    }

    /// The TorRoute base for a focused meta (v2.1.1,
    /// FIX-6): scope-first, mirroring torContextInfo's
    /// FIX-5 resolution — a "torCat:" focus ID names
    /// its own catalogue (that catalogue's base, the
    /// metaRail / torPcMetaRail mint); genre and search
    /// cards mint against TorrentSettings.cinemeta
    /// (pcTorExploreRails / searchGrid).
    private func torHeroBase(forFocusedMeta focused: String,
                             meta: TorMeta) -> String {
        if focused.hasPrefix("torCat:") {
            let segments = focused.dropFirst("torCat:".count)
                .split(separator: "|")
            let catId = segments.first.map(String.init) ?? ""
            let catType = segments.count > 1 ? String(segments[1]) : ""
            if let cat = pcTorLandedCatalogs.first(where: {
                $0.id == catId && (catType.isEmpty || $0.type == catType)
            }) {
                return cat.base
            }
        }
        return TorrentSettings.cinemeta
    }

    /// The hero actions' tap (v2.1.1, FIX-6): perform
    /// the resolved title's OWN card tap — the
    /// identical TorRoute mint each rail builder
    /// performs (cwRail / favRail rebuild the meta
    /// from the entry's stored fields, exactly as
    /// here), nothing new.
    private func torOpenHeroTarget(_ target: TorHeroTarget) {
        switch target {
        case .meta(let meta, let base):
            nav.tor = TorRoute(meta: meta, base: base)
        case .entry(let entry, let preselect):
            nav.tor = TorRoute(
                meta: TorMeta(id: entry.metaId, type: entry.metaType,
                              name: entry.title, poster: entry.poster,
                              background: entry.background,
                              year: entry.year, desc: entry.desc,
                              isLive: entry.isLive),
                base: entry.reopenBase,
                preselectStreamId: preselect ? entry.streamId : "")
        }
    }

    /// The Private Cinema torrent hero block (v2.1.1,
    /// FIX-6): the Phim hero's composition verbatim —
    /// the shared controller's crossfade layer as a
    /// 485-tall full-width stage, the same three
    /// scrims, the text stack at the same positions,
    /// and the right-side tagline block. Renders
    /// nothing until a title resolves (the state
    /// surfaces below own the loading / empty states).
    @ViewBuilder
    private var torHeroBlock: some View {
        if let resolved = torHeroDisplayResolved() {
            ZStack(alignment: .bottomLeading) {
                // claude/opt-2 (FL-457): the stage is TEXT-ONLY — the
                // backdrop and its scrims moved to page level
                // (joePCPageBackdrop on the scroll view). This clear
                // spacer keeps the stage's full-width frame, so the
                // text, the tagline anchor and the strip below sit
                // exactly where they did.
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: 560)
                // FIX-214 (FULL-THEME-AUDIT-214 Phần C họ
                // 1): the design's Ink scrims
                // (JoeCinemaScrims), shared by all three
                // heroes.
                // FIX-213 (Fault 8): NO top scrim — the
                // design draws exactly two scrims on this
                // stage (left + bottom); the third one
                // that stood here was added by the build
                // for the OLD bar's legibility and
                // darkened the art under the bar zone
                // ("Làm che luôn backdrop"). See
                // cinemaHeroBlock in JoePhimHome.swift.
                torHeroText(resolved)
            }
            .frame(height: 560)
            // FIX-213 (Fault 7): full-bleed stage, as
            // on the Phim hero — the block bleeds
            // across the shell's 80 pt ambient inset;
            // the hero text keeps the design's x94
            // inside torHeroText and the tagline ends
            // at 1826.
            .padding(.horizontal, -80)
            .overlay(alignment: .bottomTrailing) {
                torHeroTagline
                    .padding(.trailing, 94)
                    .padding(.bottom, 72)
            }
        }
    }

    /// The torrent hero's text block (v2.1.1, FIX-6 —
    /// a named helper per FL-390): the drawing's
    /// static section eyebrow, typeset title, meta
    /// line, synopsis (only when the meta carries a
    /// desc) and the design's TWO actions — pale
    /// "▶ Chọn nguồn phát" and dark "ⓘ Thông tin
    /// phim", BOTH wired to the resolved title's own
    /// torrent-detail route via torOpenHeroTarget.
    /// Geometry mirrors JoePhimHome.cinemaHeroText
    /// exactly.
    private func torHeroText(_ resolved: TorHeroResolved) -> some View {
        let item = resolved.item
        // FIX-214 (DESIGN-PASS-214 §1a): the measured
        // 394 text-zone budget, as on the Phim hero —
        // the synopsis is the only compressible row.
        let titleLines = min(2, JoeHeroMeasure.lines(
            of: item.title,
            postScriptName: "BricolageGrotesque-Medium",
            size: 72, width: 850))
        var synopsisLimit = item.synopsis.isEmpty ? 0
            : min(2, JoeHeroMeasure.lines(
                of: item.synopsis, postScriptName: "Outfit-Regular",
                size: 20, width: 665))
        func torBlockHeight() -> CGFloat {
            var h: CGFloat = 72
            h += JoeHeroMeasure.lineHeight(
                postScriptName: "Outfit-Medium", size: 15)
            h += 12 + JoeHeroMeasure.lineHeight(
                postScriptName: "BricolageGrotesque-Medium",
                size: 72) * CGFloat(titleLines)
            if !item.meta.isEmpty {
                h += 12 + JoeHeroMeasure.lineHeight(
                    postScriptName: "Outfit-Regular", size: 20)
            }
            if synopsisLimit > 0 {
                h += 10 + JoeHeroMeasure.lineHeight(
                    postScriptName: "Outfit-Regular", size: 20)
                    * CGFloat(synopsisLimit)
                    + 10 * CGFloat(synopsisLimit - 1)
            }
            h += 16 + 55
            return h
        }
        while torBlockHeight() > 394 && synopsisLimit > 0 {
            synopsisLimit -= 1
        }
        return VStack(alignment: .leading, spacing: 0) {
            // FIX-214 (FULL-THEME-AUDIT-214 B5): the
            // drawn eyebrow ends "· ĐANG CHỌN".
            Text("THƯ VIỆN TORRENT CỦA BẠN / TORRENT · ĐANG CHỌN")
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
            if !item.meta.isEmpty {
                // FIX-214: ivory meta line, only the ★
                // celadon (JoeCinemaMetaText).
                JoeCinemaMetaText(meta: item.meta)
                    .padding(.top, 12)
            }
            if synopsisLimit > 0 {
                Text(item.synopsis)
                    // FIX-214: 20/400, spacing 10, clamp =
                    // the measured budget limit, max 665.
                    .font(JoePCType.outfit(20))
                    .foregroundStyle(theme.text.opacity(0.92))
                    .lineSpacing(10)
                    .lineLimit(synopsisLimit)
                    .frame(maxWidth: 665, alignment: .leading)
                    .padding(.top, 10)
            }
            HStack(spacing: 16) {
                Button {
                    torOpenHeroTarget(resolved.target)
                } label: {
                    JoePrimaryLabel(title: "Chọn nguồn phát",
                                    systemImage: "play.fill")
                }
                .joeCardButton()
                .focused($torHeroPlayFocused)
                Button {
                    torOpenHeroTarget(resolved.target)
                } label: {
                    JoeSecondaryLabel(title: "Thông tin phim",
                                      systemImage: "info.circle")
                }
                .joeCardButton()
                .focused($torHeroInfoFocused)
            }
            .padding(.top, 16)
        }
        // FIX-213 (Fault 7): the hero block now bleeds
        // to the frame's edges (see torHeroBlock), so
        // this inset is the design's own hero x94
        // (many-rail spec: hero x94, w850).
        .padding(.leading, 94)
        .padding(.vertical, 36)
        // FIX-214: 94 + 850 = 944, the drawn content
        // width (the B2 family fix).
        .frame(maxWidth: 944, alignment: .leading)
    }

    /// The hero's right-side tagline block (v2.1.1,
    /// FIX-6 — the drawing's block, shared by all
    /// three PC heroes): the italic line over the caps
    /// line with THIS home's real visible rail count
    /// (pcTorVisibleRailTitles — the strip's own list).
    private var torHeroTagline: some View {
        // FIX-214 (FULL-THEME-AUDIT-214 B5): the drawn
        // copy — "Phim đang được chọn" over
        // "<TITLE> · <N> DÃY PHIM"; the invented lines
        // are removed, as on the other two heroes.
        let heroTitle = (torHeroDisplayResolved()?.item.title
                         ?? "").uppercased()
        return VStack(alignment: .trailing, spacing: 8) {
            Text("Phim đang được chọn")
                .font(JoePCType.editorial(28, italic: true))
                .foregroundStyle(theme.text)
                .lineLimit(1)
            Text("\(heroTitle) · \(pcTorVisibleRailTitles.count) DÃY PHIM")
                .font(JoePCType.outfit(14, weight: .medium))
                .tracking(3)
                .foregroundStyle(theme.heroMeta)
                .lineLimit(1)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Phim Torrent")
                .font(.system(size: 56, weight: .heavy))
                .foregroundStyle(theme.text)
            Text("Nguồn Torrentio + Real-Debrid của anh — lấy mới mỗi lần mở")
                .font(.system(size: 25))
                .foregroundStyle(theme.meta)
        }
    }

    private var searchRow: some View {
        HStack(spacing: 18) {
            // Fault (e): the field is a DISPLAY now (the
            // JoeSearchView fieldRow construction — the
            // field's chrome, never focused): the query text
            // or its placeholder, painted by joeFieldChrome
            // exactly as the old field painted it, at the
            // same 820 width. There is no TextField here any
            // more, so focusing this row can never summon
            // the system keyboard; typing happens on the
            // letter strip directly below (see body).
            HStack(spacing: 14) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 26, weight: .semibold))
                Text(query.isEmpty ? "Tìm phim torrent…" : query)
                    .font(theme.id == .privateCinema ? JoePCType.outfit(29, weight: .light) : .system(size: ThemeTokens.fieldTextSize))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .joeFieldChrome(focused: false)
            .frame(width: 820)
            Button {
                runSearch()
            } label: {
                JoeSecondaryLabel(title: searching ? "Đang tìm…" : "Tìm")
            }
            .joeCardButton()
            .focused($searchFocus, equals: .search)
            .disabled(searching)
            if !searchResults.isEmpty {
                Button {
                    // Fault (e): the clear supersedes any
                    // in-flight round (searchRound bump), so
                    // its results cannot repaint over the
                    // cleared home a moment later.
                    searchRound += 1
                    searching = false
                    searchResults = []
                    query = ""
                    searchAttempted = false
                    searchError = nil
                } label: {
                    JoeSecondaryLabel(title: "Xoá tìm kiếm")
                }
                .joeCardButton()
                .focused($searchFocus, equals: .clear)
            }
        }
        // v2.0.5 (N1, pair g): the search row is a declared
        // focus region; the rails below are regions of their
        // own (the shared Rail carries .focusSection()).
        // v2.0.8: no handler declares an UP landing back onto
        // this row any more — the engine's geometric search
        // finds this region from the rails below on its own.
        .focusSection()
    }

    private var torProgress: [WatchStore.Entry] {
        Array(WatchStore.filterKinds(watch.progress(), [WatchStore.kindTor])
            .prefix(WatchStore.railCap))
    }

    @ViewBuilder
    private var cwRail: some View {
        if !torProgress.isEmpty {
            Rail(title: "▶ Đang xem dở") {
                ForEach(torProgress) { entry in
                    let card = Button { nav.tor = TorRoute(
                        meta: TorMeta(id: entry.metaId, type: entry.metaType,
                                      name: entry.title, poster: entry.poster,
                                      background: entry.background,
                                      year: entry.year, desc: entry.desc,
                                      isLive: entry.isLive),
                        base: entry.reopenBase,
                        preselectStreamId: entry.streamId) } label: {
                        PosterCard(
                            title: entry.title,
                            posterURL: entry.posterURL,
                            meta: entry.epLabel,
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
                    // v2.0.8 (Phase 1): no move handler — the
                    // card is a plain focusable in its rail's
                    // .focusSection(); movement is geometric.
                    card
                }
            }
        }
    }

    private var torFavorites: [WatchStore.Entry] {
        Array(WatchStore.filterKinds(watch.favorites(), [WatchStore.kindTor])
            .prefix(WatchStore.railCap))
    }

    @ViewBuilder
    private var favRail: some View {
        if !torFavorites.isEmpty {
            Rail(title: "♥ Yêu thích") {
                ForEach(torFavorites) { entry in
                    let card = Button { nav.tor = TorRoute(
                        meta: TorMeta(id: entry.metaId, type: entry.metaType,
                                      name: entry.title, poster: entry.poster,
                                      background: entry.background,
                                      year: entry.year, desc: entry.desc,
                                      isLive: entry.isLive),
                        base: entry.reopenBase) } label: {
                        PosterCard(
                            title: entry.title,
                            posterURL: entry.posterURL,
                            meta: entry.year,
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
                    // v2.0.8 (Phase 1): no move handler (the
                    // first-rail arithmetic that used to attach
                    // here when Continue Watching was empty is
                    // removed) — movement is geometric.
                    card
                }
            }
        }
    }

    // v2.0.8 (Phase 1): the first-rail routing model that
    // lived here (TorRailItem / torRails, under a "Focus
    // traversal" mark) is DELETED with its handler — nothing
    // in this file routes focus by hand any more; the
    // engine's geometric search over the declared
    // .focusSection() regions owns all movement.

    /// True when NO catalogue rail has anything — the catalogue
    /// rails dict and the genre rails are both empty. (The
    /// owner's own CW/Favourites rails do not count: they are
    /// not catalogue health, same C-8 logic as the Phim home.)
    private var torCatalogueEmpty: Bool {
        store.genreRails.allSatisfy { $0.metas.isEmpty }
            && store.rails.values.allSatisfy { $0.isEmpty }
    }

    /// BLOCK-1 (Team 4): the G3 error surface is keyed on RAILS,
    /// never on hasData (discoverCatalogs' Cinemeta fallbacks
    /// make hasData permanently true). It fires when the store's
    /// 20 s watchdog tripped (loadTimedOut — possibly with jobs
    /// still in flight), OR when a load has ENDED with the
    /// catalogue list known but zero rails landed — every
    /// catalogue fetch came back empty or failed, which on a
    /// dead route is the failure case that used to sit at a bare
    /// header for ~100 s. The attempted gate keeps it from
    /// flashing at cold entry.
    private var torErrorVisible: Bool {
        torAttempted && torCatalogueEmpty
            && (store.loadTimedOut
                || (!store.loading && !store.catalogs.isEmpty))
    }

    /// §8/G5, folded per Team 4's instruction: the store exposes
    /// no per-catalogue error state the view could use to tell
    /// "every fetch failed" from "genuinely nothing exists", so
    /// the truly-empty line is reserved for the one state that
    /// can honestly carry it — a load that ended with NO
    /// catalogue list at all, no timeout, no rails. (With the
    /// Cinemeta fallbacks in discoverCatalogs this state is
    /// currently unreachable; an ended load with catalogues but
    /// zero rails is the G3 surface above, whose Retry forces a
    /// real reload.)
    private var torEmptyVisible: Bool {
        torAttempted && torCatalogueEmpty && !store.loading
            && !store.loadTimedOut && store.catalogs.isEmpty
    }

    /// Catalogues that produced no rail after a completed load,
    /// for the G4 bottom line (only when at least one catalogue
    /// DID produce a rail — the all-failed case is the G5/G3
    /// surface's job).
    private var failedCatalogNames: [String] {
        guard !store.loading, store.hasData else { return [] }
        let names = store.catalogs.compactMap { cat -> String? in
            let metas = store.rails[cat.id + "|" + cat.type]
            return (metas?.isEmpty ?? true) ? cat.name : nil
        }
        return names.count < store.catalogs.count ? names : []
    }

    /// The G3 error shape, torrent edition (C-4 + BLOCK-1).
    /// Retry calls the store's FORCED reload — loadIfNeeded's
    /// freshness guard could no-op here, which is exactly the
    /// dead-end BLOCK-1 names.
    private var torErrorSurface: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text("Không tải được danh mục torrent.")
                .font(theme.id == .privateCinema
                      ? JoePCType.outfit(29, weight: .semibold)
                      : .system(size: 29, weight: .semibold))
                .foregroundStyle(theme.text)
            // 1.9.2 (Team 9 item 6): the copy names the likely
            // cause — the torrent route itself, and the tunnel
            // profile's known habit of blocking it — instead of
            // a generic network shrug.
            Text("Chưa tải được mục Torrent — đường tới Torrentio/Cinemeta đang không thông. Nếu profile hầm đang bật, đường này thường bị chặn; thử tắt hầm rồi bấm Thử lại.")
                .font(theme.id == .privateCinema
                      ? JoePCType.outfit(25) : .system(size: 25))
                .foregroundStyle(theme.meta)
            Button { store.reload() } label: {
                JoePrimaryLabel(title: "Thử lại")
            }
            .joeCardButton()
            .focused($torRetryFocused)
        }
    }

    /// C-10: after a search, the results area says what happened —
    /// "no matches" and "the search failed" are different surfaces.
    @ViewBuilder
    private var searchMessage: some View {
        if let searchError {
            VStack(alignment: .leading, spacing: 16) {
                Text(searchError)
                    .font(.system(size: 25))
                    .foregroundStyle(.orange)
                Button { runSearch() } label: {
                    JoePrimaryLabel(title: "Thử lại")
                }
                .joeCardButton()
                .focused($searchRetryFocused)
            }
        } else {
            Text("Không tìm thấy kết quả nào.")
                .font(.system(size: 29))
                .foregroundStyle(theme.meta)
        }
    }

    // v2.0.8 (Phase 1): currentTorRailItem /
    // firstRailFocusIndex / firstTorScope / setTorRailFocus
    // are DELETED with handleFirstRailMove below — they
    // existed only to feed the first-rail arithmetic. The
    // @FocusState declarations themselves stay: their
    // .focused bindings still give every card its focus
    // identity for the engine (and its per-screen memory).

    // CONVERGENCE (2026-11-15): the search-row boundary
    // handler (handleSearchRowMove) is DELETED with its trap.
    // Its outcomes are what geometric focus movement does on
    // this layout unaided: UP → the pills, LEFT/RIGHT → the
    // row's elements in visual order (the engine additionally
    // skips the Tìm button while it is disabled mid-search —
    // an improvement over the old arithmetic walk), DOWN →
    // the first result / first rail card / the visible Retry.
    // The two Retry buttons' UP-to-field routing is likewise
    // geometric (the field is the nearest focusable above).

    // v2.0.8 (Phase 1): handleFirstRailMove is DELETED. Its
    // UP landing (the search field), its LEFT/RIGHT rail
    // neighbours and its DOWN same-index landing in the next
    // rail are all moves the focus engine's geometric search
    // makes unaided inside the rails' .focusSection()
    // regions; the single-rail DOWN landing on the error
    // surface's Retry is likewise the nearest focusable
    // below. No direction is hand-routed in this file now.

    private func metaRail(_ title: String, _ metas: [TorMeta], base: String,
                          scope: String) -> some View {
        Rail(title: title) {
            ForEach(metas) { meta in
                let card = Button { nav.tor = TorRoute(meta: meta, base: base) } label: {
                    PosterCard(
                        title: meta.name,
                        posterURL: meta.posterURL,
                        meta: meta.year,
                        form: .rail)
                }
                .joeCardButton()
                .focused($focusedMeta, equals: scope + "|" + meta.id)
                // v2.0.8 (Phase 1): no move handler on any
                // catalogue rail (the first rail's used to
                // attach here) — movement is geometric.
                card
            }
        }
    }

    // MARK: - Private Cinema Many-Rails (v2.1.1, WS-H)

    /// The PC rail shell (WS-H): the shared Rail's
    /// construction mirrored at the design's rhythm —
    /// heading 27 pt medium, card gap 25, side margin 94
    /// total (shell 80 + 14 leading here).
    private func torPcRailShell<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(JoePCType.display(27, weight: .medium))
                .tracking(-0.3)
                .foregroundStyle(theme.text)
                // FIX-213 (Fault 7): heading at the
                // design's 94 (shell 80 + 14 here); the
                // track below owns the frame, as on the
                // Phim home's cinemaRailShell.
                .padding(.leading, 14)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 25) { content() }
                    // FIX-213 (Fault 7): the design's
                    // track insets (94 / 94) inside a
                    // track bled across the shell's 80 pt
                    // ambient inset — first card at x94,
                    // last card resting 94 short of the
                    // right edge, scrolled cards painting
                    // to both bezels, as drawn.
                    .padding(.leading, 94)
                    .padding(.trailing, 94)
                    // FIX-5 / Lens C Finding 1 (C5) +
                    // FIX-213 (Fault 14): track padding
                    // 16/11 + row padding 8/9 — the
                    // design's measured poster row (395)
                    // is their sum; carrying only 8/9
                    // compressed every rail by ~26.
                    .padding(.top, 24)
                    .padding(.bottom, 20)
            }
            .scrollClipDisabled()
            .padding(.horizontal, -80)
        }
        .focusSection()
    }

    /// Design rail 1 (WS-H): Continue Watching FIRST as
    /// landscape 320×180 cards with progress bars
    /// (JoeCinemaCwCard, JoePhimHome.swift — same module);
    /// data, tap and context menu are cwRail's own.
    @ViewBuilder
    private var pcTorCwRail: some View {
        if !torProgress.isEmpty {
            torPcRailShell(title: "Xem tiếp") {
                ForEach(torProgress) { entry in
                    Button { nav.tor = TorRoute(
                        meta: TorMeta(id: entry.metaId, type: entry.metaType,
                                      name: entry.title, poster: entry.poster,
                                      background: entry.background,
                                      year: entry.year, desc: entry.desc,
                                      isLive: entry.isLive),
                        base: entry.reopenBase,
                        preselectStreamId: entry.streamId) } label: {
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

    /// The landed catalogues in store order (the PC
    /// rails' feeders).
    private var pcTorLandedCatalogs: [TorCatalog] {
        store.catalogs.filter {
            !(store.rails[$0.id + "|" + $0.type]?.isEmpty ?? true)
        }
    }

    /// Design rails 2–4 (WS-H): the first three landed
    /// catalogues ("provider" rails — addon catalogues,
    /// see WS-H mapping §5), each with the PC local
    /// 205×263 card; tap and focus binding are metaRail's.
    @ViewBuilder
    private var pcTorProviderRails: some View {
        ForEach(Array(pcTorLandedCatalogs.prefix(3).enumerated()), id: \.offset) { _, cat in
            if let metas = store.rails[cat.id + "|" + cat.type], !metas.isEmpty {
                torPcMetaRail(cat.name, metas, base: cat.base,
                              scope: "torCat:\(cat.id)|\(cat.type)")
            }
        }
    }

    /// Design rail 5 (WS-H): "Torrent · Khám phá
    /// catalogue" — the remaining catalogue rails plus
    /// the genre rails, in existing order (the
    /// catalogue-exploration family; WS-H mapping §5
    /// flags the family mapping). GATE-213 R3 Lens 3
    /// Finding 2: these are §3.6 DESIGN rails (rail 5,
    /// "Khám phá catalogue"), so they build through the
    /// PC rail construction (torPcMetaRail — torPcRail
    /// Shell + JoeCinemaTorCard), NOT the legacy shared
    /// metaRail/Rail they previously used.
    @ViewBuilder
    private var pcTorExploreRails: some View {
        ForEach(Array(pcTorLandedCatalogs.dropFirst(3).enumerated()), id: \.offset) { _, cat in
            if let metas = store.rails[cat.id + "|" + cat.type], !metas.isEmpty {
                torPcMetaRail(cat.name, metas, base: cat.base,
                              scope: "torCat:\(cat.id)|\(cat.type)")
            }
        }
        ForEach(Array(store.genreRails.enumerated()), id: \.offset) { _, rail in
            if !rail.metas.isEmpty {
                torPcMetaRail(rail.title, rail.metas, base: TorrentSettings.cinemeta,
                              scope: "torGenre:\(rail.type):\(rail.genre)")
            }
        }
    }

    /// A PC poster rail over torrent metas: the local
    /// 205×263 card (JoeCinemaTorCard, JoePhimHome.swift),
    /// metaRail's tap and focus binding verbatim.
    private func torPcMetaRail(_ title: String, _ metas: [TorMeta], base: String,
                               scope: String) -> some View {
        torPcRailShell(title: title) {
            ForEach(metas) { meta in
                Button { nav.tor = TorRoute(meta: meta, base: base) } label: {
                    JoeCinemaTorCard(meta: meta)
                }
                .joeCardButton()
                .focused($focusedMeta, equals: scope + "|" + meta.id)
            }
        }
    }

    /// The PC context strip (WS-H): the pinned Section
    /// header — focused title · year · its rail · "Dãy
    /// NN/TT · ↑ để trở lại", from the existing focus
    /// memory. This view has no hero (WS-H mapping §5
    /// flag); the strip's rest state names the section.
    private var torContextStrip: some View {
        let info = torContextInfo
        return HStack(alignment: .center, spacing: 14) {
            // FIX-8 / C-R4-2: the drawn composition
            // (delivery-joetv-TorrentManyRails-browse.png)
            // — left column: the surface eyebrow in small
            // caps ABOVE the title, the meta riding the
            // title's baseline beside it.
            VStack(alignment: .leading, spacing: 4) {
                Text("TORRENT / ĐANG KHÁM PHÁ")
                    .font(JoePCType.outfit(15, weight: .medium))
                    .tracking(3.6)
                    .foregroundStyle(theme.heroMeta)
                    .lineLimit(1)
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    // FIX-5 / Lens C Finding 1 (C4): the spec's strip title is 34/500.
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

    /// The strip's content for the torrent home: resolve
    /// the focused meta ("torCat:…|metaId" /
    /// "torGenre:…|metaId") or CW/favourite entry against
    /// the store's rails.
    private var torContextInfo: (title: String, meta: String, railName: String, railLine: String) {
        let titles = pcTorVisibleRailTitles
        let total = titles.count
        if let focusedMeta {
            if let meta = (store.rails.values.flatMap { $0 }
                           + store.genreRails.flatMap { $0.metas })
                .first(where: { focusedMeta.hasSuffix("|" + $0.id) }) {
                // FIX-5 / Lens B Finding 2: resolve the rail
                // from the focus ID's OWN scope segment first
                // (mirroring cinemaTorrentRailPosition in
                // JoePhimHome) — genre-rail metas share ids
                // with the `top` catalogue, so the first
                // catalogue containing the id is not the rail
                // the user is on. Only a scope carrying no
                // rail identity (e.g. "torSearch") falls back
                // to the catalogue search below.
                var railName = ""
                if focusedMeta.hasPrefix("torCat:") {
                    let segments = focusedMeta.dropFirst("torCat:".count)
                        .split(separator: "|")
                    let catId = segments.first.map(String.init) ?? ""
                    let catType = segments.count > 1 ? String(segments[1]) : ""
                    if let cat = pcTorLandedCatalogs.first(where: {
                        $0.id == catId && (catType.isEmpty || $0.type == catType)
                    }) {
                        railName = cat.name
                    }
                } else if focusedMeta.hasPrefix("torGenre:") {
                    let scopePart = focusedMeta.split(separator: "|")
                        .first.map(String.init) ?? ""
                    let segments = scopePart.dropFirst("torGenre:".count)
                        .split(separator: ":", maxSplits: 1)
                    let genreType = segments.first.map(String.init) ?? ""
                    let genre = segments.count > 1 ? String(segments[1]) : ""
                    if let rail = store.genreRails.first(where: {
                        $0.type == genreType && $0.genre == genre
                    }) {
                        railName = rail.title
                    }
                }
                if railName.isEmpty {
                    for cat in store.catalogs {
                        if store.rails[cat.id + "|" + cat.type]?
                            .contains(where: { $0.id == meta.id }) == true {
                            railName = cat.name
                            break
                        }
                    }
                }
                if railName.isEmpty {
                    railName = store.genreRails
                        .first(where: { $0.metas.contains { $0.id == meta.id } })?.title ?? ""
                }
                let pos = titles.firstIndex(of: railName).map { $0 + 1 } ?? 1
                return (meta.name, meta.year,
                        railName,
                        "Dãy \(String(format: "%02d", pos)) / \(total) · ↑ để trở lại")
            }
        }
        if let focusedEntry {
            if let entry = torProgress.first(where: { "cw|" + $0.key == focusedEntry }) {
                return (entry.title, entry.epLabel,
                        "Xem tiếp",
                        "Dãy 01 / \(total) · ↑ để trở lại")
            }
            if let entry = torFavorites.first(where: { "fav|" + $0.key == focusedEntry }) {
                let pos = titles.firstIndex(of: "Yêu thích").map { $0 + 1 } ?? total
                return (entry.title, entry.year,
                        "Yêu thích",
                        "Dãy \(String(format: "%02d", pos)) / \(total) · ↑ để trở lại")
            }
        }
        // FIX-10a / RECON-POWERMAX point 6: no card
        // focused — return the last resolved strip tuple
        // when one exists. Before any focus ever, memory
        // is nil and the rest tuple below is unchanged.
        if focusedMeta == nil, focusedEntry == nil,
           let memory = torStripMemory {
            return memory
        }
        return ("Phim Torrent", "",
                "",
                "Dãy 01 / \(total) · ↑ để trở lại")
    }

    /// The visible PC rails' titles in render order (the
    /// strip's denominator).
    private var pcTorVisibleRailTitles: [String] {
        var out: [String] = []
        if !torProgress.isEmpty { out.append("Xem tiếp") }
        for cat in pcTorLandedCatalogs { out.append(cat.name) }
        for rail in store.genreRails where !rail.metas.isEmpty {
            out.append(rail.title)
        }
        if !torFavorites.isEmpty { out.append("Yêu thích") }
        return out
    }

    private var searchGrid: some View {
        // Fixed 6 columns (§7.6: 6×264 + 5×28 = 1724 ≤ 1760).
        // v2.0.8: the fixed columns now serve the focus
        // engine's geometric search (a regular grid gives it
        // clean candidates), not a hand-written router.
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 28),
                                 count: 6),
                  alignment: .leading, spacing: 40) {
            ForEach(searchResults) { meta in
                Button { nav.tor = TorRoute(meta: meta, base: TorrentSettings.cinemeta) } label: {
                    PosterCard(
                        title: meta.name,
                        posterURL: meta.posterURL,
                        meta: meta.year)
                }
                .joeCardButton()
                .focused($focusedMeta, equals: "torSearch|" + meta.id)
                // v2.0.8 (Phase 1): no move handler — the
                // grid's movement (including UP from the
                // first row back to the search row) is the
                // engine's geometric search.
            }
        }
        // Design D's wall ring is an OUTSET band around the
        // art (6 pt): under D the grid takes edge clearance
        // past it so the outer columns' rings are never
        // clipped by the scroll frame.
        .padding(.horizontal, theme.id == .posterWall ? 8 : 0)
    }

    // v2.0.8 (Phase 1): searchResultMove is DELETED (C-2's
    // arithmetic grid router). It was NOT a composite
    // control — it handled plain grid cards and coded DOWN
    // past the last row as a no-op — so no exception
    // applies: the grid's movement is geometric now, and
    // UP from a first-row result reaches the search row as
    // the nearest focusable above.

    /// The debounced type-ahead driver (fault (e) — the
    /// JoeSearchView scheduleTypeAhead pattern): every strip
    /// edit cancels the pending firing and re-arms it; when
    /// ~500 ms elapse with the text unchanged, the round for
    /// that text runs. An emptied query does NOT run a round
    /// — it resets the section to its un-searched state,
    /// superseding any in-flight round so a late landing
    /// cannot repaint a home the owner has already cleared.
    private func scheduleSearch() {
        searchTask?.cancel()
        let text = query
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            guard query == text else { return }
            if text.trimmingCharacters(in: .whitespaces).isEmpty {
                searchRound += 1
                searching = false
                searchResults = []
                searchAttempted = false
                searchError = nil
            } else {
                runSearch()
            }
        }
    }

    private func runSearch() {
        // An immediate round (the Tìm button, or the
        // type-ahead firing itself) supersedes any pending
        // debounce — its firing must not re-run this round.
        searchTask?.cancel()
        let kw = query.trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty else { return }
        searchRound += 1
        let round = searchRound
        searching = true
        searchError = nil
        Task {
            let searchable = store.catalogs.filter { $0.searchable }
            var out: [TorMeta] = []
            var failures = 0
            for cat in searchable {
                do {
                    out.append(contentsOf: try await TorrentClient.search(cat, keyword: kw))
                } catch {
                    failures += 1
                }
            }
            // Fault (e): a superseded round never publishes —
            // a newer term's round (or a clear) owns the grid.
            guard round == searchRound else { return }
            searchResults = out
            searching = false
            searchAttempted = true
            // C-10: "no catalogues to search" and "every search
            // failed" are explicit surfaces, not a silent empty.
            if searchable.isEmpty {
                searchError = "Chưa tải được danh mục — kiểm tra mạng rồi thử lại."
            } else if failures == searchable.count {
                searchError = "Không tải được kết quả tìm kiếm. Kiểm tra mạng rồi thử lại."
            }
        }
    }
}

/// Torrent title detail: hero, favourite toggle, episode list
/// (series), then the stream list for the chosen video — direct
/// links play at once, hash-only entries resolve through the
/// owner's Real-Debrid account at tap time.
struct JoeTorrentDetail: View {
    let route: TorRoute
    @EnvironmentObject private var watch: WatchStore
    @EnvironmentObject private var nav: JoeNavigator
    @Environment(\.joeTheme) private var theme
    @State private var videos: [TorVideo] = []
    @State private var selectedVideo: TorVideo?
    @State private var streams: [TorStream] = []
    @State private var loadingStreams = false
    @State private var videosFailed = false
    @State private var streamsFailed = false
    @State private var notice: String?
    @State private var hasViSub = false
    /// v2.0.16: the best Vietnamese subtitle itself (not only
    /// the hasViSub flag) — play() attaches it to every ladder
    /// candidate so the player loads it beside the embedded
    /// tracks.
    @State private var viSubtitleURL: URL?
    @State private var playerHolder: JoeMovieDetail.DirectorHolder?
    /// v2.0.28 (FIX4 fix 3, face c): the TMDB cast for this
    /// title — the torrent path never fetched it (TorMeta's
    /// id is the Cinemeta/IMDb id and nothing bridged it to
    /// TMDB), so torrent details showed no cast at all.
    /// Filled by loadCast(); empty = the row simply never
    /// renders, exactly like the Phim detail's fail-soft.
    @State private var cast: [TMDBCastMember] = []
    @State private var actorRoute: JoeActorRoute?
    /// v2.0.49 (item 7): bumped by the detail's Menu
    /// handler to make standardBody's ScrollViewReader
    /// jump to the top of the page (owner order
    /// 2026-11-21).
    @State private var topScrollSignal = 0
    /// FIX-213 (Fault 1, DIAG-20261122): the Menu exit's
    /// second-press arm — Menu #1 jumps to the top and
    /// arms this, Menu #2 closes, independent of whether
    /// the jump's programmatic focusedRow write landed
    /// (the chain detail's exitArmed, same construction).
    /// Cleared by any focusedRow change (the .onChange
    /// stage in body below).
    @State private var exitArmed = false
    @FocusState private var focusedRow: String?

    private var meta: TorMeta { route.meta }
    private var favKey: String { WatchStore.torFavKey(metaId: meta.id, type: meta.type) }
    private var isFav: Bool { watch.isFavorite(key: favKey) }
    private var videoId: String { selectedVideo?.id ?? meta.id }

    var body: some View {
        Group {
            // v2.0.19 (Ultra): the Phim4K composition — full-bleed
            // backdrop, title bottom-left, frosted Chọn Server
            // panel on the right. Every other theme keeps the
            // standard single-column body below; state, load logic
            // and actions are shared, only the composition moves.
            // v2.1.1 (Private Cinema): the PC composition family
            // (cinemaTorBody below) — its own branch, checked
            // first; Ultra and the standard body are unchanged.
            if theme.id == .privateCinema {
                cinemaTorBody
            } else if theme.id == .ultra {
                ultraBody
            } else {
                standardBody
            }
        }
        .task { await load() }
        .fullScreenCover(item: $actorRoute) { route in
            JoeActorPage(route: route)
        }
        .fullScreenCover(item: $playerHolder) { holder in
            JoePlayerView(director: holder.director,
                          filmTitle: holder.title,
                          filmEpisode: holder.episode,
                          sourceLine: holder.sourceLine)
        }
        // 1.9.2 (Team 9 items 4 + 9): Menu closes THIS detail
        // from its OWN root (the wrapper-handler lesson, same
        // as JoeMovieDetail), and the favourite button is the
        // declared initial focus — see favButton.
        .onExitCommand {
            // v2.0.49 (item 7, owner order 2026-11-21
            // 22:32): Menu jumps straight to the top of
            // the page first. Focus on the favourite
            // button (this page's declared first element)
            // keeps the existing close; anywhere else,
            // Menu scrolls to the top and lands focus on
            // the favourite button, swallowing the exit.
            // (The Ultra body has no scroll surface, so
            // there the signal is inert and only the
            // focus landing applies.)
            if focusedRow == "fav" {
                nav.tor = nil
            } else if exitArmed {
                // FIX-213 (Fault 1): the previous Menu
                // already jumped to the top and armed the
                // exit; this press closes even if the
                // focusedRow write never landed.
                nav.tor = nil
            } else {
                topScrollSignal += 1
                focusedRow = "fav"
                exitArmed = true
            }
        }
        // FIX-213 (Fault 1): any focus change on this
        // screen disarms the Menu exit (see exitArmed).
        .onChange(of: focusedRow) { _, _ in exitArmed = false }
        .defaultFocus($focusedRow, "fav")
    }

    private var standardBody: some View {
        // v2.0.49 (item 7): the ScrollView sits inside a
        // ScrollViewReader so Menu can jump straight to
        // the top of the page (see the body's handler).
        ScrollViewReader { proxy in
        ScrollView(.vertical, showsIndicators: false) {
            // v2.0.8 (Phase 7d): LazyVStack — the eager VStack
            // built the hero, episode block and stream block
            // (and every stream row) up front; children,
            // order and spacing are identical.
            LazyVStack(alignment: .leading, spacing: 32) {
                hero
                if !cast.isEmpty {
                    // v2.1.0 (Private Cinema): the cast slot is
                    // the ONLY branch — under Private Cinema the
                    // photo cast row is replaced by the text-line
                    // credits (cinemaTorCredits); every other
                    // theme keeps torCastRow, and the rest of
                    // standardBody (hero, episodes, streams, the
                    // focus sections, the Menu-to-top hook) is
                    // shared unchanged, so no separate
                    // cinemaTorBody duplicates this body.
                    if theme.id == .privateCinema {
                        cinemaTorCredits
                            .focusSection()
                    } else {
                        torCastRow
                            .focusSection()
                    }
                }
                if meta.type == "series" {
                    // v2.0.5 (N1, pair i): the episode block
                    // and the stream block are declared focus
                    // regions inside the detail's single column.
                    episodeSection
                        .focusSection()
                }
                streamSection
                    .focusSection()
            }
            .id("joeTorDetailTop")
            // No manual padding: the layer sits inside the root
            // safe area, which IS the §4 inset (80/60).
        }
        // v2.0.49 (item 7): the Menu-to-top jump's scroll
        // hook, inside the reader.
        .onChange(of: topScrollSignal) { _, _ in
            proxy.scrollTo("joeTorDetailTop", anchor: .top)
        }
        }
    }

    // MARK: - Ultra composition (v2.0.19)

    /// Full-bleed backdrop for the Ultra torrent detail: the
    /// portrait poster as a blur field first, the Cinemeta
    /// landscape background sliced over it when present, then
    /// the same left + vertical scrims as the Ultra movie
    /// detail, so the title block and the panel stay readable.
    private var ultraTorBackdrop: some View {
        ZStack {
            if let url = meta.posterURL {
                JoeBandImage(url: url, targetPixels: 1920,
                             anchor: 0.16, portraitMode: .blurField)
            }
            if !meta.background.isEmpty,
               let u = URL(string: meta.background), u != meta.posterURL {
                JoeBandImage(url: u, targetPixels: 1920,
                             anchor: 0.16, portraitMode: .slice)
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
        // v2.0.23 (owner verdict on 2.0.22: every movie tab's
        // theme is fixed, "Còn duy nhất tab torrent là chưa
        // sửa"): this backdrop is the same fixed full-screen
        // layer as JoeMovieDetail.ultraBackdrop — and it was
        // the one the 2.0.22 fix missed. Without this it filled
        // only the safe-area rect and painted as an inset
        // framed picture, exactly as photographed (Resident
        // Evil detail). The backdrop now bleeds edge-to-edge,
        // the same platform idiom as the movie detail; the
        // HStack content beside it keeps the HIG inset exactly
        // as before, so no text or panel moves. Ultra-only —
        // this layer exists for no other theme.
        .ignoresSafeArea()
    }

    private var ultraBody: some View {
        ZStack {
            ultraTorBackdrop
            HStack(alignment: .bottom, spacing: 40) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(meta.name)
                        .font(.system(size: 54, weight: .heavy))
                        .foregroundStyle(theme.text)
                        .lineLimit(3)
                    if !meta.year.isEmpty {
                        Text(meta.year)
                            .font(.system(size: 29, weight: .bold))
                            .foregroundStyle(theme.heroMeta)
                    }
                    if !meta.desc.isEmpty {
                        Text(meta.desc)
                            .font(.system(size: 25))
                            .foregroundStyle(theme.text.opacity(0.85))
                            .lineSpacing(6)
                            .lineLimit(4)
                    }
                }
                .frame(maxWidth: 600, alignment: .leading)
                Spacer(minLength: 0)
                ultraPanel
            }
            .frame(maxHeight: .infinity)
        }
    }

    /// The frosted Chọn Server panel: favourite row, the
    /// episode block (series) and the stream block, inside a
    /// translucent plate — the Sony 2.3.31 row-10 composition
    /// carried to tvOS.
    private var ultraPanel: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 22) {
                Text("Chọn Server")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(theme.text)
                    .frame(maxWidth: .infinity, alignment: .center)
                HStack(spacing: 16) {
                    favButton
                    if hasViSub {
                        Text("Phụ đề Việt: có (OpenSubtitles)")
                            .font(.system(size: 25))
                            .foregroundStyle(theme.text.opacity(0.8))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(Color.white.opacity(0.10)))
                    }
                }
                if let notice {
                    Text(notice)
                        .font(.system(size: 25))
                        .foregroundStyle(.orange)
                }
                if !cast.isEmpty {
                    torCastRow
                        .focusSection()
                }
                if meta.type == "series" {
                    episodeSection
                        .focusSection()
                }
                streamSection
                    .focusSection()
            }
            .padding(36)
        }
        .frame(width: 1040)
        .background(RoundedRectangle(cornerRadius: 24)
            .fill(Color.white.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 24)
            .strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 24))
    }

    // MARK: - Private Cinema composition (2.1.1)

    /// Private Cinema torrent detail: the PC detail family
    /// (FIDELITY-AUDIT-210 §4) — the whole body takes the
    /// family composition: the STATIC backdrop hero (the
    /// shared static stack — poster blur field + the
    /// Cinemeta background sliced over it + scrims; NO
    /// preview machinery exists on this screen and none is
    /// added, per the 2.0.49 static-image ruling), a serif
    /// title block, the text-line credits (cinemaTorCredits,
    /// shipped in 2.1.0 — kept), the shared episode block,
    /// and the streams dressed as numbered Panel cards
    /// (cinemaStreamSection). State, load logic and actions
    /// are the detail's own, shared with every theme; only
    /// the composition is PC's. The ScrollViewReader carries
    /// the same Menu-to-top hook the standard body has.
    private var cinemaTorBody: some View {
        ZStack {
            ultraTorBackdrop
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 32) {
                        cinemaTorHeader
                        if !cast.isEmpty {
                            cinemaTorCredits
                                .focusSection()
                        }
                        if meta.type == "series" {
                            episodeSection
                                .focusSection()
                        }
                        cinemaStreamSection
                            .focusSection()
                    }
                    .id("joeTorDetailTopPC")
                    // FIX-214 (FULL-THEME-AUDIT-214 B12):
                    // the detail text frame is x94 — this
                    // body carried no horizontal padding of
                    // its own and stood at the ambient 80.
                    .padding(.horizontal, 94)
                    .padding(.vertical, 10)
                }
                .onChange(of: topScrollSignal) { _, _ in
                    proxy.scrollTo("joeTorDetailTopPC", anchor: .top)
                }
            }
        }
    }

    /// The PC title block: letterspaced eyebrow, serif
    /// typeset title, the year line, the shared favourite
    /// row (+ the ViSub capsule when the subtitle fetch
    /// found one), the synopsis, and the notice line —
    /// every value the meta's own real field, over the
    /// backdrop with NO poster card (the family dress).
    private var cinemaTorHeader: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(meta.type == "series" ? "PHIM BỘ / TORRENT"
                                       : "PHIM ĐIỆN ẢNH / TORRENT")
                .font(JoePCType.outfit(15, weight: .medium))
                .tracking(3.6)
                .foregroundStyle(theme.heroMeta)
                .lineLimit(1)
                .padding(.top, 30)
            Text(meta.name)
                .font(JoePCType.display(100))
                .tracking(-3)
                .foregroundStyle(theme.text)
                .lineLimit(3)
                // FIX-214 (Finding 16 guard, noted in
                // FULL-THEME-AUDIT-214 B12): the title
                // may use the whole x94 text frame
                // (1920 − 94 − 94 = 1732) but never
                // beyond it, and a long title shrinks
                // instead of clipping mid-glyph.
                .frame(maxWidth: 1732, alignment: .leading)
                .minimumScaleFactor(0.5)
                .padding(.top, 16)
            if !meta.year.isEmpty {
                Text(meta.year)
                    .font(JoePCType.outfit(20))
                    .foregroundStyle(theme.heroMeta)
                    .padding(.top, 12)
            }
            HStack(spacing: 16) {
                favButton
                if hasViSub {
                    Text("Phụ đề Việt: có (OpenSubtitles)")
                        .font(JoePCType.outfit(25))
                        .foregroundStyle(theme.text.opacity(0.8))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Color.white.opacity(0.10)))
                }
            }
            .padding(.top, 20)
            if !meta.desc.isEmpty {
                // FIX-10a / ADJUDICATION F2: the spec type
                // sheet's Detail synopsis — 21 pt regular,
                // 1.55 line height (lineSpacing = 21 × 0.55
                // ≈ 11.5 extra between lines), maxWidth 720.
                Text(meta.desc)
                    .font(JoePCType.outfit(21))
                    .foregroundStyle(theme.text.opacity(0.92))
                    .lineSpacing(11.5)
                    // FIX-12 / R7 C-F3: 3 lines, matching
                    // the chain-detail synopsis twin.
                    .lineLimit(3)
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(.top, 20)
            }
            if let notice {
                Text(notice)
                    .font(JoePCType.outfit(25))
                    .foregroundStyle(.orange)
                    .padding(.top, 14)
            }
        }
    }

    /// The PC stream block: the design's source-card dress
    /// over THIS screen's stream list — a Divider + "Chọn
    /// nguồn phát" heading, then one NUMBERED card per
    /// stream (cinemaStreamRow). The loading / failed /
    /// empty states are streamSection's own, mirrored
    /// verbatim so the PC arm can never diverge from the
    /// shared honesty surfaces.
    @ViewBuilder
    private var cinemaStreamSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Divider()
            Text("Chọn nguồn phát")
                // FIX-214: the unified source-heading
                // decision (see pcSourceBlock in
                // JoeMovieDetail.swift) — outfit(28,
                // .semibold) on all three details.
                .font(JoePCType.outfit(28, weight: .semibold))
                .foregroundStyle(theme.text)
                .padding(.top, 8)
            if loadingStreams {
                ProgressView("Đang lấy nguồn…")
                    .font(JoePCType.outfit(29))
                    .foregroundStyle(theme.text)
                    .tint(.white)
            } else if streamsFailed {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Không lấy được nguồn phát. Kiểm tra mạng rồi thử lại.")
                        .font(JoePCType.outfit(25))
                        .foregroundStyle(.orange)
                    retryButton(focusKey: "retry|streams") {
                        Task { await loadStreams() }
                    }
                }
            } else if streams.isEmpty {
                Text(TorrentSettings.isConfigured || TorrentSettings.mfBase != nil
                     ? "Chưa có nguồn phát."
                     : "Chưa cấu hình nguồn — vào Cài đặt nhập link Torrentio, token Real-Debrid/TorBox hoặc link MediaFusion.")
                    .font(JoePCType.outfit(25))
                    .foregroundStyle(theme.meta)
            } else {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(streams.enumerated()), id: \.offset) { pair in
                        cinemaStreamRow(pair.element,
                                        number: pair.offset + 1)
                    }
                }
            }
        }
    }

    /// One numbered PC source row. FIX-213 (Faults 3+4,
    /// DIAG-20261122; owner ruling 2026-11-22 10:25 CST —
    /// "Làm nút nhỏ nguồn ghi tắt nhỏ ít thông tin được
    /// rồi", which OVERRIDES the drawing for these rows):
    /// this is the row the owner's Fault-3 photo shows,
    /// and it now carries the same ONE line as streamRow
    /// — the number, the availability dot (the "PHÁT
    /// NGAY" word-capsule's replacement, see streamDot)
    /// and the compact line (provider short form · one
    /// quality token · size, see streamCompactLine). The
    /// role label, the full release name, the spec +
    /// language lines and the chevron are gone; vertical
    /// padding 16 → 8. The face is the theme's Panel
    /// surface token; focus is the design's source-row
    /// state (Fault 11 fix round: JoeSourceRowFace +
    /// JoeDesignRing, exactly as streamRow dresses it).
    /// A tap plays through the same play(_:) as every
    /// other theme.
    private func cinemaStreamRow(_ stream: TorStream,
                                 number: Int) -> some View {
        Button {
            play(stream)
        } label: {
            HStack(spacing: 14) {
                Text(String(format: "%02d", number))
                    .font(JoePCType.editorial(24))
                    .foregroundStyle(theme.meta)
                streamDot(stream)
                Text(Self.streamCompactLine(stream))
                    .font(JoePCType.outfit(25, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 8)
            .frame(width: Self.streamBarWidth)
            // OWNER REFINEMENT 2026-11-22 12:28 CST
            // (§3.12): the stacked list takes ONE uniform
            // bar width (Self.streamBarWidth, applied
            // above before the face/ring so both span the
            // full width) — not the 12:15 content-hug
            // (ragged column) and not the old full-width
            // stretch.
            // Fault 11 fix round: the design's source-row
            // state, as on streamRow (JoeSourceRowFace +
            // JoeDesignRing) — this row renders only under
            // Private Cinema, so the celadon outset outline
            // and the #304039DF focused face are its dress.
            // FIX-214 (FULL-THEME-AUDIT-214 A3): the
            // Geometry radius for source rows is 7, not
            // the Settings-field rField 12 this row
            // borrowed.
            .background(JoeSourceRowFace(
                shape: RoundedRectangle(cornerRadius: 7),
                restFill: theme.surface2))
            .overlay(JoeDesignRing(shape: RoundedRectangle(cornerRadius: 7)))
        }
        .joeCardButton()
        .focused($focusedRow, equals: "st|" + stream.id.uuidString)
    }

    // MARK: - Hero

    private var hero: some View {
        HStack(alignment: .top, spacing: 40) {
            ZStack {
                RoundedRectangle(cornerRadius: theme.rCard).fill(Color.black.opacity(0.45))
                if let url = meta.posterURL {
                    // v2.0.5 (N6): the portrait aspect gate, as
                    // on every other 2:3 slot — a landscape
                    // bitmap in this frame is rejected instead
                    // of letterboxing into a band. TorMeta
                    // carries no TMDB identity (its id is the
                    // Cinemeta/IMDb id), so there is no TMDB
                    // fallback leg here; the placeholder stands.
                    JoeRemoteImage(url: url, targetPixels: 720, fit: true,
                                   slotClass: .portrait) {
                        Text(meta.name)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(theme.text.opacity(0.8))
                            .multilineTextAlignment(.center).padding(18)
                    }
                }
            }
            .frame(width: 240, height: 360)
            .clipShape(RoundedRectangle(cornerRadius: theme.rCard))
            // The hairline is an INSIDE strokeBorder (the
            // v2.0.6 outset band is retired on this frame —
            // the torrent surfaces carry no drawing of their
            // own, and the inside form is the system's resting
            // frame treatment outside the two drawn outset
            // rings: the field's and design D's wall art).
            .overlay(RoundedRectangle(cornerRadius: theme.rCard)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 2))

            VStack(alignment: .leading, spacing: 16) {
                Text(meta.name)
                    .font(.system(size: 64, weight: .heavy))
                    .foregroundStyle(theme.text)
                    .lineLimit(3)
                if !meta.year.isEmpty {
                    Text(meta.year)
                        .font(.system(size: 29))
                        .foregroundStyle(theme.meta)
                }
                HStack(spacing: 16) {
                    favButton
                    if hasViSub {
                        Text("Phụ đề Việt: có (OpenSubtitles)")
                            .font(.system(size: 25))
                            .foregroundStyle(theme.text.opacity(0.8))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(Color.white.opacity(0.10)))
                    }
                }
                if !meta.desc.isEmpty {
                    Text(meta.desc)
                        .font(.system(size: 29))
                        .foregroundStyle(theme.meta)
                        .lineSpacing(8)
                        .lineLimit(5)
                        .frame(maxWidth: 1050, alignment: .leading)
                }
                if let notice {
                    Text(notice)
                        .font(.system(size: 25))
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var favButton: some View {
        Button {
            var e = WatchStore.Entry()
            e.kind = WatchStore.kindTor
            e.key = favKey
            e.title = meta.name
            e.poster = meta.poster
            e.year = meta.year
            e.metaId = meta.id
            e.metaType = meta.type
            e.isLive = meta.isLive
            // v2.0.40 (P0.1 / C-1): store the base's family
            // code, never the base itself (it carries tokens).
            e.metaSource = TorrentSettings.metaSource(forBase: route.base)
            e.background = meta.background
            e.desc = meta.desc
            e.ts = Int64(Date().timeIntervalSince1970 * 1000)
            watch.toggleFavorite(e)
        } label: {
            // v2.0.29 (Cluster E, item 9 audit): the label now
            // carries the drawings' .btn chrome exactly — 29
            // semibold, padding 17/36, surface2 fill, resting
            // inset stroke 1.5 theme.stroke, focused ring
            // theme.focus at ringWidth (the JoeSecondaryLabel
            // construction, spelt out here because the label
            // text carries the favourite state colour). It was
            // 29 medium / vertical 16 with a JoeFocusRing
            // overlay, which paints no resting stroke.
            Text(isFav ? "♥ Đã thích" : "♡ Yêu thích")
                .font(theme.id == .privateCinema
                      ? JoePCType.outfit(22, weight: .medium)
                      : .system(size: 29, weight: .semibold))
                .foregroundStyle(isFav ? JoeTheme.accentRed
                                 : (theme.id == .privateCinema
                                    ? theme.text : .white))
                .padding(.horizontal, theme.id == .privateCinema ? 22 : 36)
                .padding(.vertical, theme.id == .privateCinema ? 13 : 17)
                .background(Capsule().fill(theme.surface2))
                .overlay(Capsule().strokeBorder(
                    focusedRow == "fav" && theme.id != .privateCinema
                        ? theme.focus : theme.stroke,
                    lineWidth: focusedRow == "fav"
                        && theme.id != .privateCinema
                        ? theme.ringWidth : 1.5))
                // Fault 11 fix round: this button also
                // renders in the Private Cinema header
                // (cinemaTorBody → cinemaTorHeader), where
                // its focus is the design's action state —
                // the ivory outset outline + 1.025 scale
                // (the JoeSecondaryLabel cinema treatment);
                // the inset stroke above rests there.
                .overlay(JoeOutsetRing(
                    shape: Capsule(), color: JoeCinemaFocus.ivory,
                    lineWidth: 2, offset: 6,
                    forced: theme.id == .privateCinema
                        ? focusedRow == "fav" : false))
                .scaleEffect(theme.id == .privateCinema
                             && focusedRow == "fav" ? 1.025 : 1)
                // GATE-213 R5 Lens 2 F2: this favourite
                // button renders under EVERY theme, so its
                // animation is theme-branched — the PC
                // action curve (240 ms, RECALC R4) under
                // Private Cinema, the pre-freeze 220 ms
                // curve (same bézier points) elsewhere.
                .animation(theme.id == .privateCinema
                           ? JoeCinemaFocus.actionCurve
                           : Animation.timingCurve(0.2, 0.7, 0.2, 1,
                                                   duration: 0.22),
                           value: focusedRow)
        }
        .joeCardButton()
        // 1.9.2 (Team 9 item 9): the button joins the detail's
        // FocusState and is its declared default focus. It was
        // the ONLY unbound focusable on this screen: for an
        // UNCONFIGURED title (no stream rows, no episodes) it
        // was also the only focusable element at all, so focus
        // never landed and the owner could not favourite such
        // a title — the toggle itself was never gated on
        // configuration. On configured titles the initial
        // landing is now this button (topmost action; one DOWN
        // reaches the stream rows) — accepted by the leader.
        .focused($focusedRow, equals: "fav")
        // v2.0.8 (Phase 1): the declared DOWN exit
        // (.joeBoundaryMove → favDownLanding) is REMOVED,
        // and favDownLanding with it. The button is the
        // layer's top element and alone in its row (the
        // subtitle capsule beside it is not focusable); DOWN
        // from it is the engine's geometric move to the
        // nearest focusable below — the episode block's
        // first chip, a failure surface's Retry, or the
        // first stream row, each inside its declared
        // .focusSection() region.
    }

    // MARK: - Episodes (series)

    /// C-11: a failed videos fetch is a notice + Retry IN PLACE —
    /// v1.8 collapsed it to `?? []`, indistinguishable from a
    /// series with no episodes.
    @ViewBuilder
    private var episodeSection: some View {
        if videosFailed {
            VStack(alignment: .leading, spacing: 16) {
                Text("Không tải được danh sách tập.")
                    .font(theme.id == .privateCinema
                          ? JoePCType.outfit(25) : .system(size: 25))
                    .foregroundStyle(.orange)
                retryButton(focusKey: "retry|videos") {
                    Task { await load() }
                }
            }
        } else {
            episodeList
        }
    }

    private func retryButton(focusKey: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            JoePrimaryLabel(title: "Thử lại")
        }
        .joeCardButton()
        .focused($focusedRow, equals: focusKey)
    }

    @ViewBuilder
    private var episodeList: some View {
        if !videos.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("Tập")
                    .font(theme.id == .privateCinema ? JoePCType.outfit(34, weight: .bold)
                              : .system(size: 34, weight: .bold))
                    .foregroundStyle(theme.text)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16)],
                          alignment: .leading, spacing: 16) {
                    ForEach(videos) { video in
                        let selected = videoId == video.id
                        let rowFocused = focusedRow == "ep|" + video.id
                        Button {
                            selectedVideo = video
                            Task { await loadStreams() }
                        } label: {
                            // v2.0.29 (Cluster E, item 9 audit):
                            // the selected episode now wears the
                            // drawings' selected-chip treatment —
                            // SOLID theme.accent fill with
                            // onAccent text (the .chip.sel values
                            // JoeMovieDetail's epChip already
                            // carries) — not the 30% accent tint
                            // with resting text colour it had.
                            // The ring mirrors epChip's rule,
                            // including the owner's D ruling:
                            // selected + focused under posterWall
                            // wears the opaque-white frame, since
                            // D's accent and focus are one colour.
                            // The row anatomy (25 pt, full-width
                            // rounded rect) is unchanged.
                            Text(video.label)
                                .font(theme.id == .privateCinema
                                      ? JoePCType.outfit(25, weight: selected ? .semibold : .medium)
                                      : .system(size: 25, weight: selected ? .semibold : .medium))
                                .foregroundStyle(selected && !rowFocused ? theme.onAccent : theme.text)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 12)
                                // claude/opt-2 (FL-422): selected
                                // fill only while NOT focused.
                                .background(RoundedRectangle(cornerRadius: theme.rField)
                                    .fill(selected && !rowFocused ? theme.accent
                                          : theme.surface2))
                                .overlay(RoundedRectangle(cornerRadius: theme.rField)
                                    .strokeBorder(rowFocused
                                                  && theme.id != .privateCinema
                                                  ? (theme.id == .posterWall && selected
                                                     ? Color.white : theme.focus)
                                                  : (selected && !rowFocused ? .clear : theme.stroke),
                                                  lineWidth: rowFocused
                                                    && theme.id != .privateCinema
                                                    ? theme.ringWidth : 1.5))
                                // Fault 11 fix round: the
                                // episode rows also render in
                                // the Private Cinema body
                                // (cinemaTorBody shares
                                // episodeSection); there the
                                // focus is the chip family's
                                // ivory outset outline and the
                                // inset stroke rests.
                                .overlay(JoeOutsetRing(
                                    shape: RoundedRectangle(cornerRadius: theme.rField),
                                    color: JoeCinemaFocus.ivory,
                                    lineWidth: 2, offset: 4,
                                    forced: theme.id == .privateCinema
                                        ? rowFocused : false))
                        }
                        .joeCardButton()
                        .focused($focusedRow, equals: "ep|" + video.id)
                    }
                }
            }
        }
    }

    // MARK: - Streams

    @ViewBuilder
    private var streamSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Nguồn phát")
                .font(theme.id == .privateCinema ? JoePCType.outfit(34, weight: .bold)
                              : .system(size: 34, weight: .bold))
                .foregroundStyle(theme.text)
            if loadingStreams {
                ProgressView("Đang lấy nguồn…")
                    .font(.system(size: 29))
                    .foregroundStyle(theme.text)
                    .tint(.white)
            } else if streamsFailed {
                // C-11: "the fetch failed" is its own surface
                // with a Retry — never the empty copy below.
                VStack(alignment: .leading, spacing: 16) {
                    Text("Không lấy được nguồn phát. Kiểm tra mạng rồi thử lại.")
                        .font(.system(size: 25))
                        .foregroundStyle(.orange)
                    retryButton(focusKey: "retry|streams") {
                        Task { await loadStreams() }
                    }
                }
            } else if streams.isEmpty {
                Text(TorrentSettings.isConfigured || TorrentSettings.mfBase != nil
                     ? "Chưa có nguồn phát."
                     : "Chưa cấu hình nguồn — vào Cài đặt nhập link Torrentio, token Real-Debrid/TorBox hoặc link MediaFusion.")
                    .font(.system(size: 25))
                    .foregroundStyle(theme.meta)
            } else {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(streams.enumerated()),
                            id: \.element.id) { index, stream in
                        streamRow(stream, number: index + 1)
                    }
                }
            }
        }
    }

    /// FIX-213 (Faults 3+4, DIAG-20261122; owner ruling
    /// 2026-11-22 10:25 CST — "Làm nút nhỏ nguồn ghi tắt
    /// nhỏ ít thông tin được rồi"): the row is now ONE
    /// line — the number, the availability dot (the
    /// "PHÁT NGAY" word-capsule's replacement, see
    /// streamDot) and the compact line (provider short
    /// form · one quality token · size, see
    /// streamCompactLine). The full release name and
    /// the Ultra spec/language lines are gone from the
    /// row face; vertical padding 14 → 8.
    /// OWNER REFINEMENT 2026-11-22 12:28 CST ("Xem cân
    /// bằng độ dài dự tính. Để các nguồn đều có thể vừa
    /// khung chứ không phải khung dài khung ngắn"): the
    /// stream rows form a VERTICALLY STACKED list, so
    /// every bar in the list takes ONE uniform width —
    /// never a per-bar hugged width (the ragged column
    /// was the named fault) and never the old full-width
    /// stretch. Both row constructions (streamRow +
    /// cinemaStreamRow) share this width.
    /// FIX-214 (DESIGN-PASS-214 §1f): 560 → 440. The 560
    /// estimate priced a label alphabet the app never
    /// renders ("Real-Debrid · …" ≈29 chars); the real
    /// grammar's longest line is "RD+ · 1080p · 102.4
    /// GB" = 22 chars ≈ 397 pt with the row furniture —
    /// 440 is that line + ≈43 headroom, PROVIDED the
    /// provider token stays inside the short-form
    /// alphabet (the streamProviderShort fallback cap
    /// below is the companion rule that keeps it true).
    static let streamBarWidth: CGFloat = 440

    private func streamRow(_ stream: TorStream,
                           number: Int) -> some View {
        Button {
            play(stream)
        } label: {
            HStack(spacing: 14) {
                Text(String(format: "%02d", number))
                    .font(theme.id == .privateCinema
                          ? JoePCType.editorial(24)
                          : .system(size: 24, weight: .light,
                                    design: .serif))
                    .foregroundStyle(theme.meta)
                streamDot(stream)
                Text(Self.streamCompactLine(stream))
                    .font(theme.id == .privateCinema
                          ? JoePCType.outfit(25, weight: .semibold)
                          : .system(size: 25, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .frame(width: Self.streamBarWidth)
            // OWNER REFINEMENT 2026-11-22 12:28 CST
            // ("Xem cân bằng độ dài dự tính. Để các nguồn
            // đều có thể vừa khung chứ không phải khung
            // dài khung ngắn"; RECALC-SPEC §3.12): the
            // stacked list takes ONE uniform bar width
            // (Self.streamBarWidth, applied above before
            // the face/ring so both span the full width)
            // — not the 12:15 content-hug (ragged
            // long/short bars) and not the old full-width
            // stretch. Row height, focus dress, ordering
            // and actions are unchanged.
            // §7.6: stream rows are the one sanctioned outline-only
            // focus variant — the fill NEVER changes on focus (the
            // old white 0.06→0.13 brightening was a focus wash).
            // v2.0.0: the fill is the theme's surface token and
            // the outline is the theme ring (value-only).
            // v2.0.3: the outline is the shared JoeFocusRing
            // primitive — the same shape instance geometry as the
            // fill (rField), drawn inside the row's own bounds,
            // environment-driven like every other control in the
            // app (the hand-rolled copy here keyed off the
            // parent's FocusState instead).
            // Fault 11 fix round: §7.6's never-change rule is a
            // LEGACY-theme rule — the Private Cinema spec sheet
            // explicitly draws the source row's focused face
            // (#304039DF) with its celadon outset outline, and
            // under PC the drawing governs (JoeSourceRowFace /
            // JoeDesignRing below). Off the PC path both
            // primitives reproduce the §7.6 values exactly.
            // Fault 11 fix round: the face/ring pair is the
            // shared source-row construction — under Private
            // Cinema the design's source-row state (celadon
            // outset outline + #304039DF focused face); under
            // every other theme the values above, unchanged
            // (JoeSourceRowFace restFill / JoeDesignRing's
            // JoeFocusRing leg).
            // FIX-214 (FULL-THEME-AUDIT-214 A3): under
            // Private Cinema the source-row radius is
            // the Geometry 7 (see cinemaStreamRow);
            // every other theme keeps theme.rField.
            .background(JoeSourceRowFace(
                shape: RoundedRectangle(cornerRadius: theme.id == .privateCinema
                                        ? 7 : theme.rField),
                restFill: theme.id == .ultra
                    ? Color.white.opacity(0.16) : theme.surface2))
            .overlay(JoeDesignRing(shape: RoundedRectangle(cornerRadius: theme.id == .privateCinema
                                                           ? 7 : theme.rField)))
        }
        .joeCardButton()
        .focused($focusedRow, equals: "st|" + stream.id.uuidString)
    }

    /// FIX-213 (Faults 3+4): the availability dot that
    /// replaces the retired "PHÁT NGAY" word-capsule
    /// (streamTag, removed with the compact pass): green
    /// (JoeTheme.okGreen) when the row plays at once,
    /// orange when it is still waiting on the debrid or
    /// is hash-only — the old capsule's CHỜ DEBRID /
    /// RD · GIẢI LINK / TORRENT states, carried by
    /// colour alone under the owner's "ít thông tin"
    /// ruling. The pooled ranking already sorts the
    /// play-now rows first.
    private func streamDot(_ stream: TorStream) -> some View {
        Circle()
            .fill(stream.playable && !stream.awaitingDisplay
                  ? JoeTheme.okGreen : Color.orange)
            .frame(width: 14, height: 14)
    }

    /// FIX-213: the compact row's provider short form —
    /// the bracket tag the stream's label already
    /// carries ("[TB+] Torrentio" → "TB+"), else the
    /// MediaFusion gateway's short form, else the
    /// label's first word.
    private static func streamProviderShort(_ s: TorStream) -> String {
        let label = s.label
        if label.hasPrefix("["),
           let close = label.firstIndex(of: "]") {
            return String(label[label.index(after: label.startIndex)..<close])
        }
        if s.gateway == "MF" { return "MF" }
        // FIX-214 (DESIGN-PASS-214 §1f, companion rule):
        // the unbracketed fallback is capped to the
        // short-form alphabet (≤3 chars, like TB+/RD+/
        // PM+/MF) — an arbitrary addon label's first
        // word was the one path that could blow the
        // 440 bar's arithmetic (an uncapped
        // "Real-Debrid · …" line measures ≈501).
        let word = label.split(separator: " ").first.map(String.init) ?? label
        return word.count <= 3 ? word : String(word.prefix(3))
    }

    /// FIX-213: the ONE quality token the compact row
    /// shows — the retired ultraSpec's quality branch
    /// verbatim (4K / 1080p / 720p, read from the
    /// stream's own name/title text; empty when the text
    /// states none — a fact the text does not state is
    /// never shown).
    private static func streamQualityToken(_ s: TorStream) -> String {
        let up = (s.name + " " + s.title).uppercased()
        if up.contains("2160P") || up.contains("2160") || up.contains("4K") {
            return "4K"
        }
        if up.contains("1080P") || up.contains("1080") { return "1080p" }
        if up.contains("720P") || up.contains("720") { return "720p" }
        return ""
    }

    /// FIX-213: the size the compact row keeps — the 💾
    /// value copied verbatim from the stream's own text
    /// (the retired ultraSpec's size branch), "" when
    /// the text carries none.
    private static func streamSizeText(_ s: TorStream) -> String {
        let raw = s.name + " " + s.title
        guard let r = raw.range(of: "💾") else { return "" }
        let words = raw[r.upperBound...]
            .split(whereSeparator: { $0 == " " || $0 == "\n" })
            .prefix(2).map(String.init)
        return words.joined(separator: " ")
    }

    /// FIX-213: the compact row's ONE line of text —
    /// provider short form · quality token · size, each
    /// part present only when the stream's own text
    /// states it.
    private static func streamCompactLine(_ s: TorStream) -> String {
        var parts = [streamProviderShort(s)]
        let quality = streamQualityToken(s)
        if !quality.isEmpty { parts.append(quality) }
        let size = streamSizeText(s)
        if !size.isEmpty { parts.append(size) }
        return parts.joined(separator: " · ")
    }

    // FIX-213 (Faults 3+4): the v2.0.19 ultraSpec
    // tokenizer (the server rows' spec + language lines)
    // is REMOVED — both of its row consumers took the
    // compact one-line shape above, and its two surviving
    // branches (quality, size) live on verbatim inside
    // streamQualityToken / streamSizeText. The spec,
    // seeders and language lines it used to build are
    // exactly what the owner's compact ruling drops.

    // MARK: - Loading + playing

    private func load() async {
        // v2.0.28 (FIX4 fix 3, face c): the cast fetch runs
        // beside the videos/streams loads, never in front of
        // them — the row appears when it lands.
        Task { await loadCast() }
        if meta.type == "series" {
            do {
                videos = try await TorrentClient.fetchVideos(
                    addonBase: route.base, type: meta.type, id: meta.id)
                videosFailed = false
            } catch {
                videos = []
                videosFailed = true
            }
            if let pre = route.preselectStreamId.isEmpty ? nil
                : videos.first(where: { $0.id == route.preselectStreamId }) {
                selectedVideo = pre
            } else {
                selectedVideo = videos.first
            }
        }
        await loadStreams()
    }

    /// v2.0.28 (FIX4 fix 3, face c): bridge this meta to its
    /// TMDB identity and fetch the cast the Phim detail gets
    /// from fetchCast. The meta's own id is tried first — for
    /// Torrentio/MediaFusion metas it IS the IMDb id, and
    /// TMDB's /find resolves it exactly (torrent titles are
    /// mostly US films: the easiest identity case there is).
    /// The strict title+year searchIdentity is the fallback
    /// for metas whose id is not an IMDb id. Fail-soft: any
    /// miss leaves cast empty and the detail unchanged.
    private func loadCast() async {
        var resolved: (tmdbId: String, type: String)?
        if meta.id.hasPrefix("tt") {
            resolved = await TMDBClient.findByImdb(meta.id,
                                                   type: meta.type)
        }
        if resolved == nil {
            resolved = await TMDBClient.searchIdentity(
                name: meta.name, originName: meta.name,
                year: meta.year)
        }
        guard let resolved else { return }
        let members = await TMDBClient.fetchCast(
            tmdbId: resolved.tmdbId, type: resolved.type)
        if !members.isEmpty { cast = members }
    }

    /// v2.1.0 (Private Cinema): the torrent detail's text-line
    /// credits — the photo cast row's replacement under this
    /// theme only. A "DIỄN VIÊN" label over a row of buttons
    /// for the FIRST 3 cast names in billing order; each
    /// button's action is torCastRow's cell action verbatim
    /// (the same actorRoute .tmdb(...) assignment), and the
    /// name is a plain TEXT line (JoeTorNameLabel, the
    /// JoeActorNameLabel discipline) — no capsule pill.
    /// (RECALC-213 R6: the label's focused state now
    /// carries semibold + the ivory outset ring, no
    /// plate — see JoeTorNameLabel.)
    private var cinemaTorCredits: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("DIỄN VIÊN")
                .font(JoePCType.outfit(23, weight: .semibold))
                .tracking(3)
                .foregroundStyle(theme.meta)
            HStack(spacing: 16) {
                ForEach(Array(cast.prefix(3))) { member in
                    Button {
                        actorRoute = .tmdb(
                            personId: member.id,
                            name: member.name,
                            photoURL: member.photoURL)
                    } label: {
                        JoeTorNameLabel(name: member.name)
                    }
                    .joeCardButton()
                }
            }
        }
    }

    /// The cast row for the torrent detail — the Phim
    /// detail's castRow construction mirrored (circular
    /// photo, name, character, the house card button), each
    /// cell presenting the same actor page.
    private var torCastRow: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Diễn viên")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(theme.text.opacity(0.9))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 24) {
                    ForEach(cast) { member in
                        Button {
                            actorRoute = .tmdb(
                                personId: member.id,
                                name: member.name,
                                photoURL: member.photoURL)
                        } label: {
                            JoeTorCastCellLabel(member: member)
                        }
                        .joeCardButton()
                    }
                }
            }
        }
    }

/// v2.0.29 (item 1a, torrent half): one torrent cast
/// cell's label — the JoeCastCellLabel treatment mirrored
/// for this file (that label is private to
/// JoeMovieDetail.swift). Until now this cell painted NO
/// focus state: .joeCardButton() suppresses the system
/// focus effect centrally, and the label never read its
/// own focus, so a focused torrent cast cell was
/// pixel-identical to an unfocused one — the owner's
/// "diễn viên hiện, không focus" on torrent details. The
/// label now reads \.isFocused exactly like the Phim cast
/// cell: focused, the photo gains the theme's ring
/// (ringWidth, theme.focus) and the name takes the focus
/// title colour. Every resting value (110 pt circle,
/// white .10 fill, white .14 / 1.2 resting stroke, 23 pt
/// name/character, 120 width) is byte-identical to the
/// pre-fix cell.
private struct JoeTorCastCellLabel: View {
    let member: TMDBCastMember
    @Environment(\.isFocused) private var isFocused
    @Environment(\.joeTheme) private var theme

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().fill(Color.white.opacity(0.10))
                if !member.photoURL.isEmpty,
                   let url = URL(string: member.photoURL) {
                    JoeRemoteImage(url: url, targetPixels: 240) {
                        initial
                    }
                } else {
                    initial
                }
            }
            .frame(width: 110, height: 110)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(
                isFocused ? theme.focus : Color.white.opacity(0.14),
                lineWidth: isFocused ? theme.ringWidth : 1.2))
            Text(member.name)
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(isFocused ? theme.focusTitle : theme.text)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            if !member.character.isEmpty {
                // v2.0.29 (Cluster E, item 9 audit):
                // lineLimit 2, exactly as the mirrored
                // Phim cast cell (JoeMovieDetail.castCell)
                // — the 2.0.28 mirror had it at 1, so a
                // long character name truncated where the
                // Phim row wraps.
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

/// One cast name in the Private Cinema credits line
/// (cinemaTorCredits) — the JoeActorNameLabel discipline
/// (JoeMovieDetail.swift, private to that file) mirrored
/// for this file: a plain text name at 25 pt to match the
/// Private Cinema credits line, with NO capsule or scale.
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
private struct JoeTorNameLabel: View {
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

    private func loadStreams() async {
        let torBase = TorrentSettings.effectiveBase
        let mfBase = TorrentSettings.mfBase
        guard torBase != nil || mfBase != nil else {
            streams = []
            streamsFailed = false
            return
        }
        loadingStreams = true
        defer { loadingStreams = false }
        // v2.0.16: the pooled fetch — Torrentio + MediaFusion
        // in parallel, deduped to one row per release, ranked
        // best-first, cut to 30 (the Sony 2.3.16 form the
        // owner approved). The error surface stays honest:
        // it shows only when the Torrentio leg failed AND
        // nothing came back from either gateway.
        // v2.0.24 (Sony D1's tvOS shape): the subtitle fetch
        // no longer queues BEHIND the pooled stream fetch.
        // It depends only on the stream id, known before
        // either starts, so the two run concurrently and the
        // section waits for the slower of the two — max, not
        // sum. The subtitle CHOICE (bestVietnamese over the
        // same fetch) is unchanged; the pre-fix serial order
        // taxed every torrent detail open with the subtitle
        // leg's full latency (an 18 s budget) stacked on top
        // of the stream fetch's.
        async let pooledFetch = TorrentClient.fetchPooledStreams(
            torrentioBase: torBase, mfBase: mfBase,
            type: meta.type, id: videoId,
            userAddonBase: TorrentSettings.userAddonBase,
            userAddonName: JoeAddonStore.shared.addonName)
        async let subsFetch = TorrentClient.fetchSubtitles(
            base: TorrentSettings.subtitleBase(addonBase: torBase ?? mfBase ?? ""),
            type: meta.type, id: videoId)
        let pooled = await pooledFetch
        streams = pooled.streams
        streamsFailed = pooled.primaryFailed && pooled.streams.isEmpty
        let subs = await subsFetch
        let bestVi = TorrentClient.bestVietnamese(subs)
        hasViSub = bestVi != nil
        viSubtitleURL = bestVi.flatMap { URL(string: $0.url) }
    }

    private func play(_ stream: TorStream) {
        let director = Self.makePlayDirector(
            meta: meta, base: route.base, watch: watch,
            video: selectedVideo, preferred: stream,
            seedStreams: streams, seedSubtitleURL: viSubtitleURL)
        Self.wireUpNext(on: director, after: selectedVideo,
                        meta: meta, base: route.base, watch: watch,
                        videos: videos)
        playerHolder = JoeMovieDetail.DirectorHolder(
            director: director,
            title: meta.name,
            episode: selectedVideo?.label ?? "",
            sourceLine: "Nguồn: Torrent")
    }

    /// Builds the PlayDirector for ONE video of a torrent
    /// title — the tapped episode here, or the NEXT episode
    /// through the Up Next factory below. One builder for
    /// both, so a next-episode session is the current session
    /// in every respect: same pooled source family and
    /// settings (TorrentSettings read at ladder time, exactly
    /// as before), same candidate conversion, same subtitle
    /// attach, same resume rule. Static and value-capturing
    /// only, so the factory closure can hold it without a
    /// retain cycle through the view's @State.
    ///
    /// v2.0.25 (Idea 3b): `seedStreams` is the stream list
    /// ALREADY loaded for this video in this view session
    /// (the displayed rows for the tapped episode; the
    /// pre-resolved list for a next episode). The ladder's
    /// FIRST invocation for the ORIGIN identity serves it
    /// instead of re-fetching the same pooled list from
    /// scratch; every later invocation (failover refresh,
    /// retry) fetches fresh exactly as before. The guard is
    /// progressKey equality with the origin entry's key, and
    /// an empty seed never consumes the first call — it falls
    /// through to the fresh fetch. The pool itself is
    /// untouched: the seed IS fetchPooledStreams' own ranked
    /// output, served once, so the pooled top-30 /
    /// cached-first / 2160 REMUX > BluRay > WEB /
    /// TorBox > RD > Premiumize behaviour cannot change.
    @MainActor
    private static func makePlayDirector(
        meta: TorMeta, base: String, watch: WatchStore,
        video: TorVideo?, preferred: TorStream?,
        seedStreams: [TorStream], seedSubtitleURL: URL?
    ) -> PlayDirector {
        let sid = video?.id ?? meta.id
        // v2.0.45 (leg 3, gate round 3 A3-1): the user
        // addon's name is read HERE, in this @MainActor
        // builder (both call sites are MainActor
        // contexts: the detail's play action and the
        // @MainActor nextEpisodeFactory), and the ladder
        // literal below captures the String VALUE — the
        // literal's declared type carries no isolation
        // annotation, so it must never read the
        // @MainActor store itself.
        let userAddonName = JoeAddonStore.shared.addonName
        var entry = WatchStore.Entry()
        entry.kind = WatchStore.kindTor
        entry.key = WatchStore.torProgressKey(streamId: sid)
        entry.ep = video?.label ?? ""
        entry.epLabel = video.map { "Đang xem: \($0.label)" } ?? ""
        entry.title = meta.name
        entry.poster = meta.poster
        entry.year = meta.year
        entry.metaId = meta.id
        entry.metaType = meta.type
        entry.isLive = meta.isLive
        entry.streamId = sid
        // v2.0.40 (P0.1 / C-1): family code only — the base
        // itself (tokens inside) is never persisted.
        entry.metaSource = TorrentSettings.metaSource(forBase: base)
        entry.background = meta.background
        entry.desc = meta.desc
        let resume = watch.progressFor(matching: entry)?.pos ?? 0
        let originKey = entry.key
        let type = meta.type
        let firstCall = TorLadderFirstCallBox()
        return PlayDirector(
            store: watch,
            identity: PlayIdentity(entry: entry),
            resumeMs: resume,
            resolveLadder: { identity in
                // v2.0.16: the ladder re-fetches the SAME
                // pooled list the rows came from (Torrentio +
                // MediaFusion, ranked) — pre-fix it re-asked
                // Torrentio alone, so a tapped MediaFusion row
                // was not even present in its own ladder. The
                // shared conversion (TorrentClient): the tapped
                // stream leads — a hash entry earns its ONE
                // Real-Debrid resolution there — then any
                // direct-URL streams in list order.
                // v2.0.25: the FIRST origin-identity call
                // serves the already-loaded list instead
                // (see the builder note above) — the identical
                // fetch is not paid for a second time.
                let list: [TorStream]
                if !firstCall.consumed,
                   identity.progressKey == originKey,
                   !seedStreams.isEmpty {
                    firstCall.consumed = true
                    list = seedStreams
                } else {
                    let pooled = await TorrentClient.fetchPooledStreams(
                        torrentioBase: TorrentSettings.effectiveBase,
                        mfBase: TorrentSettings.mfBase,
                        type: type, id: identity.entry.streamId,
                        userAddonBase: TorrentSettings.userAddonBase,
                        userAddonName: userAddonName)
                    list = pooled.streams
                }
                var cands = await TorrentClient.playCandidates(
                    streams: list, preferred: preferred)
                // The session's Vietnamese subtitle rides
                // every candidate, so failover keeps it.
                if let seedSubtitleURL {
                    for i in cands.indices { cands[i].subtitleURL = seedSubtitleURL }
                }
                return cands
            },
            hopIdentity: nil)
    }

    /// Idea 6, torrent-series half (v2.0.25): the PlayDirector
    /// Up Next contract for a series episode — the next
    /// episode in THIS detail's loaded episode sequence
    /// (`videos`, in fetch order). Movies, the last episode,
    /// and a current episode outside the loaded list get
    /// nothing: no title, no factory, no preparation. All
    /// three members are set here, before the director is
    /// handed to JoePlayerView (and, for a factory-built
    /// director, before it is returned).
    private static func wireUpNext(
        on director: PlayDirector, after video: TorVideo?,
        meta: TorMeta, base: String, watch: WatchStore,
        videos: [TorVideo]
    ) {
        guard meta.type == "series",
              let video,
              let idx = videos.firstIndex(where: { $0.id == video.id }),
              idx + 1 < videos.count else { return }
        let nextVideo = videos[idx + 1]
        director.nextEpisodeTitle = nextVideo.label
        // Preparation state shared by onPlayingStarted (which
        // launches it) and the factory (which consumes it):
        // the next episode's pooled streams + Vietnamese
        // subtitle, resolved once in the background while the
        // current episode plays.
        let prep = TorNextEpisodePrep(videoId: nextVideo.id,
                                      type: meta.type)
        director.onPlayingStarted = {
            prep.start()
        }
        director.nextEpisodeFactory = {
            // If preparation is still in flight (a quick skip
            // to the end), wait for it rather than duplicating
            // its fetch; if it never launched, result()
            // launches it now. The factory director is seeded
            // with the prepared list, so ITS first ladder call
            // reuses it under the same Idea 3b guard — no
            // source decision is re-made: the builder, the
            // pooled family/settings and the candidate
            // conversion are the session's own, and with no
            // tapped row for a next episode the pool's own
            // top-ranked stream leads (preferred: nil), never
            // a re-rank across families. Its own Up Next is
            // wired for the episode after, so the chain
            // continues episode to episode.
            let prepared = await prep.result()
            let next = Self.makePlayDirector(
                meta: meta, base: base, watch: watch,
                video: nextVideo, preferred: nil,
                seedStreams: prepared.streams,
                seedSubtitleURL: prepared.viSubtitleURL)
            Self.wireUpNext(on: next, after: nextVideo,
                            meta: meta, base: base, watch: watch,
                            videos: videos)
            return next
        }
    }
}

/// First-call flag for a torrent ladder's resolveLadder
/// closure (v2.0.25, Idea 3b — JoeMovieDetail's
/// LadderFirstCallBox pattern): reference type because the
/// escaping closure must mutate it across invocations.
/// `consumed` flips on the first origin-identity invocation
/// that serves the already-loaded stream list; every later
/// invocation fetches its pooled list fresh.
/// Swift 6: @unchecked Sendable is justified because the
/// only toucher is the resolveLadder closure of the ONE
/// PlayDirector built beside the box — PlayDirector is
/// @MainActor and awaits each ladder invocation to
/// completion before issuing the next, so invocations
/// never overlap and each completion happens-before the
/// next start through the await chain; the flag is only
/// ever touched by one invocation at a time, whichever
/// executor the closure body itself runs on.
private final class TorLadderFirstCallBox: @unchecked Sendable {
    var consumed = false
}

/// Idea 6 preparation box (v2.0.25): the next episode's
/// pooled streams + best Vietnamese subtitle, resolved ONCE
/// in the background while the current episode plays
/// (launched by the director's onPlayingStarted) and consumed
/// by the next-episode factory as its director's seed list —
/// the factory director's first ladder call then reuses it
/// under the same first-call guard as the tapped session's,
/// so no fetch is duplicated. Main-actor isolated: both
/// contract closures that touch it are @MainActor.
@MainActor
private final class TorNextEpisodePrep {
    let videoId: String
    let type: String
    private(set) var streams: [TorStream] = []
    private(set) var viSubtitleURL: URL?
    private var task: Task<Void, Never>?

    init(videoId: String, type: String) {
        self.videoId = videoId
        self.type = type
    }

    /// Launch preparation if it has not launched yet.
    func start() {
        guard task == nil else { return }
        task = Task { await self.run() }
    }

    /// The prepared payload: waits for an in-flight launch,
    /// or launches now if onPlayingStarted never fired.
    func result() async -> (streams: [TorStream], viSubtitleURL: URL?) {
        start()
        await task?.value
        return (streams, viSubtitleURL)
    }

    private func run() async {
        // The same concurrent pair loadStreams runs for the
        // tapped episode: the pooled fetch and the subtitle
        // fetch depend only on the episode id, so they race
        // instead of stacking (max, not sum).
        async let pooledFetch = TorrentClient.fetchPooledStreams(
            torrentioBase: TorrentSettings.effectiveBase,
            mfBase: TorrentSettings.mfBase,
            type: type, id: videoId,
            userAddonBase: TorrentSettings.userAddonBase,
            userAddonName: JoeAddonStore.shared.addonName)
        async let subsFetch = TorrentClient.fetchSubtitles(
            base: TorrentSettings.subtitleBase(
                addonBase: TorrentSettings.effectiveBase
                    ?? TorrentSettings.mfBase ?? ""),
            type: type, id: videoId)
        let pooled = await pooledFetch
        streams = pooled.streams
        let subs = await subsFetch
        viSubtitleURL = TorrentClient.bestVietnamese(subs)
            .flatMap { URL(string: $0.url) }
    }
}

// CONVERGENCE RECORD (2026-11-15): this file's duplicated
// JoeMoveTrap struct is DELETED — see the record at the end of
// JoeTVApp.swift. The search-row/first-rail/Retry traps it
// powered are replaced by geometric focus movement.
// v2.0.8 (Phase 1): the per-card first-rail handler that
// briefly survived that record, the search grid's handler
// and the favourite button's boundary move are now deleted
// too — this file carries no .onMoveCommand and no
// .joeBoundaryMove; all movement is the engine's geometric
// search over the declared .focusSection() regions.
