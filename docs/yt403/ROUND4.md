# YT-403 round 4: more ways to save TVB (research only, no app change)

Labels used throughout: **[E]** = evidence (source, log or measurement, cited); **[I]** = inference; **[G]** = guess.
Sources read this round:
- yt-dlp master 6f73a8d (2026-11-23), cloned;
- this repo (`JoeYtHlsServer`, `JoeYtResolver`, `JoeYtWeb`);
- the owner's 2026-11-22 diag log (`joetv-diag_2.txt`, the last **working** session);
- the public pages cited inline.

## 0. Two corrections and one new fact

1. **My round-1 claim was wrong.** I said "playlists cannot exist without a 206 on the sidx range". In fact `JoeYtHlsServer` falls back to a **one-segment playlist** when the sidx probe fails (`sidx … bỏ qua / đọc hỏng ở probe (playlist giữ 1 segment)`, lines 934–1003) [E]. So "playlists 200" never implied that googlevideo had accepted the URL. Your "zero sidx OK" reading stands.
2. **The working-vs-failing distinction matters, and the answer is in the 11-22 log** [E]:
   - `23:11:55.349 session DFE79171: sidx video OK — 498 đoạn`
   - `23:11:55.903 sidx audio OK — 263 đoạn`
   - then every `serve-done GET … outcome=đủ byte`.

   On 11-22 googlevideo accepted the URL **at byte zero**. On 11-23 it refused the same request shape at byte zero, for every itag and both fetchers (the relay with the Tizen UA; AVFoundation for itag 18).

   ⇒ This is **whole-URL rejection**, not a media/position gate [I, strong]. The GVS-PO-token signature is "206 for ~60 s of media, then 403". It shows up in yt-dlp's guide and hometube, and a plugin.video.youtube issue (number not visible in the listing) is titled "GVS returns 403 for ranges past the first ~60s with ANDROID_VR client (likely missing GVS PO token)". **That does not match.** The PO-token family drops in the ranking.
3. **The app's solver is byte-identical to yt-dlp's** [E]. The sha3-512 of `JoeTV/yt.solver.lib.min.js` and `yt.solver.core.min.js` equals yt-dlp 6f73a8d `vendor/_info.py` (ejs 0.8.0). yt-dlp's default solving variant is also `tv` (`_DEFAULT_PLAYER_JS_VARIANT = 'tv'`, i.e. `tv-player-ias.js`), the same file the app uses [E]. And a yt-dlp/ejs issue opened today reports that with one account's cookies, yt-dlp gets player 7f755914 and everything works.

   ⇒ "the app solves `n` wrong" survives only as **an engine difference (JavaScriptCore vs V8)** [I]. `solver_equiv.py` closes that from a VM or a Mac.

**What changed between 11-22 23:11 (works) and 11-23 21:41 (fails)** [E unless marked]:
- the player, 6b3d0364 → 7f755914 (sts 20774 → 20775);
- a fresh device-code token (the stored one lapsed);
- the server side at large [I];
- **the network path: unknown.** Nobody has logged the address family, and this matters (Q1).

## Q1. If sts is not the cure, what else differs on the GVS side?

At byte zero googlevideo can only judge **the URL and the connection**. Range shape, pacing and HEAD patterns cannot matter for a request that is the first one ever made on that URL. The sidx probe is a plain GET with `Range: bytes=init.end+1-…` [E: `fetchOriginRange`]. Ranked:

**G1. IP binding / address-family mismatch** [I, cheap to convict].
- googlevideo URLs carry the requesting IP (`ip=` plus `ipbits`), taken from the address that called `/player`.
- `/player` goes to `www.youtube.com` via `URLSession.shared`. The relay and AVFoundation go to `rrN---sn-….googlevideo.com`, each in its own session.
- With dual-stack Happy Eyeballs, `/player` can leave over IPv6 while googlevideo is reached over IPv4 (or the reverse), or a VPN/DNS change can split them. Either way the URL is invalid for the fetching address → 403 on every request, every itag, both fetchers. That is exactly the symptom.
- Forcing IPv4 is the textbook yt-dlp remedy (`--force-ipv4`) [I from general practice, not re-verified this round].
- Nothing in the app logs the families, so this is **untested, not acquitted**.
- **Convict/acquit:** log (a) whether the `ip=` value in the issued URL is v4 or v6 (family only, never the value), and (b) `URLSessionTaskTransactionMetrics.remoteAddress` family for the `/player` call and for the first googlevideo GET. If (a) ≠ (b) on a 403 run, it is convicted.
- **Cost:** a few log lines in the probe app.

