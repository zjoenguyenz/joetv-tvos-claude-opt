"""FL-447 R4 host model: cost of JoeTVBView.railSpecs(catalog) (Python port
of the decade / Tron bo / Hay nhat / Nhieu phan / actor shelves) on the real
bundled tvb-catalog.json, x the builds per focus step read off the code
(main ~7, opt-2 0 after the first build). Python timing, not device."""
import json,sys,time,statistics
c=json.load(open(sys.argv[1])); T=[t for t in c['titles'] if t.get('isDisplayed', t.get('displayed', True))]
def build():
    dec={}
    for t in T:
        y=t.get('year')
        if y: dec.setdefault(y//10*10,[]).append(t)
    out=[]
    for d in sorted(dec):
        g=dec[d]
        if len(g)>=6: out.append([x['tmdbId'] for x in sorted(g,key=lambda x:-(x.get('popularity') or 0))])
    pop=lambda x:-(x.get('popularity') or 0)
    out.append(sorted([t for t in T if t.get('status')=='Ended'],key=pop)[:40])
    out.append(sorted([t for t in T if (t.get('voteCount') or 0)>=5],key=lambda x:(-(x.get('voteAverage') or 0),-(x.get('voteCount') or 0),pop(x)))[:30])
    out.append(sorted([t for t in T if len(t.get('seasons') or [])>1],key=pop)[:30])
    byA={}
    for t in T:
        for n in t.get('cast') or []:
            if n: byA.setdefault(n,[]).append(t)
    out.append(sorted([(n,len(v)) for n,v in byA.items() if len(v)>=6],key=lambda e:(-e[1],e[0]))[:20])
    return out
ts=[]
for _ in range(20):
    t=time.perf_counter(); build(); ts.append(time.perf_counter()-t)
one=statistics.median(ts)*1000
print(f"displayed titles={len(T)}  one build={one:.2f} ms")
print(f"main : 7 builds / focus step = {7*one:.1f} ms   opt-2: 0 builds after first = 0.0 ms")
