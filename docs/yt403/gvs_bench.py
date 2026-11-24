#!/usr/bin/env python3
"""YT-403 bench (claude/yt-403-diag) — run on a machine with internet,
ideally on the SAME network as the Apple TV.

Needs: python3 (stdlib only) + a current yt-dlp on PATH (with its JS
runtime set up, e.g. deno). yt-dlp is the reference resolver here:
its n/sig solving is independently maintained, so a status difference
between yt-dlp's URL and the app's URL isolates the app's solver.

What it does, per client x video:
  1. asks yt-dlp to resolve (= /player) with that player_client;
  2. records yt-dlp's PO-token / SABR warnings and the player JS id;
  3. for itags 18 / 135 / 137 / 140 GETs three byte ranges of the
     returned googlevideo URL:  index (0-2047), first media
     (64 KiB-1 MiB), deep (~40% of the file, 1 MiB);
  4. prints the HTTP status of each.

Usage:
  python3 gvs_bench.py                       # anonymous, all clients
  python3 gvs_bench.py --cookies cookies.txt # logged-in (Gold account)
  python3 gvs_bench.py --clients tv_samsung,tv --vids ahuhI_4dOr8
  python3 gvs_bench.py --clients tv_samsung,visionos --poll
URLs and tokens are never printed — statuses, sizes, warnings only.
"""
import argparse, json, re, subprocess, sys, time, urllib.request, urllib.error

VIDS = ["-fvytGF7toA", "ahuhI_4dOr8", "4x8E4PeenTQ", "tEbSSP6WG1Y"]
CLIENTS = ["tv_samsung", "visionos", "tv", "web_embedded", "android_vr", "web_safari"]
ITAGS = [18, 135, 137, 140]
UA_TV = ("Mozilla/5.0 (SMART-TV; Linux; Tizen 2.4.0) AppleWebKit/538.1 "
         "(KHTML, like Gecko) Version/2.4.0 TV Safari/538.1")

def ytdlp(vid, client, cookies):
    cmd = ["yt-dlp", "-J", "-v", "--extractor-args",
           f"youtube:player_client={client}", f"https://www.youtube.com/watch?v={vid}"]
    if cookies:
        cmd[1:1] = ["--cookies", cookies]
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
    warn = [l.strip() for l in p.stderr.splitlines()
            if re.search(r"PO Token|SABR|po_token|GVS|n challenge|sig", l, re.I)]
    player = re.findall(r"player[ _]?(?:id|version)?\s*[=:]?\s*([0-9a-f]{8})", p.stderr)
    try:
        info = json.loads(p.stdout)
    except Exception:
        return None, warn, player, p.stderr.strip().splitlines()[-1:] or ["?"]
    return info, warn, player, []

def status(url, start, end, ua):
    req = urllib.request.Request(url, headers={"User-Agent": ua,
                                               "Range": f"bytes={start}-{end}"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            body = r.read()
            return f"{r.status}/{len(body)}B"
    except urllib.error.HTTPError as e:
        return f"{e.code}"
    except Exception as e:
        return f"ERR({type(e).__name__})"

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cookies")
    ap.add_argument("--clients", default=",".join(CLIENTS))
    ap.add_argument("--vids", default=",".join(VIDS))
    ap.add_argument("--poll", action="store_true",
                    help="also re-request the first-media range of itag 140 at "
                         "t=0,1,2,4,8,16,30 s after resolve (warm-up vs persistent 403)")
    a = ap.parse_args()
    v = subprocess.run(["yt-dlp", "--version"], capture_output=True, text=True)
    print(f"yt-dlp {v.stdout.strip()}  mode={'cookies' if a.cookies else 'anonymous'}")
    for vid in a.vids.split(","):
        for client in a.clients.split(","):
            info, warn, player, err = ytdlp(vid, client, a.cookies)
            print(f"\n== {vid}  client={client}  player={sorted(set(player)) or '?'}")
            for w in warn[:6]:
                print("   warn:", w[:160])
            if not info:
                print("   resolve failed:", err)
                continue
            fmts = {f.get("format_id"): f for f in info.get("formats", []) if f.get("url")}
            for itag in ITAGS:
                f = fmts.get(str(itag))
                if not f:
                    print(f"   itag {itag}: (not offered)")
                    continue
                url = f["url"]
                size = f.get("filesize") or f.get("filesize_approx") or 0
                ua = f.get("http_headers", {}).get("User-Agent") or UA_TV
                deep = int(size * 0.4) if size else 20_000_000
                r = [status(url, 0, 2047, ua),
                     status(url, 65536, 1048575, ua),
                     status(url, deep, deep + 1048575, ua)]
                pot = "pot=yes" if re.search(r"[?&]pot=", url) else "pot=no"
                n = "n=yes" if re.search(r"[?&]n=", url) else "n=no"
                print(f"   itag {itag}: index {r[0]:>10}  first {r[1]:>12}  deep {r[2]:>12}   ({pot}, {n}, size={size})")
                if a.poll and itag == 140:
                    t0, series = time.time(), []
                    for t in (0, 1, 2, 4, 8, 16, 30):
                        time.sleep(max(0, t0 + t - time.time()))
                        series.append(f"t+{t}s:{status(url, 65536, 131071, ua)}")
                    print("   poll 140 first-media:", "  ".join(series))

if __name__ == "__main__":
    sys.exit(main())
