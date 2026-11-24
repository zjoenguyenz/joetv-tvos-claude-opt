#!/usr/bin/env python3
"""YT-403 round 3 — authenticated /player request-shape matrix.

Runs from any machine (datacenter VM is fine for the /player part; the
segment part is only meaningful from a residential IP). stdlib only.

Inputs (never printed):
  --token   a VALID TV device-code access token (same kind the app
            mints), or env YT_BEARER
  --tv-key  the TVHTML5 public key the app sends (JoeYtClientSpec.tvSamsung.apiKey)
  --sts     signatureTimestamp of the current TV player JS (5 digits).
            Or --player-js URL_OR_FILE and it is extracted with yt-dlp's regex.

Variants (one /player each, per video):
  A  tv_samsung  — exactly the app today: key=TV, no playbackContext, no Origin
  B  tv_samsung  — yt-dlp HEAD shape: NO key, playbackContext{html5Preference,
                   signatureTimestamp}, Origin header
  B2 tv_samsung  — B + key=TV (isolates the key)
  C  tv          — TVHTML5 7.20260707.07.00, Cobalt UA, yt-dlp shape (no key)
  D  ios         — no key
  E  ios         — key=TV
  F  visionos    — no key
  G  visionos    — key=TV
For each: HTTP status, error message, playability, #formats with url,
#ciphered, whether URLs carry n=. For URLs WITHOUT n (ios / visionos)
it also GETs the first media range and prints the status — no solving
needed. TV-family URLs carry n and need the JS solver: use
gvs_bench.py --extra (see ROUND3.md) for their segment status.
"""
import argparse, json, os, re, urllib.request, urllib.error

VIDS = ["-fvytGF7toA", "ahuhI_4dOr8", "4x8E4PeenTQ", "tEbSSP6WG1Y"]
TIZEN_UA = ("Mozilla/5.0 (SMART-TV; Linux; Tizen 2.4.0) AppleWebKit/538.1 "
            "(KHTML, like Gecko) Version/2.4.0 TV Safari/538.1")
CLIENTS = {  # copied from yt-dlp master 6f73a8d (2026-11-23), _base.py INNERTUBE_CLIENTS
    "tv_samsung": (7, {"clientName": "TVHTML5", "clientVersion": "5.20260707",
                       "deviceMake": "Samsung", "deviceModel": "UKS9800",
                       "userAgent": TIZEN_UA, "osName": "Tizen", "osVersion": "2.4.0"}),
    "tv": (7, {"clientName": "TVHTML5", "clientVersion": "7.20260707.07.00",
               "userAgent": "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/25.lts.30.1034943-gold "
                            "(unlike Gecko), Unknown_TV_Unknown_0/Unknown (Unknown, Unknown)"}),
    "ios": (5, {"clientName": "IOS", "clientVersion": "21.26.4", "deviceMake": "Apple",
                "deviceModel": "iPhone16,2",
                "userAgent": "com.google.ios.youtube/21.26.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
                "osName": "iPhone", "osVersion": "18.3.2.22D82"}),
    "visionos": (101, {"clientName": "VISIONOS", "clientVersion": "1.02", "deviceMake": "Apple",
                       "deviceModel": "RealityDevice17,1",
                       "userAgent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 "
                                    "(KHTML, like Gecko) Version/26.0 Safari/605.1.15",
                       "osName": "visionOS", "osVersion": "26.5.23O471"}),
}
# name, client, send_key, yt-dlp shape (playbackContext + Origin)
VARIANTS = [("A", "tv_samsung", True, False), ("B", "tv_samsung", False, True),
            ("B2", "tv_samsung", True, True), ("C", "tv", False, True),
            ("D", "ios", False, True), ("E", "ios", True, True),
            ("F", "visionos", False, True), ("G", "visionos", True, True)]

def sts_from(src):
    if os.path.exists(src):
        code = open(src, encoding="utf-8", errors="replace").read()
    else:
        code = urllib.request.urlopen(src, timeout=60).read().decode("utf-8", "replace")
    m = re.search(r"(?:signatureTimestamp|sts)\s*:\s*(?P<sts>[0-9]{5})", code)
    return int(m.group("sts")) if m else None

def player(vid, client, send_key, ytdlp_shape, token, tv_key, sts):
    num, ctx = CLIENTS[client]
    body = {"videoId": vid, "context": {"client": dict(ctx, hl="en", gl="US")},
            "contentCheckOk": True, "racyCheckOk": True}
    if ytdlp_shape:
        cpc = {"html5Preference": "HTML5_PREF_WANTS"}
        if sts and client in ("tv_samsung", "tv"):  # REQUIRE_JS_PLAYER clients only
            cpc["signatureTimestamp"] = sts
        body["playbackContext"] = {"contentPlaybackContext": cpc}
    url = "https://www.youtube.com/youtubei/v1/player?prettyPrint=false"
    if send_key:
        url += "&key=" + tv_key
    h = {"Content-Type": "application/json", "User-Agent": ctx["userAgent"],
         "Authorization": "Bearer " + token, "X-YouTube-Client-Name": str(num),
         "X-YouTube-Client-Version": ctx["clientVersion"]}
    if ytdlp_shape:
        h["Origin"] = "https://www.youtube.com"
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers=h)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read())
        except Exception:
            return e.code, {}

def seg(url, ua):
    req = urllib.request.Request(url, headers={"User-Agent": ua, "Range": "bytes=65536-131071"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return f"{r.status}/{len(r.read())}B"
    except urllib.error.HTTPError as e:
        return str(e.code)
    except Exception as e:
        return f"ERR({type(e).__name__})"

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--token", default=os.environ.get("YT_BEARER"))
    ap.add_argument("--tv-key", required=True)
    ap.add_argument("--sts", type=int)
    ap.add_argument("--player-js")
    ap.add_argument("--vids", default=",".join(VIDS))
    a = ap.parse_args()
    if not a.token:
        ap.error("--token or YT_BEARER required")
    sts = a.sts or (sts_from(a.player_js) if a.player_js else None)
    print(f"sts={sts}")
    for vid in a.vids.split(","):
        print(f"\n== {vid}")
        for name, client, send_key, shape in VARIANTS:
            code, j = player(vid, client, send_key, shape, a.token, a.tv_key, sts)
            err = (j.get("error") or {}).get("message", "")
            ps = j.get("playabilityStatus") or {}
            sd = j.get("streamingData") or {}
            fmts = (sd.get("formats") or []) + (sd.get("adaptiveFormats") or [])
            with_url = [f for f in fmts if f.get("url")]
            ciph = sum(1 for f in fmts if f.get("signatureCipher") or f.get("cipher"))
            has_n = any(re.search(r"[?&]n=", f["url"]) for f in with_url)
            line = (f"  {name:2s} {client:10s} key={'TV' if send_key else '--'} "
                    f"shape={'yt-dlp' if shape else 'app   '}  HTTP {code}"
                    f"  {ps.get('status', '-'):16s} fmts={len(with_url)} ciph={ciph} n={'yes' if has_n else 'no'}")
            if err:
                line += f"  err='{err[:70]}'"
            if with_url and not has_n:
                pick = next((f for f in with_url if f.get("itag") == 140), with_url[0])
                line += f"  seg(itag {pick.get('itag')})={seg(pick['url'], CLIENTS[client][1]['userAgent'])}"
            print(line)

if __name__ == "__main__":
    main()
