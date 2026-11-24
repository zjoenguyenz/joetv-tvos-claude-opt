# OPTIMIZATION AUDIT — JoeTV tvOS (baseline `main` @ 01db0f0)

Scope: read-only audit of the whole JoeTV target against CLAUDE.md and
HOW-IT-WORKS.md. Every line reference is to `main` @ 01db0f0. No code was
changed on this branch.

**Tooling caveat, stated first:** the audit environment is Linux with no
Swift toolchain, no Xcode and no Apple TV. Nothing here was compiled or run
on device. Evidence is code reading plus host-side models (Python) where a
model is meaningful; each item says which.

---

## 1. Map of the app

| Layer | Files (lines) | What it does |
|---|---|---|
| Entry / shell | `JoeTVApp.swift` (1587) | `@main` app; installs `URLCache.shared` (16–64 MB mem / 512 MB disk, `:27-42`); `JoeRootView` shell with the tab bar (`Section` enum, TV last, `:94-120`); root exit-command chain (`:563-588`); `LaunchGate` (connection probe → catalogue → detached poster preload, `:1366-1515`); app-open hooks (follow re-check, match reminders, `:1021-1070`). |
| Networking | `JoeHTTP.swift` (262) | One shared data session (6/host, `waitsForConnectivity`), per-call deadline race, metrics → `PerfLog`. |
| Shared data repos | `JoeTrendingFile.swift`, `JoeYtCatalog.swift`, `JoeTVB.swift` | `trending.json` and `tvb-yt.json` pulled from `dabanh-playlist` at launch (`JoeTrendingFile.swift:55`, `JoeYtCatalog.swift:531`); bundled snapshots `tvb-yt.json` (6.9 MB) and `tvb-catalog.json` (2.0 MB) as fallbacks. |
| Metadata | `TMDBClient.swift` (735) | TMDB backbone (posters, backdrops, cast, trending). |
| Film sources | `Providers.swift` (1128) + `KkClient`, `F4kClient`, `TpClient`, `VsClient`, `CacheVideo` | Per-source clients; `Providers` merges, dedupes, builds play ladders, finds alternatives (`:851-897`), memoises resolves. |
| Source health | `SourceHealth.swift` (613), `SourceProbe.swift` (172) | Per (provider × stage × host) EWMA + timeout latch; `SourceHealth.run` budget race wraps every measured call (`:251-291`). |
| Image pipeline | `JoeImagePipeline.swift` (1081) | Own URLSession (8/host), in-flight dedupe, size buckets, ImageIO thumbnail decode + libwebp, decoded `NSCache` (48–120 MB), bounded prefetch (3 workers), hedged primary/fallback resolve (`JoeRemoteImage`), band layers (`JoeBandImage`). |
| Screens / themes | `JoeHomeScreen` (3717), `JoePhimHome` (4269), `JoeMovieDetail` (5825), `JoeTorrent` (3116), `JoeTVB` (2471), `JoeActorPage`, `JoeSearch`, `JoeBrowse`, `JoePrivateCinema`, `JoeTVSection`, `JoeSettings`, `JoeTheme` (1870) | Themes `billboard / posterWall / sourceBoard / ultra / …` (`JoeTheme.swift:16`), each its own code path. |
| Playback | `JoePlayerView.swift` (3344), `JoeKSPlayerView.swift` (2301), `JoeStreamWarmer.swift`, `JoeProxy.swift` | AVPlayer house player + `PlayDirector` failover; KSPlayer for the torrent/MKV path; detail-dwell warm of the first KK item. |
| Torrent / debrid | `TorrentClient.swift` (1735), `JoeTorrent.swift` | Torrentio / MediaFusion / debrid resolution (tokens from build-time placeholders, none in repo). |
| TVB YouTube | `JoeYt*.swift` (~7.6k lines), `JoeWebBridge.m` | Catalogue, native resolver + HLS server, preview quality map. |
| Diagnostics | `JoeDiagLog.swift` (911) | File log + LAN export server + QR (`DiagLogServer`). |

## 2. Where HOW-IT-WORKS.md disagrees with the code (code wins)

1. **Focus rendering.** HOW-IT-WORKS §"Build & delivery" says focus is
   rendered by the OS and the app must never draw a second focus layer.
   The code does the opposite by design: `.joeCardButton()` installs a
   custom `ButtonStyle` and `.focusEffectDisabled()` (`JoeTheme.swift:884`,
   `:1011`, notes at `:1055-1074`), the root comment states "the system
   .card style and its platter are GONE … the app's drawn rings"
   (`JoeTVApp.swift:632-640`), and cards paint their own ring from
   `\.isFocused` (e.g. `JoeCastCellLabel`, `JoeMovieDetail.swift:3332-3366`).
   This audit touches no focus surface either way; the leader should
   reconcile the document.
