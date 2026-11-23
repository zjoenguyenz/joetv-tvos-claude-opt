# HOW IT WORKS — JoeTV tvOS — read this BEFORE auditing or optimizing

Written by the leader from the production project records and code. If anything
here disagrees with the code on branch `main`, trust the code, flag the
disagreement in your PR, and do not silently follow this document.

## What the app is for
The owner watches films and TV on his Apple TV 4K: mostly torrent films, plus
TVB and some Vietnamese films. One app aggregates many sources into one
catalogue, one detail page and one player, so he never cares which source a
title came from. A sibling Android (Sony) version exists and must stay at
full parity with this tvOS version — same features, same source behaviour,
same playback rescue logic; the ONLY sanctioned difference is trailers for
torrent titles (tvOS: still images / own cached clip; Sony: YouTube trailer).

## The core flows
1. **Browse** — sections on a tab bar (the TV-channels section sits LAST by
   owner ruling). Home rails include trending, which is NOT baked into the
   app: following the owner's shared-data law, updatable content arrives as
   JSON on public data repos and is pulled at launch (e.g. `trending.json`,
   TVB/YouTube catalogues such as `tvb-yt.json` on the dabanh-playlist data
   repo). Do not embed updatable content in code.
2. **Catalogue & metadata** — TMDB is the metadata backbone (posters,
   backdrops, cast, trending). Film sources each have a client in code
   (KKPhim via phimapi.com, Film4K, Tủ Phim, VSMOV, MotChill and others in
   `Providers.swift` + per-source clients). Posters/backdrops load through
   the app's own image pipeline (sized TMDB image URLs, caching) — this
   pipeline decides how fast the UI feels.
3. **Detail page** — one unified page per title: backdrop (with trailer
   preview rules below), cast (tapping an actor opens their filmography;
   focusing a film there previews its trailer as the backdrop), and ONE
   combined row of playable sources gathered from every provider, with
   episodes grouped into compact chips.
4. **Source probing & player start** — when a title is opened/played,
   sources are probed in parallel with a short cap; source health is
   remembered per-URL so dead links are not retried blindly. Playback uses
   the app's player surface (KSPlayer-based view) for both normal streams
   and torrent streams. If a link dies, the app must rescue itself
   (advance/retry per the standing rules) instead of sitting on a spinner.
5. **Torrent path** — torrent titles resolve through debrid services:
   TorBox (carries most traffic), Real-Debrid, Premiumize (minor backup),
   plus Torrentio/MediaFusion-style resolvers. Tokens are baked in at
   BUILD time from GitHub Actions secrets of the ORIGINAL repo (this copy
   has none — never invent or commit any). Quality rule: prefer ≥FHD,
   then speed.
6. **TVB path** — TVB titles come from a YouTube-based catalogue (data repo
   JSON); backdrop trailer plays only when a ≥720p version exists,
   otherwise the best still image.
7. **Preview/trailer rules (owner-settled, do not redesign)** — a preview
   that resolves at low quality must NOT play (static backdrop stays); a
   finished preview crossfades back to the static backdrop, never parks on
   the last frame; torrent previews use only clips from already-cached
   files on tvOS.
8. **Themes** — multiple runtime-selectable themes (Settings has a default-
   theme choice; the app opens into the chosen theme). Each theme is its
   own code path built to its own approved drawing. The approved drawings
   are the sole appearance standard.
9. **Continue Watching / favourites / settings** live in the app sandbox.

## Build & delivery flow (how code reaches the owner's TV)
- GitHub Actions workflow `build-joetv.yml` builds the unsigned IPA with
  secrets (TMDB key, debrid tokens, MediaFusion URL) injected at build time.
- The owner signs with Signulous and installs by DELETE + REINSTALL: the
  sandbox is wiped every install. Therefore anything the app needs must be
  in the build or re-fetched at launch — never rely on data entered or
  cached in a previous install surviving.
- Target: Apple TV 4K, tvOS 27.x. tvOS focus is rendered by the OS itself
  (system plate + scale + lightened face); the app must design WITH that
  treatment, never draw a second competing focus layer.

## What "optimization" must never break
- Player start latency and the dead-link self-rescue behaviour; the unified
  source row on the detail page; episode chips; the poster image pipeline's
  corner/focus treatment (focus follows the poster's rounded corners);
  Sony↔tvOS parity (any behaviour change here must be flagged as a parity
  impact in the PR); the diagnostic-log export in Settings (LAN download
  link + QR code — tvOS has no share sheet).
- The app must stay light: it runs beside a player on a TV box, not on a
  phone — memory spikes in poster/backdrop handling are user-visible as
  crashes.
