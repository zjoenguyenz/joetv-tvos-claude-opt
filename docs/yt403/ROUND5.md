# YT-403 round 5 — what has everyone missed?

Research only, no app change. Labels: **[E]** evidence (source opened this session, cited), **[I]** inference, **[G]** guess.
Sources opened today:
- **SmartTube:** `yuliskov/SmartTube` @ a0c319a (2026-11-22) and `yuliskov/MediaServiceCore` @ bad6cb5 (2026-11-22), both cloned, with history since 2026-10-01;
- **yt-dlp:** master 6f73a8d (2026-11-23), cloned;
- **this repo:** `JoeYtResolver.swift`, `JoeYtIdentity.swift`, `JoeYtHlsServer.swift`;
- **the owner's two 2026-11-22 DiagLogs:** 22:16 and 23:11, both working;
- **public pages:** yt-dlp/ejs #79, MediaServiceCore PR #51 and PR #75, yt-music-gpui PR #246.

**Where evidence runs out:**
- **I do not have the 11-23 (failing) DiagLog.** Only the two 11-22 logs reached this session. Item 9 ships `logdiff.py`, which does the field-by-field diff the moment both files sit side by side. I ran it on the two 11-22 logs to prove it works.
- **No request to YouTube was made from here.** The shell has no route.

---

## Ranked "overlooked" list

### 1. SmartTube DOES send a PO token on TV clients: the "living-room" token. The survey's "no PO on TV clients" is wrong.

**[E]** MediaServiceCore @ bad6cb5:
- **Which clients:** `AppClient.kt:114`, `isTvPotRequired = equalsAny(this, TV, TV_SAMSUNG)`. That covers **both** of our chain's clients.
- **Where the token is applied:** `PoTokenGate.getPoToken(client)` routes TV/TV_SAMSUNG to `TvPoTokenProvider`. The token goes into **three places**:
  - every stream URL as `pot=` (`VideoInfoServiceBase.applySessionPoToken`, `VideoUrlHolder.setPoToken` → `PARAM_POT`);
  - the /player body as `serviceIntegrityDimensions.poToken` (`QueryBuilder.createPotChunk`);
  - the /player body as `context.client.tvAppInfo.livingRoomPoTokenId` (`QueryBuilder.createClientChunk`).
- **How it is minted (`TvPoTokenProvider.kt`):**
  - the BotGuard request key comes from `https://www.youtube.com/tv_config?action_get_config=true&client=lb4&theme=cl` (`challengeRequestKey`); the class comment says it "differs from the web one";
  - the program comes from `/att/get` (`FORCE_ATT_CHALLENGE = true`);
  - `LIVING_ROOM_PO_TOKEN_ID` and `visitorData` come from the `/tv` page;
  - the token is minted in a WebView (`TvPoTokenWebView4`), is session-bound (not per-video), and is reused for both the /player request and streaming.
