"""Exhaustive equivalence of buildFromDisk's copy choice, main vs opt-1.
Each copy is one of: missing, unreadable (no stamp), stamp-only (stamp
decodes, full model fails), full (decodes). Stamps vary over
older/newer/equal/unparseable."""
import itertools
STATES=["missing","nostamp","stamponly","full"]; DATES=[1,2,None]   # None = unparseable
def full_ok(st): return st=="full"
def stamp_ok(st): return st in("stamponly","full")
def d(x): return -1 if x is None else x
def old(b,bd,c,cd):
    B=full_ok(b); C=full_ok(c)
    if B and C: return "cache" if d(cd)>=d(bd) else "bundled"
    if B: return "bundled"
    if C: return "cache"
    return None
def new(b,bd,c,cd):
    bs=stamp_ok(b); cs=stamp_ok(c)
    if bs and cs: order=["cache","bundled"] if d(cd)>=d(bd) else ["bundled","cache"]
    elif bs: order=["bundled"]
    elif cs: order=["cache"]
    else: return None
    for o in order:
        if full_ok(b if o=="bundled" else c): return o
    return None
n=0
for b,c in itertools.product(STATES,STATES):
    for bd,cd in itertools.product(DATES,DATES):
        n+=1; assert old(b,bd,c,cd)==new(b,bd,c,cd),(b,bd,c,cd,old(b,bd,c,cd),new(b,bd,c,cd))
print("all",n,"combinations choose the same copy")
