import Foundation

// MARK: - TVB YouTube catalogue (tvb-yt.json)
//
// The YouTube side of the TVB tab, consuming the EXACT file
// the Sony build consumes (design plan §1.1/§1.2; handover
// package MANIFEST, verified 2026-11-19: 1,873 series, 51,180
// episodes, generatedAt 2026-11-20T04:51:44Z). Load order is
// the Sony contract: the last accepted hosted copy (cache)
// wins over the bundled fallback; a background refresh runs
// when the loaded copy is over 24 h old and replaces the
// CACHE only — the published snapshot is never swapped under
// its readers in-process (publish-once, design §1.2 item 4);
// the refreshed copy takes effect on the next cold start.
//
// Matching to the 803-title snapshot is fail-closed (design
// §1.4): a series links ONLY when its tmdbId is non-zero, a
// DISPLAYED snapshot title holds that id, AND the series'
// matched Vi name (or its cleaned title) equals that title's
// Vi / EN / original name exactly after Providers
// .normalizeTitle. Desk-verified against the real files
// before this code was written: 1,177 series pass the
// name test, naming 626 distinct titles — 416 titles have
// 2–4 passing series, and those collisions resolve by the
// deterministic preference in JoeYtSnapshot.build
// (own-title exact → tier → rail rank), never by file
// order. Any doubt on the name test ⇒ no link: the series
// stands YouTube-only and the 803 title stands chain-only.
//
// Rail order is the owner's 2026-11-19 ruling: HOT /
// most-watched first, NEW ahead on ties — `views` (YouTube's
// own playlist view count, the primary signal) desc, then
// `rssNewestAt` desc (a coarse freshness hint only — the RSS
// window covers the first ≤15 playlist positions, so it is
// never read as a latest-episode date), then pid for
// determinism.

struct JoeYtSeries: Codable, Sendable, Identifiable {
    let pid: String
    let title: String
    let rawTitle: String
    let channel: String
    /// "gold" | "vip" | "members" | "free" — the file's own
    /// vocabulary, kept verbatim (design §1.1). Unknown values
    /// group into no rail.
    let tier: String
    let eps: [String]
    let epTitles: [String]
    /// 0 = unmatched / ambiguous in the builder (fail-closed
    /// there); a non-zero value still has to pass the in-app
    /// title check before it links (§1.4).
    let tmdbId: Int
    let matchVi: String
    let views: Int?
    let rssNewestAt: String?

