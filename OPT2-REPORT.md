# OPT2 REPORT — claude/opt-2-ui-lag (baseline main = c2a38504 + docs)

> **Nothing in this branch has been compiled or run.** This environment has
> no Swift toolchain, no Xcode and no Apple TV. All Swift was written and
> reviewed by hand against Swift 6 language mode and tvOS 17 deployment. The
> first compile is the leader's CI. Every behaviour/timing claim below says how
> it was checked (code reading, host model, pixel measurement of the drawings).
> Design gate first: §3 is the per-screen declaration. Nothing in it is
> self-passed; every deviation is listed for the separate design team.

Sources used: RECALC-SPEC.md + DEMO/TRIAL renders (joetv-pc-recalc-20261122.zip)
for every Private Cinema (PC) screen; joetv-designs-flat.zip (A–F) for the
legacy themes (A = billboard, D = posterWall, F = sourceBoard; B/C/E were
never built). Ultra has **no drawing in either pack**.

This PR **supersedes PR #1** (its five code commits and the round-1 audit
are carried here unchanged, so one build gets everything). PR #1 can be
closed unmerged.

---

## 1. The seven faults — status

| # | Fault | Status | What changed (file) | Verification |
|---|---|---|---|---|
| 1 | FL-448 frame cut / horizontal stretch (Settings root PC + PC bar) | **Mechanism candidate + instrumentation, no geometry change** | `JoeTVApp.swift` JoePCWidthProbe on the PC shell's content + bar | Static. Device log `[LAYOUT] PC … width=` convicts/clears |
| 2 | FL-422 focus still fills | **Fixed + swept** | PillLabel, JoeChipLabel ×2, PCCategoryRowLabel, PCNavLabel, epChip, YT ep chip, torrent ep rows, PC fav/follow | Code reading; sweep table §4 |
| 3 | FL-427 text over backdrop, pinned state | **Fixed (pinned); torrent "missing compensation" not reproduced** | `JoePrivateCinema.swift` JoePCPinnedBandCover on all 4 strips | Measured deep render; rest/pinned on device unverified |
| 4 | FL-447 heavy lag | **R1 reduced (39 → 12 builds/step), R2, R4 fixed; R3/R5/R6 kept (reasons §2)** | Providers, JoeHomeScreen, JoePhimHome, JoeTVB, JoePrivateCinema | Host models (§2) |
| 5 | FL-457 backdrop cut | **Fixed: full-screen page backdrop on Trang chủ, Phim, TVB, Torrent (+ HomeTVBFocus form)** | JoePrivateCinema (JoeCinemaPageBackdrop), 4 homes | Code reading; device look unverified |
| 6 | FL-448 family, Ngôn ngữ & phụ đề pane | **Same mechanism candidate; covered by the Fault 1 probe** | — | Device log |
| 7 | FL-423 debrid pane double frame | **Fixed + Settings swept** | `JoeTheme.swift` JoeSettingsFieldChrome (PC leg) | Code reading; sweep §4 |

### Fault 1 / 6: mechanism (candidate, with evidence)
- The PC shell is **one `ZStack(alignment: .top)`** holding the section
  content and the bar (`JoeTVApp.swift` shellStack, main :655-663).
- The content's `.frame(maxWidth: .infinity, maxHeight: .infinity)` **does not
  cap** a child whose ideal width exceeds the proposal. One over-wide child
  widens the content frame and therefore the shared ZStack, and the shell
  centres the result:
  - corners of the content fall off **both** edges;
  - the bar (sized to the ZStack) spreads its corner wordmark and clock
    off-screen while the centred nav stays put;
  - vertical geometry is untouched.

  That is exactly "≈1.6–1.9× horizontal, vertical ≈ spec, corner elements
  out of frame" on Settings **and** the bar together.
