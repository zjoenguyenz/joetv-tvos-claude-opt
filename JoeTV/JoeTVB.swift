import SwiftUI

// MARK: - TVB catalogue snapshot (bundled)
//
// The TVB tab renders ONE offline snapshot, tvb-catalog.json,
// produced by the pipeline in tvos-training/tvb-pipeline (plan:
// tvos-training/TVB-TAB-BUILD-PLAN.md; audit: TVB-PHASE1-AUDIT.md).
// The snapshot carries the full TMDB network-48 spine (1,561
// titles) with per-provider resolution records; only titles that
// resolved on at least one provider (803) are displayed — an
// unresolved title has an empty `providers` map and never renders
// (plan §1.4). Playback priority inside the snapshot is
// TP → KK → VS → F4K, already encoded per title as
// `primaryProvider`.
//
// The Codable shapes below mirror the real file field by field
// (validated against the shipped snapshot): the nulls the file
// actually carries are `imdbId` (null on 557 displayed and 691
// unresolved titles), `posterPath`, `backdropPath` and `year`
// (null only on unresolved titles — 15, 44 and 4 of them),
// `primaryProvider` and `providerUpdatedAt` (null on all 758
// unresolved titles and on no displayed title), and
// `claimedTotal` (carried by the TP records and by the 13 F4K
// records, explicitly null on all 13 F4K records; its non-null
// values are TP-only).
// `voteAverage` arrives as a JSON int on some titles and a float
// on others — a Swift Double decodes both. Unknown future keys
// are ignored by the decoder; every key the file carries today
// is modelled.

struct TVBCatalog: Codable, Sendable {
    let version: Int
    let generatedAt: String
    let source: String
    let spineCount: Int
    let resolvedCount: Int
    let titles: [TVBTitle]
    /// Genre name → tmdbId list (the seven shelves of plan §3.2).
    let shelves: [String: [Int]]
    let rails: TVBRails

    /// Load the bundled snapshot; nil on any failure (missing
    /// resource or a decode mismatch) so the tab can show its
    /// plain load-failure line instead of trapping.
    static func loadBundled() -> TVBCatalog? {
        guard let url = Bundle.main.url(forResource: "tvb-catalog",
                                        withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? JSONDecoder().decode(TVBCatalog.self, from: data)
    }
}

/// FIX-214 (DESIGN-PASS-214 §3.2): the decoded bundled
/// catalogue, latched ONCE per process. Through 2.1.3
/// loadBundled() decoded the ~2 MB snapshot at EVERY
/// call — the TVB tab's init, the Phim/Home core's
/// catalogue task, the actor page, the YT snapshot
/// build — so every section enter paid the full decode
/// again, inside the stall clusters log 17 measured.
/// The store latches the first result (a failed decode
/// latches too: the bundled file cannot change under a
/// running process, so a retry could only fail again).
/// NSLock + nonisolated(unsafe) follow this tree's
/// standing idiom for process-latched state
/// (DiagLog / SourceHealth): every access is under the
/// lock, and TVBCatalog is a Sendable value.
enum TVBCatalogStore {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var cached: TVBCatalog??

    static func load() -> TVBCatalog? {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let loaded = TVBCatalog.loadBundled()
        cached = loaded
        return loaded
    }
}

struct TVBRails: Codable, Sendable {
    let dangHot: [Int]
    let deCu: [Int]
    let moiCapNhat: [Int]
    let moiPhatHanh: [Int]
    let kinhDien: [Int]
}

struct TVBSeason: Codable, Sendable {
    let season: Int
    let episodes: Int
}

struct TVBProviderRecord: Codable, Sendable {
    let slugs: [String]
    /// "tmdb" | "imdb" | "fallback" | "tmdb-detail" — how the
    /// pipeline matched ("tmdb-detail" on 40 records: all 13
    /// F4K records and 27 TP records).
    let matchKey: String
    let matchConfidence: String
    let episodesListed: Int
    let episodesExpected: Int
    let completeness: Double
    let countSource: String
    /// Non-null values are TP-only; the key is also carried,
    /// explicitly null, by the 13 F4K records, and is null on
    /// 16 TP records in the file. KK/VS records omit the key
    /// entirely (decodes to nil).
    let claimedTotal: Int?
    /// The provider's own dub form ("Lồng Tiếng", "Vietsub", …),
    /// read from `lang` per plan §1.3 — never relabelled.
    let dubForm: String
    let dubbed: Bool
    let categories: [String]
    let updatedAt: String?
    /// Full poster URL on the provider's own CDN — the fallback
    /// art when the TMDB poster path is missing (plan §3).
    let posterFallback: String
}

struct TVBTitle: Codable, Sendable, Identifiable {
    let tmdbId: Int
    let imdbId: String?
    let titleVi: String
    let titleViTmdb: String
    let titleEn: String
    let titleOriginal: String
    let year: Int?
    let status: String
    let seasons: [TVBSeason]
    let episodeTotalTmdb: Int
    let genreIds: [Int]
    let cast: [String]
    let popularity: Double
    let voteAverage: Double
    let voteCount: Int
    let posterPath: String?
    let backdropPath: String?
    /// Catalogue provider keys: "tp" | "kk" | "vs" | "f4k".
    /// NOTE: the catalogue's "vs" is the app's Providers.VS
    /// code ("vsmov") — see appProviderCode below. Empty on
    /// unresolved titles.
    let providers: [String: TVBProviderRecord]
    /// First of TP → KK → VS → F4K holding the title; null
    /// exactly when `providers` is empty.
    let primaryProvider: String?
    let categories: [String]
    let providerUpdatedAt: String?
    /// Precomputed normalized search keys (plan §3.1): display
    /// title, TMDB vi title, EN + original titles, every holder's
    /// own names, top-billed cast, year — already folded with
    /// Providers.normalizeTitle by the pipeline.
    let searchKeys: [String]

    var id: Int { tmdbId }

    /// Displayed = resolved on at least one provider (plan §1.4).
    var isDisplayed: Bool { !providers.isEmpty }

    var yearString: String { year.map(String.init) ?? "" }

    /// Best (highest) completeness across this title's
    /// provider records; 0 when it has no records. Backs the
    /// "✅ Trọn bộ" rich shelf (Idea 1, 2.0.25).
    var bestCompleteness: Double {
        providers.values.map(\.completeness).max() ?? 0
    }

    /// Vote score for the "🏆 Hay nhất" rich shelf (Idea 1,
    /// 2.0.25): the raw average discounted by how few votes
    /// back it, so a 9.0 from a handful of votes cannot
    /// outrank a well-attested title. Callers must still
    /// gate on voteCount ≥ 5 before ranking with it.
    var weightedVoteScore: Double {
        voteAverage * (Double(min(voteCount, 50)) / 50.0)
    }

    // MARK: Provider resolution

    /// Catalogue key → the app's provider code. Only "vs"
    /// differs: Providers.VS is "vsmov", and Providers.detail /
    /// search dispatch on that code — handing the detail the
    /// raw catalogue key "vs" would fall through to the KKPhim
    /// default with a VSMOV slug. "f4k" (v2.0.39, the rebuilt
    /// snapshot's fourth holder) must map explicitly for the
    /// same reason: left to the default it would fall through
    /// to KK with a Film4K slug — the wrong-film class.
    static func appProviderCode(_ catalogueKey: String) -> String {
        switch catalogueKey {
        case "vs": return Providers.VS
        case "tp": return Providers.TP
        case "f4k": return Providers.F4K
        default: return Providers.KK
        }
    }

    /// Playback priority inside the snapshot (plan §1.2/§1.4):
    /// TP → KK → VS → F4K, the settled chain order (F4K last —
    /// it can only be a title's primary when it is the sole
    /// holder, which is exactly the titles the v2.0.39 rebuilt
    /// snapshot adds).
    static let priorityKeys = ["tp", "kk", "vs", "f4k"]

    var primaryRecord: TVBProviderRecord? {
        guard let primaryProvider else { return nil }
        return providers[primaryProvider]
    }

    /// The route target for a tap: the primary provider's FIRST
    /// slug (plan §3 / build spec), with a defensive fallback to
    /// the first holder in TP → KK → VS → F4K order carrying a slug —
    /// unreachable on the shipped snapshot (every displayed
    /// title's primary record has ≥1 slug, verified in the
    /// audit pass), kept so a future snapshot can never render
    /// a dead card.
    var routeTarget: (provider: String, slug: String)? {
        if let primaryProvider,
           let record = providers[primaryProvider],
           let slug = record.slugs.first, !slug.isEmpty {
            return (Self.appProviderCode(primaryProvider), slug)
        }
        for key in Self.priorityKeys {
            if let record = providers[key],
               let slug = record.slugs.first, !slug.isEmpty {
                return (Self.appProviderCode(key), slug)
            }
        }
        return nil
    }

    /// v2.0.31 (L7/I1): the route context for a tap — the
    /// snapshot's own identity for this title: its TMDB id,
    /// its IMDb id when the spine carries one, and every
    /// holder record as an exact (provider, slug) pair in
    /// TP → KK → VS → F4K order, flagged by the pipeline's own
    /// match key. The detail verifies against it (L7) and
    /// orders its holders by measured playability (I1).
    var routeContext: TVBRouteContext {
        var holders: [TVBRouteContext.Holder] = []
        for key in Self.priorityKeys {
            guard let record = providers[key],
                  let slug = record.slugs.first, !slug.isEmpty
            else { continue }
            holders.append(TVBRouteContext.Holder(
                provider: Self.appProviderCode(key),
                slug: slug,
                idMatched: record.matchKey != "fallback"))
        }
        return TVBRouteContext(
            tmdbId: tmdbId, imdbId: imdbId ?? "", holders: holders,
            backdropPath: backdropPath ?? "")
    }

    /// The primary holder's dub form, exactly as the provider
    /// states it (plan §2: non-dubbed titles are shown by their
    /// real form, never relabelled).
    var dubForm: String {
        if let form = primaryRecord?.dubForm, !form.isEmpty { return form }
        for key in Self.priorityKeys {
            if let form = providers[key]?.dubForm, !form.isEmpty { return form }
        }
        return ""
    }

    /// Card meta line in the Movie.cardMeta shape: year · dub form.
    var cardMeta: String {
        [yearString, dubForm].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // MARK: Artwork

    /// TMDB poster first (the house w500 convention —
    /// JoeImagePipeline.tmdbPosterURL builds the same URL from
    /// a path), the primary holder's posterFallback behind it,
    /// then any holder's fallback in priority order (plan §3).
    var posterURLString: String {
        if let path = posterPath, !path.isEmpty {
            return "https://image.tmdb.org/t/p/w500"
                + (path.hasPrefix("/") ? path : "/" + path)
        }
        if let fallback = primaryRecord?.posterFallback, !fallback.isEmpty {
            return fallback
        }
        for key in Self.priorityKeys {
            if let fallback = providers[key]?.posterFallback, !fallback.isEmpty {
                return fallback
            }
        }
        return ""
    }

    var posterURL: URL? {
        posterURLString.isEmpty ? nil : URL(string: posterURLString)
    }

    /// v2.1.1 (WS-I): the title's TMDB backdrop as a
    /// w1280 URL (the TMDBClient backdrop convention —
    /// TMDBClient.swift:102), from the snapshot's own
    /// backdropPath; nil when the spine carries none.
    /// The Private Cinema homes' focus-follows-backdrop
    /// ladder reads this first, the poster behind it.
    var cinemaBackdropURL: URL? {
        guard let path = backdropPath, !path.isEmpty else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w1280"
            + (path.hasPrefix("/") ? path : "/" + path))
    }

    // MARK: Search index