    var id: String { pid }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pid = try c.decode(String.self, forKey: .pid)
        title = try c.decode(String.self, forKey: .title)
        rawTitle = try c.decodeIfPresent(String.self, forKey: .rawTitle) ?? title
        channel = try c.decodeIfPresent(String.self, forKey: .channel) ?? ""
        tier = try c.decodeIfPresent(String.self, forKey: .tier) ?? ""
        eps = try c.decodeIfPresent([String].self, forKey: .eps) ?? []
        epTitles = try c.decodeIfPresent([String].self, forKey: .epTitles) ?? []
        tmdbId = try c.decodeIfPresent(Int.self, forKey: .tmdbId) ?? 0
        matchVi = try c.decodeIfPresent(String.self, forKey: .matchVi) ?? ""
        views = try c.decodeIfPresent(Int.self, forKey: .views)
        rssNewestAt = try c.decodeIfPresent(String.self, forKey: .rssNewestAt)
    }

    private enum CodingKeys: String, CodingKey {
        case pid, title, rawTitle, channel, tier, eps, epTitles
        case tmdbId, matchVi, views, rssNewestAt
    }

    /// Members tiers need the Gold session (design §1.6).
    var isMembersTier: Bool {
        tier == "gold" || tier == "vip" || tier == "members"
    }

    var isSuperVIP: Bool { tier == "vip" }

    /// The file's tier vocabulary in the app's words
    /// (design §1.1): gold → Gold, vip → Super VIP,
    /// members → Silver, free → Miễn phí.
    var tierLabel: String {
        switch tier {
        case "gold": return "Gold"
        case "vip": return "Super VIP"
        case "members": return "Silver"
        case "free": return "Miễn phí"
        default: return tier
        }
    }

    var channelDisplay: String {
        switch channel {
        case "TVB_Vietnam": return "TVB Vietnam"
        case "tvbtuyentapdacsac": return "TVB Tuyển Tập Đặc Sắc"
        case "tvb_kenhkinhdien": return "TVB Kênh Kinh Điển"
        case "tvblivecung": return "TVB Live Cùng"
        case "tvbduyentinh": return "TVB Duyên Tình"
        case "tvbsitcomvietnam": return "TVB Sitcom Vietnam"
        case "rapphimso9": return "Rạp Phim Số 9"
        default: return channel
        }
    }

    /// Tier-3 fallback art (2.0.47): the first episode's
    /// YouTube thumbnail, derived, never stored (design
    /// §1.1). JoeYtPosterResolver tries a real portrait
    /// poster first (TMDB by tmdbId, then a chain-catalogue
    /// poster borrowed by normalised title); this thumbnail
    /// is what a series keeps only when both legs miss.
    var posterURL: URL? {
        guard let first = eps.first, !first.isEmpty else { return nil }
        return URL(string: "https://i.ytimg.com/vi/\(first)/hqdefault.jpg")
    }

    var posterURLString: String { posterURL?.absoluteString ?? "" }

    /// epTitles is parallel to eps but a future file could
    /// carry it short; out-of-range reads answer "" and the
    /// caller falls back to "Tập N" (design §1.1).
    func epTitle(at index: Int) -> String {
        guard epTitles.indices.contains(index) else { return "" }
        return epTitles[index]
    }

    /// Rail ranking (owner ruling): views desc (nil last),
    /// rssNewestAt desc on ties, pid asc for determinism.
    static func rankBefore(_ a: JoeYtSeries, _ b: JoeYtSeries) -> Bool {
        let av = a.views ?? -1
        let bv = b.views ?? -1
        if av != bv { return av > bv }
        let ad = a.rssNewestAt ?? ""
        let bd = b.rssNewestAt ?? ""
        if ad != bd { return ad > bd }
        return a.pid < b.pid
    }
}

/// One display rail of the YouTube shelf (design §1.3 caps).
struct JoeYtRail: Sendable, Identifiable {
    let scope: String
    let title: String
    let series: [JoeYtSeries]
    var id: String { scope }
}

/// The published, immutable catalogue snapshot for this
/// process (design §1.2 item 4).
struct JoeYtSnapshot: Sendable {
    let generatedAt: String
    let series: [JoeYtSeries]
    let byPid: [String: JoeYtSeries]
    /// Fail-closed links, both directions (§1.4). One link
    /// per title: when several series pass the name test
    /// for one title, the collision resolves by the
    /// deterministic preference in build() — never silently
    /// by file order.
    let matchByTmdbId: [Int: JoeYtSeries]
    let matchedTitleByPid: [String: TVBTitle]
    /// How many titles had more than one passing series
    /// (for the load log line).
    let collisions: Int
    /// Rails in display order, caps applied, ranked.
    let rails: [JoeYtRail]

