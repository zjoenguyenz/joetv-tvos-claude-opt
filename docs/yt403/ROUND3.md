# YT-403 round 3: authenticated /player, 400 on non-TV clients

There is no app change in this round. This is analysis plus `auth_matrix.py`. Sources are yt-dlp master **6f73a8d (2026-11-23)**, which I cloned and read: `yt_dlp/extractor/youtube/_base.py` and `_video.py`. The app's code is `JoeYtResolver.callPlayer` on `main`. Every point is labelled **[evidence]** (read in source or measured by the leader) or **[inference]**.

## 0. The request-shape diff (app vs yt-dlp HEAD, tv_samsung)

| | app (`callPlayer`) | yt-dlp HEAD (`_extract_player_response` → `_call_api`) |
|---|---|---|
| `key=` query | **sent** (`JoeYtClientSpec.apiKey`) | **never sent**: `_call_api(api_key=None)`, and there is no INNERTUBE_API_KEY anywhere in the extractor **[evidence]** |
| `playbackContext.contentPlaybackContext` | **absent** | `{html5Preference: HTML5_PREF_WANTS, signatureTimestamp: sts}`; sts comes from the same player JS used for solving (`_extract_signature_timestamp`, regex `(?:signatureTimestamp\|sts)\s*:\s*(\d{5})`) **[evidence]** |
| `Origin` header | absent | `https://www.youtube.com` **[evidence]** |
| `X-Goog-Visitor-Id` | absent | sent when known (it is filtered out when unknown) **[evidence]** |
| auth | OAuth `Bearer` (TV device code) | cookies (SAPISIDHASH); yt-dlp has **no OAuth path** in HEAD **[evidence]** |
| client context | identical to yt-dlp's `tv_samsung` (5.20260707, Samsung UKS9800, Tizen UA) **[evidence]** | — |
| order | player JS fetched **after** `/player` (solver stage) | player JS fetched **before**, because sts is needed in the request **[evidence]** |

## Q1. What is the 400?

**[evidence]** A garbage bearer gives 401 and a valid TV token gives 400 on IOS and VISIONOS. So the token is authenticated *before* the 400, and the 400 is about the **combination**: the valid TV-client token together with the non-TV clientName and/or the API key's project.

**[inference]** There are two mechanisms, and one cheap test separates them:
- **(i) API-key/credential project mismatch.** Google front ends reject a request whose `key` belongs to a different GCP project than the OAuth client that minted the token. The app sends the iOS/web key with a token from the TV OAuth client. Google's specific text for this is "API key and authentication credential are from different projects", returned as 400 INVALID_ARGUMENT. InnerTube's generic "Request contains an invalid argument" fits.
- **(ii) Token bound to the client family.** Since late 2024, OAuth on InnerTube is accepted for TV clients only. This is why yt-dlp dropped OAuth; that is from my memory of yt-dlp history, not re-verified this round.

**Test (auth_matrix variants D/E/F/G):** IOS/VISIONOS **without any key**, and **with the TV key**.
- **D or F = 200** ⇒ mechanism (i), and the fix is "drop `key`".
- **D/E/F/G all 400** ⇒ mechanism (ii): no non-TV client can carry this token, and options (b) and (c) are dead.

I expect (ii). That is inference, which is why it is a VM test and not a device build.

**A TV-family client that might escape the gate:** HEAD has `tv` (TVHTML5 **7.20260707.07.00**, Cobalt UA, `SUPPORTS_COOKIES`, no GVS PO policy) and `tv_simply` (TVHTML5_SIMPLY, **GVS PO required**, no account support). It does **not** have `tv_embedded` in INNERTUBE_CLIENTS. I found no `android_tv` client and won't invent one. `tv` shares the clientName with tv_samsung, so the token should pass **[inference]**. Whether `tv`'s URLs escape the segment gate is **unknown**; no source tested it signed-in.

## Q2. Is the body missing something?

**Yes, for the TV path, and it is the strongest new lead [evidence + inference].** The app sends **no `playbackContext` / `signatureTimestamp`**. yt-dlp sends sts for every client with `REQUIRE_JS_PLAYER` (the default; tv_samsung and tv). sts tells the server **which player version the client will use to transform `n`/`sig`**.

The working session (11-22) ran player `6b3d0364` and the failing one (11-23) ran `7f755914`.