    /// The in-tab search corpus for this title (plan §3.1): the
    /// pipeline's precomputed searchKeys, plus the raw title and
    /// cast fields normalized here so the corpus stays correct
    /// even if a future snapshot's key list thins out. All keys
    /// pass through Providers.normalizeTitle — the same folding
    /// the query gets — so diacritics-free typing matches.
    var normalizedKeys: [String] {
        (searchKeys + [titleVi, titleEn, titleOriginal] + cast)
            .map { Providers.normalizeTitle($0) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Snapshot identity lookup (v2.0.37, cluster E item 9)
//
// The reopen gate's snapshot side: WatchStore.Entry
// .tvbRouteContext (WatchStore.swift) names a stored
// Continue Watching / Favourites entry by its stamped
// TMDB or IMDb id, and this lookup answers "which
// DISPLAYED snapshot title — if any — carries that id?"
// Only displayed titles are indexed (an unresolved title
// has no holders to reopen through, so it can never be
// the answer). The maps are built once from the bundled
// snapshot and cached for the session, lock-guarded in
// the Providers raw-memo idiom; the snapshot file is
// immutable for the process's life, so the cache never
// needs invalidation. A miss is meaningful: the entry's
// film is not a TVB snapshot title (the ordinary Phim
// catalogue carries TMDB ids too), and its reopen stays
// exactly as it has always been.
enum TVBSnapshotLookup {
    private static let lock = NSLock()
    // Swift 6: nonisolated(unsafe) — every access is
    // serialized by lock (maps()); the published maps are
    // immutable snapshots of immutable bundled data.
    private nonisolated(unsafe) static var byTmdbId: [Int: TVBTitle]?
    private nonisolated(unsafe) static var byImdbId: [String: TVBTitle]?

    private static func maps() -> (tmdb: [Int: TVBTitle],
                                   imdb: [String: TVBTitle]) {
        lock.lock()
        if let byTmdbId, let byImdbId {
            lock.unlock()
            return (byTmdbId, byImdbId)
        }
        lock.unlock()
        // Built outside the lock; racing builders build
        // identical maps from the same immutable file,
        // and the first publisher wins.
        var tmdb: [Int: TVBTitle] = [:]
        var imdb: [String: TVBTitle] = [:]
        if let catalog = TVBCatalogStore.load() {
            for title in catalog.titles where title.isDisplayed {
                tmdb[title.tmdbId] = title
                if let imdbId = title.imdbId, !imdbId.isEmpty {
                    imdb[imdbId] = title
                }
            }
        }
        lock.lock()
        if byTmdbId == nil {
            byTmdbId = tmdb
            byImdbId = imdb
        }
        let published = (tmdb: byTmdbId ?? tmdb,
                         imdb: byImdbId ?? imdb)
        lock.unlock()
        return published
    }

    static func title(tmdbId: Int) -> TVBTitle? {
        maps().tmdb[tmdbId]
    }

    static func title(imdbId: String) -> TVBTitle? {
        guard !imdbId.isEmpty else { return nil }
        return maps().imdb[imdbId]
    }
}

// MARK: - TVB section root
//
// One new section beside the existing ones, on the shell's
// unchanged scaffolding: a header (title + the tab's own search
// entry, the Phim slim-header construction), then the rails
// home (the five pipeline rails of plan §3.3/§3 in build order,
// then the seven genre shelves AS RAILS). The in-tab
// search (plan §3.1) swaps in above the home exactly as the
// Phim search swaps in above JoePhimHome.
//
// v2.1.2 (owner ruling 2026-11-22 03:43 CST): the genre
// chips row that used to stand between the header and the
// rails is REMOVED — "Trang tvb vẫn giữ tìm kiếm thôi, vì
// có rail rồi": the search entry stays, and the seven genre
// shelves stay reachable as the rails railSpecs already
// appends (both arms render them), so the chip-selected
// genre grid and its state went with the row. Nothing else
// on this page moved.
//
// MENU: this root carries the section handler in the
// JoeTVSection / JoeSettingsView shape — Menu returns to the
// Phim section. The search layer carries its own nearer handler
// (the JoeSearchView placement), so while search is open one
// press closes search and nothing else; the state check inside
// this root's handler mirrors JoePhimHome's for the presses the
// root itself sees. Focus is geometric throughout: plain
// buttons in declared .focusSection()s, the shared
// .joeCardButton() construction, no handlers, no focus writes
// beyond the header's .defaultFocus entry declaration (the
// slim-header pattern).
struct JoeTVBView: View {
    @EnvironmentObject private var nav: JoeNavigator
    @EnvironmentObject private var watch: WatchStore
    @Environment(\.joeTheme) private var theme
    @State private var catalog: TVBCatalog?
    @State private var loadFailed = false
    @State private var searchOpen = false
    /// Idea 1 (actor rail): the actor page presented over
    /// this tab when an actor card is tapped — see
    /// JoeActorPage.swift (.tvb mode).
    @State private var actorRoute: JoeActorRoute?
    /// v2.0.49 (item 7): bumped by the section's Menu
    /// handler to make home's ScrollViewReader jump to
    /// the top of the page (owner order 2026-11-21).
    @State private var topScrollSignal = 0
    @FocusState private var headerSearchFocused: Bool
    @FocusState private var cardFocus: String?
    /// v2.1.1 (WS-I): the PC arm's focus-follows-backdrop
    /// controller (the shared JoeCinemaBackdropController,
    /// JoePrivateCinema.swift), fed from the SAME
    /// cardFocus memory tvbContextInfo derives from.
    /// Read only by pcHome; every other theme ignores it.
    @StateObject private var tvbBackdrop =
        JoeCinemaBackdropController()
    /// v2.1.1 (FIX-6): the PC hero's action focus —
    /// while focus sits on the hero's own buttons
    /// cardFocus reads nil, and tvbHeroMemory below is
    /// what keeps the hero on the last focused title
    /// (the JoePhimHome cinemaHeroMemory discipline).
    @FocusState private var tvbHeroPlayFocused: Bool
    @FocusState private var tvbHeroInfoFocused: Bool
    /// v2.1.1 (FIX-6): the last card-resolved hero, kept
    /// while focus is on the hero's actions or the
    /// header (see tvbHeroFocusMoved).
    @State private var tvbHeroMemory: TVBHeroResolved?

    /// v2.1.1 (FIX-10a / RECON-POWERMAX point 6): the
    /// context strip's memory — the last RESOLVED strip
    /// tuple, recorded in tvbHeroFocusMoved while a card
    /// is focused. When focus moves up to the tab bar
    /// (no card focused) the strip RETAINS this context
    /// instead of resetting to the section label; nil
    /// before any card has ever been focused (the rest
    /// behaviour is unchanged).
    @State private var tvbStripMemory: (title: String, meta: String, railName: String, railLine: String)?

    /// v2.1.1 (FIX-6): what the PC hero's two actions
    /// open for the currently resolved title — EXACTLY
    /// the focused card's own tap mint per surface (a
    /// catalogue title's open(), a YouTube series'
    /// openYouTube(), an actor card's actorRoute, a
    /// Continue Watching entry's JoeYtRoute reopen).
    private enum TVBHeroTarget {
        case title(TVBTitle)
        case yt(JoeYtSeries)
        case actor(ActorRailEntry)
        case cwEntry(WatchStore.Entry)
    }

    /// v2.1.1 (FIX-6): a resolved TVB hero — the shared
    /// controller's item (text + art ladder) and the
    /// actions' target. (FIX-8 / C-R4-1: no eyebrow
    /// field — the hero eyebrow is the drawing's STATIC
    /// section line, painted literally by tvbHeroText
    /// exactly as the Torrent hero paints its own.)
    private struct TVBHeroResolved {
        var item: JoeCinemaHeroItem
        var target: TVBHeroTarget
    }

    /// The seven genre shelves, in the snapshot's audit order
    /// (TVB-PHASE1-AUDIT §5). A shelf renders only when the
    /// loaded snapshot carries it.
    static let genreOrder = [
        "Cổ Trang / Kiếm Hiệp",
        "Hình Sự / Phá Án",
        "Tình Cảm",
        "Gia Đình",
        "Hài Hước",
        "Hành Động",
        "Tâm Lý / Chính Kịch",
    ]

    /// Displayed titles by TMDB id, built once at load.
    @State private var byId: [Int: TVBTitle] = [:]
    @State private var displayed: [TVBTitle] = []

    /// The YouTube catalogue store (TVB YouTube feature,
    /// design §1.2): its rails stage above the 803 rails on
    /// the rails home, and a matched 803 title routes to the
    /// YouTube detail (YouTube primary, the owner's law).
    @ObservedObject private var ytStore = JoeYtStore.shared

    var body: some View {
        Group {
            if searchOpen {
                JoeTVBSearchView(titles: displayed) { searchOpen = false }
            } else if theme.id == .privateCinema {
                // v2.1.1 (WS-H): the Many-Rails PC arm of
                // the TVB home; every other theme keeps
                // `home` byte-for-byte in behaviour.
                pcHome
            } else {
                home
            }
        }
        // Menu in this SECTION returns to the Phim section —
        // the app's main menu — instead of exiting the app
        // (the JoeTVSection / JoeSettingsView handler, on this
        // section's own root). The search layer's own handler
        // is the nearer consumer while search is open.
        .onExitCommand {
            if searchOpen {
                searchOpen = false
            } else if headerSearchFocused == true
                        || tvbHeroPlayFocused == true {
                // FIX-213 (Fault 5): the "focus rests on
                // this page's declared first element" test
                // names BOTH landings — the header search
                // button (every other theme) and the hero
                // Play button (Private Cinema, whose header
                // carries no button since this fix). Each
                // binding is only ever bound under its own
                // theme, so the combined test is exact.
                nav.section = .home  // FIX-213 (Fault 13): return to Trang chủ (.home), the home surface since the split
            } else if theme.id == .privateCinema && catalog == nil {
                // GATE-213 R6 Lens 2 F3: under Private
                // Cinema with no catalogue on screen (the
                // loading / load-failed states) the hero —
                // and with it the $tvbHeroPlayFocused
                // binding — is not rendered, so the landing
                // write below was a visibly dead press; only
                // the second press, its state now reading
                // true, reached the return above. Fall
                // through to that return on the first press.
                nav.section = .home
            } else {
                // v2.0.49 (item 7, owner order 2026-11-21
                // 22:32): Menu jumps straight to the top of
                // the page first — scroll to the top and
                // land focus on the header search button
                // (this page's declared first element),
                // swallowing the exit.
                // FIX-213 (Fault 5): under Private Cinema
                // the landing is the hero Play button —
                // the header search button no longer
                // exists there.
                topScrollSignal += 1
                if theme.id == .privateCinema {
                    tvbHeroPlayFocused = true
                } else {
                    headerSearchFocused = true
                }
            }
        }
        // Idea 1: the actor page (.tvb mode) over this tab.
        .fullScreenCover(item: $actorRoute) { route in
            JoeActorPage(route: route)
        }
        // FIX-213 (Fault 5): the shell bar's search
        // request for this section (see JoeNavigator
        // .tvbSearchRequested) — consume it, reset it,
        // and open the in-tab search, with the header
        // button's own catalogue guard.
        .onChange(of: nav.tvbSearchRequested) { _, requested in
            if requested {
                nav.tvbSearchRequested = false
                if catalog != nil { searchOpen = true }
            }
        }
        .task { await loadCatalog() }
        .task { ytStore.ensureLoaded() }
    }

    // MARK: - Load

    private func loadCatalog() async {
        guard catalog == nil, !loadFailed else { return }
        let loaded = await Task.detached(priority: .userInitiated) {
            TVBCatalogStore.load()
        }.value
        guard let loaded else {
            loadFailed = true
            return
        }
        catalog = loaded
        displayed = loaded.titles.filter { $0.isDisplayed }
        byId = Dictionary(uniqueKeysWithValues: displayed.map { ($0.tmdbId, $0) })
        // Warm the first rails' posters (the JoePhimHome launch
        // prefetch pattern) so the home paints with art, not
        // placeholders, on its first scroll.
        let warm = (loaded.rails.dangHot + loaded.rails.deCu
            + loaded.rails.moiCapNhat)
            .compactMap { byId[$0]?.posterURL }
        JoeImagePipeline.shared.prefetch(warm, targetPixels: 720)
    }

    private func titles(for ids: [Int]) -> [TVBTitle] {
        ids.compactMap { byId[$0] }
    }

    // MARK: - Home

    private var home: some View {
        // v2.0.49 (item 7): the ScrollView sits inside a
        // ScrollViewReader so Menu can jump straight to
        // the top of the page (see the body's handler).
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 40) {
                header
                if let catalog {
                    // YouTube rails stage ABOVE the 803
                    // rails (design §1.2), only on the
                    // rails home; with no snapshot the
                    // home is exactly what it was.
                    if let snapshot = ytStore.snapshot {
                        ytRailSections(snapshot)
                    }
                    railSections(catalog)
                } else if loadFailed {
                    Text("Không tải được danh sách TVB.")
                        .font(.system(size: 29))
                        .foregroundStyle(theme.meta)
                        .padding(.top, 30)
                } else {
                    ProgressView("Đang tải danh sách TVB…")
                        .font(.system(size: 29))
                        .foregroundStyle(theme.text)
                        .tint(theme.text)
                        .padding(.top, 30)
                }
            }
            .id("joeTVBHomeTop")
            }
            // v2.0.49 (item 7): the Menu-to-top jump's
            // scroll hook, inside the reader.
            .onChange(of: topScrollSignal) { _, _ in
                proxy.scrollTo("joeTVBHomeTop", anchor: .top)
            }
        }
        // v2.0.16 (owner's 2026-11-17 TVB clip): this
        // container deliberately CLIPS at its frame — no
        // .scrollClipDisabled(). The v2.0.8 Phase 4 unclip
        // let poster rows scrolling past the frame's top
        // edge keep painting over the shell's top pill bar
        // (the v2.0.12 search rule, second conviction). The
        // rails inside keep their own bounded horizontal
        // escape (JoeTheme.Rail); nothing in this stack
        // needs to cross the frame vertically — the first
        // rail's cards sit below the in-flow header, and a
        // focused card's ring lives inside its rail.
    }