    static func build(file: JoeYtFile,
                      displayedTitles: [TVBTitle]) -> JoeYtSnapshot {
        let series = file.series
        var byPid: [String: JoeYtSeries] = [:]
        byPid.reserveCapacity(series.count)
        for s in series { byPid[s.pid] = s }

        // Fail-closed matching (design §1.4): tmdbId non-zero
        // AND a displayed snapshot title holds it AND the
        // normalised matched name (or cleaned title) equals
        // one of that title's names EXACTLY. (A duplicate id
        // in a future snapshot must fail soft, never trap —
        // the first title wins, as the tab's own loader does.)
        let titlesById = Dictionary(
            displayedTitles.map { ($0.tmdbId, $0) },
            uniquingKeysWith: { first, _ in first })
        // Collision resolution (review MAJOR, 2026-11-19):
        // 1,177 series pass the name test but they name only
        // 626 distinct titles — 416 titles have 2–4 passing
        // series (Gold / free / part uploads of one show),
        // and silent last-in-file wins was WRONG in measured
        // cases (a "…3" playlist surviving over the exact
        // base-title playlist on a matched-name pass; a
        // Super VIP surviving over a watchable Gold). The
        // winner is deterministic: a series whose OWN title
        // is exact beats one that passed only via its
        // matched name; then the tier the owner watches
        // best (Gold — his membership, the intact playlists
        // — then free, then Silver, Super VIP last); then
        // the rail rank. rankBefore ends in the unique pid,
        // so the order is total: every group has exactly
        // one well-defined winner.
        func tierRank(_ tier: String) -> Int {
            switch tier {
            case "gold": return 0
            case "free": return 1
            case "members": return 2
            case "vip": return 3
            default: return 4
            }
        }
        var candidatesById: [Int: [(series: JoeYtSeries, ownExact: Bool)]] = [:]
        for s in series where s.tmdbId != 0 {
            guard let title = titlesById[s.tmdbId] else { continue }
            let names = [title.titleVi, title.titleEn, title.titleOriginal]
                .map { Providers.normalizeTitle($0) }
            let ownNorm = Providers.normalizeTitle(s.title)
            let matchNorm = Providers.normalizeTitle(s.matchVi)
            let ownExact = !ownNorm.isEmpty && names.contains(ownNorm)
            let viaMatch = !matchNorm.isEmpty && names.contains(matchNorm)
            if ownExact || viaMatch {
                candidatesById[s.tmdbId, default: []]
                    .append((series: s, ownExact: ownExact))
            }
        }
        var matchByTmdbId: [Int: JoeYtSeries] = [:]
        var matchedTitleByPid: [String: TVBTitle] = [:]
        var collisions = 0
        for (tmdbId, candidates) in candidatesById {
            guard let title = titlesById[tmdbId] else { continue }
            if candidates.count > 1 { collisions += 1 }
            let winner = candidates.sorted { a, b in
                if a.ownExact != b.ownExact { return a.ownExact }
                let ta = tierRank(a.series.tier)
                let tb = tierRank(b.series.tier)
                if ta != tb { return ta < tb }
                return JoeYtSeries.rankBefore(a.series, b.series)
            }.first!
            matchByTmdbId[tmdbId] = winner.series
            matchedTitleByPid[winner.series.pid] = title
        }

        func rail(_ scope: String, _ title: String,
                  _ items: [JoeYtSeries], cap: Int) -> JoeYtRail? {
            guard !items.isEmpty else { return nil }
            return JoeYtRail(scope: scope, title: title,
                             series: Array(items.sorted(by: JoeYtSeries.rankBefore)
                                .prefix(cap)))
        }

        // Sony rail order, mirrored (design §1.3): Gold,
        // Super VIP, Silver, Free (main channel), then one
        // rail per sister channel.
        var rails: [JoeYtRail] = []
        if let r = rail("ytGold", "🏆 Gold · YouTube",
                        series.filter { $0.tier == "gold" }, cap: 120) {
            rails.append(r)
        }
        if let r = rail("ytVip", "👑 Super VIP · YouTube",
                        series.filter { $0.tier == "vip" }, cap: 60) {
            rails.append(r)
        }
        if let r = rail("ytSilver", "🥈 Silver · YouTube",
                        series.filter { $0.tier == "members" }, cap: 60) {
            rails.append(r)
        }
        if let r = rail("ytFree", "🆓 Miễn phí · YouTube",
                        series.filter {
                            $0.tier == "free" && $0.channel == "TVB_Vietnam"
                        }, cap: 120) {
            rails.append(r)
        }
        for channel in ["tvbtuyentapdacsac", "tvb_kenhkinhdien",
                        "tvblivecung", "tvbduyentinh",
                        "tvbsitcomvietnam", "rapphimso9"] {
            let items = series.filter { $0.channel == channel }
            guard let first = items.first else { continue }
            if let r = rail("ytSister:" + channel,
                            "📺 " + first.channelDisplay,
                            items, cap: 80) {
                rails.append(r)
            }
        }

        return JoeYtSnapshot(generatedAt: file.generatedAt,
                             series: series,
                             byPid: byPid,
                             matchByTmdbId: matchByTmdbId,
                             matchedTitleByPid: matchedTitleByPid,
                             collisions: collisions,
                             rails: rails)
    }
}

struct JoeYtFile: Codable, Sendable {
    let generatedAt: String
    let series: [JoeYtSeries]
}

