#!/usr/bin/env python3
"""YT-403 round 4 — is the app's n/sig answer the same as yt-dlp's?

Runs the app's OWN bundled solver (JoeTV/yt.solver.lib.min.js +
yt.solver.core.min.js) on a given player JS, with the stdin shape
yt-dlp's ejs.py `_construct_stdin` builds, under every JS engine it
finds: node, deno, and Apple's JavaScriptCore `jsc` (macOS:
/System/Library/Frameworks/JavaScriptCore.framework/Versions/Current/Helpers/jsc).

Proves:   whether engines (V8 vs JavaScriptCore — the app's engine)
          give the same n outputs for player X; and the bundle's
          sha3-512 vs yt-dlp's vendored hashes (printed).
Does NOT: prove googlevideo accepts the n (that needs a live URL from
          a non-bot-walled IP) — it only removes "the app's solver
          disagrees with yt-dlp's" from the hypothesis list.
VM-safe:  fetches only the static player file (or pass --player-file).

Usage: python3 solver_equiv.py --player 7f755914 [--variant tv]
"""
import argparse, hashlib, json, os, shutil, subprocess, tempfile, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.path.join(HERE, "..", "..", "JoeTV")
VARIANTS = {"tv": "tv-player-ias.vflset/tv-player-ias.js",
            "main": "player_ias.vflset/en_US/base.js"}
YTDLP_HASHES = {  # yt-dlp 6f73a8d vendor/_info.py (ejs 0.8.0)
    "yt.solver.lib.min.js": "8420c259ad16e99c",
    "yt.solver.core.min.js": "ee5b307d07f55e91",
}
CHALLENGES = ["ZdZIqFPQK-Ty8wId", "AAAAAAAAAAAAAAAA", "0123456789abcdefGHIJ", "x_-y_-z_-w_-v_-u"]
JSC_MAC = "/System/Library/Frameworks/JavaScriptCore.framework/Versions/Current/Helpers/jsc"

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--player", default="7f755914")
    ap.add_argument("--variant", default="tv", choices=VARIANTS)
    ap.add_argument("--player-file")
    a = ap.parse_args()
    lib = open(os.path.join(APP, "yt.solver.lib.min.js")).read()
    core = open(os.path.join(APP, "yt.solver.core.min.js")).read()
    for name, code in (("yt.solver.lib.min.js", lib), ("yt.solver.core.min.js", core)):
        h = hashlib.sha3_512(code.encode()).hexdigest()
        print(f"{name}: sha3-512 {h[:16]}…  {'== yt-dlp vendored' if h.startswith(YTDLP_HASHES[name]) else '!= yt-dlp vendored'}")
    if a.player_file:
        player = open(a.player_file, encoding="utf-8").read()
    else:
        url = f"https://www.youtube.com/s/player/{a.player}/{VARIANTS[a.variant]}"
        player = urllib.request.urlopen(urllib.request.Request(
            url, headers={"User-Agent": "Mozilla/5.0"}), timeout=60).read().decode("utf-8")
    print(f"player {a.player}/{a.variant}: {len(player)} bytes")
    data = {"type": "player", "player": player, "output_preprocessed": False,
            "requests": [{"type": "n", "challenges": CHALLENGES}]}
    # ejs.py _construct_stdin, with print() fallback for jsc (no console.log there)
    script = (lib + "\nObject.assign(globalThis, lib);\n" + core +
              "\nvar __out = JSON.stringify(jsc(" + json.dumps(data) + "));"
              "\nif (typeof console !== 'undefined') console.log(__out); else print(__out);\n")
    with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False) as f:
        f.write(script)
        path = f.name
    engines = [("node", ["node", path]), ("deno", ["deno", "run", path]),
               ("jsc", [shutil.which("jsc") or JSC_MAC, path])]
    results = {}
    for name, cmd in engines:
        if not (shutil.which(cmd[0]) or os.path.exists(cmd[0])):
            print(f"{name}: not installed")
            continue
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
        out = (p.stdout.strip().splitlines() or [""])[-1]
        try:
            resp = json.loads(out)
            results[name] = json.dumps(resp.get("responses"), sort_keys=True)
            print(f"{name}: {results[name][:300]}")
        except Exception:
            print(f"{name}: FAILED rc={p.returncode} {p.stderr.strip()[-300:]}")
    vals = set(results.values())
    print("VERDICT:", "engines agree" if len(vals) == 1 and results else
          "ENGINES DISAGREE — app (jsc) n differs" if len(vals) > 1 else "no engine ran")
    os.unlink(path)

if __name__ == "__main__":
    main()