    // MARK: - Private Cinema Many-Rails home (v2.1.1, WS-H)

    /// The PC arm of the TVB home (WS-H): the header
    /// (v2.1.2: the genre chips row is gone — the owner
    /// ruling at the section doc above; only the search
    /// entry stands above the hero now), then the
    /// rails inside a Section whose header is the pinned
    /// context strip (the OS pins it once scrolled past —
    /// no scroll-offset APIs). The design's lead rails
    /// (FIX-4 / C3: dangHot → moiCapNhat → the crime genre
    /// shelf → kinhDien, under plain headings) render FIRST
    /// with the PC local card; the YT rails and the
    /// remaining shelves (deCu, moiPhatHanh included)
    /// APPEND after in their existing order (WS-H mapping
    /// §4). NOTE the PC-only order change: on every other
    /// theme the YT rails stage above the 803 rails; here
    /// the lead rails lead.
    private var pcHome: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 8,
                       pinnedViews: [.sectionHeaders]) {
                // GATE-213 R3 Lens 3 Finding 1 (RECALC-SPEC
                // §3.5 + §5): the PC TVB home opens STRAIGHT
                // with its hero, like the other three homes —
                // the legacy `header` title block ("Phim bộ
                // TVB" in system 44 heavy over a system 25
                // subtitle) is legacy-theme furniture and
                // does not render here. The legacy home
                // keeps `header` unchanged.
                if let catalog {
                    // v2.1.1 (FIX-6): the full PC hero
                    // (485 stage, the Phim hero's
                    // composition) — it supersedes WS-I's
                    // top-zone-only backdrop placement:
                    // the shared controller's layer now
                    // lives INSIDE this hero block, and
                    // the hero text + actions follow
                    // focus (tvbHeroResolved).
                    tvbHeroBlock(catalog)
                    Section {
                        // v2.1.1 (FIX-6): the design's
                        // FIRST rail — TVB Continue
                        // Watching, when entries exist.
                        pcTVBCwRail
                        pcPipelineRails(catalog)
                        if let snapshot = ytStore.snapshot {
                            // FIX-213 (Fault 7) + GATE-213
                            // R5 Lens 2 F1: the YT rails ride
                            // the shared Rail, which since
                            // the R4 gate fix carries the
                            // design's 94 frame itself under
                            // Private Cinema — no wrapper
                            // inset here (it double-inset
                            // the rails to 108).
                            ytRailSections(snapshot)
                        }
                        pcAppendSections(catalog)
                    } header: {
                        tvbContextStrip(catalog)
                            // claude/opt-2 (FL-427): Ink above
                            // the strip while it is pinned.
                            .joePCPinnedBandCover()
                    }
                    // claude/opt-2 (FL-457, owner ruling): the
                    // Section's plain Ink fill is removed — it
                    // cut the full-screen page backdrop at the
                    // hero's foot; the rails sit on the page
                    // scrim's near-full Ink, as on the other
                    // three homes.
                } else if loadFailed {
                    Text("Không tải được danh sách TVB.")
                        .font(JoePCType.outfit(29))
                        .foregroundStyle(theme.meta)
                        .padding(.top, 30)
                } else {
                    ProgressView("Đang tải danh sách TVB…")
                        .font(JoePCType.outfit(29))
                        .foregroundStyle(theme.text)
                        .tint(theme.text)
                        .padding(.top, 30)
                }
            }
            .id("joeTVBHomeTop")
            // FIX-213 (Fault 16): the stack rides up by
            // the bar's height to cancel the scroll
            // view's bar-clearance inset (joePCBarInset
            // below) — rest geometry is unchanged (the
            // hero still paints behind the transparent
            // bar), but the pinned context strip now
            // pins BELOW the bar instead of inside its
            // band.
            .padding(.top, -joePCBarHeight)
            // FIX-213 (Fault 7): the design's bottom
            // margin (library bottom64), as on the Phim
            // home — the stack previously ended flush.
            .padding(.bottom, 64)
            }
            .joePCBarInset()
            // claude/opt-2 (FL-457): the full-screen backdrop behind
            // the whole page (Private Cinema only; see JoePrivateCinema).
            .joePCPageBackdrop(tvbBackdrop)
            .onChange(of: topScrollSignal) { _, _ in
                proxy.scrollTo("joeTVBHomeTop", anchor: .top)
            }
        }
        // v2.1.1 (WS-I; FIX-6): cardFocus is the PC arm's
        // focus memory (the strip's own source) — every
        // move feeds the hero + backdrop controller
        // through the resolver below; the debounce task
        // inside the controller is the only scheduled
        // work (FL-017). The displayed-count hook seeds
        // the hero's default title when the catalogue
        // lands after onAppear.
        .onChange(of: cardFocus) { _, new in
            // FIX-213 (Fault 6 instrumentation): the
            // focus-step breadcrumb — one DiagLog line
            // per focus step on this home, so the next
            // test session's log can convict or clear
            // the lag hypotheses (see DiagLog's stall
            // heartbeat). No behaviour change.
            DiagLog.noteFocus(surface: "tvb-home", key: new)
            tvbHeroFocusMoved()
        }
        .onChange(of: displayed.count) { _, _ in tvbHeroFocusMoved() }
        .onAppear { tvbHeroFocusMoved() }
    }

    /// Feed the TVB hero + backdrop controller from
    /// cardFocus (v2.1.1, WS-I; FIX-6 — the full hero):
    /// a card focus resolves + remembers the hero and
    /// pushes its item to the controller (text first —
    /// the block renders the same resolution in body —
    /// backdrop after the controller's debounce). NO
    /// card focus keeps the remembered hero (focus is
    /// on the hero's actions or the header); before any
    /// focus the default resolution (the first title of
    /// the first catalogue rail) seeds both.
    private func tvbHeroFocusMoved() {
        guard let catalog else {
            tvbBackdrop.focusChanged(to: nil)
            return
        }
        if cardFocus != nil {
            if let resolved = tvbHeroResolved(catalog) {
                // FIX-12 / R7 B-1: record the strip's
                // resolved tuple ONLY when the hero
                // resolution actually resolved the FOCUSED
                // card (this existing hook only — FL-017;
                // no new per-focus work). tvbHeroResolved
                // returns nil when a focused card no
                // longer resolves (a reload removed it),
                // and its focused branches key the item
                // by the focus ID itself — the rest
                // fallback keys it "rest|…", so the key
                // test can never pass for a rest tuple.
                if resolved.item.key == cardFocus {
                    tvbStripMemory = tvbContextInfo(catalog)
                }
                tvbHeroMemory = resolved
                tvbBackdrop.focusChanged(to: resolved.item)
            }
            return
        }
        if tvbHeroMemory != nil { return }
        if let resolved = tvbHeroResolved(catalog) {
            tvbHeroMemory = resolved
            tvbBackdrop.focusChanged(to: resolved.item)
        }
    }

    /// The hero the block renders: the live resolution
    /// while a card is focused; the remembered hero once
    /// focus has left the cards; the default resolution
    /// before either exists.
    private func tvbHeroDisplayResolved(
        _ catalog: TVBCatalog
    ) -> TVBHeroResolved? {
        if cardFocus != nil { return tvbHeroResolved(catalog) }
        return tvbHeroMemory ?? tvbHeroResolved(catalog)
    }

    /// The hero for the current focus, resolved from
    /// the SAME cardFocus memory tvbContextInfo derives
    /// from (its branches, extended with the CW rail):
    /// a Continue Watching entry → a YT series → a
    /// catalogue title → an actor entry; before any
    /// focus, the first title of the first catalogue
    /// rail (the lead scopes in FIX-4 order, then the
    /// appended specs). Art ladders are WS-I's: a
    /// catalogue title's TMDB backdrop (cinemaBackdrop
    /// URL) then its poster; a YT series / actor card
    /// carries only poster art, so the poster IS the
    /// backdrop; a CW entry's own background then its
    /// poster (else the YT series' poster by pid).
    /// Synopsis comes only from a field the record
    /// carries — the TVB snapshot carries NO synopsis
    /// field, so catalogue/YT/actor heroes omit the
    /// block; a CW entry's own desc is the only one.
    private func tvbHeroResolved(
        _ catalog: TVBCatalog
    ) -> TVBHeroResolved? {
        if let cardFocus {
            let parts = cardFocus.split(separator: "|", maxSplits: 1)
            let scope = parts.isEmpty ? "" : String(parts[0])
            let tail = parts.count > 1 ? String(parts[1]) : ""
            if scope == "tvbcw",
               let entry = tvbCwEntries.first(
                   where: { "tvbcw|" + $0.key == cardFocus }) {
                let poster = entry.posterURL
                    ?? ytStore.snapshot?.byPid[entry.slug]?.posterURL
                return TVBHeroResolved(
                    item: JoeCinemaHeroItem(
                        key: cardFocus,
                        title: entry.title,
                        meta: entry.epLabel,
                        synopsis: entry.desc,
                        backdropURL: entry.background.isEmpty
                            ? nil : URL(string: entry.background),
                        posterURL: poster),
                    target: .cwEntry(entry))
            }
            // FIX-10a / Pass-2 Lens B F1: YT cards bind
            // the rail-scoped "yt:<rail.scope>|<pid>" —
            // the scope segment carries the rail, the
            // tail is still the pid.
            if scope.hasPrefix("yt:"), let snapshot = ytStore.snapshot,
               let series = snapshot.byPid[tail] {
                return TVBHeroResolved(
                    item: JoeCinemaHeroItem(
                        key: cardFocus,
                        title: series.title,
                        meta: [series.tierLabel,
                               "\(series.eps.count) tập"]
                            .filter { !$0.isEmpty }
                            .joined(separator: " · "),
                        synopsis: "",
                        backdropURL: nil,
                        posterURL: series.posterURL),
                    target: .yt(series))
            }
            if let tmdbId = Int(tail), let title = byId[tmdbId] {
                return TVBHeroResolved(
                    item: JoeCinemaHeroItem(
                        key: cardFocus,
                        title: title.titleVi,
                        meta: tvbHeroMetaLine(title),
                        synopsis: "",
                        backdropURL: title.cinemaBackdropURL,
                        posterURL: title.posterURL),
                    target: .title(title))
            }
            if let spec = railSpecs(catalog)
                   .first(where: { $0.scope == scope }),
               let actor = spec.actors.first(where: { $0.name == tail }) {
                return TVBHeroResolved(
                    item: JoeCinemaHeroItem(
                        key: cardFocus,
                        title: actor.name,
                        meta: "\(actor.count) phim",
                        synopsis: "",
                        backdropURL: nil,
                        posterURL: actor.posterURL),
                    target: .actor(actor))
            }
            return nil
        }
        // Rest / default: the first title of the first
        // catalogue rail — the lead scopes in their
        // FIX-4 order first, then the appended specs in
        // railSpecs order.
        let specs = railSpecs(catalog)
        for scope in pcLeadScopes {
            if let spec = specs.first(where: { $0.scope == scope }),
               let title = titles(for: spec.ids).first {
                return TVBHeroResolved(
                    item: JoeCinemaHeroItem(
                        key: "rest|" + "\(title.tmdbId)",
                        title: title.titleVi,
                        meta: tvbHeroMetaLine(title),
                        synopsis: "",
                        backdropURL: title.cinemaBackdropURL,
                        posterURL: title.posterURL),
                    target: .title(title))
            }
        }
        for spec in specs {
            if let title = titles(for: spec.ids).first {
                return TVBHeroResolved(
                    item: JoeCinemaHeroItem(
                        key: "rest|" + "\(title.tmdbId)",
                        title: title.titleVi,
                        meta: tvbHeroMetaLine(title),
                        synopsis: "",
                        backdropURL: title.cinemaBackdropURL,
                        posterURL: title.posterURL),
                    target: .title(title))
            }
        }
        return nil
    }

    /// The hero meta line for a catalogue title
    /// (v2.1.1, FIX-6): year · ★ rating · episode
    /// count — ONLY from fields the snapshot record
    /// carries: year (yearString), voteAverage (only
    /// when > 0 — most of the spine carries 0 votes),
    /// episodeTotalTmdb ("N tập", only when > 0). The
    /// drawing's age / quality chips have NO field on
    /// this model and are omitted, never invented.
    private func tvbHeroMetaLine(_ title: TVBTitle) -> String {
        var parts: [String] = []
        if !title.yearString.isEmpty {
            parts.append(title.yearString)
        }
        if title.voteAverage > 0 {
            parts.append("★ " + String(format: "%.1f",
                                       title.voteAverage))
        }
        if title.episodeTotalTmdb > 0 {
            parts.append("\(title.episodeTotalTmdb) tập")
        }
        return parts.joined(separator: " · ")
    }

    // FIX-8 / C-R4-1: tvbHeroRailName is DELETED — its
    // only caller was the hero eyebrow, which is now
    // the drawing's static line (see tvbHeroText). The
    // context strip's own rail-name resolution inside
    // tvbContextInfo is a separate derivation and is
    // untouched.

    /// The hero actions' tap (v2.1.1, FIX-6): perform
    /// the resolved title's OWN card tap — the identical
    /// mint each rail builder performs, nothing new.
    private func tvbOpenHeroTarget(_ target: TVBHeroTarget) {
        switch target {
        case .title(let title):
            open(title)
        case .yt(let series):
            openYouTube(series)
        case .actor(let actor):
            actorRoute = .tvb(name: actor.name)
        case .cwEntry(let entry):
            nav.ytDetail = JoeYtRoute(pid: entry.slug)
        }
    }

    /// The Private Cinema TVB hero block (v2.1.1,
    /// FIX-6): the Phim hero's composition verbatim —
    /// the shared controller's crossfade layer as a
    /// 485-tall full-width stage, the same three scrims,
    /// the text stack at the same positions, and the
    /// right-side tagline block. The stage is in-flow
    /// (it scrolls away with the page, exactly like the
    /// Phim hero) — WS-I's ScrollView-background
    /// placement is replaced by this hero-zone layer.
    private func tvbHeroBlock(_ catalog: TVBCatalog) -> some View {
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
            // FIX-214 (FULL-THEME-AUDIT-214 Phần C họ 1):
            // the design's Ink scrims (JoeCinemaScrims),
            // shared by all three heroes — the shipped
            // pair was the same BLACK-gradient family as
            // the Phim hero's.
            // FIX-213 (Fault 8): NO top scrim — the
            // design draws exactly two scrims on this
            // stage (left + bottom); the third one that
            // stood here was added by the build for the
            // OLD bar's legibility and darkened the art
            // under the bar zone ("Làm che luôn
            // backdrop"). See cinemaHeroBlock in
            // JoePhimHome.swift.
            if let resolved = tvbHeroDisplayResolved(catalog) {
                tvbHeroText(resolved)
            }
        }
        .frame(height: 560)
        // FIX-213 (Fault 7): full-bleed stage, as on
        // the Phim hero — the block bleeds across the
        // shell's 80 pt ambient inset; the hero text
        // keeps the TVB design's own x93 inside
        // tvbHeroText and the tagline ends at 1826.
        .padding(.horizontal, -80)
        .overlay(alignment: .bottomTrailing) {
            tvbHeroTagline(catalog)
                .padding(.trailing, 94)
                .padding(.bottom, 72)
        }
        // GATE-213 R6 Lens 2 F2: the declared section
        // landing under Private Cinema — opening the TVB
        // tab lands on the hero's Play control, as on the
        // other PC homes (cinemaHeroBlock in JoePhimHome
        // carries the same declaration). The header's own
        // .defaultFocus serves every other theme (see the
        // header declaration above).
        .defaultFocus($tvbHeroPlayFocused, true)
    }

    /// The TVB hero's text block (v2.1.1, FIX-6 — a
    /// named helper per FL-390): eyebrow, typeset
    /// title, meta line, synopsis (only when the record
    /// carries one) and the design's TWO actions —
    /// pale "▶ Chọn tập" and dark "ⓘ Thông tin phim",
    /// BOTH wired to the resolved title's own detail
    /// route via tvbOpenHeroTarget (the detail screen
    /// is where episodes are chosen). Geometry mirrors
    /// JoePhimHome.cinemaHeroText exactly.
    private func tvbHeroText(_ resolved: TVBHeroResolved) -> some View {
        let item = resolved.item
        // FIX-214 (DESIGN-PASS-214 §1a): the same
        // measured 394 text-zone budget as the Phim hero
        // — this form has no origin row, so the synopsis
        // is the only compressible row (2→1→0).
        let titleLines = min(2, JoeHeroMeasure.lines(
            of: item.title,
            postScriptName: "BricolageGrotesque-Medium",
            size: 72, width: 850))
        var synopsisLimit = item.synopsis.isEmpty ? 0
            : min(2, JoeHeroMeasure.lines(
                of: item.synopsis, postScriptName: "Outfit-Regular",
                size: 20, width: 665))
        func tvbBlockHeight() -> CGFloat {
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
        while tvbBlockHeight() > 394 && synopsisLimit > 0 {
            synopsisLimit -= 1
        }
        return VStack(alignment: .leading, spacing: 0) {
            // FIX-8 / C-R4-1: the drawing's STATIC section
            // eyebrow (delivery-joetv-TVBManyRails.png),
            // painted literally — the same pattern as the
            // Torrent hero's static line in torHeroText.
            // FIX-214 (FULL-THEME-AUDIT-214 B4): the drawn
            // line ends "· ĐANG CHỌN".
            Text("MỘT THỜI HỒNG KÔNG / TVB · ĐANG CHỌN")
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
                    // the measured budget limit, max 665
                    // (the B2 family values).
                    .font(JoePCType.outfit(20))
                    .foregroundStyle(theme.text.opacity(0.92))
                    .lineSpacing(10)
                    .lineLimit(synopsisLimit)
                    .frame(maxWidth: 665, alignment: .leading)
                    .padding(.top, 10)
            }
            HStack(spacing: 16) {
                Button {
                    tvbOpenHeroTarget(resolved.target)
                } label: {
                    JoePrimaryLabel(title: "Chọn tập",
                                    systemImage: "play.fill")
                }
                .joeCardButton()
                .focused($tvbHeroPlayFocused)
                Button {
                    tvbOpenHeroTarget(resolved.target)
                } label: {
                    // FIX-214 (FULL-THEME-AUDIT-214 B4):
                    // the drawn second action is
                    // "Thông tin phim bộ".
                    JoeSecondaryLabel(title: "Thông tin phim bộ",
                                      systemImage: "info.circle")
                }
                .joeCardButton()
                .focused($tvbHeroInfoFocused)
            }
            .padding(.top, 16)
        }
        // FIX-213 (Fault 7): the hero block now bleeds
        // to the frame's edges (see tvbHeroBlock), so
        // this inset is the TVB design's own hero x93
        // (TVB Home completion spec: hero x93, w850).
        // FIX-214: the frame is 93 + 850 = 943 (the
        // shipped 900 starved the content the same way
        // the Phim hero's did).
        .padding(.leading, 93)
        .padding(.vertical, 36)
        .frame(maxWidth: 943, alignment: .leading)
    }

    /// The hero's right-side tagline block (v2.1.1,
    /// FIX-6 — the drawing's block, shared by all three
    /// PC heroes): the italic line over the caps line
    /// with THIS home's real visible rail count
    /// (pcVisibleRailTitles — the strip's own list).
    private func tvbHeroTagline(_ catalog: TVBCatalog) -> some View {
        // FIX-214 (FULL-THEME-AUDIT-214 B4): the drawn
        // copy — "Phim đang được chọn" over
        // "<TITLE> · <N> DÃY PHIM" (the displayed hero's
        // title + this home's real rail count); the
        // invented lines are removed, as on the Phim
        // hero.
        let heroTitle = (tvbHeroDisplayResolved(catalog)?.item.title
                         ?? "").uppercased()
        return VStack(alignment: .trailing, spacing: 8) {
            Text("Phim đang được chọn")
                .font(JoePCType.editorial(28, italic: true))
                .foregroundStyle(theme.text)
                .lineLimit(1)
            Text("\(heroTitle) · \(pcVisibleRailTitles(catalog).count) DÃY PHIM")
                .font(JoePCType.outfit(14, weight: .medium))
                .tracking(3)
                .foregroundStyle(theme.heroMeta)
                .lineLimit(1)
        }
    }

    /// The TVB Continue Watching entries (v2.1.1,
    /// FIX-6): the SAME data JoePhimHome's TVB CW rail
    /// reads (its tvbProgress — the WatchStore kindYT
    /// progress rows, rail-capped).
    private var tvbCwEntries: [WatchStore.Entry] {
        Array(WatchStore.filterKinds(watch.progress(),
                                     [WatchStore.kindYT])
            .prefix(WatchStore.railCap))
    }

    /// Design rail 1 of the TVB home (v2.1.1, FIX-6):
    /// "Xem tiếp" FIRST, as PC landscape cards with
    /// progress (JoeCinemaTVBCwCard), shown only when
    /// TVB CW entries exist — empty, the catalogue
    /// rails start the page. Data is tvbCwEntries (the
    /// Phim home's TVB CW data); the tap is that rail's
    /// own JoeYtRoute reopen; the focus binding rides
    /// this view's cardFocus as "tvbcw|<key>" (the
    /// Phim home's own CW binding value), so the strip
    /// and the hero resolve it to this rail.
    @ViewBuilder
    private var pcTVBCwRail: some View {
        if !tvbCwEntries.isEmpty {
            pcRailShell(title: "Xem tiếp") {
                ForEach(tvbCwEntries) { entry in
                    Button {
                        nav.ytDetail = JoeYtRoute(pid: entry.slug)
                    } label: {
                        JoeCinemaTVBCwCard(
                            entry: entry,
                            series: ytStore.snapshot?.byPid[entry.slug])
                    }
                    .joeCardButton()
                    .focused($cardFocus, equals: "tvbcw|" + entry.key)
                    .contextMenu {
                        Button(role: .destructive) {
                            watch.removeProgress(key: entry.key)
                        } label: {
                            Text("Xoá khỏi Đang xem dở")
                        }
                    }
                }
            }
            .onAppear { ytStore.ensureLoaded() }
        }
    }

    /// The PC rail shell (WS-H): the shared Rail's
    /// construction mirrored at the design's rhythm —
    /// heading 27 pt medium, card gap 25, side margin 94
    /// total (shell 80 + 14 leading here).
    private func pcRailShell<Content: View>(
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
                    // FIX-4 / C5 + FIX-213 (Fault 14): track
                    // padding 16/11 + row padding 8/9, as
                    // on the Phim home — the design's
                    // measured poster row (395) is their
                    // sum; carrying only 8/9 compressed
                    // every rail by ~26.
                    .padding(.top, 24)
                    .padding(.bottom, 20)
            }
            .scrollClipDisabled()
            .padding(.horizontal, -80)
        }
        .focusSection()
    }

    /// FIX-4 / C3 (Gate R2 Lens C): the spec sheet's TVB
    /// lead rails, in the sheet's order — Đang được quan
    /// tâm (the pipeline's dangHot) → Mới trong thư viện
    /// (moiCapNhat) → Hình sự & điều tra (the crime /
    /// investigation GENRE shelf: genreOrder's
    /// "Hình Sự / Phá Án", appended by railSpecs as scope
    /// "shelf:Hình Sự / Phá Án" from catalog.shelves) →
    /// Xem lại một thời Hồng Kông (kinhDien). The sheet's
    /// first rail, Xem tiếp, has NO counterpart inside
    /// this view — TVB Continue Watching lives on the
    /// Phim home (WS-H mapping §4 flag) — so it is NOT
    /// fabricated here. The old leads deCu and
    /// moiPhatHanh are not lead rails under the sheet:
    /// they move DOWN into the appended group
    /// (pcAppendSections), nothing dropped.
    private var pcLeadScopes: [String] {
        ["dangHot", "moiCapNhat", "shelf:Hình Sự / Phá Án", "kinhDien"]
    }

    /// The lead rails' plain design headings (no emoji
    /// prefixes), by scope.
    private func pcLeadTitle(forScope scope: String) -> String? {
        switch scope {
        case "dangHot": return "TVB · Đang được quan tâm"
        case "moiCapNhat": return "TVB · Mới trong thư viện"
        case "shelf:Hình Sự / Phá Án": return "TVB · Hình sự & điều tra"
        case "kinhDien": return "TVB · Xem lại một thời Hồng Kông"
        default: return nil
        }
    }

    /// A rail's title as the PC arm displays it: the plain
    /// design heading for a lead rail, the railSpec's own
    /// title for every appended rail.
    private func pcDisplayTitle(_ railSpec: RailSpec) -> String {
        pcLeadTitle(forScope: railSpec.scope) ?? railSpec.title
    }

    /// The lead rails (FIX-4 / C3), in the sheet's order,
    /// with the PC local 205×263 card (JoeCinemaTVBCard,
    /// JoePhimHome.swift — same module) under their plain
    /// design headings. Tap and focus binding are the
    /// existing card()'s own.
    @ViewBuilder
    private func pcPipelineRails(_ catalog: TVBCatalog) -> some View {
        // FIX-5 / Lens A MINOR 1 (FL-017): ONE railSpecs
        // build per body pass, hoisted above the ForEach
        // (the same hoist FIX-4 applied in
        // pcVisibleRailTitles) — the pre-fix body rebuilt
        // the heavyweight railSpecs(catalog) once per lead
        // scope (4× per pass, on the focus path). The four
        // lookups below read this one build, in the same
        // pcLeadScopes order, so the rails produced are
        // identical.
        let specs = railSpecs(catalog)
        ForEach(pcLeadScopes, id: \.self) { scope in
            if let railSpec = specs.first(where: { $0.scope == scope }) {
                let movies = titles(for: railSpec.ids)
                if !movies.isEmpty {
                    pcRailShell(title: pcDisplayTitle(railSpec)) {
                        ForEach(movies) { title in
                            Button { open(title) } label: {
                                JoeCinemaTVBCard(title: title)
                            }
                            .joeCardButton()
                            .focused($cardFocus,
                                     equals: railSpec.scope + "|" + "\(title.tmdbId)")
                        }
                    }
                }
            }
        }
    }

    /// The appended shelves (WS-H mapping §4): every
    /// railSpecs entry EXCEPT the lead rails, in existing
    /// order and existing builders — the rich shelves and
    /// genre shelves, unchanged. FIX-4 / C3: deCu and
    /// moiPhatHanh now render HERE (moved down from the
    /// lead group), keeping their existing headings.
    @ViewBuilder
    private func pcAppendSections(_ catalog: TVBCatalog) -> some View {
        ForEach(railSpecs(catalog)) { railSpec in
            if !pcLeadScopes.contains(railSpec.scope) {
                // FIX-213 (Fault 7) + GATE-213 R5 Lens 2
                // F1: these appended shelves ride the
                // SHARED Rail, which since the R4 gate fix
                // carries the design's 94 frame itself
                // under Private Cinema — no wrapper inset
                // here (it double-inset the shelves to
                // 108).
                if !railSpec.actors.isEmpty {
                    Rail(title: railSpec.title) {
                        ForEach(railSpec.actors) { actor in
                            actorCard(actor,
                                      focusID: railSpec.scope + "|" + actor.name)
                        }
                    }
                } else {
                    let movies = titles(for: railSpec.ids)
                    if !movies.isEmpty {
                        Rail(title: railSpec.title) {
                            ForEach(movies) { title in
                                card(title, focusID: railSpec.scope + "|" + "\(title.tmdbId)",
                                     form: .rail)
                            }
                        }
                    }
                }
            }
        }
    }

    /// The PC context strip (WS-H): the pinned Section
    /// header — the focused title · its meta · its rail ·
    /// "Dãy NN/TT · ↑ để trở lại", derived from the
    /// existing cardFocus memory. (FIX-6: this view now
    /// HAS a hero and a CW rail — both derive from the
    /// same cardFocus memory and the same visible-rail
    /// list; the strip's rest state still names the
    /// section itself.)
    private func tvbContextStrip(_ catalog: TVBCatalog) -> some View {
        let info = tvbContextInfo(catalog)
        return HStack(alignment: .center, spacing: 14) {
            // FIX-8 / C-R4-2: the drawn composition
            // (delivery-joetv-TVBManyRails-browse.png) —
            // left column: the surface eyebrow in small
            // caps ABOVE the title, the meta riding the
            // title's baseline beside it.
            VStack(alignment: .leading, spacing: 4) {
                Text("TVB / ĐANG KHÁM PHÁ")
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

    /// The strip's content for the TVB home: resolve the
    /// focused card ("scope|tmdbId" for catalogue cards,
    /// "yt:<rail.scope>|pid" for YouTube cards) against
    /// the displayed titles / the YT snapshot.
    private func tvbContextInfo(_ catalog: TVBCatalog)
        -> (title: String, meta: String, railName: String, railLine: String) {
        let titles = pcVisibleRailTitles(catalog)
        let total = titles.count
        if let cardFocus {
            let parts = cardFocus.split(separator: "|", maxSplits: 1)
            let scope = parts.isEmpty ? "" : String(parts[0])
            let tail = parts.count > 1 ? String(parts[1]) : ""
            // FIX-6: the Continue Watching rail's cards
            // bind "tvbcw|<key>" — resolve to rail 1
            // ("Xem tiếp", counted in pcVisibleRailTitles
            // whenever the rail renders).
            if scope == "tvbcw",
               let entry = tvbCwEntries.first(
                   where: { "tvbcw|" + $0.key == cardFocus }) {
                let pos = titles.firstIndex(of: "Xem tiếp").map { $0 + 1 } ?? 1
                return (entry.title, entry.epLabel,
                        "Xem tiếp",
                        "Dãy \(String(format: "%02d", pos)) / \(total) · ↑ để trở lại")
            }
            // FIX-10a / Pass-2 Lens B F1: the YT focus
            // ID is rail-scoped ("yt:<rail.scope>|<pid>"),
            // so the rail is the one NAMED in the ID —
            // never the first rail containing the pid (a
            // series can live in two YT rails).
            if scope.hasPrefix("yt:"), let snapshot = ytStore.snapshot,
               let series = snapshot.byPid[tail] {
                let railScope = String(scope.dropFirst("yt:".count))
                let railName = snapshot.rails
                    .first(where: { $0.scope == railScope })?.title ?? ""
                let pos = titles.firstIndex(of: railName).map { $0 + 1 } ?? 1
                return (series.title, series.tierLabel,
                        railName,
                        "Dãy \(String(format: "%02d", pos)) / \(total) · ↑ để trở lại")
            }
            if let tmdbId = Int(tail),
               let title = byId[tmdbId] {
                let railName = railSpecs(catalog)
                    .first(where: { $0.scope == scope })
                    .map { pcDisplayTitle($0) } ?? ""
                let pos = titles.firstIndex(of: railName).map { $0 + 1 } ?? 1
                return (title.titleVi, title.cardMeta,
                        railName,
                        "Dãy \(String(format: "%02d", pos)) / \(total) · ↑ để trở lại")
            }
            // FIX-4 / B3: actor-rail cards bind
            // "scope|actor name" — the tail parses as
            // neither a pid nor a TMDB id, so the strip used
            // to sit at its rest state. Resolve to the
            // enclosing rail's real title + position, with
            // the actor's own name and title count.
            if let spec = railSpecs(catalog).first(where: { $0.scope == scope }),
               let actor = spec.actors.first(where: { $0.name == tail }) {
                let railName = pcDisplayTitle(spec)
                let pos = titles.firstIndex(of: railName).map { $0 + 1 } ?? 1
                return (actor.name, "\(actor.count) phim",
                        railName,
                        "Dãy \(String(format: "%02d", pos)) / \(total) · ↑ để trở lại")
            }
        }
        // FIX-10a / RECON-POWERMAX point 6: no card
        // focused — return the last resolved strip tuple
        // when one exists. Before any focus ever, memory
        // is nil and the rest tuple below is unchanged.
        if cardFocus == nil, let memory = tvbStripMemory {
            return memory
        }
        return ("Phim bộ TVB", "",
                "",
                "Dãy 01 / \(total) · ↑ để trở lại")
    }

    /// The visible PC rails' titles in render order (the
    /// strip's denominator): the lead rails that resolve
    /// (FIX-4 / C3 order + plain headings), the YT rails,
    /// then the appended shelves.
    private func pcVisibleRailTitles(_ catalog: TVBCatalog) -> [String] {
        var out: [String] = []
        // FIX-6: Continue Watching is rail 1 whenever it
        // renders (entries exist) — counted here so the
        // strip's positions and the hero tagline's count
        // derive from the ACTUAL rail list construction.
        if !tvbCwEntries.isEmpty { out.append("Xem tiếp") }
        // FIX-4 / C3: lead rails first, in the sheet's
        // order, under their plain design headings.
        let specs = railSpecs(catalog)
        for scope in pcLeadScopes {
            if let spec = specs.first(where: { $0.scope == scope }),
               !titles(for: spec.ids).isEmpty {
                out.append(pcDisplayTitle(spec))
            }
        }
        if let snapshot = ytStore.snapshot {
            for rail in snapshot.rails { out.append(rail.title) }
        }
        for railSpec in specs {
            if !pcLeadScopes.contains(railSpec.scope),
               !railSpec.actors.isEmpty || !titles(for: railSpec.ids).isEmpty {
                out.append(railSpec.title)
            }
        }
        return out
    }

    /// The header mirrors JoePhimHome's slim header: section
    /// title + subtitle on the left, ONE entry button on the
    /// right carrying the section's .defaultFocus declaration —
    /// here the entry into the tab's own search.
    /// FIX-213 (Fault 5, DIAG-20261122): under Private
    /// Cinema the header carries NO search button and NO
    /// .defaultFocus — the shell's floating bar centres
    /// its own "Tìm phim" pill in the same top band, and
    /// the two pills landed on top of each other (the
    /// owner's "Đè nhau"). Under PC the bar's pill is
    /// this page's single search entry (it raises
    /// nav.tvbSearchRequested, consumed in body above),
    /// and the section landing is the hero block's first
    /// focusable, as on the other PC homes. Every other
    /// theme keeps the button + landing below, byte-for-
    /// byte (their VStack shell cannot collide).
    @ViewBuilder
    private var header: some View {
        if theme.id == .privateCinema {
            headerRow
        } else {
            headerRow.defaultFocus($headerSearchFocused, true)
        }
    }

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 28) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Phim bộ TVB")
                    .font(.system(size: 44, weight: .heavy))
                    .foregroundStyle(theme.text)
                Text("Phim bộ Hồng Kông lồng tiếng — Tủ Phim · KKPhim · VSMOV")
                    .font(.system(size: 25))
                    .foregroundStyle(theme.meta)
            }
            Spacer()
            if theme.id != .privateCinema {
                Button {
                    if catalog != nil { searchOpen = true }
                } label: {
                    JoeSecondaryLabel(title: "Tìm trong TVB",
                                      systemImage: "magnifyingglass")
                }
                .joeCardButton()
                .focused($headerSearchFocused)
            }
        }
    }

    // MARK: - Rails home (plan §3 + §3.3)

    /// One entry of the actor rail (Idea 1): the actor's
    /// name, how many displayed titles carry them, and the
    /// poster of their most popular displayed title (the
    /// card's art — the rail's cards are actors, not titles,
    /// so they cannot ride the title-id machinery).
    private struct ActorRailEntry: Identifiable {
        let name: String
        let count: Int
        let posterURL: URL?
        let tmdbId: Int
        var id: String { name }
    }

    private struct RailSpec: Identifiable {
        let scope: String
        let title: String
        let ids: [Int]
        /// Non-empty ONLY on the actor rail: its entries are
        /// ActorRailEntry values, rendered by actorCard —
        /// every other rail leaves this empty and renders
        /// titles(for: ids) exactly as before.
        var actors: [ActorRailEntry] = []
        var id: String { scope }
    }

    /// claude/opt-2 (FL-447 R4): railSpecs(catalog) is a pure
    /// function of the catalogue, and `catalog` is assigned
    /// exactly once (loadCatalog's guard), yet the strip, the
    /// tagline, the rails and the focus handler each rebuilt
    /// it — decade grouping, four sorts and an actor index
    /// over every displayed title — about seven times per
    /// focus step. The first build is kept here and returned
    /// while the catalogue key still matches. A reference
    /// box, so filling it inside body is not a state write.
    private final class RailSpecsMemo {
        var key: String?
        var specs: [RailSpec] = []
    }
    @State private var railSpecsMemo = RailSpecsMemo()

    /// The five pipeline rails in build order, then the
    /// Idea 1 rich shelves (2.0.25: decade shelves, Trọn bộ,
    /// Hay nhất, Nhiều phần — computed below from the
    /// displayed titles), then the seven genre shelves in
    /// audit order. A rail renders only when it resolves to
    /// at least one displayed title.
    private func railSpecs(_ catalog: TVBCatalog) -> [RailSpec] {
        let key = "\(catalog.version)|\(catalog.generatedAt)|\(catalog.titles.count)"
        if railSpecsMemo.key == key { return railSpecsMemo.specs }
        let built = buildRailSpecs(catalog)
        railSpecsMemo.key = key
        railSpecsMemo.specs = built
        return built
    }

    /// The pre-opt-2 railSpecs body, verbatim.
    private func buildRailSpecs(_ catalog: TVBCatalog) -> [RailSpec] {
        var specs = [
            RailSpec(scope: "dangHot", title: "🔥 Đang hot",
                     ids: catalog.rails.dangHot),
            RailSpec(scope: "deCu", title: "⭐ Đề cử",
                     ids: catalog.rails.deCu),
            RailSpec(scope: "moiCapNhat", title: "✨ Mới cập nhật",
                     ids: catalog.rails.moiCapNhat),
            RailSpec(scope: "moiPhatHanh", title: "🆕 Mới phát hành",
                     ids: catalog.rails.moiPhatHanh),
            RailSpec(scope: "kinhDien", title: "🏛️ Kinh điển",
                     ids: catalog.rails.kinhDien),
        ]
        // Idea 1 (2.0.25) rich shelves, computed from the
        // displayed titles only.
        let displayedTitles = catalog.titles.filter { $0.isDisplayed }

        // 1. Decade shelves: one rail per decade holding at
        // least six displayed titles, decades in chronological
        // order, titles inside a rail by popularity desc.
        // Titles with no year belong to no decade rail.
        var decadeGroups: [Int: [TVBTitle]] = [:]
        for title in displayedTitles {
            guard let year = title.year else { continue }
            let decade = (year / 10) * 10
            decadeGroups[decade, default: []].append(title)
        }
        for decade in decadeGroups.keys.sorted() {
            guard let group = decadeGroups[decade], group.count >= 6
            else { continue }
            let ids = group
                .sorted { $0.popularity > $1.popularity }
                .map(\.tmdbId)
            let label: String
            switch decade {
            case 1980: label = "📺 Thập niên 80"
            case 1990: label = "📺 Thập niên 90"
            default: label = "📺 Thập niên \(decade)"
            }
            specs.append(RailSpec(scope: "decade:\(decade)",
                                  title: label, ids: ids))
        }

        // 2. Trọn bộ: ended series whose best provider
        // completeness is at least 0.95, popularity desc,
        // capped at 40.
        let tronBo = displayedTitles
            .filter { $0.status == "Ended" && $0.bestCompleteness >= 0.95 }
            .sorted { $0.popularity > $1.popularity }
        if !tronBo.isEmpty {
            specs.append(RailSpec(scope: "tronBo", title: "✅ Trọn bộ",
                                  ids: tronBo.prefix(40).map(\.tmdbId)))
        }

        // 3. Hay nhất: only titles with at least 5 votes are
        // ranked (most of the catalogue carries no votes, so
        // a raw average would be noise), by the weighted
        // score, tie-broken by vote count then popularity,
        // capped at 30.
        let hayNhat = displayedTitles
            .filter { $0.voteCount >= 5 }
            .sorted {
                if $0.weightedVoteScore != $1.weightedVoteScore {
                    return $0.weightedVoteScore > $1.weightedVoteScore
                }
                if $0.voteCount != $1.voteCount {
                    return $0.voteCount > $1.voteCount
                }
                return $0.popularity > $1.popularity
            }
        if !hayNhat.isEmpty {
            specs.append(RailSpec(scope: "hayNhat", title: "🏆 Hay nhất",
                                  ids: hayNhat.prefix(30).map(\.tmdbId)))
        }

        // 4. Nhiều phần: multi-season titles, popularity
        // desc, capped at 30.
        let nhieuPhan = displayedTitles
            .filter { $0.seasons.count > 1 }
            .sorted { $0.popularity > $1.popularity }
        if !nhieuPhan.isEmpty {
            specs.append(RailSpec(scope: "nhieuPhan", title: "🎞️ Nhiều phần",
                                  ids: nhieuPhan.prefix(30).map(\.tmdbId)))
        }

        // 5. Diễn viên (Idea 1, actor rail): aggregate the
        // displayed titles by cast name; an actor earns a
        // card at ≥ 6 displayed titles. Order: title count
        // desc, then name; capped at 20. The card's art is
        // the actor's most popular displayed title's poster
        // and its tap presents JoeActorPage (.tvb mode) —
        // the entries ride RailSpec.actors, never a faked
        // title id.
        var titlesByActor: [String: [TVBTitle]] = [:]
        for title in displayedTitles {
            for name in title.cast where !name.isEmpty {
                titlesByActor[name, default: []].append(title)
            }
        }
        let actorEntries = titlesByActor
            .filter { $0.value.count >= 6 }
            .map { name, titles -> ActorRailEntry in
                let top = titles.max { $0.popularity < $1.popularity }
                return ActorRailEntry(
                    name: name, count: titles.count,
                    posterURL: top?.posterURL,
                    tmdbId: top?.tmdbId ?? 0)
            }
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.name < $1.name
            }
        if !actorEntries.isEmpty {
            specs.append(RailSpec(scope: "dienVien", title: "🎭 Diễn viên",
                                  ids: [],
                                  actors: Array(actorEntries.prefix(20))))
        }

        for name in Self.genreOrder {
            if let ids = catalog.shelves[name] {
                specs.append(RailSpec(scope: "shelf:" + name, title: name,
                                      ids: ids))
            }
        }
        return specs
    }

    @ViewBuilder
    private func railSections(_ catalog: TVBCatalog) -> some View {
        ForEach(railSpecs(catalog)) { spec in
            if !spec.actors.isEmpty {
                Rail(title: spec.title) {
                    ForEach(spec.actors) { actor in
                        actorCard(actor,
                                  focusID: spec.scope + "|" + actor.name)
                    }
                }
            } else {
                let movies = titles(for: spec.ids)
                if !movies.isEmpty {
                    Rail(title: spec.title) {
                        ForEach(movies) { title in
                            card(title, focusID: spec.scope + "|" + "\(title.tmdbId)",
                                 form: .rail)
                        }
                    }
                }
            }
        }
    }

    /// The YouTube rails (design §1.2): the snapshot's rail
    /// order — Gold, Super VIP, Silver, the main channel's
    /// free rail, then the sister channels — each card
    /// opening the YouTube detail. The snapshot builds these
    /// ONCE per load (JoeYtSnapshot.build), so this body path
    /// only reads finished rails; no regrouping runs here.
    @ViewBuilder
    private func ytRailSections(_ snapshot: JoeYtSnapshot) -> some View {
        ForEach(snapshot.rails) { rail in
            Rail(title: rail.title) {
                ForEach(rail.series) { series in
                    ytCard(series, railScope: rail.scope)
                }
            }
        }
    }

    private func ytCard(_ series: JoeYtSeries,
                        railScope: String) -> some View {
        // FIX-10a / Pass-2 Lens B F1: the focus ID
        // carries the RAIL's scope ("yt:<rail.scope>|<pid>",
        // mirroring the catalogue branches' scoped IDs),
        // so the strip + hero resolve the rail the card
        // was actually focused in.
        JoeYtPosterCard(series: series, form: .rail,
                        focusID: "yt:" + railScope + "|" + series.pid,
                        focus: $cardFocus) {
            openYouTube(series)
        }
    }

    /// One actor-rail card (Idea 1): the actor's most
    /// popular title's poster carrying the actor's NAME as
    /// its label (the PosterCard construction every other
    /// rail uses), the title count as its meta line. The
    /// tap presents the actor page in .tvb mode — the
    /// filmography is resolved there from the snapshot.
    private func actorCard(_ actor: ActorRailEntry, focusID: String) -> some View {
        Button { actorRoute = .tvb(name: actor.name) } label: {
            PosterCard(
                title: actor.name,
                posterURL: actor.posterURL,
                tmdbId: actor.tmdbId > 0 ? "\(actor.tmdbId)" : "",
                tmdbType: "tv",
                meta: "\(actor.count) phim",
                form: .rail)
        }
        .joeCardButton()
        .focused($cardFocus, equals: focusID)
    }

    // MARK: - Cards + detail routing

    private func card(_ title: TVBTitle, focusID: String,
                      form: PosterCard.Form) -> some View {
        Button { open(title) } label: {
            PosterCard(
                title: title.titleVi,
                posterURL: title.posterURL,
                tmdbId: "\(title.tmdbId)",
                tmdbType: "tv",
                meta: title.cardMeta,
                badge: title.routeTarget.map { Providers.badge($0.provider) },
                form: form)
        }
        .joeCardButton()
        .focused($cardFocus, equals: focusID)
    }

    /// A tap mints the SAME MovieRoute every other rail mints:
    /// the detail loads Providers.detail(provider, slug) from
    /// it, resolves the series' TMDB identity from the provider
    /// detail payload, and finds the other holders through its
    /// existing alternatives search (Providers.findAlternatives,
    /// name + year over the other providers) — the detail's
    /// source chips cover switching, exactly as for any title.
    /// FIX4 (fix 8): the chain for these titles now closes on
    /// Film4K (owner-approved 2026-11-18: Tủ Phim → KKPhim →
    /// VSMOV → Film4K) — the detail's alternatives search
    /// carries the title's TMDB id into the Film4K leg, which
    /// accepts on id where its name test fails (Providers
    /// .searchSlug; TpClient now parses the id its payload
    /// carries). Titles carried ONLY by Film4K DO appear in
    /// this tab since the v2.0.39 rebuilt snapshot: the 13
    /// f4k-primary titles are sole holders in the snapshot,
    /// satisfy `isDisplayed`, and route through the explicit
    /// "f4k" case in `appProviderCode` above.
    private func open(_ title: TVBTitle) {
        // TVB YouTube feature (design §1.6, final paragraph,
        // + the owner's shared-grid ruling 2026-11-19): a
        // matched title opens THIS SAME chain detail — the
        // detail itself gains the YouTube source row and the
        // one shared episode grid, Auto preferring YouTube
        // per-episode. Routing matched titles to a parallel
        // YouTube-only detail was tried and ruled against
        // (it strands the chain's episodes). The mint below
        // is byte-identical to the pre-feature route.
        guard let target = title.routeTarget else { return }
        nav.movie = MovieRoute(
            provider: target.provider, slug: target.slug,
            name: title.titleVi, poster: title.posterURLString,
            year: title.yearString,
            tvb: title.routeContext)
    }

    /// A YouTube rail card: a MATCHED series opens the
    /// unified chain detail (minted from its matched title,
    /// exactly as the tab mints it — the shared grid lives
    /// there); a YouTube-only series opens the YouTube
    /// detail (JoeYtDetail).
    private func openYouTube(_ series: JoeYtSeries) {
        if let title = ytStore.snapshot?.matchedTitleByPid[series.pid],
           let target = title.routeTarget {
            nav.movie = MovieRoute(
                provider: target.provider, slug: target.slug,
                name: title.titleVi, poster: title.posterURLString,
                year: title.yearString, tvb: title.routeContext)
        } else {
            nav.ytDetail = JoeYtRoute(pid: series.pid)
        }
    }
}