**G2. `n` correctness under JavaScriptCore** [I, low prior after §0.3]. The bundle is identical, so only an engine divergence remains. Convict/acquit with `solver_equiv.py` (node vs jsc on a Mac, 7f755914 `tv`). Cost: 5 minutes on a Mac, with no device.

**G3. OAuth-issued URLs are flagged at GVS** [I, medium].
- Every working reference path in November 2026 is cookie-authenticated or anonymous: yt-dlp HEAD has **no OAuth path** (auth = `_has_auth_cookies`) [E], and its authed default chain (tv_samsung → web_embedded → web) runs on cookies.
- Kodi's add-on removed TV OAuth login in 2024, though for Data-API reasons.
- We are the outlier: `TVHTML5` + bearer from a scraped TV OAuth client.
- **Convict/acquit:** the same video, the same client (`tv_samsung`), the same device and the same minute: /player with bearer vs /player with cookie auth (SAPISIDHASH, below); compare byte-zero status. Cost: one probe variant, needing a one-time door sign-in (§Q2/Q4).

**G4. URL parameter diffs vs a working client** [E for what the app does]. The app adds exactly one thing to the issued URL, the solved `n`. It adds no `pot`, no `cpn`/`rn`/`rbuf`/`alr`, and no `range=` query (it uses the `Range` header, as yt-dlp's HTTP downloader does).
- `expire` is hours ahead, and the 403 arrives within a second.
- `sig`: `ciphered=0`, so there is nothing to sign.

Nothing else at URL level differs from a yt-dlp download of the same URL [I]. **Not** a lead unless G1–G3 all acquit.

**G5. The Sony data point** [E as reported, I in meaning]. A hard-coded sts 20683 still played on 11-20, two generations stale. So on 11-20 the server tolerated a wrong sts (for whatever client the Sony build uses; please confirm it is TVHTML5 + bearer). That **weakens sts as the 11-23 cure** but doesn't kill it, because the gate could have arrived with 7f755914. **The single most valuable free test tonight: does Sony play now, on the same network?**
- Sony works ⇒ the cause is JoeTV-specific (G1 family split, G2, request shape).
- Sony fails ⇒ the cause is the account, network or server (G1 network, G3).

## Q2. web_embedded / web with a bearer token?

- **[E]** yt-dlp drives web_embedded and web **only with cookies**. Auth headers are `_generate_cookie_auth_headers` → `SAPISIDHASH <ts>_<sha1(ts SAPISID origin)>` (+ `SAPISID1PHASH` / `SAPISID3PHASH`), `X-Origin`, `X-Goog-AuthUser`, plus `X-Goog-PageId` / `X-Youtube-Bootstrap-Logged-In` when known. There is no bearer path for any client.
- **[E]** Your device matrix: a valid TV bearer on IOS/VISIONOS → 400, while garbage → 401. **[I]** web_embedded/web will behave like IOS/VISIONOS (non-TV clientName), not like TVHTML5. That is untested, but it is a /player-only check, VM-runnable with the token (add a variant to `auth_matrix.py`).
- **[E]** Even with cookies, web_embedded and web carry `WEB_PO_TOKEN_POLICIES`: GVS PO **required** for HTTPS/DASH, `not_required_for_premium=True`. So for a non-Premium account (channel membership ≠ Premium [I]), web_embedded means **cookies + PO token**. This matches hometube's production fix (`default,-tv_samsung,web_creator,web_embedded;fetch_pot=always`).

**A legitimate path from the TV OAuth grant to a web session?** **[I]** None that we can use. Google's token→cookie exchange (OAuthLogin / MergeSession, the "ubertoken" flow) needs the `accounts/OAuthLogin` scope, which only first-party clients like Chrome get. A device-code token scoped `youtube` can't mint cookies. **[E]** But you don't need an exchange: **the app already has a web sign-in.** `JoeYtWeb.swift` contains the "Gold sign-in door": a real accounts.google.com sign-in in WKWebView with an honest Safari UA, a cookie mirror, and a SAPISID-presence rule, marked PROVEN-SONY. One sign-in by the owner yields the cookie session yt-dlp's whole authed chain is built on.

## Q3. PO token: the real cost

- **[E]** BotGuard is "an obfuscated virtual machine implemented in JavaScript". NewPipe states that minting needs **a JavaScript engine with a good DOM implementation**, and its only implementation is a WebView (`PoTokenWebView`); HtmlUnit-style emulation was judged not doable. BgUtils itself says it does not bypass BotGuard: you still need a compliant environment.
- **[I]** So **JavaScriptCore alone (our solver's JSContext) will not do it**: no DOM, no layout or canvas, and the wrong fingerprint. A **hidden WKWebView will** (real WebKit, the same engine as Safari). The app already ships WKWebView plumbing (JoeWebBridge).
- **Minimal honest implementation [I]:**
  - one hidden WKWebView loads a youtube.com page with the Safari UA and runs the BgUtils flow (fetch challenge → run VM → integrity token → mint);
  - mint a **session/visitor-bound** token once per WebView life (≈2–5 s cold, sub-second warm, per the NewPipe-derived docs);
  - mint a **content-bound** token per video;
  - append `pot=` to GVS URLs and/or `serviceIntegrityDimensions.poToken` to /player.
- **What it unlocks:** web_embedded/web with cookies. TV clients declare **no** GVS PO policy in yt-dlp [E], so a PO token is not what TV clients are missing [I].
- **What breaks first [I + E]:**
  - the challenge-fetch shape (request key / API key);
  - the integrity-token lifetime;
  - WebView fingerprint rejection (bgutil #285 reports minted tokens being rejected).
- **The leading TV-OAuth app has gone there [E]:** yuliskov (SmartTube's author) maintains **PoTokenService**, "creation of PoTokens by directly interacting with BotGuard's API".
- **Verdict:** not unavoidable on current evidence, because our failure is byte-zero rejection, not the PO signature. Keep it as plan E.

## Q4. The official web-player fallback, engineered properly

**[E]** It is mostly built already:
- `JoeYtWeb.swift` has the player surface (desktop watch page, watchmax CSS that pins `#movie_player` full-viewport, a remote model);
- the sign-in door with the Safari UA;
- the cookie mirror into the shared data store;
- `JoeYtPlayRouter` already has `.pageFallback`.

What stands between us and "native fails → web player opens, signed in, fullscreen":

1. **The session.** There is no token→cookie exchange (Q2). The owner signs in **once** through the door. Cookies persist in WKWebsiteDataStore across launches, but **not across delete+reinstall** [I: the data store lives in the app container]. With the owner's reinstall cycle, that means one sign-in per install unless the production build gets a stable test channel. Members-only works if the signed-in account is the member [I].
2. **The trigger.** A media-403 death currently ends in `terminalFailure`; only "can't build the item" hands over to the page (`handOverToPageFallback`) [E, round 1]. A one-line policy change ("origin refused media on assembly **and** muxed → page fallback") makes it a rescue path. It is a rescue-logic change, so it is your call.
3. **Remote and UX.** It is PROVEN-SONY on Android. On tvOS, WKWebView focus and press routing goes through JoeWebBridge. It needs one probe check that play/pause/seek/back behave.

**Ranking [I]:** this is the highest-certainty path to "the owner watches TVB tonight". The official player handles n, PO and whatever comes next. Its cost is UX polish, not research.

## Q5. Other projects today

- **hometube (PR #99, 6 Nov)** [E]:
  - production client list `default,-tv_samsung,web_creator,web_embedded;fetch_pot=always`, with tokens from the bgutil sidecar (video-bound, one request per client per extraction);
  - the PR itself says the tv_samsung exclusion **was not the cause**, so the list can return to `default,-tv_samsung,web_embedded` or `default,web_embedded` after release. That makes the PO token the actual fix for their cookie/web case;
  - an open review comment says `fetch_pot` clause handling is still buggy.

  I could not see anything newer than that PR from here.
- **SmartTube** [E]: open issues 6–24 Nov include a mid-playback 403 on a chunk URL (#6484, asks to refresh the URL on the first 403), a SABR ReloadPlayerResponse stall (#6478), and "Fixing stalled client" freezes (#6515). Its author ships PoTokenService (above). **[I]** The leading TV-OAuth app is on SABR + PO tokens, not plain HTTPS TV URLs.
- **ambient-tv (PR #417, 20 Nov)** [E]: records terminal 403/410 from its **local YouTube relay**, renews SmartTube playback data once, then stops. Note that reopening the same title **may reuse signed URLs and return 403**. **[I]** That is relevant to us: JoeTV re-resolves on recovery, so it already avoids URL reuse. Confirm in the probe log.
- **Kodi plugin.video.youtube** [E]: issues include a 403 on one audio request (#1501, 6 Nov), a bot-check block on Android TV (#1494, 20 Oct), an MPEG-DASH 403 stall with ANDROID_VR (#1483, Aug), and a separate ANDROID_VR 60 s GVS 403 issue. They use their own TV OAuth clients for the Data API.
- **yt-music-gpui PR #246** (round 1): tv_samsung URLs 403 immediately after extraction (anonymous, yt-dlp's solver), with visionos the working alternative. **[I]** Combined with G1 and G3, this supports "tv_samsung URLs issued in our situation are refused outright".

## Q6. The probe-app experiment matrix

**Principle:** one probe build runs **every variant automatically** on one tap, on two videos (V-pub = a public TVB trailer, V-mem = a members-only episode), and writes one table to the diag log (LAN + QR export). The owner installs once per *round*, not once per variant.

**Every variant logs:**
- `/player` HTTP status, playability, #formats, client, and whether sts was sent (value);
- for itag 140 and itag 18: GET `bytes=0-1023`, GET first-media `65536-131071`, and the same again at **t+8 s** (catches the yt-music-gpui warm-up pattern);
- the `ip=` family in the URL and the `remoteAddress` family per request (G1);
- an `n` hash (first 8 hex of sha1, never the value);
- for the winners only: a **continuous 75 s fetch** of sequential media ranges (crosses the 60 s PO cutoff);
- no URLs, no tokens, no cookie values.

**Ordered variants (run all, in this order; each one is a few seconds of requests):**

| # | client / shape | auth | bets on | expectation |
|---|---|---|---|---|
| 1 | tv_samsung, run60 shape (sts, key kept) | bearer | sts | today's build, the baseline |
| 2 | tv_samsung, run60 shape, **no key** | bearer | key/project | yt-dlp parity |
| 3 | tv (Cobalt 7.20260707.07.00), parity | bearer | client-version gate | |
| 4 | tv_samsung, parity, **all googlevideo GETs forced over the /player family** (NWParameters IP version pinned) | bearer | G1 | only meaningful if the logs show a split |
| 5 | tv_samsung, parity | **none** (V-pub only) | account/token gate | separates "our token" from "the client" |
| 6 | tv_samsung, parity | **cookies** (door, SAPISIDHASH) | G3 | yt-dlp's authed default |
| 7 | web_embedded, yt-dlp shape | cookies | control | expect a byte-zero 206, then 403 by 60 s (PO policy) |
| 8 | official web player (JoeYtWeb) on V-mem | cookies | rescue viability | plays ≥ 75 s, back/seek work |

Variants 6–8 need the **one-time door sign-in** inside the probe. Do it first, in the same install.

**Decision rule (promote to JoeTV):**
- a variant must, on **both** V-pub and V-mem (V-pub only for #5):
  - return 206 for byte-zero **and** first-media at t=0 **and** t+8 s;
  - pass the 75 s continuous fetch with zero 403;
  - and do so on **two runs ≥ 10 min apart** (fresh resolve each time);
- among promotable variants, prefer the lowest number: smallest change, no sign-in dependency;
- if **none** of 1–6 promote but 8 does, port the page-fallback trigger (Q4) and stop researching for now;
- if 7 promotes past 75 s, the account doesn't need PO (Premium-like) [I]. Note it, but don't build on it.

**Expected cycles:** 1 probe install answers G1, G3, key, client version, anonymous vs token, and rescue viability together. A second install exists only to verify the chosen port.

## Benches (VM-safe) and what they prove

- `solver_equiv.py --player 7f755914 --variant tv`: runs the app's own bundle (hash-checked against yt-dlp's vendored ejs 0.8.0, which **already matches** [E]) under node/deno, and on a Mac under Apple's `jsc`.
  - **Proves:** whether JavaScriptCore gives the same `n` as V8 for this player (G2).
  - **Does not prove:** that googlevideo accepts the `n`.
  - **Bot wall:** none. It fetches only the static player file (use `--player-file` if even that is blocked).
- `auth_matrix.py` (round 3): /player-only. Add web_embedded/web variants with the bearer to settle Q2's prediction.
  - **Proves:** which clients accept a TV bearer.
  - **Does not prove:** anything about segments. That is the probe app's job, from the residential IP.
