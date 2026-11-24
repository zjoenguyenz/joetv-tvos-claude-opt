# DATA & API MAP — JoeTV tvOS — for Claude Code (leader-supplied, 2026-11-22)

Every URL below was extracted from the app code on main (2.1.4, c2a38504)
by the leader. No API keys, tokens or debrid credentials are listed here
on purpose — in production they are injected at build time from the
ORIGINAL repo's GitHub Actions secrets (TMDB key, TorBox / Real-Debrid /
Premiumize tokens, MediaFusion URL MF_URL). This copy has none and must
never receive any. If a task seems to need a real key, stop and say so
in the PR.

## 1. Shared data repos (pulled at launch)
- TV channels playlist (owner's merged M3U):
  https://raw.githubusercontent.com/zjoenguyenz/data-582047/main/582047.m3u
  (TV section — TVApp/TVStore.swift, JoeTV/JoeTVSection.swift)
- TVB YouTube catalogue:
  https://raw.githubusercontent.com/zjoenguyenz/dabanh-playlist/main/tvb-yt.json
  (JoeTV/JoeYtCatalog.swift; bundled fallbacks JoeTV/tvb-yt.json +
  JoeTV/tvb-catalog.json ship inside the app)
- Trending films rail:
  https://raw.githubusercontent.com/zjoenguyenz/dabanh-playlist/main/trending.json
  (JoeTV/JoeTrendingFile.swift)
dabanh-playlist is LIVE production data shared with other apps — read-only
reference for this work. Updatable content stays on data repos, never
embedded in code.

## 2. TMDB (metadata backbone)
- API base https://api.themoviedb.org/3/ — search/multi, search/tv,
  trending/all/week, movie & tv detail, credits, external_ids, images,
  videos, collection, person + combined_credits. Language vi-VN.
- Image CDN https://image.tmdb.org/t/p/ sizes w185, w500, w1280, h632,
  through the app's own image pipeline.

## 3. Film sources (clients in code)
- KKPhim: https://phimapi.com (JSON API, link_m3u8 per episode) — KkClient.swift
- Film4K: https://film4k.net, alt https://free2.phim4k.dev,
  API https://api.phimsrv.com/v1 — F4kClient.swift
- Tủ Phim (TP) and VSMOV (https://vsmov.com) and MotChill
  (https://motchillv.tel/, mirror https://motchillv.q-1208.fun)
  — Providers.swift
- Phim4K proxy helper: https://free.cryboiz.workers.dev

## 4. Torrent / debrid
- Addons: Torrentio https://torrentio.strem.fun, Cinemeta
  https://v3-cinemeta.strem.io, Stremverse
  https://stremverse1.alwaysdata.net, OpenSubtitles
  https://opensubtitles-v3.strem.io/manifest.json
- MediaFusion: build-time secret MF_URL (placeholder only in this copy).
- Real-Debrid API https://api.real-debrid.com/rest/1.0; TorBox and
  Premiumize flow through TorrentClient.swift with build-time tokens.
  Measured on the owner's TV/network: TorBox ~70%, Real-Debrid ~29%,
  Premiumize <1% — do not propose new debrid services.
- Sports torrent: Nuvio https://nuviosports.xyz primary, MediaFusion backup.

## 5. YouTube / TVB
- Innertube https://www.youtube.com/youtubei/v1/player (TV client),
  https://www.youtube.com/tv, embed, thumbnails https://i.ytimg.com/vi/
- Google device OAuth: https://oauth2.googleapis.com/device/code + /token,
  scope youtube. Local HLS server: JoeYtHlsServer.swift.

## 6. Rules
Source behaviour/probing/rescue is owner-settled — do not change it.
Flag every Sony-parity impact. Nothing here needs a secret to be read
for code work; live keys exist only in the production build.