// MARK: - YouTube series poster card (2.0.47)
//
// One YouTube/TVB series card for the rails and the in-tab
// search grid. The card owns the series' poster resolution
// (JoeYtPosterResolver: TMDB by tmdbId → chain-catalogue
// poster by normalised title → episode-1 thumbnail): until
// the resolution lands the PosterCard paints its placeholder
// (never the landscape thumbnail first — that letterboxed
// flash is the fault this feature removes); a resolved real
// poster gates the slot on .portrait and a resolved
// thumbnail keeps the .any slot it has always had, so the
// final fallback renders exactly as before. tmdbId is
// passed EMPTY on purpose: the resolver already ran the
// TMDB leg (through the pipeline's cached posterPath
// lookup), and PosterCard's own TMDB fallback would only
// re-run the same leg behind a failed portrait load.
private struct JoeYtPosterCard: View {
    let series: JoeYtSeries
    let form: PosterCard.Form
    let focusID: String
    var focus: FocusState<String?>.Binding
    let onTap: () -> Void

    @State private var resolved: JoeYtResolvedPoster?

    var body: some View {
        Button {
            onTap()
        } label: {
            PosterCard(
                title: series.title,
                posterURL: resolved?.url,
                tmdbId: "",
                tmdbType: "tv",
                meta: "\(series.eps.count) tập · \(series.tierLabel)",
                badge: series.isMembersTier ? "YouTube" : nil,
                // 2.0.48 (Approach C): the honest quality
                // badge — the measured ceiling from
                // JoeYtQualityMap, or NO badge at all when
                // this install has never measured the
                // series (never an assumed figure).
                quality: JoeYtQualityMap.badgeText(pid: series.pid) ?? "",
                form: form,
                artSlotClass: (resolved?.isPortraitPoster ?? true)
                    ? .portrait : .any,
                // v2.0.49: fill ONLY when the resolver's
                // thumbnail leg won (a landscape still in a
                // 2:3 frame letterboxed — VERDICT §4); while
                // unresolved or on a real poster, exactly the
                // pre-2.0.49 fit behaviour. (Argument order
                // follows the declaration — memberwise init.)
                artFill: (resolved != nil && !(resolved!.isPortraitPoster)))
        }
        .joeCardButton()
        .focused(focus, equals: focusID)
        .task(id: series.pid) {
            resolved = await JoeYtPosterResolver.resolve(series)
        }
    }
}

