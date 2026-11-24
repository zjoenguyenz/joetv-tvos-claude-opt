# YT-403: googlevideo refuses every media segment (TVB + trailers)

Branch `claude/yt-403-diag`. **This is a diagnosis plus a bench. No app code changed**, because the evidence does not yet convict one hypothesis firmly enough to justify a fix (per the round's rule "chưa chắc thì … không sửa bừa").

Limits of this round: this session has no route to youtube.com or googlevideo (shell network is blocked: `curl youtube.com` → 000), so nothing below was measured from here. The measurement is `docs/yt403/gvs_bench.py`, to be run by the leader.

## What the code does today (verified in this repo)

- **Resolve:** InnerTube `/player` as **`tv_samsung`**: `TVHTML5`, `clientVersion 5.20260707`, Tizen 2.4 UA, with an `Authorization: Bearer` from the device-code OAuth (`JoeYtResolver.callPlayer`). No PO token is sent anywhere: there is no `pot` parameter and no `serviceIntegrityDimensions`.
- **Index:** `JoeYtHlsServer.fetchOriginRange` GETs the sidx range of the googlevideo URL (UA = the same Tizen UA, `Range` header). The session (and its master and media playlists) exists **only if this returns 206** with the exact byte count.
- **Segments:** `originEvents` GETs the same URL with the same UA and a `Range` header, and relays status verbatim. The `relay: upstream trả status 403` lines come from here.
- **Muxed fallback (itag 18):** `AVPlayerItem(url:)` directly. AVFoundation fetches with its own UA, not through the relay. "You do not have permission to access the requested resource" is AVFoundation's text for an HTTP 403.

## Hypotheses, ranked by the evidence

### 1. YouTube's late-Oct/Nov 2026 change to `tv_samsung` (TVHTML5) stream URLs: STRONGEST

External, independent observations from the same window:
- yt-dlp **2026.10.26** (26 Oct) made `tv_samsung` a default client. The yt-music-gpui project measured its URLs returning **403 on every immediate request (3 runs × 3 requests), and 206/403/206 after 8 s idle**. The same URLs returned 403 "with every UA". The previous client (`visionos`, yt-dlp 2026.08.19) returned 206 immediately. (AksharP5/yt-music-gpui PR #246, closed 23 Nov 2026.)
- hometube observed logged-in `tv_samsung` and `web_embedded` URLs serving 206 for about 1 min of media, then 403. It confirmed a fix on 6 Nov by dropping `tv_samsung` and requesting a GVS PO token (`fetch_pot=always`). (jimsimon/hometube PR #99.)
- yt-dlp's PO-Token guide: GVS PO tokens are not required for Premium accounts. It documents that a missing GVS token shows up as 403 on media requests.

This matches our log on every point: `/player` is healthy, URLs come back with `ciphered=0`, and the refusal is at googlevideo for every itag, including 18, which AVFoundation fetched with a different UA. That last fact means **the refusal does not depend on the UA**, which agrees with the PR #246 finding.

What the external evidence does not settle is whether the gate is **transient** (a "warm-up" window after issuance, as PR #246 saw; our app requests the first segment ~250 ms after resolve) or **persistent** (a GVS PO token requirement, as hometube saw).
**Measure:** `gvs_bench.py --clients tv_samsung,visionos --poll` gives first-media status at t = 0/1/2/4/8/16/30 s after resolve, anonymous and then with `--cookies`.

### 2. The player JS changed between the working and the failing session: STRONG timing, must be ruled in or out

- The owner's 2026-11-22 23:11 log (working playback): `tv-player-ias` **2 550 154 bytes**, solver hash `6b3d0364`.
- The 2026-11-23 21:41 session (failing): `tv-player-ias` **2 556 434 bytes**, hash `7f755914`.

So the player changed in exactly the break window. The solver's "NHẬN DIỆN ĐƯỢC … giải 2 challenge" only proves that the pattern was found and that strings came out. It does not prove the n-values are correct. A wrong `n` is a classic cause of googlevideo 403 for every format.

**Discriminators:**
- (a) Does the failing session log `sidx video OK` / `sidx audio OK`? The leader reports playlists served 200, and playlists cannot exist without a 206 on the sidx range. If those lines are present, googlevideo **accepted that very URL** (same UA, same IP) for the index bytes. That argues against a bad-n URL (a bad n is refused outright) and for a gate that bites on media.
- (b) The bench: if **yt-dlp's** `tv_samsung` URLs (independently solved n) are also 403, the app's solver is cleared.

### 3. URL bound to client/UA/IP, with the relay sending different headers: RULED OUT (pending check 2a)

- The relay uses `JoeYtClientSpec.tvSamsung.userAgent`, the same constant `/player` used, and it runs on the same device and IP.
- itag 18 was refused while being fetched by AVFoundation with a different UA, so UA binding cannot explain both.
- PR #246 saw 403 with every UA.
- If 2a holds, the same URL from the same process got 206 for the index, which removes binding altogether.

### 4. `cver` drift (`5.20260707` vs the current player): WEAK

Drift of the client version shows up at `/player` (LOGIN_REQUIRED, "not available on this app", or missing formats). Here `/player` returned `playability=OK` with 25–31 formats.
**Cheap test:** bump `clientVersion` in a scratch build. The bench can't test this directly because yt-dlp pins its own.

### 5. The device-code identity is flagged: WEAK, but testable

The stored token failed at the start of the session (expected: the 2026-11-22 approval had `expires_in 74954 s`, about 20.8 h, so it lapsed around 19:59 on 11-23). The re-auth then succeeded and `/player` was OK.
**Test:** run the bench anonymously on public vids (the trailers): 403 anonymous ⇒ not the identity. Then run with `--cookies` from the Gold account.

## Fix options inside the current architecture (resolve → assembly → AVPlayer)

Pick one after the bench, not before:

| bench result | fix | cost / risk |
|---|---|---|
| tv_samsung: 403 at t=0, 206 by t≈2–8 s (warm-up) | relay + muxed: on an **origin 403 within the first ~10 s of a URL's issuance**, retry the same range with backoff (1, 2, 4 s) before surfacing the status; delay the first segment request ~1 s after resolve | small, local to `JoeYtHlsServer`; adds ≤ ~7 s to the start in the worst case; does not touch rescue logic |
| tv_samsung persistently 403, **visionos 206** (anonymous and signed-in) | add a `visionos` `JoeYtClientSpec` and resolve with it first; tv_samsung stays the fallback | medium; must confirm that VISIONOS accepts the device-code bearer and serves members-only TVB, which only the bench `--cookies` run / a device run can show; per a VRChat report, visionos has **no muxed itag 18**, so the muxed tier would need tv_samsung |
| every token-less client 403 when signed in | GVS PO token required | see below |
| yt-dlp URLs 206, app URLs 403 | the app's n-solver is wrong on player `7f755914` | fix the solver against that player (needs the JS file) |

**On PO tokens:** a GVS PO token is minted by running Google's BotGuard attestation (in a web view or JS runtime) and is bound to the session or the video. It is heavy (a JS VM per mint, rotating per video) and fragile: bgutil reports that about half of minted integrity tokens are rejected for ~12 h (bgutil-ytdlp-pot-provider #285, 21–22 Nov 2026). It also means defeating YouTube's bot check rather than using a supported client. I would not build it into the app. If the bench shows no token-less client works signed in, the clean light path is the one the app already has: **hand the episode to the existing official-player surface** (`JoeYtPlayRouter` `.pageFallback` / `JoeYtPlayerView`). The official player carries its own attestation.

Today that hand-over fires only when the native construction can't be built. A media-403 death ends in `terminalFailure` → "Không phát được qua YouTube". Extending `handOverToPageFallback` to the "origin refused media on assembly and muxed" case is a **rescue-logic change** and needs the leader's explicit go-ahead. It is not done here.

## How the leader verifies independently

1. **From the owner's 11-23 log:**
   - grep `sidx video OK|sidx audio OK` in the failing session (check 2a);
   - grep `serve-head` to see whether the 403s were HEAD or GET;
   - read the time from `[YT-PLAY] mở player` to the first `upstream trả status 403` (≈250 ms ⇒ the warm-up hypothesis is in play).
2. **On a Mac on the owner's network:** `pip install -U yt-dlp` (plus deno), then:
   - `python3 docs/yt403/gvs_bench.py --poll` (anonymous)
   - `python3 docs/yt403/gvs_bench.py --cookies gold.txt --poll` (signed in)

   The output shows the status per client × itag × range, PO/SABR warnings, `pot=`/`n=` presence, and the 0–30 s status series. No URLs or tokens are printed.
3. **Paste the output back.** The fix row in the table above follows mechanically from it.

## Sources

- yt-music-gpui PR #246: https://github.com/AksharP5/yt-music-gpui/pull/246
- hometube PR #99: https://github.com/jimsimon/hometube/pull/99
- yt-dlp PO Token Guide: https://github.com/yt-dlp/yt-dlp/wiki/PO-Token-Guide
- yt-dlp releases (2026.10.26: visionos client, web_embedded fallbacks): https://github.com/yt-dlp/yt-dlp/releases
- bgutil-ytdlp-pot-provider #285: https://github.com/Brainicism/bgutil-ytdlp-pot-provider/issues/285