/// Just the stamp of a JoeYtFile (claude/opt-1,
/// OPTIMIZATION-AUDIT item 3): buildFromDisk reads this from
/// both copies to choose one, then fully decodes only the
/// chosen copy. Any document that decodes as a JoeYtFile also
/// decodes as this (same required top-level String key).
private struct JoeYtFileStamp: Decodable, Sendable {
    let generatedAt: String
}

// MARK: - Poster resolution (2.0.47)
//
// The owner's order: YouTube/TVB series cards and the
// YouTube detail must show a REAL series poster like the
// chain-catalogue titles do, not episode 1's landscape
// thumbnail letterboxed into a portrait card. Resolution
// order for one series:
//   1. TMDB poster by the series' own tmdbId (when
//      non-zero) — JoeImagePipeline.tmdbPosterURL, which
//      rides TMDBClient.posterPath and caches the path
//      per identity for the session, negatives included,
//      so this leg never re-asks TMDB for a series it has
//      already answered.
//   2. A chain-catalogue poster borrowed by title: the
//      bundled TVB snapshot (TVBCatalog — the catalogue
//      the TP → KK → VS → F4K chain resolved) is indexed
//      by posterMatchKey, and a series whose cleaned
//      title or matched Vi name keys equal to a snapshot
//      title's Vi / TMDB-Vi / EN / original name borrows
//      that title's chain poster (its provider
//      posterFallback first, in TP → KK → VS → F4K order;
//      the title's own posterURLString behind it).
//      v2.0.49: the index also claims each "/"-separated
//      component of a combined chain title under its own
//      key, so one component alone can borrow the poster.
//   2.5 (v2.0.49). A TMDB SEARCH poster keyed on the
//      series' local title (TMDBClient.searchPoster) —
//      the leg for a series with tmdbId 0 (or a failed id
//      leg) and no chain poster, which previously had no
//      poster leg at all ("Hồ Sơ Trinh Sát II", VERDICT
//      §4). It IS a real portrait poster (source .tmdb).
//   3. Episode 1's YouTube thumbnail (the pre-2.0.47
//      behaviour, JoeYtSeries.posterURL).
// Every resolved result is cached per pid for the
// session (lock-guarded, the TVBSnapshotLookup idiom),
// so rails re-rendering never re-run a leg; the bitmap
// itself always loads through JoeImagePipeline — this
// resolver only ever hands out URLs, never images.

struct JoeYtResolvedPoster: Sendable {
    enum Source: Sendable {
        case tmdb
        case chain
        case youtubeThumbnail
    }

    let url: URL?
    let source: Source

    /// True for the two real-poster legs: their slots gate
    /// on .portrait and fit the whole poster. The thumbnail
    /// leg is landscape art and keeps the .any slot.
    var isPortraitPoster: Bool { source != .youtubeThumbnail }
}

enum JoeYtPosterResolver {
    private static let lock = NSLock()
    // Swift 6: nonisolated(unsafe) — every access is
    // serialized by lock; the published chain index is an
    // immutable map of immutable bundled data.
    private nonisolated(unsafe) static var resolvedByPid: [String: JoeYtResolvedPoster] = [:]
    private nonisolated(unsafe) static var chainIndex: [String: TVBTitle]?

    /// The poster-match key for one title: the app's one
    /// normalisation (Providers.normalizeTitle — lowercase,
    /// diacritics stripped, non-alphanumeric runs collapsed)
    /// plus a trailing 4-digit year token dropped, applied
    /// IDENTICALLY to the series side and the catalogue
    /// side. Chain titles are stored both with and without
    /// a year suffix across the catalogues, so the year is
    /// not part of a poster's identity key; a title that is
    /// ONLY a year keeps its normalised form (the drop
    /// requires at least one other token).
    static func posterMatchKey(_ raw: String) -> String {
        let normalized = Providers.normalizeTitle(raw)
        var tokens = normalized.split(separator: " ").map(String.init)
        if tokens.count > 1, let last = tokens.last, last.count == 4,
           last.allSatisfy({ $0.isNumber }), let year = Int(last),
           (1950...2035).contains(year) {
            tokens.removeLast()
        }
        let joined = tokens.joined(separator: " ")
        return joined.isEmpty ? normalized : joined
    }

