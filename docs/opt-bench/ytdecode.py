"""Host proxy for JoeYtStore.buildFromDisk: cost of fully decoding the
bundled tvb-yt.json AND a same-size cache copy (main) vs reading only the
generatedAt stamp of both and fully decoding just the chosen one (opt-1).
Python json is a stand-in for Foundation JSONDecoder: absolute numbers
differ on device, the ratio of work is what this shows."""
import json, sys, time, tracemalloc, statistics
raw = open(sys.argv[1], 'rb').read()
cache = raw  # a refreshed cache is the same document shape/size
def full(b): return json.loads(b)
def stamp(b):  # header-only model: JSONDecoder still scans the document
    return json.loads(b)["generatedAt"]   # (python has no partial decode; see note)
def run(fn, n=5):
    ts=[]; peaks=[]
    for _ in range(n):
        tracemalloc.start(); t=time.perf_counter(); fn(); ts.append(time.perf_counter()-t)
        peaks.append(tracemalloc.get_traced_memory()[1]); tracemalloc.stop()
    return statistics.median(ts)*1000, max(peaks)/1e6
def main_path():
    b=full(raw); c=full(cache); return (b,c)          # both alive at once
def opt_path():
    s1=stamp(raw); s2=stamp(cache)                     # transient, freed
    return full(cache)                                 # only the chosen one
d=json.loads(raw); print("file bytes", len(raw), "series", len(d["series"]),
  "episodes", sum(len(s.get("episodes",[])) for s in d["series"]) if isinstance(d["series"],list) else "?")
print("main  (2 full decodes, both resident): %.0f ms, peak %.1f MB" % run(main_path))
print("opt-1 (2 stamp scans + 1 full decode): %.0f ms, peak %.1f MB" % run(opt_path))