/// v2.1.1 (FIX-6): the PC TVB Continue Watching card
/// for the TVB home's own "Xem tiếp" rail — the
/// JoeCinemaCwCard landscape construction (320×180 art,
/// the ĐANG XEM state badge, the celadon progress bar
/// on the art's bottom edge, title + episode line +
/// remaining line below) with its art resolved through
/// JoeYtPosterResolver exactly like JoeYtCwPosterCard
/// below (TMDB by tmdbId → chain poster by normalised
/// title → episode thumbnail in the .any slot; a series
/// the catalogue no longer carries resolves from the
/// ROW's own keys). JoeCinemaCwCard itself cannot serve
/// here: it paints entry.posterURL directly, and a
/// kindYT row's stored poster is empty by construction
/// (the FL-374 mechanism).
struct JoeCinemaTVBCwCard: View {
    let entry: WatchStore.Entry
    let series: JoeYtSeries?
    @Environment(\.joeTheme) private var theme
    @Environment(\.isFocused) private var isFocused
    @State private var resolved: JoeYtResolvedPoster?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Color.black.opacity(0.35)
                if let url = resolved?.url {
                    JoeRemoteImage(url: url, targetPixels: 480,
                                   fit: false, slotClass: .any) {
                        Image(systemName: "film")
                            .font(.system(size: 64))
                            .foregroundStyle(theme.meta.opacity(0.55))
                    }
                } else {
                    Image(systemName: "film")
                        .font(.system(size: 64))
                        .foregroundStyle(theme.meta.opacity(0.55))
                }
            }
            .frame(width: 320, height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            // Fault 11 fix round: the design's tile focus —
            // ivory OUTSET outline (3 px, offset 5 px, 7 px
            // button radius) + 1.045 scale, replacing the
            // legacy inside ring; rest opacity at the root.
            .overlay(JoeOutsetRing(
                shape: RoundedRectangle(cornerRadius: 7),
                color: JoeCinemaFocus.ivory,
                lineWidth: 3, offset: 5))
            .scaleEffect(isFocused ? 1.045 : 1)
            .animation(JoeCinemaFocus.tileCurve, value: isFocused)
            .overlay(alignment: .topLeading) {
                Text(cwStateBadge)
                    .font(JoePCType.outfit(11))
                    .foregroundStyle(theme.badgeText)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 3)
                        .fill(Color(red: 0.047, green: 0.070,
                                    blue: 0.082).opacity(0.91)))
                    .padding(.leading, 10)
                    .padding(.top, 11)
            }
            .overlay(alignment: .bottom) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color(red: 0.047, green: 0.070,
                                               blue: 0.082).opacity(0.79))
                        Rectangle().fill(Color(red: 0.847, green: 0.902,
                                               blue: 0.733))
                            .frame(width: geo.size.width
                                   * CGFloat(min(max(entry.fraction, 0), 1)))
                    }
                }
                .frame(height: 5)
            }
            Text(entry.title)
                .font(JoePCType.outfit(theme.cardTitleSize))
                .foregroundStyle(isFocused ? theme.focusTitle : theme.text)
                .lineLimit(1)
                .padding(.top, 10)
            if !entry.epLabel.isEmpty {
                Text(entry.epLabel)
                    .font(JoePCType.outfit(theme.cardMetaSize))
                    .foregroundStyle(theme.meta)
                    .lineLimit(1)
                    .padding(.top, 3)
            }
            Text("Còn \(WatchStore.fmtClock(entry.dur - entry.pos))")
                .font(JoePCType.outfit(theme.cardMetaSize))
                .foregroundStyle(theme.meta)
                .lineLimit(1)
                .padding(.top, 3)
        }
        .frame(width: 320, alignment: .leading)
        .joeCinemaCardFocus()
        // Keyed on the entry AND the series' arrival
        // (JoeYtCwPosterCard's rule: the catalogue
        // snapshot can land after the rail first paints).
        .task(id: entry.key + "|" + (series?.pid ?? "")) {
            resolved = await Self.resolve(entry: entry,
                                          series: series)
        }
    }

    /// The CW state badge's text (JoeCinemaCwCard's
    /// rule): "ĐANG XEM", plus " · TẬP <n>" only when
    /// the entry itself carries an episode number.
    private var cwStateBadge: String {
        let ep = WatchStore.episodeNumber(of: entry)
        return ep > 0 ? "ĐANG XEM · TẬP \(ep)" : "ĐANG XEM"
    }

    /// JoeYtCwPosterCard.resolve verbatim: the series'
    /// resolver chain when the series is known; the
    /// row's own stored keys (TMDB by tmdbId, then the
    /// stored poster) when it is not.
    private static func resolve(
        entry: WatchStore.Entry, series: JoeYtSeries?
    ) async -> JoeYtResolvedPoster {
        if let series {
            return await JoeYtPosterResolver.resolve(series)
        }
        if !entry.tmdbId.isEmpty,
           let url = await JoeImagePipeline.shared.tmdbPosterURL(
               tmdbId: entry.tmdbId, type: "tv") {
            return JoeYtResolvedPoster(url: url, source: .tmdb)
        }
        return JoeYtResolvedPoster(url: entry.posterURL,
                                   source: .youtubeThumbnail)
    }
}

