import SwiftUI

/// Merged search across KKPhim + Film4K + VSMOV + Tủ Phim: all
/// providers answer, results are listed together with provider
/// badges (the Android behaviour — a film carried by several
/// shows once per source, so the owner picks the source himself).
struct JoeSearchView: View {
    @EnvironmentObject private var nav: JoeNavigator
    @EnvironmentObject private var phim: PhimStore
    @Environment(\.joeTheme) private var theme
    @State private var query = ""
    /// The term the on-screen results belong to (UI-6 defect
    /// D-19: D's results heading names it — the live field
    /// text can already have been edited past it).
    @State private var searchedQuery = ""
    @State private var results: [Movie] = []
    @State private var searching = false
    @State private var searched = false
    @State private var searchFailed = false
    // v2.0.1 search-round state (Android FIX2/FIX3 parity):
    // the two render pools, the round generation (a new press
    // supersedes any in-flight round), and the settle
    // bookkeeping. `searching` is the VISIBLE settle (soft
    // deadline); `roundActive` runs to the hard settle.
    @State private var localPool: [Movie] = []
    @State private var serverPool: [Movie] = []
    @State private var roundID = 0
    @State private var roundActive = false
    @State private var branchesDone = 0
    @State private var branchesOK = 0
    @State private var branchesFailed = 0
    @State private var firstPaintLogged = false
    @State private var pressStart = Date()
    // v2.0.13 (Netflix-style search — owner order
    // 2026-11-16, "Bỏ luôn cái lọc phim ra tùm lum thể
    // loại đi"): the facet bar is GONE from this screen —
    // no JoeFilterBar, no JoeBrowseFilter state here any
    // more (both types stay in JoeBrowse.swift for the
    // browse layer, untouched). The field drives the
    // search directly: every edit re-arms a ~300 ms
    // debounce (scheduleTypeAhead below); when it fires,
    // the round for the current text runs — local hits
    // paint first, provider branches merge behind them,
    // never wiping the screen. v2.0.17: the edits now come
    // from the on-screen letter strip (JoeLetterStrip,
    // below) — the system TextField and its full-screen
    // keyboard are gone, so the grid the rounds paint stays
    // visible while typing (the owner's Netflix comparison,
    // 2026-11-17). The debounce and the rounds are unchanged.
    @State private var typeAheadTask: Task<Void, Never>?
    @FocusState private var focusedMovie: Movie.ID?
    @FocusState private var retryFocused: Bool
    // v2.0.45 (leg 3): the user addon's search group —
    // its own state beside the round's pools (the addon
    // branch rides the round generation but stays out of
    // the branch bookkeeping and the snapshot rule).
    @ObservedObject private var addonStore = JoeAddonStore.shared
    /// v2.0.45 (leg 3): the TVB catalogue store — read
    /// for the addon search branch's match snapshot.
    @ObservedObject private var ytStore = JoeYtStore.shared
    @State private var addonResults: [TorMeta] = []
    @State private var addonGroupName = ""
    @FocusState private var focusedAddon: String?
    // v2.1.1 (WS-E): the Private Cinema discovery landing's
    // items — the trending FILE's titles, flattened in file
    // order (JoeTrendingFile already deduped across rails).
    // Loaded once per appearance of the search layer, PC
    // theme only, fail-open (an empty load simply leaves
    // the landing without its grid).
    @State private var discoveryItems: [TorMeta] = []
    @FocusState private var focusedDiscovery: String?