- Excluded by evidence:
  - no `UIScreen`/native-scale reads;
  - no anisotropic transforms (the only `CGAffineTransform` is the QR's
    uniform ×12);
  - no rasterisation (`drawingGroup`/`ImageRenderer`);
  - the bundled fonts are static instances with normal width class
    (usWidthClass 5, xAvg/upm 0.42–0.59), and every `JoePCType` name
    matches a PostScript name;
  - no `fixedSize` anywhere in `JoeSettings.swift`;
  - no fixed frame ≥ 1760 in layout (the only 1920 frame is this PR's band
    cover, which is a background and takes no layout).
- I did **not** find the over-wide child statically. Per the brief, no blind
  fix. The probe logs one `[LAYOUT]` line per off-canvas width (surface,
  section). One device run on Settings (Giao diện and Ngôn ngữ & phụ đề)
  convicts or clears it.

### Fault 3: what the code shows
- `joePCBarInset` reserves the bar band with a **clear** `safeAreaInset`, and
  scroll content keeps scrolling **under** insets. Once the strip pins, rails
  slide up behind the transparent bar and through any gap above the strip.
- The deep-state render (`TRIAL-Home-recalc-deep.png`, measured: y0–131
  flat Ink #0C1215, divider y131, strip y132–219 Ink, rails from y224) has
  only Ink above the strip.
- The fix paints Ink from the screen top to the strip bottom (1920 wide)
  **only while the strip is pinned**: its global top must be ≤ 330, while
  the rest position is the 560/600 stage foot. It is paint-only (no state
  writes, no layout effect) and sits under the shell bar.
- The brief's second conviction does **not hold on c2a38504**: JoeTorrent
  already carries `.padding(.top, theme.id == .privateCinema ?
  -joePCBarHeight : 0)` at `JoeTorrent.swift:288` (blame: 096edbe, 2.1.3), on
  the same element as its three siblings. Not changed.

### Fault 5: the full-screen backdrop
- The same focus-follows controller and crossfade layer is hoisted out of
  the stage to **page level behind the ScrollView** (`.background`, ignoring
  the safe area → 1920×1080).
- It sits under the spec's left scrim + a new full-height ramp
  `JoeCinemaScrims.page`: clear → 0.35 clear → Ink .88 at .85 → full Ink.
  That is the theme's own detail-backdrop melt, but with the **top clear**,
  per the FIX-213 Fault 8 "no top darkening" ruling.
- The stages are text-only at the **same 560/600** (a clear full-width spacer
  keeps text, tagline and strip positions).
- The TVB and Torrent rail Sections drop their plain-Ink fill (v2.1.1 FIX-6),
  which would have re-cut the backdrop at the stage foot.
- The pinned strip keeps its Ink, and the FL-427 cover gives the deep state
  its Ink band.

---

## 2. Lag table (FL-447 + own findings)

Method key:
- **H** = host model in `docs/opt2-bench/` / `docs/opt-bench/` (Python, real
  data where available).
- **C** = code reading / operation counting.
- **D** = needs a device.

| Rank | Item | Evidence (main) | Fix | Before → After | Method |
|---|---|---|---|---|---|
| R1 ★ | PC home strip/tagline/rails rebuild every rail per focus step | `railSpecs` computed property read ≈39×/focus step (strip 13, tagline 7, rails 5, `cinemaHeroFocusMoved` 14): `JoeHomeScreen.swift:1171-1250, 1586-1670, 2177`; same in `JoePhimHome.swift`. Each build title-normalises 2 names per movie (`Providers.swift:254`) | memo `normalizeTitle` (exact: NSString-literal key); `railSpecs` read once per resolver; visible-titles built once in `cinemaContextInfo` | **Builds reduced, not eliminated: 39 → 12 rail-spec builds per focus step.** The bench (≈207 ms → ≈3.4 ms) models **only the trending-file dedupe slice** of those builds, on a **synthetic catalogue** (real titles, assumed 24/rail, 696 movies + 212 trending-file items). Not a whole-step or device figure | H `strip_focus_step.py` (dedupe slice only) |
| R1 ★ | 1 873-title TVB scan per resolve | `pcTVBById.values.first { hasSuffix }` `JoeHomeScreen.swift:1187,1400`, `JoePhimHome.swift:1348,1561` | `joePCTVBTitle`: exact key lookup (same answer; map keyed by own tmdbId) | O(n) string formats → O(1) | C |
| — | Note on the brief | Hooks are scoped to the `cinemaHome` arm (`JoePhimHome.swift:744-868`, `JoeHomeScreen.swift:583-707`): legacy themes do **not** run `cinemaContextInfo`. They re-render on focus only as any `@FocusState` view does | — | — | C |
| R2 | Hero text measured per focus move | `JoeHeroMeasure.lines` = `UIFont(name:)` + `NSString.boundingRect` per call, from every PC hero body | memo by (text, face, size, width) | unverified (UIKit) | C, D |
| R4 | TVB home rebuilds its rail specs ≈7×/focus step | `JoeTVB.swift:1672` pure in `catalog`, `catalog` assigned once (`:606`) | memo keyed by catalogue version/stamp/count | ≈15 ms → 0 per step (1 561 titles, ≈2.2 ms/build) | H `tvb_railspecs.py` |
| R4 | TVB catalogue double decode at load | `JoeYtCatalog.swift:622-658` decodes bundled + cache (6.9 MB each) | stamp-first, decode chosen only (PR #1 item) | peak 59.5 → 41.7 MB; selection identical in 144/144 cases | H `ytdecode.py`, `select_equiv.py` |
| R4 | Settings KK probe + YT refresh per enter | `JoeSettings.swift:149,152` | **kept**: KK probe already throttled 900 s (`:1237-1243`); YT refresh = one cookie read | — | C |
| R4 | TVB displayed/byId per tab enter | `JoeTVB.swift:607-608` (~1 ms filter+dict) | **kept** (small; per-enter, not per-step) | — | C |
| R4 | Hero `.task` refetch per mount | `JoeHomeScreen.swift:1835+` | **kept**: network path, cached by URLCache/TMDB memo; changing it changes data freshness | — | C |
| R3 | dual 1920 backdrop loads + 520 ms crossfade | RECALC-SPEC §2.5 (debounce 140, crossfade 520, bucket 1920 for full screen) | **kept**: it is the spec | — | C |
| R5 | per-step DiagLog enqueue | `JoeDiagLog.swift:noteFocus` (off-main queue) | **kept** (owner-requested stall instrumentation); per-line DateFormatter construction removed (PR #1 item) | unverified | C |
| R6 | rail posters | acquitted by the leader | **not touched** | — | — |
| own | race loops poll 25–100 ms | `SourceHealth.swift:271`, `KkClient.swift:139`, `Providers.swift:886`, `SourceProbe.swift:94`, `JoeImagePipeline.swift:808`, `JoePrivateCinema.swift:672` | bounded wake (`JoeWake`); player failover hedge excluded (decides at poll time) | mean detection 13–50 ms → ≈0; 1 500-interleaving model: no hang/double-resume/lost wake | H `poll_vs_wake.py`, `joewake_model.py` |
| own | warm posters run the hedged race | `JoeImagePipeline.swift:747-819` | synchronous fast path, same bitmap + log | 2 tasks + loop + ~8 locks → 0 per warm card | C |

---

## 3. Per-screen design-match declaration (DESIGN GATE)

Legend:
- **MATCH** = value checked equal.
- **DEV** = deviation, listed for the design team (never self-passed).
- **OVR** = owner ruling overrides the spec (cited).
- **NV** = row not verified in this pass; the design gate must check it.

A screen's result is **MATCH** only if every row is MATCH or OVR.

### 3.1 Private Cinema (source: RECALC-SPEC)

| Screen | Spec § | Result | Rows (spec value → code value, file:line) |
|---|---|---|---|
| Shell bar | §3.0 | **DEV** | DEV bar height 132 → 148 (`JoePrivateCinema.swift:56`, FIX-214 raise) · MATCH inset 88 (80 safe + 8) · MATCH nav 24/400 gap 16 · MATCH order Trang chủ·Phim·TVB·Phim Torrent·TV·Tìm phim·Cài đặt (`JoeTVApp.swift` PC arm, Cài đặt last = OVR chốt 9) · OVR selected capsule Ivory 13×27 r30 → **no fill at any state, selected = semibold text** (owner ruling via FL-422, this PR) · MATCH nav focus Celadon 3/5 + 1.035 (R1) · MATCH clock Outfit 24 · MATCH wordmark editorial 38 + tv badge r6 · DEV strip pin y132 → y148 (follows bar 148) · NV wordmark ink position (90×38 @ y52–90) |
| Trang chủ | §3.1 | **DEV** | OVR backdrop full screen (FL-457, this PR) · DEV stage 485 → 560 (`JoeHomeScreen.swift` cinemaHeroBlock) · NV hero y158 (text zone bottom-anchored) · MATCH hero x94 w850 (frame 944) · MATCH title Bricolage 72/500 −3 (R2) · MATCH eyebrow 15/500 track 3.6 · MATCH origin 20/500 upper track 6 (≈.3em) · **DEV synopsis 18/400 → 20/400**, max 665 (`JoeHomeScreen.swift:2093`, FIX-214 "re-measured"; conflicts with §2.3) · MATCH tagline Instrument Serif italic 28 · MATCH buttons 22/500 · DEV rails order: spec CW→Trending→KK→VS→F4K→TP→TVB hot→TVB new→3 torrent, code inserts **Yêu thích at #2** (FIX-214 §1d) · MATCH CW card 320×180, poster 205×263, gap 25, margins 94, heading Bricolage 27/500, bottom 64 · MATCH card focus 1.045 Ivory 3/5, rest .83 · DEV scrims: spec bottom scrim on a 485 stage → full-height page ramp (consequence of the FL-457 OVR; the ramp is a design question) · DEV deep: library y224 → y236 (148+88) · MATCH deep strip 88, title 34/500, meta 20 |
| HomeTVBFocus | §3.2 | **DEV** | OVR backdrop full screen · MATCH title Bricolage 78/500 −4 · **DEV extra 68 pt step when the title wraps** (`JoeHomeTVBFocus.swift:56`, not in §3.2) · DEV stage 600 (no stage value in §3.2; hero y164) · NV episode line 17/400 + ruler 126×4 r2 (code `outfit(17)` present) · NV actions "Chọn tập/Tựa đang trỏ/Đánh dấu tựa" |
| Phim | §3.3 | **DEV** | same rows as Trang chủ (shared renderer) · DEV rails: spec exactly 7 (CW→Trending→KK→VS→F4K→TP→Phim lẻ), code adds **Yêu thích at #2** → 8 |
| TVB (tab) | §3.5 | **DEV** | OVR backdrop full screen · MATCH lead 5 (CW + dangHot / moiCapNhat / Hình sự / kinhDien, `JoeTVB.swift:1332`) · DEV YT rails + appended shelves follow the 5 (§3.5 says "đúng 5"; §3.1-style app extras not ruled for TVB) · MATCH in-page search removed (OVR 03:43) · NV static eyebrow "MỘT THỜI HỒNG KÔNG / TVB" |
| Torrent (tab) | §3.6 | **DEV** | OVR backdrop full screen · MATCH no furniture above hero · MATCH CW → providers → explore, Yêu thích after · DEV stack spacing 36 vs siblings 8 (rhythm 395/312 — NV that it lands on 395) |
| TV (tab) | §3.7 | **NO DESIGN SOURCE** | spec: UNMEASURED (no drawing; system-derived by ruling). Nothing to match; listed so the gate sees it |
| Tìm phim | §3.8 | **NV (partial MATCH)** | MATCH headline Times serif 60 (`JoeSearch.swift:346`) · MATCH grid 8 cols, gap 31×24 (`JoeSearch.swift:419-422`) · NV field h87, pad 29, gap 22, r7 (`JoeFieldChrome` pc: pad 29×24, r7) · MATCH field text 29/300 (`JoeSearch.swift:290`, R5; the regular 29s at :139/170/178 are status lines) · NV frame x94 y132 |
| Cài đặt | §3.9 | **DEV (pending Fault 1)** | MATCH headline Times serif 64 · MATCH rail Outfit 28, row r14, w390 · OVR/leader-directed: selected Panel face now suppressed while focused (FL-422) · MATCH theme card ✓ Celadon independent of focus, "Chọn" chip r7 · MATCH fields #22312E r12 single bar, ✓ bare inside (Ruling 22, this PR) · MATCH field text 29/300 (R3) · MATCH pane title Bricolage 34 · DEV focus of fields = one Celadon 2 pt stroke on the bar (Ruling 22 gives no focus value; design question) · **DEV FL-448 stretch on device** (unresolved) · NV 4 panes other than Giao diện (spec OPEN-2: undrawn) |
| Detail (chain) | §3.10 | **NV (partial MATCH)** | MATCH title Bricolage 100/500 −3 (`JoeMovieDetail.swift:1648-1649`) · MATCH synopsis 21/400, 1.55, max 720 (`:1702-1708`) · DEV synopsis lineLimit 3 (spec silent) · MATCH cast names Outfit 25, semibold + Ivory outset, no plate (R6) · MATCH fav/follow focus now Ivory outset, no plate (this PR) · NV frame x94 y180 w900 · NV source chips content-width gap 18 |
| Detail (TVB) | §3.11 | **NV** | MATCH still backdrop, no trailer (OVR 02:40, per code comments FIX-7) · chip tập UNMEASURED (keep app's) · NV source row set Tự động·YouTube·KK·TP·VS·F4K·Torrent |
| Detail (Torrent) | §3.12 | **NV** | NV uniform stream-bar width ≈376 (code comments cite §3.12 at `JoeTorrent.swift:2062,2418,2462`; number not re-measured) · MATCH episode rows: selected fill suppressed under focus (FL-422) |
| Actor filmography | §3.13 | **NV (partial MATCH)** | MATCH portrait 186×262, name serif 104 (`JoeActorPage.swift:734,764`) · MATCH poster card 205×263, focus 1.045 · NV grid pitch 240/377, trailer 896×504 @ (930,388) |
| Player surfaces | §3.14 | **NV (partial MATCH)** | MATCH title Outfit 45 (`JoePlayerView.swift:2537`) · NV close 60×60 top 52 side 85, bottom block 68/94, timeline 5/15, hide 3000/300 |

### 3.2 Legacy themes (source: A–F pack, pixel-measured)

| Screen | Drawing | Result | Rows |
|---|---|---|---|
| A home | A-home.png | **NV (partial MATCH)** | MATCH card face 260 = art 240 + 2×10, gap 26 (measured) · OVR bar order TV-first in drawing → TV LAST (owner ruling) + app's Trang chủ/TVB tabs not in drawing · NV hero, chips, type sizes |
| D home | D-home.png | **NV (partial MATCH)** | MATCH card 264, gap 24 (measured), focus ring 6 (276-wide focused card) · OVR bar order · NV filter chips, underline link |
| F home | F-home.png | **NV (partial MATCH)** | MATCH card 264 = 240 + 2×12, gap 28 (measured) · OVR bar order · NV source bands |
| A/D/F detail, grid, player, search, settings, dialog (18 screens) | X-*.png | **NV** | Not measured in this pass. Only change this PR makes on them: FL-422 (selected fill suppressed under focus on chips/pills/episode chips), which the drawings do not draw (no combined state) |
| Ultra (all screens) | — | **NO DESIGN SOURCE** | No drawing in either pack (Sony 2.3.31/32 port). Listed so the gate sees it |

---

## 4. FL-422 and FL-423 sweeps (documented)

**FL-422: every surface whose fill keys on a selected flag** (grep of every
conditional `.fill(...)` and every view with a `selected/isSelected/isCurrent`
input).

| Surface | Before | After |
|---|---|---|
| PillLabel `JoeTVApp.swift` | accent fill when selected, also focused | fill only when `selected && !isFocused`; theme D's selected + focused white frame (v2.0.9 ruling) kept |
| JoeChipLabel PC + legacy `JoeTheme.swift:797/821` | same | same rule (PC: hairline returns under focus) |
| PCCategoryRowLabel `JoeSettings.swift:1612` | Panel face when selected | only when not focused |
| PCNavLabel `JoePrivateCinema.swift` | capsule when selected & unfocused | **no capsule at any state** (owner); selected = semibold |
| epChip, YT episode chip `JoeMovieDetail.swift` | accent fill when preselected | only when not focused |
| Torrent episode rows `JoeTorrent.swift:2317` | accent fill when selected | only when not focused |
| PC fav/follow text buttons `JoeMovieDetail.swift:1863,1893` | **focus** Panel plate | Ivory outset ring (R6 family), no plate |
| TopLinkLabel underline (D) | selected underline bar | unchanged: a marker, not a fill (drawn in D) |
| PCThemeCardLabel | ✓ only | unchanged (no selected fill) |
| Player source menu (`isCurrent`) | system menu state | unchanged |
| JoeActorNameLabel (legacy) / JoeKeyCap (search keyboard) | focus-driven fill | **listed, not changed**: legacy-theme / keyboard focus faces, outside FL-422's selected mechanism. Design question |

**FL-423: Settings double frames**

| Surface | Finding | Action |
|---|---|---|
| All Settings text fields (debrid tokens, links, addon, sports, TMDB, subtitles, all via `JoeSettings.field` → `JoeSettingsFieldChrome`) | PC leg: bar + 1.5 hairline at rest; bar + celadon border + outer celadon ring on focus | **Fixed**: single bar #22312E r12, ✓ inside; focus = one 2 pt celadon stroke on the bar |
| TVB Gold row (`JoeTVBGoldRowLabel`) | Panel fill + hairline + ivory outset on focus | **Listed, not changed**: a button-family row; Ruling 22 is the field frame. Design question |
| Secondary buttons (log export, preview toggle, MF toggle: `JoeSecondaryLabel`) | Panel fill + hairline (spec: outlined secondary) | **Listed, not changed**: button family per spec §2.3 |
| Theme cards | fill + selected hairline + outset | unchanged: drawn per F11 |
| QR card | white quiet zone | unchanged: functional |

---

## 5. Sony ↔ tvOS parity impacts (flagged)

- **FL-422:** selected + focused no longer fills on tvOS. If Sony still
  fills, the two now differ in that state. The PC nav loses its selected
  capsule (Private Cinema).
- **FL-457:** the PC homes now have a full-screen backdrop. The owner says
  Sony already does this, so this is a move **toward** parity.
- **FL-423:** PC Settings fields change frame. Parity depends on Sony's
  Settings chrome.
- **Timing only:** `JoeWake` makes source/KK/alternatives races act up to
  one poll interval sooner. Outcomes are unchanged.
- **Diagnostics:** new `[LAYOUT]` lines in the exported log.
- No change to source/plugin behaviour, probing order, player rescue logic,
  data model, bundle ID, workflows or secrets.

## 6. Not verified (say it plainly)

- **Compilation.** Riskiest spots for the Swift review team:
  - `JoeWake` (continuation + cancellation handler);
  - the GeometryReader-in-background modifiers (`JoePCPinnedBandCover`,
    `JoePCWidthProbe`);
  - `nonisolated(unsafe) static let` NSCache/DateFormatter memos;
  - nested `@State private var railSpecsMemo` class in `JoeTVBView`;
  - tuple pattern switch in `buildFromDisk`.
- **Look on device:**
  - Fault 5: full backdrop on four homes + HomeTVBFocus, crossfade intact;
  - Fault 3: rest **and** pinned on all four homes;
  - Fault 2: focus on selected chips/pills/nav;
  - Fault 7: Settings fields;
  - the 330 pt pin threshold against the real pinned y.
- **Device timings** for every lag item (host models only).
- **Fault 1/6:** the over-wide child is not identified. The probe has to run
  on device.
- **Diagnostic export** (LAN + QR) was not run. Its code is untouched apart
  from the timestamp formatter.
- **Design gate:** every NV row in §3 must be checked by the design team.
  DEV rows need rulings before any build.