    /// The chain index: posterMatchKey → snapshot title.
    /// Displayed titles are indexed first (a displayed
    /// title's chain poster is provider-verified art), then
    /// the rest of the spine; the first title to claim a
    /// key keeps it — collisions never overwrite.
    private static func chainPosterIndex() -> [String: TVBTitle] {
        lock.lock()
        if let chainIndex {
            lock.unlock()
            return chainIndex
        }
        lock.unlock()
        // Built outside the lock; racing builders build
        // identical maps from the same immutable file, and
        // the first publisher wins (TVBSnapshotLookup.maps
        // idiom).
        var index: [String: TVBTitle] = [:]
        if let catalog = TVBCatalogStore.load() {
            let ordered = catalog.titles.filter { $0.isDisplayed }
                + catalog.titles.filter { !$0.isDisplayed }
            // v2.0.49: two claim passes (gate R1, lens B).
            // Pass 1 claims every name field WHOLE, exactly
            // as before. Pass 2 claims each "/"-separated
            // COMPONENT under its own key, into still-
            // unclaimed slots only — a combined chain title
            // ("Ỷ Thiên Đồ Long Ký / Cô Gái Đồ Long") thus
            // also answers a lookup for one component alone
            // ("co gai do long", VERDICT §4), while a title
            // whose WHOLE name equals that component keeps
            // its own poster (pass 1 already claimed it).
            // First-claim-wins within each pass.
            for pass in 0...1 {
                for title in ordered {
                    for name in [title.titleVi, title.titleViTmdb,
                                 title.titleEn, title.titleOriginal] {
                        let fields: [String] = pass == 0
                            ? [name]
                            : name.split(separator: "/")
                                .map { $0.trimmingCharacters(in: .whitespaces) }
                                .filter { !$0.isEmpty }
                        for field in fields {
                            let key = posterMatchKey(field)
                            if !key.isEmpty, index[key] == nil {
                                index[key] = title
                            }
                        }
                    }
                }
            }
        }
        lock.lock()
        if chainIndex == nil { chainIndex = index }
        let published = chainIndex ?? index
        lock.unlock()
        return published
    }

    /// v2.0.49: the series' year for the TMDB search leg —
    /// the first 4-digit run in its local title, else in
    /// its matched Vi name (Providers.yearOf); "" when
    /// neither carries one (the search leg then treats the
    /// year as unknown and its year guard stays open).
    private static func seriesYear(_ series: JoeYtSeries) -> String {
        let fromTitle = Providers.yearOf(series.title)
        return fromTitle.isEmpty ? Providers.yearOf(series.matchVi) : fromTitle
    }

    /// Tier 2 alone (synchronous, no network): the chain
    /// poster a series borrows by normalised title, or nil.
    /// The borrowed art is the matched title's provider
    /// posterFallback in TP → KK → VS → F4K priority order
    /// (the chain's own CDN art); behind it, the title's
    /// posterURLString (its TMDB path, when the snapshot
    /// carries one and no provider poster exists).
    static func chainPoster(for series: JoeYtSeries) -> URL? {
        let index = chainPosterIndex()
        guard !index.isEmpty else { return nil }
        for candidate in [series.title, series.matchVi] {
            let key = posterMatchKey(candidate)
            guard !key.isEmpty, let title = index[key] else { continue }
            for providerKey in TVBTitle.priorityKeys {
                if let fallback = title.providers[providerKey]?.posterFallback,
                   !fallback.isEmpty, let url = URL(string: fallback) {
                    return url
                }
            }
            if let url = title.posterURL { return url }
        }
        return nil
    }