    /// The top area's focus landing (v2.0.17): a letter-strip
    /// key or the Quay lại button — see JoeSearchKeyFocus.
    /// The TextField that used to own this landing is gone.
    @FocusState private var keyFocus: JoeSearchKeyFocus?
    /// v2.0.49 (item 7, fix round): bumped by the layer's
    /// Menu handler to make the results ScrollViewReader
    /// jump to the top of the page (owner order
    /// 2026-11-21).
    @State private var topScrollSignal = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            // v2.0.0 (UI-5): the field is light by design in
            // every theme (UI-1 law — the 1.9.2 white-on-dark
            // slab was the defect construction). A/F centre the
            // field row (maxW 1150, the render anatomy); D runs
            // it full width at the top of the wall.
            // v2.1.1 (WS-E): under .privateCinema the top of
            // the surface is the design's composition — the
            // serif headline + the ONE wide field (see
            // pcHeadline / pcFieldRow below). The letter
            // strip under it and every round behind it are
            // unchanged: the design dresses the surface, it
            // does not cut the function.
            if theme.id == .privateCinema {
                pcHeadline
                pcFieldRow
            } else if theme.id == .posterWall {
                fieldRow
            } else {
                HStack(spacing: 0) {
                    Spacer()
                    fieldRow
                    Spacer()
                }
            }
            // v2.0.17: the letter strip — typing lives here
            // now, under the query display, always visible.
            JoeLetterStrip(query: $query, focus: $keyFocus)
            // v2.0.13: NO filter bar on this screen — the
            // Phase 6 facet rows that sat here are removed
            // whole (owner order above). The field row above
            // and the results below keep their frame, order
            // and look; the bar's slot is simply empty, so
            // focus travel is field row ↔ results, section
            // to section geometrically, as it was around the
            // bar. No handlers anywhere (Phase 1 stands).
            // CONVERGENCE (Team 7 D4, 2026-11-15): the
            // JoeSearchMoveTrap that wrapped this row (enabled:
            // topFocus != nil) is REMOVED — its flips rebuilt
            // the row subtree under the focus engine. The row's
            // routing is geometric now: LEFT/RIGHT walk the
            // three elements in visual order (the engine skips
            // the Tìm button while it is disabled — the skip
            // the old arithmetic walk hand-coded), UP reaches
            // the pills, DOWN reaches the first result / Retry.
            // §8: searching, failure and no-results are three
            // DIFFERENT surfaces. v1.8 merged the last two into
            // one line, so a dead network read as "no such film".
            // v2.0.1: while a round is active with an empty
            // grid the surface stays "Đang tìm…" even past the
            // soft deadline (nothing found YET is not a
            // no-match); with results on screen the spinner
            // rides above them until the visible settle.
            if roundActive && results.isEmpty && !searchFailed {
                ProgressView("Đang tìm…")
                    .font(theme.id == .privateCinema ? JoePCType.outfit(29)
                               : .system(size: 29))
                    .foregroundStyle(theme.text)
                    .tint(theme.text)
            } else if searchFailed && results.isEmpty {
                VStack(alignment: .leading, spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 44))
                        .foregroundStyle(.orange)
                    Text("Không tải được kết quả tìm kiếm.")
                        .font(theme.id == .privateCinema
                              ? JoePCType.outfit(29, weight: .semibold)
                              : .system(size: 29, weight: .semibold))
                        .foregroundStyle(theme.text)
                    Text("Các nguồn phim đều lỗi. Kiểm tra mạng rồi thử lại.")
                        .font(theme.id == .privateCinema ? JoePCType.outfit(25)
                                   : .system(size: 25))
                        .foregroundStyle(theme.meta)
                    Button { runSearch() } label: {
                        JoePrimaryLabel(title: "Thử lại")
                    }
                    .joeCardButton()
                    .focused($retryFocused)
                    // (Its UP-to-strip routing is geometric:
                    // the letter strip is the nearest focusable above.
                    // The conditional trap that used to force
                    // it is removed — see the note at the top
                    // row.)
                }
            } else if searched && results.isEmpty {
                Text("Không tìm thấy phim nào.")
                    .font(theme.id == .privateCinema ? JoePCType.outfit(29)
                               : .system(size: 29))
                    .foregroundStyle(theme.meta)
            } else if searching {
                // Results are already on screen; branches are
                // still merging (the visible settle — soft
                // deadline or last branch — ends this line).
                ProgressView("Đang tìm…")
                    .font(theme.id == .privateCinema ? JoePCType.outfit(29)
                               : .system(size: 29))
                    .foregroundStyle(theme.text)
                    .tint(theme.text)
            }
            // UI-6 defect D-19: the results carry the render's
            // heading naming the searched term — design D's
            // search drawing has it, and design A's search
            // drawing has the same heading ("Kết quả cho "…"",
            // rail-title 34 bold), so A takes it too. F keeps
            // its per-source grouped rails without it.
            if theme.id != .sourceBoard && searched && !results.isEmpty {
                Text("Kết quả cho “\(searchedQuery)”")
                    .font(theme.id == .privateCinema
                          ? JoePCType.outfit(34, weight: .bold)
                          : .system(size: 34, weight: .bold))
                    .foregroundStyle(theme.text)
            }
            // v2.0.5 (N1, pair k): the results area is a
            // declared focus region, paired with the query
            // row's own section above.
            // v2.1.1 (WS-E): the PC LANDING state (no query,
            // no round run yet) shows the design's discovery
            // composition in this slot instead; the moment
            // typing starts a round, the normal results area
            // takes the slot back, untouched.
            if pcLanding {
                pcDiscoverySection
                    .focusSection()
            } else {
                resultsArea
                    .focusSection()
            }
        }
        // FIX-214 (FULL-THEME-AUDIT-214 B8): under
        // Private Cinema the drawn Search frame is x94
        // (right edge 94 too) with the bar clearance on
        // top — the swap surface carried neither (the
        // Finding 12 family). The values are branches on
        // the one shared stack: +14 horizontal over the
        // ambient 80, and the joePCBarInset arithmetic
        // (bar height − the 60 the safe area already
        // grants) as a top padding. Legacy themes keep
        // the ambient frame exactly.
        .padding(.horizontal, theme.id == .privateCinema ? 14 : 0)
        .padding(.top, theme.id == .privateCinema
                 ? joePCBarHeight - 60 : 0)
        // v2.1.1 (WS-E): the discovery grid's data — one
        // trending-file load per search-layer appearance,
        // PC only (loadDiscovery guards the theme itself).
        .task { await loadDiscovery() }
        // v2.0.17: strip edits drive the type-ahead round —
        // the onChange that used to sit on the TextField.
        .onChange(of: query) { _, _ in scheduleTypeAhead() }
        // Menu closes the search layer (convergence, Team 7):
        // the handler is unconditional and lives on the layer
        // itself, so it exists exactly while the layer does —
        // and while a movie detail is open above the search,
        // the detail's own handler is the nearer ancestor and
        // wins, preserving exactly-one-layer-per-press.
        .onExitCommand {
            // v2.0.49 (item 7, fix round — owner order
            // 2026-11-21 22:32): Menu jumps straight to
            // the top of the page first. Focus anywhere
            // on the letter strip or the Quay lại button
            // (keyFocus != nil — the strip is the page's
            // top region and its "a" key the declared
            // landing, see .defaultFocus below), or on
            // the Retry button of the pinned failure
            // surface (no scrollable results under it),
            // keeps the existing close; anywhere else,
            // Menu scrolls the results to the top and
            // lands focus on the strip, swallowing the
            // exit.
            if keyFocus != nil || retryFocused {
                nav.searchOpen = false
            } else {
                topScrollSignal += 1
                keyFocus = .key("a")
            }
        }
        // 1.9.2 (Team 9 item 8): the query field is the
        // layer's declared initial focus — a static,
        // appearance-time .defaultFocus, the same construction
        // JoeMovieDetail's play button device-proves
        // (JoeMovieDetail.swift). The convergence round removed
        // the focus-hub consumer and assumed DOWN from the pills
        // would land here geometrically; after the grid→search
        // swap destroyed the tapped button's subtree, focus had
        // NO declared landing inside this layer at all, and on
        // device the owner could not get into search at all.
        // D4-safe: the declaration installs nothing in response
        // to focus state and no structure depends on it.
        // v2.0.17: the landing is the strip's first key — the
        // field this declaration used to name no longer exists.
        .defaultFocus($keyFocus, .key("a"))
    }

    /// The query row (v2.0.17): the query as a light display
    /// (the field's chrome, never focused — there is no
    /// system field any more) + Quay lại. Typing happens on the letter strip
    /// directly below; the Tìm button is gone because typing
    /// IS the search (v2.0.13's rule, now visible while it
    /// happens). In A/F the row is centred by the body; D
    /// runs it full width.
    private var fieldRow: some View {
        HStack(spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 26, weight: .semibold))
                Text(query.isEmpty ? "Tên phim…" : query)
                    .font(theme.id == .privateCinema
                          ? JoePCType.outfit(29,
                                             weight: .light)
                          : .system(size: ThemeTokens.fieldTextSize))
                    .lineLimit(1)
            }
            // The inner frame makes the display greedy, so
            // the chrome paints the field's full width (D-19:
            // D full width; A/F keep their centred 700).
            .frame(maxWidth: .infinity, alignment: .leading)
            .joeFieldChrome(focused: false)
            .frame(maxWidth: theme.id == .posterWall ? .infinity : 700)
            Button {
                nav.searchOpen = false
            } label: {
                JoeSecondaryLabel(title: "⟵ Quay lại")
            }
            .joeCardButton()
            .focused($keyFocus, equals: .back)
        }
        // The row stays a declared focus region (v2.0.5 N1);
        // the strip below is a region of its own, and
        // movement between the regions is the engine's
        // geometric search, as it has been since v2.0.8.
        .focusSection()
    }

    // MARK: - Private Cinema landing (v2.1.1, WS-E)
    //
    // The design's Search composition (replit-set
    // ...-15-delivery-joetv-Search.png) as the PC arm's
    // LANDING state: serif headline, the wide field, and
    // the "Đáng để khám phá" discovery grid fed by the
    // trending file. The letter-strip instant search above
    // is the same function every theme runs — this section
    // only dresses the surface while no query exists.

    /// True while the PC landing composition owns the
    /// results slot: PC theme, the field empty, and no
    /// round has run (or is running) yet.
    private var pcLanding: Bool {
        theme.id == .privateCinema
            && query.trimmingCharacters(in: .whitespaces).isEmpty
            && !searched && !roundActive && results.isEmpty
    }

    /// The headline row: the design's serif headline at
    /// the left, its quiet tagline at the right.
    private var pcHeadline: some View {
        HStack(alignment: .bottom, spacing: 24) {
            Text("Câu chuyện tiếp theo của bạn.")
                // RECALC-213 correction: the delivered
                // drawing's headline is an upright
                // Times-class serif, not Instrument Serif
                // (design-team overlay measurement,
                // RECALC-SPEC §3.8); size 60 matches the
                // measured ink box.
                .font(JoePCType.timesSerif(60))
                .foregroundStyle(theme.text)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("Tìm một bộ phim. Bước vào một thế giới.")
                .font(JoePCType.outfit(22))
                .foregroundStyle(theme.meta)
                .padding(.bottom, 10)
        }
    }

    /// The wide field (the design's one full-width bar):
    /// the same query display the other themes centre,
    /// run full width here, with the design's TÌM KIẾM
    /// chip inside the bar's right end. Typing still
    /// happens on the letter strip below — the chip is
    /// the design's furniture, not a second search path.
    /// (FIX-214: the Quay lại pill that rode beside this
    /// field is removed — see the row itself.)
    private var pcFieldRow: some View {
        HStack(spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 26, weight: .semibold))
                Text(query.isEmpty
                        ? "Tên phim, diễn viên, đạo diễn..." : query)
                    .font(JoePCType.outfit(29,
                                           weight: .light))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("TÌM KIẾM")
                    .font(JoePCType.outfit(15, weight: .semibold))
                    .tracking(1.5)
                    .foregroundStyle(theme.meta)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .overlay(RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(theme.stroke, lineWidth: 1.5))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .joeFieldChrome(focused: false)
            // FIX-214 (FULL-THEME-AUDIT-214 B8): NO
            // "⟵ Quay lại" pill beside the field under
            // Private Cinema — the drawing has none;
            // Menu is the standard exit (the layer's
            // onExitCommand closes it, and with focus on
            // the strip it closes directly). Design-team
            // call per the audit's fix text: removed, not
            // relocated. (The legacy fieldRow keeps its
            // button — other themes, other drawings.)
        }
        .focusSection()
    }

    /// The discovery section: heading + the file's title
    /// count at the right (the design's furniture, fed by
    /// the real count), then the poster grid — eight
    /// columns at the design's card geometry (205×263),
    /// two rows of the trending file's first titles.
    private var pcDiscoverySection: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline, spacing: 24) {
                    Text("Đáng để khám phá")
                        .font(JoePCType.outfit(30, weight: .semibold))
                        .foregroundStyle(theme.text)
                    Spacer(minLength: 0)
                    if !discoveryItems.isEmpty {
                        Text("\(discoveryItems.count) tựa phim")
                            .font(JoePCType.outfit(22))
                            .foregroundStyle(theme.meta)
                    }
                }
                LazyVGrid(columns: Array(
                            repeating: GridItem(.flexible(), spacing: 31),
                            count: 8),
                          alignment: .leading, spacing: 24) {
                    ForEach(discoveryItems.prefix(16)) { meta in
                        pcDiscoveryCard(meta)
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 4)
            }
            // claude/opt-2 (owner photo 2026-11-22: "bị cắt
            // khung"): the focused card's outset ring + scale
            // reach past this scroll view's clipping frame, so the
            // outermost card lost part of its frame. The content
            // is inset 16 and the scroll view widened by the same
            // 16 on both sides: the clip edge moves out, every
            // card stays exactly where it was (net geometry 0).
            .padding(.horizontal, 16)
        }
        .padding(.horizontal, -16)
    }

    private func pcDiscoveryCard(_ meta: TorMeta) -> some View {
        Button { openDiscovery(meta) } label: {
            JoeSearchDiscoveryCard(meta: meta)
        }
        .joeCardButton()
        .focused($focusedDiscovery, equals: "discovery|" + meta.id)
    }

    /// Load the discovery items once (PC only, fail-open):
    /// the trending file's rails flattened in file order.
    private func loadDiscovery() async {
        guard theme.id == .privateCinema, discoveryItems.isEmpty
        else { return }
        let rails = await JoeTrendingFile.loadRails()
        discoveryItems = rails.flatMap { $0.metas }
    }

    /// A discovery tap (v2.1.1, WS-E): the chain-first
    /// bridge of DIAG-2050 §4 — the same discipline the
    /// phim home / actor page resolve foreign titles with.
    /// A trending-file item carries no provider slug, so
    /// it must never mint a detail route directly.
    private func openDiscovery(_ meta: TorMeta) {
        Task { await resolveDiscovery(meta) }
    }

    private func resolveDiscovery(_ meta: TorMeta) async {
        // 1. The resident catalogue first (no network):
        // an exact normalised-name match, the year
        // agreeing whenever both sides state one.
        if let hit = discoveryMatch(in: storeMovies(), for: meta) {
            openChainMovie(hit)
            return
        }
        // 2. The providers, in priority order, one search
        // pass each, same acceptance rule.
        for code in Providers.priority {
            guard let results = try? await Providers.search(
                code, keyword: meta.name) else { continue }
            if let hit = discoveryMatch(in: results, for: meta) {
                openChainMovie(hit)
                return
            }
        }
        // 3. No chain record carries the title: fall
        // through to the torrent detail by the item's IMDb
        // id (every file item carries one — items without
        // are skipped at parse), exactly as the torrent
        // home opens these metas today. A tap is never dead.
        nav.tor = TorRoute(meta: meta, base: TorrentSettings.cinemeta)
    }

    /// The discovery acceptance rule: normalised-name
    /// equality (the search round's own exact tier), the
    /// year agreeing whenever both sides state one, and a
    /// slug present — a record that cannot open is not a
    /// match.
    private func discoveryMatch(in movies: [Movie],
                                for meta: TorMeta) -> Movie? {
        let target = Providers.normalizeTitle(meta.name)
        guard !target.isEmpty else { return nil }
        return movies.first {
            !$0.slug.isEmpty
                && Providers.normalizeTitle($0.name) == target
                && (meta.year.isEmpty || $0.year.isEmpty
                    || $0.year == meta.year)
        }
    }

    /// Mint the normal detail route for a resolved chain
    /// record — resultCard's own construction.
    private func openChainMovie(_ movie: Movie) {
        nav.movie = MovieRoute(
            provider: movie.provider, slug: movie.slug,
            name: movie.name, poster: movie.poster,
            year: movie.year)
    }

    /// Results: design F groups them by source (one rail per
    /// provider, in failover priority order, with counts);
    /// designs A and D keep the 6-column grid (D's cards render
    /// in wall anatomy via the shared PosterCard).
    @ViewBuilder
    private var resultsArea: some View {
        if theme.id == .sourceBoard && !results.isEmpty {
            // v2.0.49 (item 7, fix round): the ScrollView
            // sits inside a ScrollViewReader so Menu can
            // jump straight to the top of the results (see
            // the body's .onExitCommand).
            ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 36) {
                    ForEach([Providers.KK, Providers.F4K, Providers.VS, Providers.TP],
                            id: \.self) { code in
                        let list = results.filter { $0.provider == code }
                        if !list.isEmpty {
                            Rail(title: "\(Providers.displayName(code)) — \(list.count) kết quả") {
                                ForEach(list) { movie in
                                    resultCard(movie)
                                }
                            }
                        }
                    }
                    addonGroupRail
                }
                .padding(.vertical, 8)
                .id("joeSearchTop")
            }
            // v2.0.49 (item 7, fix round): the Menu-to-top
            // jump's scroll hook, inside the reader.
            .onChange(of: topScrollSignal) { _, _ in
                proxy.scrollTo("joeSearchTop", anchor: .top)
            }
            }
            // v2.0.12 (search overlap fix): this container
            // deliberately CLIPS at its frame — no
            // .scrollClipDisabled() here. The status line
            // and the results heading are PINNED siblings
            // directly above this ScrollView in the body's
            // VStack (the facet bar that sat there until
            // v2.0.13 was one too); with clipping disabled,
            // results scrolling past the frame's top edge
            // kept rendering into their space, painting
            // posters and provider headers over them
            // (owner's 2.0.11 clip, shot when the bar was
            // the victim). The home's outer scroll
            // (JoePhimHome.railHome) ships clipped with the
            // same cards; the rails' own inner horizontal
            // scrolls keep their clip-disabled construction
            // (JoeTheme.Rail) — that escape is bounded inside
            // this container, and this container's frame is
            // now the hard boundary nothing crosses.
        } else {
            // v2.0.49 (item 7, fix round): the ScrollView
            // sits inside a ScrollViewReader so Menu can
            // jump straight to the top of the results (see
            // the body's .onExitCommand).
            ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                // v2.0.45 (leg 3): the grid and the addon
                // group stack in one column — the group
                // rides below the provider grid (and still
                // shows when the providers found nothing).
                VStack(alignment: .leading, spacing: 40) {
                // Fixed 6 columns (was .adaptive(minimum: 240)).
                // v2.0.8 (Phase 1): no arithmetic routing any
                // more — resultMove is deleted and the engine
                // moves geometrically over this grid.
                // Column gap = the theme's rail gap (design
                // card pitch: A 26, D 24, F 28).
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: theme.railGap),
                                         count: 6),
                          alignment: .leading, spacing: 40) {
                    ForEach(results) { movie in
                        resultCard(movie)
                    }
                }
                .padding(.vertical, 8)
                // Design D's wall ring is an OUTSET band around
                // the art (6 pt): the grid's edge clearance
                // grows past it under D so the outer columns'
                // rings are never clipped by the scroll frame.
                .padding(.horizontal, theme.id == .posterWall ? 8 : 4)
                addonGroupRail
                }
                .id("joeSearchTop")
            }
            // v2.0.49 (item 7, fix round): the Menu-to-top
            // jump's scroll hook, inside the reader.
            .onChange(of: topScrollSignal) { _, _ in
                proxy.scrollTo("joeSearchTop", anchor: .top)
            }
            }
            // v2.0.12 (search overlap fix): CLIPS at its
            // frame, same as the source-board branch above —
            // no .scrollClipDisabled() on this container.
            // The pinned status/heading lines sit directly
            // above it in the stack; unclipped grid content
            // scrolling past the top edge rendered over
            // them.
            // The grid's own edge clearances (vertical 8,
            // horizontal 8 under D — past the 6 pt outset
            // ring) are unchanged, so a focused card's ring
            // keeps its room inside the frame.
        }
    }

    // v2.0.13: the results area renders `results` — the
    // round's render pool — directly. The Phase 6 facet
    // layer that used to sit between the pool and the grid
    // (displayedResults + facetFiltered over the shared
    // JoeBrowseFilter) is DELETED with the bar it served;
    // nothing filters or re-sorts a round's results on
    // this screen any more.

    private func resultCard(_ movie: Movie) -> some View {
        Button { nav.movie = MovieRoute(
            provider: movie.provider, slug: movie.slug,
            name: movie.name, poster: movie.poster,
            year: movie.year) } label: {
            PosterCard(
                title: movie.name,
                posterURL: movie.posterURL,
                tmdbId: movie.tmdbId,
                tmdbType: movie.tmdbType,
                meta: movie.cardMeta,
                badge: Providers.badge(movie.provider),
                quality: movie.quality)
        }
        .joeCardButton()
        .focused($focusedMovie, equals: "search|" + movie.id)
    }

    // v2.0.45 (leg 3): the user addon's search group. The
    // branch rides the round generation (a stale round's
    // answer never lands) but stays OUT of the branch
    // bookkeeping: the addon's silence never fails a
    // round, and its hits never enter the snapshot rule.
    // Results are match-filtered in the store (a title
    // the app already carries gets no duplicate card).
    private func runAddonBranch(gen: Int, kw: String) {
        addonResults = []
        addonGroupName = ""
        guard addonStore.hasAddon else { return }
        Task {
            let found = await addonStore.search(
                keyword: kw, movies: storeMovies(),
                tvbSeries: ytStore.snapshot?.series ?? [])
            guard gen == roundID else { return }
            addonGroupName = found.name
            addonResults = found.metas
        }
    }

    @ViewBuilder
    private var addonGroupRail: some View {
        if !addonResults.isEmpty {
            Rail(title: "\(addonGroupName) — \(addonResults.count) kết quả") {
                ForEach(addonResults) { meta in
                    addonCard(meta)
                }
            }
        }
    }

    private func addonCard(_ meta: TorMeta) -> some View {
        Button {
            if let base = addonStore.servingBase {
                nav.addonDetail = JoeAddonRoute(
                    base: base, type: meta.type, metaId: meta.id,
                    name: meta.name, poster: meta.poster,
                    year: meta.year, addonName: addonStore.addonName)
            }
        } label: {
            PosterCard(
                title: meta.name,
                posterURL: meta.posterURL,
                meta: meta.year)
        }
        .joeCardButton()
        .focused($focusedAddon, equals: "addon|" + meta.type + "|" + meta.id)
    }

    // v2.0.8 (Phase 1): resultMove is DELETED — result
    // cards are plain buttons in the results focus section;
    // the engine moves within the grid geometrically and UP
    // out of it (to the query row, from any column) the
    // same way. No coded no-op directions remain in this
    // view.

    // MARK: - Search round (v2.0.1 — Android FIX2 + FIX3 parity)
    //
    // One press runs ONE round:
    //  1. LOCAL FIRST: the title pool (everything already
    //     downloaded — home rails, the browse dataset, genre /
    //     country lists, all resident in PhimStore — plus every
    //     earlier round's branch results) answers synchronously
    //     at the press. The search never waits on the store's
    //     load: an unloaded store simply yields fewer local hits
    //     and the branches carry the round.
    //  2. The four provider branches fan out; each merges into
    //     the server pool and re-renders THE MOMENT IT LANDS
    //     (progressive merge — the pre-fix round rendered
    //     nothing until the slowest branch answered).
    //  3. Two settles: the VISIBLE settle at the 2.5 s soft
    //     deadline (or when the last branch lands, if sooner)
    //     flips `searching` off; branches keep merging until
    //     the 15 s hard budget, where stragglers are cut and
    //     counted failed.
    //  4. Bookkeeping is honest (the FIX2 rule): only a round
    //     with ZERO failed branches is snapshotted for instant
    //     replay; an all-failed round is never cached — a
    //     re-press re-runs it — and shows the failure surface,
    //     never the no-match line.
    // JOESEARCH lines ride the house signpost log (LoadSignpost)
    // with per-branch timings and the round's first paint.
    //
    // v2.0.13: rounds now fire from the keyboard as well —
    // scheduleTypeAhead() below debounces field edits by
    // ~300 ms and runs the round for the settled text, so
    // the grid follows the typing (local paint per round,
    // branches merging behind). runSearch itself is
    // unchanged: same local-first step, same fan-out, same
    // settles, same snapshot rule. A new round supersedes
    // the in-flight one by roundID, so a stale term's
    // branches can never land over a newer term's grid.

    /// The debounced type-ahead driver (v2.0.13). Every
    /// field edit cancels the pending firing and re-arms
    /// it; when the ~300 ms elapse with the text unchanged,
    /// the round for that text runs. An emptied field does
    /// NOT run a round — it resets the screen to its
    /// un-searched state (resetSearch), superseding any
    /// in-flight round so a late branch cannot repaint a
    /// screen the owner has already cleared.
    private func scheduleTypeAhead() {
        typeAheadTask?.cancel()
        let text = query
        typeAheadTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            // Belt and braces beside the cancellation: a
            // firing whose text is no longer the field's
            // stands down (a newer edit re-armed its own).
            guard query == text else { return }
            if text.trimmingCharacters(in: .whitespaces).isEmpty {
                resetSearch()
            } else {
                runSearch()
            }
        }
    }

    /// The field was cleared: back to the pre-search state.
    /// The roundID bump stands down the old round's branch
    /// tasks and both settle tasks (all guard on it).
    private func resetSearch() {
        roundID += 1
        roundActive = false
        searching = false
        searched = false
        searchFailed = false
        searchedQuery = ""
        localPool = []
        serverPool = []
        results = []
        addonResults = []
        addonGroupName = ""
    }

    private func runSearch() {
        // An immediate round (Tìm / onSubmit, or the
        // type-ahead firing itself) supersedes any pending
        // debounce — its firing must not re-run this round
        // a second time for the same text.
        typeAheadTask?.cancel()
        let kw = query.trimmingCharacters(in: .whitespaces)
        guard !kw.isEmpty else { return }
        searchedQuery = kw
        searchFailed = false

        // Snapshot restore: a clean earlier round for this
        // name replays instantly with zero network.
        if let snap = JoeSearchSession.shared.snapshot(for: kw) {
            roundID += 1
            roundActive = false
            searching = false
            searched = true
            results = Self.renderPool(local: snap.local,
                                      server: snap.server, query: kw)
            LoadSignpost.log("JOESEARCH snapshot query=\"\(kw)\" results=\(results.count)")
            runAddonBranch(gen: roundID, kw: kw)
            return
        }

        roundID += 1
        let gen = roundID
        roundActive = true
        searching = true
        searched = false
        branchesDone = 0
        branchesOK = 0
        branchesFailed = 0
        firstPaintLogged = false
        pressStart = Date()

        // 1. Local first.
        JoeSearchSession.shared.feed(storeMovies())
        let hits = JoeSearchSession.shared.localHits(for: kw)
        localPool = hits
        serverPool = []
        results = Self.renderPool(local: hits, server: [], query: kw)
        if !hits.isEmpty { logFirstPaint(localHits: hits.count) }
        runAddonBranch(gen: gen, kw: kw)

        // 2. Branch fan-out with progressive merge.
        for code in Providers.priority {
            Task {
                let t0 = Date()
                let res = try? await Providers.search(code, keyword: kw)
                guard gen == roundID, roundActive else { return }
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                branchesDone += 1
                if let res {
                    branchesOK += 1
                    JoeSearchSession.shared.feed(res)
                    serverPool = Self.mergePool(serverPool, res)
                    LoadSignpost.log("JOESEARCH provider=\(code) ms=\(ms) results=\(res.count) timeout=0 error=0 query=\"\(kw)\"")
                } else {
                    branchesFailed += 1
                    LoadSignpost.log("JOESEARCH provider=\(code) ms=\(ms) results=0 timeout=0 error=1 query=\"\(kw)\"")
                }
                results = Self.renderPool(local: localPool,
                                          server: serverPool, query: kw)
                if !results.isEmpty { logFirstPaint(localHits: hits.count) }
                if branchesDone == Providers.priority.count {
                    hardSettle(gen: gen, kw: kw)
                }
            }
        }

        // 3a. Soft deadline: the visible settle.
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard gen == roundID, roundActive, searching else { return }
            searching = false
            LoadSignpost.log("JOESEARCH soft_settle ms=2500 query=\"\(kw)\" results=\(results.count)")
        }

        // 3b. Hard budget: cut the stragglers, settle with
        // what the round has.
        Task {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard gen == roundID, roundActive else { return }
            let missing = Providers.priority.count - branchesDone
            if missing > 0 {
                branchesFailed += missing
                LoadSignpost.log("JOESEARCH hard_budget missing=\(missing) query=\"\(kw)\"")
            }
            hardSettle(gen: gen, kw: kw)
        }
    }

    /// The hard settle: failure honesty + the snapshot rule.
    private func hardSettle(gen: Int, kw: String) {
        guard gen == roundID, roundActive else { return }
        roundActive = false
        searching = false
        searched = true
        // Failure means every provider threw (or was cut by
        // the hard budget); a provider that answered empty is
        // a (partial) success. The failure surface itself only
        // shows when the grid is empty (body rule) — local
        // hits stand even under an all-failed round.
        if branchesFailed >= Providers.priority.count {
            searchFailed = true
        }
        if branchesFailed == 0 {
            JoeSearchSession.shared.storeSnapshot(
                name: kw, local: localPool, server: serverPool)
        }
        let totalMs = Int(Date().timeIntervalSince(pressStart) * 1000)
        LoadSignpost.log("JOESEARCH total ms=\(totalMs) ok=\(branchesOK) failed=\(branchesFailed) query=\"\(kw)\"")
    }

    private func logFirstPaint(localHits: Int) {
        guard !firstPaintLogged else { return }
        firstPaintLogged = true
        let ms = Int(Date().timeIntervalSince(pressStart) * 1000)
        LoadSignpost.log("JOESEARCH first_paint ms=\(ms) local_hits=\(localHits) query=\"\(searchedQuery)\"")
    }

    /// Everything the Phim store has already downloaded: the
    /// merged newest rails, the type lists, chiếu rạp, the
    /// Vietnam block, and every genre / country list. (The
    /// merged rail already covers the four newest rails;
    /// feeding duplicates is harmless — the pool dedupes.)
    private func storeMovies() -> [Movie] {
        var all: [Movie] = []
        all += phim.merged
        all += phim.kkSeries + phim.kkMovies + phim.kkAnime
        all += phim.f4kNew + phim.f4kMovies
        all += phim.vsNew + phim.vsSeries
        all += phim.tpNew + phim.tpMovies + phim.tpSeries
        all += phim.chieuRap + phim.vietnamAll
        for list in phim.genreLists.values { all += list }
        for list in phim.countryLists.values { all += list }
        return all
    }

    /// Append `extra` to `base`, dropping later duplicates of
    /// an already-kept film (provider|slug, first copy wins —
    /// store copies carry the richer metadata).
    private static func mergePool(_ base: [Movie], _ extra: [Movie]) -> [Movie] {
        var seen = Set(base.map { $0.id })
        var out = base
        for m in extra where !m.slug.isEmpty && !seen.contains(m.id) {
            seen.insert(m.id)
            out.append(m)
        }
        return out
    }

    /// The render pool: local hits first, then the server pool
    /// grouped in provider priority order (the shipped grid
    /// order), with the ONE sanctioned reordering — the
    /// exact-match tier: a film whose normalized name OR
    /// origin name EQUALS the query leads, in arrival order.
    /// Every other card keeps its pool order and never moves
    /// within its tier, so a branch landing late only appends
    /// (or upgrades its own exact match into the front block).
    private static func renderPool(local: [Movie], server: [Movie],
                                   query: String) -> [Movie] {
        var merged = mergePool([], local)
        for code in Providers.priority {
            merged = mergePool(merged, server.filter { $0.provider == code })
        }
        merged = mergePool(merged, server)
        let q = Providers.normalizeTitle(query)
        let exact = merged.filter {
            Providers.normalizeTitle($0.name) == q
                || Providers.normalizeTitle($0.originName) == q
        }
        guard !exact.isEmpty else { return merged }
        let exactIDs = Set(exact.map { $0.id })
        return exact + merged.filter { !exactIDs.contains($0.id) }
    }
}