/// FL-374 (2.0.48): the TVB Continue Watching card —
/// JoeYtPosterCard's construction carried onto the CW
/// rails of BOTH homes (JoePhimHome.tvbCwRail and
/// JoeBrowse.tvbCwWallRail, which now share this one
/// view, so the two surfaces can never drift apart
/// again).
///
/// The fault it fixes, convicted from code: both rails
/// built their PosterCard SYNCHRONOUSLY from
/// `series.posterURL` — the raw episode-1 YouTube
/// thumbnail (480×360, 4:3) — and passed NEITHER
/// `artSlotClass: .any` NOR a tmdbId. PosterCard's art
/// slot defaults to the .portrait gate, which rejects a
/// 4:3 bitmap by construction (the FL-343 mechanism),
/// and with no TMDB identity at the call site the
/// fallback ladder behind the gate was empty — so every
/// CW card was the bare placeholder BY CONSTRUCTION,
/// even though the history row itself was healthy (it
/// stores slug = pid and the series' tmdbId). This card
/// instead resolves through the shared JoeYtPoster
/// Resolver exactly like every other TVB surface
/// (TMDB by tmdbId → chain poster by normalised title
/// → episode thumbnail in the .any slot). A series the
/// catalogue no longer carries still resolves from the
/// ROW's own keys: the stored tmdbId runs the TMDB leg,
/// and the row's stored poster (empty for YouTube rows)
/// is the last resort before the honest placeholder.
struct JoeYtCwPosterCard: View {
    let entry: WatchStore.Entry
    let series: JoeYtSeries?
    let focusID: String
    var focus: FocusState<String?>.Binding
    let onTap: () -> Void
    let onRemove: () -> Void

