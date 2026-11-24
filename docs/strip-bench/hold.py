"""Pinned context-strip legibility bench (claude/strip-legibility).

Mirrors JoePCPinnedBandCover + JoeCinemaStreak + JoePCStripHold
arithmetic and composites flat poster colours in sRGB (CA blends
gamma-encoded), then reports WCAG contrast of the strip text.
Conservative: ultraThinMaterial counted as 0 extra darkening and
no blur (a flat poster is unchanged by blur). Run: python3 hold.py
"""
INK = (0.047, 0.070, 0.082)
IVORY = (0.949, 0.933, 0.898)   # theme.text  (title)
META = (0.675, 0.718, 0.722)    # theme.meta  (year / meta)
CELADON = (0.847, 0.902, 0.733) # theme.heroMeta (eyebrow)
POSTERS = {
    "white #FFFFFF": (1, 1, 1),
    "yellow #FFD21F": (1, 0.824, 0.122),
    "orange #FF7A1A": (1, 0.478, 0.102),
    "red #E0301E": (0.878, 0.188, 0.118),
}
H, SKIRT = 88.0, 40.0
GLASS_INK, TOP_OV = 0.35, 0.5
TARGET = 1 - (1 - GLASS_INK) * (1 - TOP_OV)

def lin(c): return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
def lum(rgb): r, g, b = map(lin, rgb); return 0.2126*r + 0.7152*g + 0.0722*b
def cr(a, b): la, lb = sorted([lum(a), lum(b)], reverse=True); return (la+.05)/(lb+.05)
def over(dst, src, a): return tuple(d*(1-a) + s*a for d, s in zip(dst, src))

def glass_m(y, above):
    f = (above + y) / (above + H)
    return 1 if f <= 0.78 else max(0, (1 - f) / 0.22)

def overlay(m): return min(TARGET, max(0, 1 - (1 - TARGET) / (1 - GLASS_INK * m)))

def hold_stops(above):
    total = H + SKIRT
    hold_end = min(H, H/2 + 34)
    d = min(hold_end, max(0, 0.78*(above+H) - above))
    mid = d + (hold_end - d) / 2
    o_mid, o_end = overlay(glass_m(mid, above)), overlay(glass_m(hold_end, above))
    tail = total - hold_end
    return [(0, TOP_OV), (d, TOP_OV), (mid, o_mid), (hold_end, o_end),
            (hold_end + .45*tail, o_end*.55), (hold_end + .78*tail, o_end*.22), (total, 0)]

def interp(stops, y):
    for (y0, v0), (y1, v1) in zip(stops, stops[1:]):
        if y0 <= y <= y1:
            return v0 if y1 == y0 else v0 + (v1 - v0) * (y - y0) / (y1 - y0)
    return 0

def streak(y):
    # streak spans strip -14..H+14 (116 pt); vertical mask clear 0, solid .22-.78, clear 1
    t = (y + 14) / (H + 28)
    v = t/.22 if t < .22 else (1 if t <= .78 else max(0, (1-t)/.22))
    return 0.30 * v, 0.09 * (1 - t) * v   # ink alpha, white sheen alpha

def backdrop(poster, y, above, after):
    c = over(poster, INK, GLASS_INK * glass_m(y, above))
    if after:
        c = over(c, INK, interp(hold_stops(above), y))
    else:  # baseline: overlay 0.5 inside the glass's bottom dissolve
        c = over(c, INK, TOP_OV * glass_m(y, above))
    a, s = streak(y)
    c = over(c, INK, a)
    return over(c, (1, 1, 1), s)

LINES = [("eyebrow", 21, CELADON), ("title centre", 55, IVORY),
         ("title baseline", 70, IVORY), ("meta", 66, META)]
for above in (132, 148):
    print(f"\n=== strip pinned at minY={above} (cover {above+H:.0f} pt) ===")
    print("hold stops (y, alpha):", [(round(y, 1), round(v, 3)) for y, v in hold_stops(above)])
    for name, y, col in LINES:
        b = 1 - (1-GLASS_INK*glass_m(y, above))*(1-TOP_OV*glass_m(y, above))
        a = 1 - (1-GLASS_INK*glass_m(y, above))*(1-interp(hold_stops(above), y))
        print(f"  {name:15s} y={y:3d}  cover density before {b:.3f}  after {a:.3f}")
    for pname, p in POSTERS.items():
        row = []
        for name, y, col in LINES:
            row.append(f"{name} {cr(col, backdrop(p, y, above, False)):.2f}→{cr(col, backdrop(p, y, above, True)):.2f}")
        print(f"  {pname:15s} " + " | ".join(row))
    # fringe below the strip (new): density at 0/10/20/30/40 pt under the strip
    print("  fringe below strip (hold alpha):",
          [round(interp(hold_stops(above), H + d), 3) for d in (0, 10, 20, 30, 40)])