/// Session search memory (v2.0.1 — the Android TitleIndex +
/// query cache, tvOS form): the local title pool and the
/// clean-round snapshots. Lock-guarded static state (the
/// Providers.altCache pattern) because the search view is
/// recreated on every open while the session memory must
/// survive it. Keys are precomputed at feed time, so a query
/// costs two substring checks per entry.
private final class JoeSearchSession: @unchecked Sendable {
    static let shared = JoeSearchSession()

    private let lock = NSLock()
    private var poolOrder: [String] = []
    private var pool: [String: Movie] = [:]
    private var poolKeys: [String: (name: String, origin: String)] = [:]
    private var snapshots: [(name: String, local: [Movie], server: [Movie])] = []

    /// Feed downloaded titles into the pool: first copy wins,
    /// cap 6000 entries with eldest-first eviction.
    func feed(_ movies: [Movie]) {
        lock.lock()
        for m in movies where !m.slug.isEmpty {
            if pool[m.id] == nil {
                pool[m.id] = m
                poolKeys[m.id] = (Providers.normalizeTitle(m.name),
                                  Providers.normalizeTitle(m.originName))
                poolOrder.append(m.id)
            }
        }
        while poolOrder.count > 6000 {
            let evicted = poolOrder.removeFirst()
            pool.removeValue(forKey: evicted)
            poolKeys.removeValue(forKey: evicted)
        }
        lock.unlock()
    }

