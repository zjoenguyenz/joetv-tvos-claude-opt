#!/usr/bin/env python3
"""YT-403 round 5 — which OAuth client does the app's credential scrape
pick TODAY, and is that choice stable / unambiguous?

Replicates JoeYtIdentity.scrapeTVClientCredentials() exactly (same UA,
same URLs, same regexes, same fallback order) and reports:
  - which path matched (base-js vs /tv HTML fallback)
  - sha1[:8] of the clientId it would use (never the id itself)
  - how many DISTINCT *.apps.googleusercontent.com ids each document holds
    (more than one = the fallback regex is ambiguous)
  - the same, repeated with a Cobalt UA and the Tizen 2.4 /player UA,
    to show whether YouTube serves different OAuth clients per UA.
VM-runnable (anonymous GETs of youtube.com/tv and its base.js).
Proves: what the scrape yields now from that IP. Does NOT prove what the
owner's TV scraped on 11-23 (the app logs only the id length) — compare
against the hash the probe app will log.
"""
import hashlib, re, urllib.request

UAS = {
    "app scrape (Tizen 6.5)": "Mozilla/5.0 (SMART-TV; Linux; Tizen 6.5) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/5.0 Chrome/85.0.4183.120 TV Safari/537.36",
    "player UA (Tizen 2.4)": "Mozilla/5.0 (SMART-TV; Linux; Tizen 2.4.0) AppleWebKit/538.1 (KHTML, like Gecko) Version/2.4.0 TV Safari/538.1",
    "Cobalt": "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/25.lts.30.1034943-gold (unlike Gecko), Unknown_TV_Unknown_0/Unknown (Unknown, Unknown)",
}
ID_STRICT = r'clientId:"([-\w]+\.apps\.googleusercontent\.com)"'
ID_LOOSE = r'([-\w]+\.apps\.googleusercontent\.com)'

def get(url, ua):
    req = urllib.request.Request(url, headers={"User-Agent": ua})
    return urllib.request.urlopen(req, timeout=30).read().decode("utf-8", "replace")

def h(s): return hashlib.sha1(s.encode()).hexdigest()[:8]

for name, ua in UAS.items():
    try:
        html = get("https://www.youtube.com/tv", ua)
    except Exception as e:
        print(f"{name}: /tv fetch failed {e}"); continue
    path, cid = None, None
    m = re.search(r'id="base-js" src="([^"]+)"', html)
    js = ""
    if m:
        src = m.group(1); src = src if src.startswith("http") else "https://www.youtube.com" + src
        try:
            js = get(src, ua)
        except Exception as e:
            print(f"{name}: base-js fetch failed {e}")
        s = re.search(ID_STRICT, js)
        if s:
            path, cid = "base-js strict", s.group(1)
        else:
            l = re.search(ID_LOOSE, js)
            if l and re.search(r'client_secret"?\s*:\s*"(\w+)"', js):
                path, cid = "base-js loose", l.group(1)
    if not cid:
        s = re.search(ID_STRICT, html) or re.search(ID_LOOSE, html)
        if s:
            path, cid = "/tv HTML fallback", s.group(1)
    jsurl = re.search(r'"jsUrl":"([^"]+)"', html)
    print(f"{name}: base-js={'yes' if m else 'NO'}  path={path}  clientId sha1={h(cid) if cid else '—'}  "
          f"distinct ids: html={len(set(re.findall(ID_LOOSE, html)))} js={len(set(re.findall(ID_LOOSE, js)))}  "
          f"jsUrl={jsurl.group(1) if jsurl else '—'}")

# Living-room (TV) PO-token plumbing that SmartTube relies on (MediaServiceCore
# TvConfig.java / AppInfo.java regexes). Presence only — values never printed.
ua = UAS["Cobalt"]
try:
    cfg = get("https://www.youtube.com/tv_config?action_get_config=true&client=lb4&theme=cl", ua)
    lr = re.search(r'"WEB_PLAYER_CONTEXT_CONFIG_ID_LIVING_ROOM_WATCH":\{.*?"jsUrl":"(.*?)"', cfg)
    print("tv_config: challengeRequestKey", "present" if re.search(r'"challengeRequestKey":"', cfg) else "absent",
          "| challengeParams", "present" if '"challengeParams"' in cfg else "absent",
          "| living-room jsUrl", lr.group(1) if lr else "—")
except Exception as e:
    print("tv_config fetch failed", e)
for name in ("app scrape (Tizen 6.5)", "Cobalt"):
    try:
        html = get("https://www.youtube.com/tv", UAS[name])
        print(f"/tv ({name}): LIVING_ROOM_PO_TOKEN_ID",
              "present" if '"LIVING_ROOM_PO_TOKEN_ID":"' in html else "absent",
              "| visitorData", "present" if '"visitorData":"' in html else "absent")
    except Exception as e:
        print(f"/tv ({name}) failed", e)