**[inference]** Without sts, the server assumes some player version. Once the live player rotates, the app's `n` (solved with the newly fetched JS) and the server's expectation can disagree. googlevideo then refuses **every** request for **every** itag **from the first byte**. That is exactly the device symptom. A missing GVS PO token instead shows "206 for ~60 s, then 403" (hometube, the yt-dlp guide), which is **not** our symptom.

For the non-TV 400, the body is not the issue: visionos and ios don't require the JS player (`REQUIRE_JS_PLAYER: False`), and anonymous calls pass with the same body.

## Q3. Current working route for authenticated playback

**[evidence]** In yt-dlp HEAD:
- Authenticated default clients: `('tv_samsung', 'web_embedded', 'web')`. Premium: `('web_creator', 'tv_samsung', 'web')`.
- `tv_samsung` and `tv` have **no `GVS_PO_TOKEN_POLICY`**; web and web_embedded use the web PO policies.

So as of 2026-11-23 the maintainers still ship **signed-in tv_samsung without a PO token** as the first choice. A GVS PO token is **not** declared mandatory for every authenticated client.

**Counter-evidence:** hometube (cookies) saw signed-in tv_samsung/web_embedded stop at ~1 min. Its fix added PO tokens for **web_creator/web_embedded**, not for tv. Its symptom differs from ours (first byte), so it doesn't transfer directly **[inference]**.

## Q4. Ranked next build (one device cycle)

1. **(a, parity) tv_samsung with yt-dlp's exact request shape.**
   - Fetch the TV player JS **before** `/player` (it's already cached per session).
   - Extract sts with yt-dlp's regex.
   - Send `playbackContext.contentPlaybackContext {html5Preference, signatureTimestamp}`.
   - **Drop `key`**, add `Origin`.

   *Reason:* this is the only known diff between the app and the request yt-dlp ships today for this exact client. It is consistent with the token binding (same clientName), and sts targets the one variable that changed in the break window. *Verify:* `auth_matrix` variant **B** vs **A** gives /player parity. The segment status comes from `gvs_bench.py --clients tv_samsung --extra "--add-header Authorization:Bearer\ $T"` from a residential IP, because yt-dlp then solves n with HEAD's solver on `7f755914`.
2. **(a, family) `tv` (7.20260707.07.00, Cobalt UA) as the second resolve attempt in the same build,** with the same parity shape. It is gated by a 64 KiB first-media probe: if tv_samsung's probe gets 403, re-resolve with `tv` before building the item. *Reason:* the same token binding, a different client version, and no PO policy in yt-dlp. It costs one extra `/player` only on failure.
3. **(d) Safety net in the same build: hand a media-403 death to the existing JoeYtWeb surface** instead of the "Không phát được" slate. *Reason:* the official TV web player carries its own attestation, so it is independent of all the above. This is a rescue-logic change, so it needs your explicit OK.
4. **(b) visionos/ios with the TV key: do NOT spend a device cycle.** Run `auth_matrix` D–G on the VM first. Only if D/E/F/G show 200 does it enter a build.
5. **(c) playbackContext for the non-TV attempts:** dead unless step 4 shows 200, because the 400 precedes any body semantics.
6. **(e) PO-token provider: not unavoidable on current evidence.** yt-dlp HEAD's signed-in tv path declares no GVS PO policy, and our symptom is not the PO signature. It becomes unavoidable only if parity tv_samsung **and** tv both 403 from a residential IP with yt-dlp's solver. Even then (d) is lighter.

## How to run

```
# /player matrix — VM is fine. Token: a TV device-code access token (test account ok).
YT_BEARER=… python3 docs/yt403/auth_matrix.py --tv-key <JoeYtClientSpec.tvSamsung.apiKey> \
    --player-js https://www.youtube.com/s/player/7f755914/tv-player-ias.vflset/tv-player-ias.js
#   (or pass --sts NNNNN)

# segment status with yt-dlp's solver, residential IP, same token:
python3 docs/yt403/gvs_bench.py --clients tv_samsung,tv --vids ahuhI_4dOr8 \
    --extra "--add-header Authorization:Bearer\ $YT_BEARER" --poll
```

The player-JS URL path above is the usual `/s/player/<hash>/…` layout; copy the exact path from the app's `player-js` log line if it differs. No URLs, tokens or keys are printed by either script.

**Not verified:** none of this was run from here (no network route to YouTube from this session). The predictions in Q1/Q2 are labelled inference and the matrix is built to falsify them.