    /// Local hits for a name — the search's own match rule:
    /// normalized substring over the name OR the origin name.
    func localHits(for query: String) -> [Movie] {
        let q = Providers.normalizeTitle(query)
        guard !q.isEmpty else { return [] }
        lock.lock()
        let ids = poolOrder
        let poolCopy = pool
        let keysCopy = poolKeys
        lock.unlock()
        return ids.compactMap { id in
            guard let m = poolCopy[id], let k = keysCopy[id] else { return nil }
            return (k.name.contains(q) || k.origin.contains(q)) ? m : nil
        }
    }

    /// A snapshotted clean round for this name (LRU touch on
    /// hit), or nil.
    func snapshot(for name: String) -> (local: [Movie], server: [Movie])? {
        lock.lock()
        defer { lock.unlock() }
        if let i = snapshots.firstIndex(where: { $0.name == name }) {
            let hit = snapshots.remove(at: i)
            snapshots.append(hit)
            return (hit.local, hit.server)
        }
        return nil
    }

    /// Snapshot a round. The CALLER enforces the FIX2 rule —
    /// only rounds with zero failed branches are stored, so a
    /// failed round can never be replayed as a result.
    func storeSnapshot(name: String, local: [Movie], server: [Movie]) {
        lock.lock()
        snapshots.removeAll { $0.name == name }
        snapshots.append((name, local, server))
        if snapshots.count > 12 {
            snapshots.removeFirst(snapshots.count - 12)
        }
        lock.unlock()
    }
}