    @State private var resolved: JoeYtResolvedPoster?

    var body: some View {
        Button {
            onTap()
        } label: {
            PosterCard(
                title: entry.title,
                posterURL: resolved?.url,
                // The resolver already ran the TMDB leg;
                // PosterCard's own fallback would only
                // re-run it (JoeYtPosterCard's rule).
                tmdbId: "",
                tmdbType: "tv",
                meta: entry.epLabel,
                progress: entry.fraction,
                subline: "Còn \(WatchStore.fmtClock(entry.dur - entry.pos))",
                form: .rail,
                artSlotClass: (resolved?.isPortraitPoster ?? true)
                    ? .portrait : .any)
        }
        .joeCardButton()
        .focused(focus, equals: focusID)
        .contextMenu {
            Button(role: .destructive) {
                onRemove()
            } label: {
                Text("Xoá khỏi Đang xem dở")
            }
        }
        // Keyed on the entry AND the series' arrival:
        // the catalogue snapshot can land after the rail
        // first paints, and the card must re-resolve
        // through the full chain once it does.
        .task(id: entry.key + "|" + (series?.pid ?? "")) {
            resolved = await Self.resolve(entry: entry,
                                          series: series)
        }
    }

    private static func resolve(
        entry: WatchStore.Entry, series: JoeYtSeries?
    ) async -> JoeYtResolvedPoster {
        if let series {
            return await JoeYtPosterResolver.resolve(series)
        }
        // The series is gone from the catalogue (or the
        // snapshot has not landed): the row's own stored
        // keys still resolve — TMDB by the stored tmdbId
        // first, then the row's stored poster.
        if !entry.tmdbId.isEmpty,
           let url = await JoeImagePipeline.shared.tmdbPosterURL(
               tmdbId: entry.tmdbId, type: "tv") {
            return JoeYtResolvedPoster(url: url, source: .tmdb)
        }
        return JoeYtResolvedPoster(url: entry.posterURL,
                                   source: .youtubeThumbnail)
    }
}