    /// The full fallback chain for one series, cached per
    /// pid. Tier 1 rides the pipeline's TMDB poster leg
    /// (TMDBClient.posterPath underneath, path cached per
    /// identity including negatives); tier 2 is the local
    /// chain index; tier 2.5 (v2.0.49) is the TMDB search
    /// leg, run when the id leg is absent/failed AND the
    /// chain leg missed; tier 3 is the episode-1
    /// thumbnail. Fail-soft: a failed search leg falls
    /// through to the thumbnail exactly as before.
    static func resolve(_ series: JoeYtSeries) async -> JoeYtResolvedPoster {
        if let hit = lock.withLock({ resolvedByPid[series.pid] }) {
            return hit
        }
        let resolved: JoeYtResolvedPoster
        if series.tmdbId > 0,
           let tmdbURL = await JoeImagePipeline.shared.tmdbPosterURL(
               tmdbId: String(series.tmdbId), type: "tv") {
            resolved = JoeYtResolvedPoster(url: tmdbURL, source: .tmdb)
        } else if let chainURL = chainPoster(for: series) {
            resolved = JoeYtResolvedPoster(url: chainURL, source: .chain)
        } else if let searchURL = await TMDBClient.searchPoster(
            name: series.title,
            year: seriesYear(series)),
           let searchPosterURL = URL(string: searchURL) {
            // v2.0.49: a real TMDB poster found by search —
            // source .tmdb, so isPortraitPoster stays true.
            resolved = JoeYtResolvedPoster(url: searchPosterURL, source: .tmdb)
        } else {
            resolved = JoeYtResolvedPoster(url: series.posterURL,
                                            source: .youtubeThumbnail)
        }
        lock.withLock {
            if resolvedByPid[series.pid] == nil {
                resolvedByPid[series.pid] = resolved
            }
        }
        return resolved
    }
}

// MARK: - Store

/// Loads and publishes the YouTube catalogue snapshot once
/// per process (FollowStore.shared is the house idiom for
/// this shape). All file/network work happens off the main
/// actor; the snapshot is published whole, then immutable.
@MainActor
final class JoeYtStore: ObservableObject {
    static let shared = JoeYtStore()

    @Published private(set) var snapshot: JoeYtSnapshot?
    private var loadStarted = false

    static let hostedURL = URL(
        string: "https://raw.githubusercontent.com/zjoenguyenz/dabanh-playlist/main/tvb-yt.json")!

    private init() {}

    /// Idempotent: the first caller starts the load; later
    /// calls (tab re-entries, the detail screen) are no-ops.
    func ensureLoaded() {
        guard !loadStarted else { return }
        loadStarted = true
        Task { await self.load() }
    }

    private func load() async {
        let built = await Task.detached(priority: .userInitiated) {
            Self.buildFromDisk()
        }.value
        guard let built else {
            DiagLog.write("YT", "catalogue load failed (no cache, no bundle)")
            return
        }
        snapshot = built.snapshot
        DiagLog.write("YT", "catalogue loaded generatedAt=\(built.snapshot.generatedAt) series=\(built.snapshot.series.count) matched=\(built.snapshot.matchByTmdbId.count) collisions=\(built.snapshot.collisions) source=\(built.fromCache ? "cache" : "bundle")")
        // Warm the first rails' posters through the existing
        // pipeline (the JoeTVBView launch-prefetch pattern),
        // resolving each series through the 2.0.47 poster
        // chain first (TMDB / chain / thumbnail) so the warm
        // set is the art the cards will actually paint — and
        // so the per-card resolves land on warm caches.
        let warmSeries = Array(built.snapshot.rails.prefix(2)
            .flatMap { $0.series.prefix(30) })
        Task {
            let warmURLs = await withTaskGroup(of: URL?.self) { group in
                for warm in warmSeries {
                    group.addTask {
                        await JoeYtPosterResolver.resolve(warm).url
                    }
                }
                var urls: [URL] = []
                for await url in group {
                    if let url { urls.append(url) }
                }
                return urls
            }
            JoeImagePipeline.shared.prefetch(warmURLs, targetPixels: 720)
        }
        // The "living" leg (design §1.2 item 3): one
        // background refresh per process when the loaded copy
        // is over 24 h old. It writes the cache ONLY; this
        // process's snapshot never changes under its readers.
        if built.isStale {
            Task { await self.refreshCache() }
        }
    }

    // MARK: Disk + refresh (detached helpers)
    //
    // These four are `nonisolated` on purpose: the class is
    // @MainActor (its @Published snapshot demands it), but
    // buildFromDisk runs inside Task.detached — under Swift 6
    // a @MainActor class isolates its statics too, so without
    // the marker the detached call is a compile error (review
    // round 1, BLOCKER). Everything they touch is Foundation
    // value work plus the nonisolated JoeYtSnapshot.build /
    // TVBCatalogStore.load — no actor state.