/// Focus identity for the search screens' top area
/// (v2.0.17): a letter-strip key (its id IS its label —
/// "a"…"z", "1"…"0", "space", "del", "mode") or the Quay
/// lại button.
/// Shared by JoeSearchView and JoeTVBSearchView, whose top
/// areas are twins.
enum JoeSearchKeyFocus: Hashable {
    case key(String)
    case back
}

/// One discovery-grid card (v2.1.1, WS-E — the PC Search
/// design's card): the bare poster at the design's card
/// geometry (205×263 in the 1920-wide drawing ≈ the grid
/// column's width at a 205:263 ratio), a type badge at the
/// poster's top-left, then title and year under it, on the
/// page background — the Private Cinema card anatomy
/// (PosterCard.cinemaBody's shape), drawn locally because
/// the shared card's width is a theme token this surface
/// does not own. Focus is the design's tile treatment
/// (Fault 11 fix round: the ivory outset outline + 1.045
/// scale on the art, the .83 rest opacity at the root —
/// the inside ring this card first shipped with was the
/// legacy pattern the owner convicted).
///
/// Data honesty: the trending file carries no quality and
/// no genre for its items, so the badge states only what
/// the data states — the type (SERIES for a series item;
/// a movie item carries no badge rather than an invented
/// "4K") — and the line under the title is the year alone
/// (the design's "year · genre" with the genre absent from
/// the data, never fabricated).
private struct JoeSearchDiscoveryCard: View {
    let meta: TorMeta
    @Environment(\.joeTheme) private var theme
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    JoeRemoteImage(url: meta.posterURL,
                                   targetPixels: 480,
                                   slotClass: .portrait) {
                        ZStack {
                            theme.surface2
                            Text(String(meta.name.prefix(1)))
                                .font(JoePCType.outfit(34, weight: .bold))
                                .foregroundStyle(theme.text.opacity(0.7))
                        }
                    }
                    .frame(width: geo.size.width,
                           height: geo.size.width * 263 / 205)
                    if meta.type == "series" {
                        badge("SERIES")
                    }
                }
            }
            .aspectRatio(205.0 / 263.0, contentMode: .fit)
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
            Text(meta.name)
                // FIX-5 / Lens C Finding 3: the design's card title is 18/400.
                .font(JoePCType.outfit(18))
                .foregroundStyle(isFocused ? theme.focusTitle : theme.text)
                .lineLimit(1)
                .padding(.top, 10)
            if !meta.year.isEmpty {
                Text(meta.year)
                    // FIX-10b / F12: spec metadata = 14.
                    .font(JoePCType.outfit(14))
                    .foregroundStyle(theme.meta)
                    .lineLimit(1)
                    .padding(.top, 4)
            }
        }
        .joeCinemaCardFocus()
    }

    /// The design's badge: a small dark chip at the
    /// poster's top-left (11 pt text, #0C1215 at ~90%).
    private func badge(_ text: String) -> some View {
        Text(text)
            // FIX-10b / F12: the rail-card badge dressing
            // — 11 regular.
            .font(JoePCType.outfit(11))
            .foregroundStyle(theme.text)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 3)
                .fill(Color.black.opacity(0.88)))
            .padding(.top, 10)
            .padding(.leading, 10)
    }
}