2. **Player engine.** HOW-IT-WORKS §4 says playback uses the KSPlayer-based
   view for both normal and torrent streams. Code: normal streams play on
   AVPlayer (`JoePlayerView.swift:30`, `JoeStreamWarmer.swift`), KSPlayer
   only for the torrent/MKV path (`JoePlayerView.swift:2138`, README).
3. **Source health granularity.** HOW-IT-WORKS §4 says health is remembered
   per-URL. Code keys it per provider × stage × host (`SourceHealth.swift:23-36`,
   `hostKey(for:)` `:155-175`).
4. **Updatable content in the build.** HOW-IT-WORKS §1 says updatable
   content must not be embedded. The build bundles `tvb-yt.json` (6.9 MB)
   and `tvb-catalog.json` (2.0 MB) as fail-safe snapshots alongside the
   launch pull (`project.yml` sources; `JoeYtCatalog.swift:622-658`). This
   is fallback data, not the primary source, but it is embedded.
5. **Target OS.** HOW-IT-WORKS says target tvOS 27.x; `project.yml` sets
   deployment target tvOS 17.0 (the device runs 27.x; the build floor is 17).

## 3. The 10 highest-impact opportunities (impact order)

Impact = how often the path runs × how much it costs × how visible it is.
Each item ends with a verdict for the implementation round.

### 1. Race-wait loops poll on a fixed sleep instead of waking on the outcome
Every "first outcome wins" race in the source/poster stack waits by
sleeping a fixed interval and re-checking a box:
- `SourceHealth.run` — `SourceHealth.swift:271-290`, 25 ms. Wraps every
  measured detail/resolve/playlist/list call — the player-start chain.
- KK host race — `KkClient.swift:139-148`, 50 ms. Every KKPhim call.
- Poster resolve — `JoeImagePipeline.swift:808-811`, 50 ms. Every
  `JoeRemoteImage` appearance.
- `Providers.findAlternatives` — `Providers.swift:886-889`, 100 ms. The
  alternatives search used by detail + failover.
- `SourceProbe.probeKK` — `SourceProbe.swift:94-112`, 50 ms. Launch gate
  phase 1.
- Private Cinema backdrop — `JoePrivateCinema.swift:672-675`, 50 ms.