    /// FIX-214 (Fault 10 / FL-421): the cache lives in
    /// the shared Caches home (JoeStorage) — the tvOS
    /// sandbox refuses to create Application Support,
    /// which is why every refresh write failed through
    /// 2.1.3 and the catalogue could never update past
    /// the bundled copy (see JoeStorage.swift for the
    /// conviction).
    private nonisolated static var cacheURL: URL {
        JoeStorage.fileURL("tvb_yt_cache.json")
    }

    private nonisolated static func decodeFile(_ data: Data) -> JoeYtFile? {
        try? JSONDecoder().decode(JoeYtFile.self, from: data)
    }

    private nonisolated static func decodeStamp(_ data: Data) -> String? {
        (try? JSONDecoder().decode(JoeYtFileStamp.self, from: data))?.generatedAt
    }

    private nonisolated static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    /// Cache wins when its generatedAt is at least the
    /// bundled copy's; an unparseable generatedAt never beats
    /// a parseable one, and a copy that fails to decode is
    /// simply not a candidate (fail-closed, design §1.2).
    private nonisolated static func buildFromDisk()
        -> (snapshot: JoeYtSnapshot, fromCache: Bool, isStale: Bool)? {
        let bundledData = Bundle.main.url(forResource: "tvb-yt",
                                          withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
        let cacheData = try? Data(contentsOf: cacheURL)

        // claude/opt-1 (OPTIMIZATION-AUDIT item 3): pre-fix both
        // ~6.9 MB copies were FULLY decoded (and held at once)
        // only to compare their stamps. Now the stamps are read
        // first, the copies are ordered by exactly the old rule
        // (cache wins ties; an unparseable stamp sorts as
        // distantPast), and only the preferred copy is fully
        // decoded. If it fails to decode, the other copy is
        // tried — the old "a copy that fails to decode is not a
        // candidate" outcome — so the chosen file is the same
        // in every case.
        var candidates: [(data: Data, fromCache: Bool)] = []
        let bundledStamp = bundledData.flatMap { decodeStamp($0) }
        let cachedStamp = cacheData.flatMap { decodeStamp($0) }
        switch (bundledData, bundledStamp, cacheData, cachedStamp) {
        case let (b?, bs?, c?, cs?):
            let bd = parseDate(bs) ?? .distantPast
            let cd = parseDate(cs) ?? .distantPast
            if cd >= bd {
                candidates = [(c, true), (b, false)]
            } else {
                candidates = [(b, false), (c, true)]
            }
        case let (b?, _?, _, nil):
            candidates = [(b, false)]
        case let (_, nil, c?, _?):
            candidates = [(c, true)]
        default:
            return nil
        }
        var chosen: JoeYtFile?
        var fromCache = false
        for candidate in candidates {
            if let file = decodeFile(candidate.data) {
                chosen = file
                fromCache = candidate.fromCache
                break
            }
        }
        guard let file = chosen else { return nil }
        let displayed = TVBCatalogStore.load()?
            .titles.filter { $0.isDisplayed } ?? []
        let snapshot = JoeYtSnapshot.build(file: file,
                                           displayedTitles: displayed)
        let stamp = parseDate(file.generatedAt) ?? .distantPast
        let isStale = Date().timeIntervalSince(stamp) > 24 * 3600
        return (snapshot, fromCache, isStale)
    }

    /// Fetches the hosted copy; replaces the cache only when
    /// its generatedAt is STRICTLY newer than the loaded
    /// snapshot's (an unparseable stamp never replaces
    /// anything — design §1.2 item 3). The decode + write of
    /// the 6.7 MB file run in a detached task (review MINOR,
    /// 2026-11-19): this class's contract is that file work
    /// happens OFF the main actor — a synchronous decodeFile
    /// call from here would execute inline on the main actor
    /// and hitch the UI.
    private func refreshCache() async {
        guard let current = snapshot else { return }
        let data: Data
        do {
            let (fetched, _) = try await URLSession.shared.data(from: Self.hostedURL)
            data = fetched
        } catch {
            DiagLog.write("YT", "refresh failed (network) — keeping loaded copy")
            return
        }
        let currentStamp = current.generatedAt
        let outcome = await Task.detached(priority: .utility) { () -> String in
            guard let file = Self.decodeFile(data) else {
                return "rejected"
            }
            let newStamp = Self.parseDate(file.generatedAt) ?? .distantPast
            let oldStamp = Self.parseDate(currentStamp) ?? .distantPast
            guard newStamp > oldStamp else {
                return "notNewer"
            }
            // FIX-214 (Fault 10 / FL-421): directory
            // creation and the write are attributed
            // SEPARATELY — through 2.1.3 they shared one
            // do/catch logged as "(cache write)", but
            // DiagLog 17 line 185's error text names the
            // DIRECTORY ("Application Support"), not the
            // file: the sandbox refused the create, and
            // the 2.1.3 fix (create the directory first)
            // aimed at exactly the denied operation. The
            // directory is JoeStorage's Caches home,
            // created + write-tested by its launch probe;
            // this create is a cheap re-ensure whose
            // failure now logs as what it is.
            do {
                try FileManager.default.createDirectory(
                    at: Self.cacheURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true)
            } catch {
                return "dirFailed \(error.localizedDescription)"
            }
            do {
                try data.write(to: Self.cacheURL, options: .atomic)
                return "cached|\(file.generatedAt)|\(data.count)|\(Self.cacheURL.path)"
            } catch {
                return "writeFailed \(error.localizedDescription)"
            }
        }.value
        switch outcome {
        case "rejected":
            DiagLog.write("YT", "refresh rejected (decode failed)")
        case "notNewer":
            DiagLog.write("YT", "refresh skipped (hosted not newer)")
        case _ where outcome.hasPrefix("dirFailed"):
            // FIX-214 (Fault 10): a directory failure is
            // a DIFFERENT fault from a write failure and
            // logs as one — the shared "(cache write)"
            // label is what let the 2.1.3 fix aim at the
            // wrong operation.
            DiagLog.write("YT", "refresh failed (cache dir) — \(outcome.dropFirst(10)) — keeping loaded copy")
        case _ where outcome.hasPrefix("writeFailed"):
            // v2.1.1 (WS-E): the line now carries the write
            // error itself (see the catch in the task above).
            DiagLog.write("YT", "refresh failed (cache write) — \(outcome.dropFirst(12)) — keeping loaded copy")
        default:
            // FIX-214 (Fault 10): the proof line — bytes
            // + the Caches path + the new stamp, so the
            // next log convicts the fix: the following
            // launch must load source=cache with this
            // generatedAt (newer than the bundle's).
            let parts = outcome.split(separator: "|", maxSplits: 3)
            if parts.count == 4 {
                DiagLog.write("YT", "refresh cached bytes=\(parts[2]) path=\(parts[3]) generatedAt=\(parts[1]) (applies next launch)")
            } else {
                DiagLog.write("YT", "refresh cached generatedAt=\(outcome.dropFirst(7)) (applies next launch)")
            }
        }
    }
}

// MARK: - Search

/// The YouTube half of the TVB tab's search (design §1.3):
/// the rail caps are display caps only — every series in the
/// file is searchable, so a beyond-cap Gold series is never
/// orphaned (the Sony X-1 gap, closed by design here).
/// Ranking mirrors JoeTVBSearchView's tiers over
/// Providers.normalizeTitle: exact, then prefix, then
/// contains; rank order (views desc) inside each tier.
enum JoeYtSearch {
    static func ranked(query: String, series: [JoeYtSeries]) -> [JoeYtSeries] {
        let q = Providers.normalizeTitle(query)
        guard !q.isEmpty else { return [] }
        var exact: [JoeYtSeries] = []
        var prefix: [JoeYtSeries] = []
        var contains: [JoeYtSeries] = []
        for s in series {
            let keys = [s.title, s.matchVi]
                .map { Providers.normalizeTitle($0) }
                .filter { !$0.isEmpty }
            if keys.contains(q) {
                exact.append(s)
            } else if keys.contains(where: { $0.hasPrefix(q) }) {
                prefix.append(s)
            } else if keys.contains(where: { $0.contains(q) }) {
                contains.append(s)
            }
        }
        let byRank = { (a: JoeYtSeries, b: JoeYtSeries) in
            JoeYtSeries.rankBefore(a, b)
        }
        return Array((exact.sorted(by: byRank)
                      + prefix.sorted(by: byRank)
                      + contains.sorted(by: byRank)).prefix(90))
    }
}