/// The Netflix-anatomy letter strip (v2.0.17 — the owner's
/// order, his Netflix photo as the drawing): ONE row of keys
/// on the search screen itself — a mode key, a space key,
/// the letters, a delete key — mutating the bound query;
/// the host's onChange fires its search round per edit, so
/// results repaint in this same screen while typing. The
/// system TextField it replaces summoned the full-screen
/// keyboard and hid the results until "done" (the owner's
/// screen recording, 2026-11-17). The second mode swaps the
/// letters for the digits and the few symbols film titles
/// carry.
struct JoeLetterStrip: View {
    @Binding var query: String
    var focus: FocusState<JoeSearchKeyFocus?>.Binding
    @State private var symbols = false

    private var letters: [String] {
        symbols
            ? ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0",
               "-", "'", ".", "&", ":"]
            : Array("abcdefghijklmnopqrstuvwxyz").map(String.init)
    }

    var body: some View {
        HStack(spacing: 8) {
            key(id: "mode", label: symbols ? "abc" : "123", width: 96) {
                symbols.toggle()
            }
            key(id: "space", label: "space", width: 128) {
                append(" ")
            }
            ForEach(letters, id: \.self) { letter in
                key(id: letter, label: letter, width: 42) {
                    append(letter)
                }
            }
            key(id: "del", label: "⌫", width: 96) {
                if !query.isEmpty { query.removeLast() }
            }
        }
        .focusSection()
    }

    private func append(_ s: String) {
        guard query.count < 48 else { return }
        query += s
    }

    private func key(id: String, label: String, width: CGFloat,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            JoeKeyCap(label: label, width: width,
                      focused: focus.wrappedValue == .key(id))
        }
        .joeCardButton()
        .focused(focus, equals: .key(id))
    }
}