Cost: an outcome that has already landed is noticed up to one interval
late (mean ≈ half). Host model (`docs/opt-bench/poll_vs_wake.py`, 300
trials per site): mean detection delay 13 ms (25 ms loop), 25 ms (50 ms
loops), 50 ms (100 ms loop); p95 ≈ the full interval. A play start chains
several `SourceHealth.run` stages plus a KK race serially, so the delay
adds up on the exact path HOW-IT-WORKS protects.
All six boxes decide the winner at **publication** (first write wins
inside the box), so waking the waiter early cannot change any outcome.
**NOT included:** the player failover hedge `JoePlayerView.swift:1280-1302`
decides its winner at **poll** time ("on a simultaneous landing the
incumbent wins" within a tick) — earlier wake-ups could change which
ladder wins the dead-link rescue. Also excluded: `PhimStore` consume loop
(`JoeStores.swift:269-280`, its 100 ms tick batches UI publishes) and the
launch-gate progress loops (`JoeTVApp.swift:1391`, `:1405`, they publish
progress per tick).
**Verdict: implement** (a bounded wake signal: sleep up to the same
interval, return early when the box publishes).

### 2. Warm posters still run the full hedged race on every appearance
`JoeRemoteImage.task(id:)` (`JoeImagePipeline.swift:747-750`) always calls
`resolve()` (`:775-819`), even when the decoded cache already holds an
accepted bitmap (which `shown`, `:721-729`, is already painting). Per warm
card appearance that is 2 unstructured tasks (primary + 5 s hedge), ≥ 1
poll sleep (the loop checks `settled` before the primary task has run),
~8 lock round-trips, and a hedge task kept alive until cancelled — on the
main actor, for every card scrolled back into view on every rail.
The outcome is fixed: `image(for:)` returns the cache hit at `:166`, the
primary leg accepts it, the box settles with leg "primary".
**Verdict: implement** a synchronous fast path that returns that same
bitmap and writes the same `leg=primary` log line.

### 3. TVB YouTube catalogue decoded twice at load
`JoeYtStore.buildFromDisk` (`JoeYtCatalog.swift:622-658`) fully decodes
BOTH the bundled 6.9 MB `tvb-yt.json` and the cache copy (same size),
only to compare their `generatedAt` stamps, keeping both 1 873-series
models resident at once. Every launch after the first refresh in an
install hits the two-copy path. Host proxy (`docs/opt-bench/ytdecode.py`,
Python `json` as a stand-in): peak traced memory 59.5 MB (two models)
vs 41.7 MB (one model + stamp scans), −30 %.
**Verdict: implement** stamp-first (decode `{generatedAt}` of both, pick by
the same rule, fully decode only the chosen copy, fall back to the other
if it fails — identical selection outcome).

### 4. Catalogue refresh decodes the hosted 6.9 MB copy just to compare stamps
`refreshCache` (`JoeYtCatalog.swift:670-690`) fully decodes the downloaded
copy before checking whether it is newer; on most launches it is not
("notNewer"), so the decode is thrown away. Off-main (utility task), so it
costs CPU/memory beside the home's poster loads, not a hitch.
Stamp-first here would change which log word an invalid-but-not-newer
file produces ("rejected" vs "notNewer").
**Verdict: skip this round** (diagnostic-log wording change; needs the
leader's OK).

### 5. Diagnostic log does heavy per-line work on the calling thread
`DiagLog.write` (`JoeDiagLog.swift:124-139`) builds a new `DateFormatter`
per line (`:321-326`, comment says "writes are rare" — no longer true:
`[focus]` lines fire on every focus step, `[IMG]`, `[stall]`, `[play]`…,
135 call sites) and does `fileExists` + open + seek + write + close per
line (`:274-286`) under one global lock, from whatever thread calls —
including the main actor.
**Verdict: implement** the formatter cache (same locale, format and
auto-updating time zone → byte-identical lines). Keeping a persistent
file handle: **skip** (rotation and the export server read the same file;
low gain for the risk to a protected feature).

### 6. Launch gate runs the connection probe strictly before the catalogue load
`LaunchGate.execute` (`JoeTVApp.swift:1386-1396`) waits for all 4 probe
answers (up to the probe caps) before `phim.loadIfNeeded()` (`:1405`).
Overlapping them would cut cold start by roughly the probe time, but the
serial order is the owner's fix for the 2.0.21 cold-start disease
(`:1318-1340`: the probe warms the Providers raw memo the load reads).
**Verdict: skip** (behaviour/ordering change on an owner-approved flow).

### 7. URL-cache memory tier duplicates the decoded poster cache
`URLCache.shared` keeps up to 64 MB of compressed bodies in memory
(`JoeTVApp.swift:37-42`) while the pipeline keeps up to 120 MB of decoded
bitmaps (`JoeImagePipeline.swift:87-92`); for posters the compressed copy
is only needed when the decoded one is evicted, and the 512 MB disk tier
already serves that. Lowering it is a memory win on the 3 GB floor box.
**Verdict: skip** (a tuning change whose effect on re-scroll latency must
be measured on device first).

### 8. Per-render cache probing in band layers
`JoeBandImage.image` (`JoeImagePipeline.swift:1021-1023`) calls
`cachedImageAnySize` (`:120-128`) on every body evaluation until its load
lands: 6 key-string builds + 6 `NSCache` lookups per render of the detail
band / hero.
**Verdict: skip** (small; fixing it means caching the peek in `@State`,
which changes first-frame timing of a protected surface).

### 9. Cast rows are eager `HStack`s inside horizontal scroll views
`JoeMovieDetail.swift:3300-3306` and `JoeTorrent.swift:2684-2688` build
every cast cell (and start every photo load) when the detail opens.
**Verdict: skip** (switching to `LazyHStack` changes focus traversal and
layout timing on the detail page — design/focus territory).

### 10. Dead and duplicated code
- `JoeNavigator.closeTop()` (`JoeTVApp.swift:229-238`) — no callers; a
  stale duplicate of the root exit chain (`:563-588`), and already out of
  step with it (it does not know `browseOpen`).
- `Providers.kkGenre` (`Providers.swift:225`) — no callers.
- `League` (`DaBanh/Channel.swift:42`) and `LeagueClassifier.isEN`
  (`DaBanh/LeagueClassifier.swift:106`) — no callers, but these are files
  shared with the Đá Banh app.
- `JoeHomeScreen.swift` is a 99 % line-for-line copy of `JoePhimHome.swift`
  (3 682 of 3 717 lines match, `difflib`) — deliberate per owner ruling
  (`JoeHomeScreen.swift:3-21`).
**Verdict: implement** removal of `closeTop` and `kkGenre`; **skip** the
DaBanh files (shared-file drift) and the home duplication (owner ruling).

## 4. What looked hot but is already handled
- Poster decode is already a downsampled ImageIO thumbnail / scaled libwebp
  decode; prefetch is bounded (3 workers, 10 per rail, paused behind
  visible loads); visible loads dedupe in flight.
- Player start already pre-resolves on detail dwell, memoises resolves and
  warms the first KK item (`Providers.preResolve`, `JoeStreamWarmer`).
- The bundled TVB catalogue decode is already latched once per process
  (`JoeTVB.swift:54-80`).
- `JoeHTTP` already uses one shared session with per-call deadlines.
