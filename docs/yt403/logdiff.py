#!/usr/bin/env python3
"""YT-403 round 5 — field-by-field diff of two JoeTV DiagLogs.

Usage:  python3 logdiff.py working.txt failing.txt
Prints every YouTube-path observable the app logs, side by side, and
marks rows that differ. Values that could identify the account are
never logged by the app (lengths only), so nothing sensitive is printed.
Offline; runs anywhere.
"""
import re, sys
from collections import Counter

FIELDS = [  # (label, regex, group)  — first match wins unless noted
    ("app / system", r"\[diag\] session start (app=\S+ system=\S+)", 1),
    ("identity at start", r"resolve vid=\S+: (không có access token dùng được[^\n]*|/player)", 1),
    ("clientId/secret len", r"dùng clientId/secret \((id len \d+, secret len \d+)\)", 1),
    ("token approved", r"DUYỆT OK — (access token len \d+, refresh token \S+ \(len \d+\), expires_in \d+s)", 1),
    ("token refresh line", r"\[YT-ID\][^\n]*(refresh[^\n]*)", 1),
    ("player-js locate", r"player-js: trang /tv trỏ player bằng pattern '([^']+)'", 1),
    ("player-js path", r"nguồn \S+ OK — host (\S+), path (\S+), \d+ bytes", 2),
    ("player-js bytes", r"nguồn \S+ OK — host \S+, path \S+, (\d+) bytes", 1),
    ("player-js markers", r"bytes, (marker[^\n]*)", 1),
    ("sts", r"(?:sts|signatureTimestamp)[^\n]*?(\d{5,8})", 1),
    ("solver hash/result", r"\[YT-SOLVER\] hash (\S+ — giải xong[^\n]*)", 1),
    ("solver n line", r"solver: n — ([^\n]*)", 1),
    ("/player first", r"/player (\d+ms playability=\S+ formats=\d+ ciphered=\d+)", 1),
    ("/player client", r"\[YT-RES\][^\n]*client[= ](\S+)", 1),
    ("captions", r"captions (tracks=[^\n]*)", 1),
    ("assembly pick", r"OK — (cặp adaptive itag \S+ \([^)]*\))", 1),
    ("census", r"census=(\[[^\]]*\])", 1),
    ("sidx video", r"sidx video ([^\n]*)", 1),
    ("sidx audio", r"sidx audio ([^\n]*)", 1),
    ("first media byte", r"byte media đầu tiên đã giao cho AVPlayer sau (\d+ ms)", 1),
    ("first frame", r"first frame [^\n]*?sau (\d+ms)", 1),
    ("terminal", r"(terminal failure[^\n]*)", 1),
]

def scan(path):
    text = open(path, encoding="utf-8", errors="replace").read()
    out = {}
    for label, rx, g in FIELDS:
        m = re.search(rx, text)
        out[label] = m.group(g).strip() if m else "—"
    ups = Counter(re.findall(r"upstream trả status (\d{3})", text))
    heads = Counter(re.findall(r"serve-head (\w+) [^\n]*?→ (\d{3})", text))
    out["upstream statuses"] = dict(ups) or "—"
    out["serve-head method→status"] = {f"{k[0]} {k[1]}": v for k, v in heads.items()} or "—"
    out["distinct player hashes"] = sorted(set(re.findall(r"/s/player/([0-9a-f]{8})/", text))) or "—"
    out["distinct /player clients"] = sorted(set(re.findall(r"client=(tv_samsung|tv|ios|visionos)\b", text))) or "—"
    out["device-code flows"] = len(re.findall(r"MÃ KÍCH HOẠT", text))
    out["resolves"] = len(re.findall(r"/player \d+ms", text))
    return out

def main():
    a, b = scan(sys.argv[1]), scan(sys.argv[2])
    w = max(map(len, a))
    print(f"{'field'.ljust(w)} | {'WORKING':40s} | FAILING")
    for k in a:
        va, vb = str(a[k]), str(b[k])
        mark = "  " if va == vb else "≠ "
        print(f"{mark}{k.ljust(w)} | {va[:40]:40s} | {vb[:90]}")

if __name__ == "__main__":
    main()