/// One strip key's face: a quiet plate unfocused, the
/// theme's focus colour filled when focused — the label
/// paints its own focus, because the house button style
/// (JoeCardButton) deliberately paints nothing.
private struct JoeKeyCap: View {
    let label: String
    let width: CGFloat
    let focused: Bool
    @Environment(\.joeTheme) private var theme

    var body: some View {
        Text(label)
            .font(theme.id == .privateCinema
                  ? JoePCType.outfit(28, weight: .medium)
                  : .system(size: 28, weight: .medium))
            .foregroundStyle(focused ? .black : theme.text)
            .frame(width: width, height: 58)
            .background(RoundedRectangle(cornerRadius: 12)
                .fill(focused ? theme.focus : Color.white.opacity(0.08)))
    }
}

// CONVERGENCE RECORD (2026-11-15): JoeSearchMoveTrap — this
// file's copy of the conditional move-trap pattern — is
// DELETED; see the record at the end of JoeTVApp.swift. The
// top-row and Retry traps it powered are replaced by geometric
// focus movement.
// v2.0.8 (Phase 1): the per-result grid handler (resultMove)
// is DELETED too — an attached .onMoveCommand owned every
// direction and made undeclared ones no-ops; result cards
// are plain buttons and movement is the engine's throughout
// this file.