- **When it arrived:** commits `2ece091` (2026-10-04) and `b85666a` (2026-10-05), "TV client fix (nsig and potoken) by @pixkk". The upstream PR text: *"PoToken can use livingRoom token for self-generation (TV client), livingRoomPoTokenId should be attached to /player request in this case."* Later hardening includes `3c733fe` on **2026-11-21**, "fix(PoTokenGate): revert 60 sec cache reset timeout", in our break window. A community PR persists the TV session token across restarts because minting takes about 7 s on low-end boxes (PR #75).
- **[E]** yt-dlp 6f73a8d declares **no** GVS PO policy for `tv`/`tv_samsung`, and has no living-room token code anywhere (grep `livingRoom`: 0 hits).

**[I]** Two of the most-used TVHTML5 implementations disagree, and the one that is a long-running signed-in TV app (SmartTube, device-code OAuth, like us) mints a TV token for both TV clients. yt-dlp is cookie-only and may be lagging, or may be in a different enforcement bucket. If YouTube enforces the living-room token per account or rollout bucket, a flip between 11-22 and 11-23 for our account looks exactly like "same request, accepted yesterday, refused today at byte zero, on every itag". What a missing living-room token does at GVS is **not documented** (the byte-zero vs 60 s shape is unknown); that is the gap.

**Cheapest tests:**
- **VM:** `scrape_check.py` (new) reports whether `tv_config` carries `challengeRequestKey`/`challengeParams`, the living-room `jsUrl`, and whether `/tv` carries `LIVING_ROOM_PO_TOKEN_ID`.
  - **Proves:** the plumbing exists today.
  - **Does not prove:** enforcement.
- **Probe:** one variant that mints the living-room token in a hidden WKWebView (port of `TvPoTokenWebView4.kt`, about 560 lines) and sends it in all three places.
  - **Convicted if:** variant 1 gives 403 and this variant gives 206 at byte zero, back to back.
  - **Cost:** the heaviest item here (a WebView BotGuard runner). It is engineering, not research; SmartTube is the recipe.

### 2. SmartTube omits `key=` whenever it is signed in; run60 deliberately kept it.

**[E]** `RetrofitOkHttpHelper.kt`, inside the `apiPrefixes` (`/youtubei/v1/`) interceptor:
- `if (authHeaders.isEmpty() || doSkipAuth)` → it adds `key=AppConstants.API_KEY`;
- `else` → it adds **only** `prettyPrint`/`t`, plus the auth headers.

yt-dlp never sends a key (round 3). So **both** reference implementations send *no key with credentials*; we are the only one sending key + bearer.

**[I]** This does not explain 11-23 on its own, because 11-22 worked with the key. It is the cleanest explanation of the IOS/VISIONOS **400**: a key from project A plus a TV-client token from project B is the classic "invalid argument" pairing. SmartTube keeps VISIONOS and IOS in its signed-in chain, so with no key they may well accept the token.

**Cheapest tests:**
- **VM, with a token:** `auth_matrix.py` variants D and F (IOS/VISIONOS, **no key**). These are /player-only.
  - **200** ⇒ the 400 was the key, and two more clients reopen.
  - **400** ⇒ client binding.
- **Probe:** variant 2 (tv_samsung, no key) is already staged.

### 3. SmartTube's full /player shape has more deltas than the survey listed.

**[E]** `QueryBuilder.kt` and `AppClient.kt`. Beyond Cobalt, `visitorData` and `X-Goog-Visitor-Id` (all confirmed: `createClientChunk` puts `visitorData` in `context.client`; the interceptor adds `X-Goog-Visitor-Id` on `/youtubei/v1/player`), it also sends:
- `clientScreen: "WATCH"`;
- `acceptLanguage`, `acceptRegion`, `utcOffsetMinutes`;
- `user: {enableSafetyMode:false, lockedSafetyMode:false}`;
- a per-request `cpn` (`resetClientPlaybackNonce()`, moved into the client loop by **b3d561f, 2026-11-12, "pot attestation fix"**);
- `playbackContext.contentPlaybackContext.signatureTimestamp`;
- a code comment: *"Newer TV -tcl player variants use 8 digits timestamp, usually with 001 suffix … wrong timestamp format yield 'page should be reloaded' error … downgraded UAs use the same timestamp format for WEB and TV"*.
- **Its chain** (`FormatInfoWrapper.CLIENT_LIST`): **TV (Cobalt) first**, then TV_SAMSUNG, WEB, VISIONOS ("no url formats"), TV_DOWNGRADED ("works with old UAs … non-tcl players"), and so on.
- **Its versions** (`Constants.kt`): TV = `TVHTML5 7.20260901.15.00` with Referer `https://www.youtube.com/tv`; TV_SAMSUNG = `5.20260707` (identical to ours).

**[I]**
- **sts:** our Tizen-2.4 TV_SAMSUNG is a "downgraded"/non-tcl UA, so a 5-digit sts (20775) is right for it.
- **Second chain entry:** run60's `tv` (Cobalt 7.20260707) may be served a **tcl** player that needs an **8-digit** sts. That matters for run60's second attempt.

**Test:** probe; log the sts actually sent per client.

### 4. Segment fetching: SmartTube asks googlevideo with a `range=` query parameter, not a `Range` header.

**[E]** `SmartTube/exoplayer-amzn-2.10.6/.../DataSpec.java` `applyRangeQuery()`: for `*.googlevideo.com` it appends `&range=start-end`, citing yt-dlp issue 6369, as a "Google throttle fix". It plays out the response as a whole-body read. Our relay uses a `Range:` header (round 1). Together with `pot=` (item 1), `cpn=` (item 3) and SABR for some clients, SmartTube's googlevideo URL carries three parameters ours never has.

**[I]** The header form worked on 11-22, so it cannot be *the* 11-23 change alone. It is a free parity knob, though.

**Test:** probe; one flag on any variant that reaches 206, plus the byte-zero GET in both forms.

### 5. Which player does the server think our account uses? The account-dependent player.

**[E]**
- yt-dlp/ejs #79, opened **2026-11-23**: *"YouTube serves this player only to some accounts"*. With one account's cookies yt-dlp gets 7f755914 and works; another gets 05a4ffc0. The reporter concludes *"the player depends on the account/cookie, not on the machine"*.
- MediaServiceCore PR #51 (Oct): *"We should grab actual jsUrl from tv_config as original YT … certain accounts might be served a client other than the TCL one."*
- **Our app** takes the player from the **anonymous** `/tv` page (`player-js: trang /tv trỏ player bằng pattern 'jsUrl tv-player-ias'`), fetched without the bearer. SmartTube's `/tv` and `tv_config` fetches are also outside its auth interceptor's prefixes, so both are anonymous.

**[I]** If the server bound our account's URLs to a different player than the anonymous page advertises, our `n` would be "correct" for the wrong player. The result would be whole-URL 403 at byte zero, a solver log that looks perfect, and in-house byte-compares that pass (they compare against the same wrong player). It fits a day-to-day flip. It needs a player rollout that is account-keyed on TVHTML5 as well as on web, and that is unproven.

**Cheapest tests:**
- **VM:** does 05a4ffc0 have a TV variant? GET `/s/player/05a4ffc0/tv-player-ias.vflset/tv-player-ias.js`; 200 or 404.
- **Probe:**
  - on a 403, re-solve `n` with every TV-variant player hash seen in the last 48 h, retry byte zero with each, and log which hash (if any) gets 206;
  - also log the living-room `jsUrl` from `tv_config` next to the `/tv` one.

### 6. The OAuth client is scraped live, three UAs are in play, and the fallback regex is ambiguous.

**[E]** `JoeYtIdentity.scrapeTVClientCredentials()`:
- fetches `/tv` with a **Tizen 6.5 SamsungBrowser** UA;
- follows `id="base-js"`;
- falls back to the **first** `*.apps.googleusercontent.com` in the HTML, plus any `client_secret`.

Meanwhile:
- /player is sent with a **Tizen 2.4** UA;
- run60's second attempt is **Cobalt**;
- the log records only `clientId len 72, secret len 24`. Both 11-22 sessions show 72/24. The path taken (base-js vs fallback) and the identity of the id are not logged.

SmartTube's `AppApi` comment says the client data lives in `base.js` (modern) **or** `main.js` (Cobalt/Legacy), so it varies with the UA.

**[I]/[G]** If YouTube changed which OAuth client the Tizen-6.5 page embeds, or the base-js path broke so the loose fallback picked another Google client id, our token would belong to a different OAuth client than on 11-22. /player would still return 200; GVS treatment could differ. **[G]** on the effect.

**Cheapest tests:**
- **VM:** `scrape_check.py` (new). It replicates the scrape exactly, under three UAs, and reports the path used, sha1[:8] of the id, and how many distinct ids each document holds.
- **Probe:** log the same hash on device.

### 7. Anomalies in the record (numbers that don't reconcile)

**a. "Solved in 0 ms": explained. It is a logging bug, not a mystery.**
- **[E]** `JoeYtResolver.swift:1072-1074`: `var outcome = EjsSolveOutcome()` (a **struct**), then `defer { outcome.elapsedMs = … }`, then `return outcome`. A Swift `defer` runs **after** the return value is copied, so the caller always receives `elapsedMs = 0`.
- The real cost is visible in the log: `player-js … OK` at 23:11:51.938, then `solver: lib nạp OK` at 23:11:54.256, a **2.3 s** gap. That gap is the JSContext load plus preprocess plus solve, which matches your 1.0–1.4 s off-device solve plus load.
- **Not** related to the 403. The probe should time with an explicit end stamp.

**b. Access-token lifetimes are non-standard and vary per grant.**
- **[E]** `DUYỆT OK … expires_in 74954s` (23:11) and `expires_in 64770s` (22:16), both from `oauth2.googleapis.com/token` (`JoeYtIdentity.swift:341`).
- **[I]** Ordinary Google OAuth access tokens are issued for about 1 h. Lifetimes of 18–21 h that **differ between two grants an hour apart** mean this OAuth client is special-cased. Nobody has explained what class of client that is; it bears on item 6.

**c. Every reinstall mints a brand-new grant.**
- **[E]** Tokens live in `UserDefaults` (`JoeYtIdentity.swift:38-87`), which is wiped by delete+reinstall. Both 11-22 sessions began with `không có access token dùng được → needsIdentity` and a fresh device-code flow. So did 11-23, per the leader.
- **[I]** That is at least three or four new grants for a *scraped* TV client on one account in 48 h, plus one per test build since. It is a plausible risk signal for an account-level flag. It cannot be convicted from our logs.
- **Probe:** keep the grant in the Keychain to stop the churn.

**d. The census has three of every audio format.**
- **[E]** `census=[…140,140,140…249,249,249,250,250,250,251,251,251…]`: three audio tracks per itag (multi-language or auto-dub).
- **[I]** Assembly picks "itag 140". Which language track is never logged. Not a 403 cause; flag it for the playback language.

**e. The relay never retries a URL after waiting.**
- **[E]** yt-music-gpui (#246): TVHTML5 URLs got **403 right after extraction, then 206, 403, 206 after 8 s idle**.
- **[E]** Our recovery always **re-resolves**, which means fresh URLs every time.
- **[I]** If that warm-up behaviour now reaches our account, the app is structurally unable to escape it: every attempt is a "right after extraction" attempt. The probe's t+8 s re-GET covers this. Keep it.

### 8. The entitlement/membership angle is largely dead on existing evidence.

**[E]** From round 1:
- **public trailers** fail identically to members-only episodes;
- members-only /player returns `playability=OK` with 25–31 formats.

**[I]** Membership checks happen at /player and passed. A transport-level refusal that hits public videos too cannot be a membership-scope change. What survives is an **account/grant-level** flag (items 6 and 7c). It is distinguishable by probe variant 5 (anonymous tv_samsung on a public trailer): anonymous 206 + bearer 403 ⇒ the grant or account, not the client.

### 9. Field-by-field log diff: tool shipped, 11-23 input missing here

**[E]** `docs/yt403/logdiff.py` extracts and diffs every YouTube-path observable the app logs: app/OS, identity path, clientId/secret lengths, token lifetime, player locate pattern/path/bytes/markers, sts, solver result, /player timing/playability/formats/ciphered, client, captions, assembly pick, census, sidx outcomes, first-media latency, first frame, terminal reason, upstream status histogram, serve-head method→status, distinct player hashes and clients, device-code flow count and resolve count.

Run on the two 11-22 logs, the only deltas are expected ones (token lifetime, video, and timing). Run it as `python3 logdiff.py joetv-diag_2.txt <11-23 log>`.

**[E] Not observable at all in either log** (so nobody can have diffed them): the `pot`/`expire`/`ip`/`ipbits`/`c`/`cver` query params of issued URLs, googlevideo response headers, HTTP version and TLS details, redirect hops, remote-address family, and visitorData (not requested). These must be added to the probe log as **presence, family or hash only**.

### 10. The home network (IPv6 / Deco)

**[E]** Public guidance treats a 403 on the media stage as the signed URL not matching the client, IP or PO token, and recommends forcing IPv4 among the first fixes. I found **nothing** dated Nov 2026 about GVS and v4/v6 splits specifically. Evidence runs out there.

**Cheaper than a device install (home-runnable, not VM):**
- on any phone or Mac on the same Deco Wi-Fi, open test-ipv6.com, or run `curl -s -6 https://www.youtube.com/generate_204 -o /dev/null -w '%{http_code}'`;
- check the Deco app's IPv6 setting.

**No IPv6 on the LAN ⇒ the IP-family split is dead with zero installs.** If IPv6 is present, the probe's per-request family log decides it. Also log `ipbits` from the issued URL: `ipbits=0` means the URL isn't IP-bound and kills the lead outright.

---

## Amendments to the probe matrix (with cause)

- **Add 1a, living room:** tv_samsung + living-room PO token in all three places (item 1). It is heavy; schedule it after the cheap stage if 1/2/3/5 all fail.
- **Add to every variant's log:**
  - URL param presence/family (`pot`, `ipbits`, `ip` family, `c`, `cver`);
  - remote-address family per request;
  - `clientId` sha1[:8] and the scrape path (item 6);
  - the `/tv` vs `tv_config` jsUrl (item 5);
  - the sts actually sent per client (item 3);
  - a real solver duration (item 7a).
- **Add "SmartTube parity" to variant 2:** no key, plus `visitorData` (from `/tv`) in the body, `X-Goog-Visitor-Id`, `clientScreen`, `acceptLanguage`/`acceptRegion`/`utcOffsetMinutes`, `user` block, and `cpn`.
- **Add an on-403 re-solve** with alternate recent player hashes (item 5) to every failing variant. It costs only extra GETs.

## If I had to bet the next single device install

I would bet it on **item 1, the living-room PO token**, built into the probe alongside the cheap variants.

1. It is the only overlooked fact that is **both** hard evidence and a direct contradiction of an assumption every team has been building on ("no PO on TV clients"). The closest working relative, a device-code-OAuth TV app, mints it for **exactly** our two clients and attaches it to /player *and* every stream URL.
2. It explains the one thing nothing else does cleanly: an identical request accepted at byte zero on 11-22 and refused at byte zero on 11-23. A per-account enforcement flip does that; sts, key and range form do not (all were the same on 11-22).
3. It also covers the yt-music-gpui "TVHTML5 403 right after extraction" observation. That came from yt-dlp, which has no living-room token.

**It is not cheap.** But the 30-second VM runs of `scrape_check.py` (the plumbing exists?) and `auth_matrix` D/F (does dropping `key` reopen IOS/VISIONOS?) should run first. If D/F return 200, a no-key VISIONOS/IOS attempt is the cheaper first bet.