// MARK: - In-tab search (plan §3.1)
//
// The tab's OWN search over the snapshot's displayed titles
// only — it never calls the providers and never touches the
// global catalogue, and it works fully offline from the file
// the tab already holds. The field row is JoeSearchView's
// construction verbatim in shape; v2.0.17: its top area is
// the same letter strip + query display as JoeSearchView's
// (the system field is gone in both), and ranking mirrors
// the existing search's tiers over Providers.normalizeTitle:
// exact normalized match first, then prefix, then contains
// (JoeSearch.renderPool's exact-tier promotion, extended with
// the plan §3.1 prefix tier). A search with no hits says so
// plainly — JoeSearchView's own empty line — and never falls
// through to the global search.
struct JoeTVBSearchView: View {
    let titles: [TVBTitle]
    let onClose: () -> Void
    @EnvironmentObject private var nav: JoeNavigator
    @Environment(\.joeTheme) private var theme
    @State private var query = ""
    @State private var results: [TVBTitle] = []
    /// YouTube hits for the same query (design §1.3: TVB
    /// search covers the FULL YouTube catalogue, railed or
    /// not — the Sony red team's X-1 lesson).
    @State private var ytResults: [JoeYtSeries] = []
    @State private var searched = false
    @FocusState private var cardFocus: String?
    @ObservedObject private var ytStore = JoeYtStore.shared

    /// The top area's focus landing (v2.0.17): the shared
    /// letter strip's keys + Quay lại — JoeSearchKeyFocus.
    @FocusState private var keyFocus: JoeSearchKeyFocus?

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            if theme.id == .posterWall {
                fieldRow
            } else {
                HStack(spacing: 0) {
                    Spacer()
                    fieldRow
                    Spacer()
                }
            }
            // v2.0.17: the shared letter strip — typing here
            // searches the snapshot live, like the Phim
            // search (this one is instant: it is all local).
            JoeLetterStrip(query: $query, focus: $keyFocus)
            if searched && results.isEmpty && ytResults.isEmpty {
                Text("Không tìm thấy phim nào.")
                    .font(theme.id == .privateCinema ? JoePCType.outfit(29) : .system(size: 29))
                    .foregroundStyle(theme.meta)
            }
            resultsArea
                .focusSection()
        }
        // v2.0.17: strip edits search live (no debounce —
        // the snapshot is on-device; runSearch is sync).
        .onChange(of: query) { _, _ in liveSearch() }
        // Menu closes the search layer: the handler is
        // unconditional and lives on the layer itself (the
        // JoeSearchView placement), so it exists exactly while
        // the layer does.
        .onExitCommand { onClose() }
        // The strip's first key is the layer's declared
        // initial focus (v2.0.17, the JoeSearchView
        // construction — the system field is gone there too).
        .defaultFocus($keyFocus, .key("a"))
    }

    private var fieldRow: some View {
        HStack(spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 26, weight: .semibold))
                Text(query.isEmpty ? "Tên phim, diễn viên…" : query)
                    .font(theme.id == .privateCinema
                          ? JoePCType.outfit(29,
                                             weight: .light)
                          : .system(size: ThemeTokens.fieldTextSize))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .joeFieldChrome(focused: false)
            .frame(maxWidth: theme.id == .posterWall ? .infinity : 700)
            Button {
                onClose()
            } label: {
                JoeSecondaryLabel(title: "⟵ Quay lại")
            }
            .joeCardButton()
            .focused($keyFocus, equals: .back)
        }
        .focusSection()
    }

    private var resultsArea: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 36) {
                resultsGrid
                if !ytResults.isEmpty {
                    Text("YouTube — TVB")
                        .font(theme.id == .privateCinema
                              ? JoePCType.outfit(31, weight: .bold)
                              : .system(size: 31, weight: .bold))
                        .foregroundStyle(theme.text)
                        .padding(.horizontal, theme.id == .posterWall ? 8 : 4)
                    ytResultsGrid
                }
            }
            // claude/opt-2 (owner: focus frames cut at the
            // edge): inset 16 + scroll widened 16, horizontally
            // only, so the outermost card's ring + scale fit
            // inside the clip (net geometry 0; the v2.0.16
            // vertical clip rule below stands).
            .padding(.horizontal, 16)
        }
        .padding(.horizontal, -16)
        // v2.0.16: CLIPS at its frame, like the JoeSearch
        // grid it was templated from — this copy kept the
        // .scrollClipDisabled() the search fix removed, so
        // results scrolling up painted over the query row
        // pinned above (the owner's 2026-11-17 sweep found
        // it). The grid's own clearances (vertical 8,
        // horizontal 8 under D — past the 6 pt outset ring)
        // are unchanged, so a focused card's ring keeps its
        // room inside the frame.
    }

    private var resultsGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: theme.railGap),
                                 count: 6),
                  alignment: .leading, spacing: 40) {
            ForEach(results) { title in
                Button { open(title) } label: {
                    PosterCard(
                        title: title.titleVi,
                        posterURL: title.posterURL,
                        tmdbId: "\(title.tmdbId)",
                        tmdbType: "tv",
                        meta: title.cardMeta,
                        badge: title.routeTarget.map { Providers.badge($0.provider) })
                }
                .joeCardButton()
                .focused($cardFocus, equals: "tvbsearch|" + "\(title.tmdbId)")
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, theme.id == .posterWall ? 8 : 4)
    }

    private var ytResultsGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: theme.railGap),
                                 count: 6),
                  alignment: .leading, spacing: 40) {
            ForEach(ytResults) { series in
                JoeYtPosterCard(series: series, form: .wall,
                                focusID: "ytsearch|" + series.pid,
                                focus: $cardFocus) {
                    openYouTube(series)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, theme.id == .posterWall ? 8 : 4)
    }

    /// v2.0.17: the strip's per-edit search — an emptied
    /// query clears back to the un-searched state instead of
    /// leaving the last round's results standing.
    private func liveSearch() {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            results = []
            ytResults = []
            searched = false
        } else {
            runSearch()
        }
    }

    private func runSearch() {
        let kw = query.trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty else { return }
        results = Self.ranked(query: kw, titles: titles)
        // The YouTube half searches the snapshot's FULL
        // catalogue (design §1.3); with no snapshot loaded
        // it simply contributes nothing.
        ytResults = ytStore.snapshot.map {
            JoeYtSearch.ranked(query: kw, series: $0.series)
        } ?? []
        searched = true
    }

    private func open(_ title: TVBTitle) {
        // The chain detail always (see the tab's open()):
        // YouTube primacy for matched titles lives inside
        // the detail's source row + shared grid.
        guard let target = title.routeTarget else { return }
        nav.movie = MovieRoute(
            provider: target.provider, slug: target.slug,
            name: title.titleVi, poster: title.posterURLString,
            year: title.yearString,
            tvb: title.routeContext)
    }

    /// A YouTube search hit: matched → the unified chain
    /// detail; YouTube-only → the YouTube detail (the same
    /// rule as the tab's rail cards).
    private func openYouTube(_ series: JoeYtSeries) {
        if let title = ytStore.snapshot?.matchedTitleByPid[series.pid],
           let target = title.routeTarget {
            nav.movie = MovieRoute(
                provider: target.provider, slug: target.slug,
                name: title.titleVi, poster: title.posterURLString,
                year: title.yearString, tvb: title.routeContext)
        } else {
            nav.ytDetail = JoeYtRoute(pid: series.pid)
        }
    }

    /// Tier ranking over the normalized keys (plan §3.1): a
    /// title takes its BEST tier across all its keys — any key
    /// equal to the query, else any key starting with it, else
    /// any key containing it. Catalogue order is preserved
    /// inside each tier (the shipped snapshot's order).
    static func ranked(query: String, titles: [TVBTitle]) -> [TVBTitle] {
        let q = Providers.normalizeTitle(query)
        guard !q.isEmpty else { return [] }
        var exact: [TVBTitle] = []
        var prefix: [TVBTitle] = []
        var contains: [TVBTitle] = []
        for title in titles {
            let keys = title.normalizedKeys
            if keys.contains(q) {
                exact.append(title)
            } else if keys.contains(where: { $0.hasPrefix(q) }) {
                prefix.append(title)
            } else if keys.contains(where: { $0.contains(q) }) {
                contains.append(title)
            }
        }
        return exact + prefix + contains
    }
}
