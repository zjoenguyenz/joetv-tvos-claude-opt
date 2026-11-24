"""FL-447 R1 host model: cost of one Private Cinema home focus step,
main vs claude/opt-2. Python ports of Providers.normalizeTitle and the
railSpecs trending-file dedupe; real titles from tvb-yt.json/trending.json.
Build counts per focus step are read off the code (see PR table).
Rail sizes are ASSUMED (24 per catalogue rail, merged 96): the live
catalogues need network + device."""
import json, sys, time, unicodedata, random, statistics
yt=json.load(open(sys.argv[1])); tr=json.load(open(sys.argv[2]))
names=[s['title'] for s in yt['series']]+[s.get('rawTitle','') for s in yt['series']]
random.seed(1)
def norm(s):  # port of normalizeTitleUncached (folding ~ NFD + strip marks)
    n=''.join(c for c in unicodedata.normalize('NFD',s) if not unicodedata.combining(c))
    n=n.replace('đ','d').replace('Đ','d').lower(); out=[]; last=True
    for ch in n:
        if ch.isalnum(): out.append(ch); last=False
        elif not last: out.append(' '); last=True
    return ''.join(out).strip()
memo={}
def norm_memo(s):
    r=memo.get(s)
    if r is None: r=memo[s]=norm(s)
    return r
def movie(): return (random.choice(names), random.choice(names), str(random.randint(2000,2026)))
rail_sizes=[96]+[24]*4+[24]*11+[24]*10          # merged, VN x4, genre8+country3, provider x10
specs=[[movie() for _ in range(n)] for n in rail_sizes]
file_specs=[[(i.get('title') or i.get('name') or '', i.get('original_title') or '', str(i.get('year','')))
             for i in r.get('items',[])] for r in tr['rails']]
def build(nf):
    keys=set()
    for sp in specs:
        for (n,o,y) in sp:
            keys.add(nf(n)+'|'+y)
            if o: keys.add(nf(o)+'|'+y)
    kept=[[m for m in fs if nf(m[0])+'|'+m[2] not in keys and not (m[1] and nf(m[1])+'|'+m[2] in keys)] for fs in file_specs]
    return kept
def step(builds, nf, reps=5):
    ts=[]
    for _ in range(reps):
        t=time.perf_counter()
        for _ in range(builds): build(nf)
        ts.append(time.perf_counter()-t)
    return statistics.median(ts)*1000
movies=sum(rail_sizes); print(f"catalogue movies={movies}, trending-file items={sum(len(f) for f in file_specs)}")
print(f"main : 39 railSpecs builds/focus step, no memo : {step(39, norm):7.1f} ms")
build(norm_memo)  # memo warm (steady state after first render)
print(f"opt-2: 12 railSpecs builds/focus step, memo    : {step(12, norm_memo):7.1f} ms")
print(f"(for reference) 39 builds with memo only       : {step(39, norm_memo):7.1f} ms")
