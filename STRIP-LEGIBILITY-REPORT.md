# STRIP-LEGIBILITY — Private Cinema context strip, text over bright posters

Branch `claude/strip-legibility` (from `claude/opt-2-ui-lag` @ 7107d5a).
There are two commits, and they can be separated:

1. `strip: port the owner's 93% streak baseline`: the code from the prompt, copied verbatim (`JoeCinemaStreak`, `JoeCinemaGlass`, `joePCPinnedStripThreshold`, `JoePCStripTextWidthKey`, `JoePCPinnedBandCover`), plus the four strip call sites. The right-hand block is deleted and the strips publish the width key. **This commit is the 93% fallback.**
2. `strip: pinned title line keeps the eyebrow line's veil (text-line hold)`: the legibility fix. It touches only `JoePrivateCinema.swift` (the pinned cover and a new `JoePCStripHold` helper) and adds `docs/strip-bench/hold.py`.

Call-site count: the copy has **four** strip call sites: `cinemaContextStrip` (JoeHomeScreen), `cinemaContextStrip` (JoePhimHome), `tvbContextStrip` (JoeTVB) and `torContextStrip` (JoeTorrent). Each applies `.joePCPinnedBandCover()`. I found no fifth strip. If the production branch has one, its call site only needs the same tail as the other four. The fix itself sits in the shared cover, so it covers every call site automatically.

## Diagnosis: why the title washes out but the eyebrow does not

In the baseline's pinned cover, the Ink 0.5 strip overlay was nested **inside** the glass's bottom-dissolve mask (`black → 0.78`, `→ clear at 1`). That mask is a fraction of the whole cover, and the cover's height is `above + 88`. When the strip is pinned under the 132–148 pt bar, the cover is 220–236 pt tall. The dissolve therefore starts **36–40 pt down the 88 pt strip**, which is exactly where the title/meta line sits (y ≈ 34–79 in the strip):

| strip line (y in strip) | cover density, baseline | after |
|---|---|---|
| eyebrow (21) | 0.675 | 0.675 (unchanged) |
| title centre (55) | 0.47–0.50 | 0.67 |
| meta (66) | 0.33–0.35 | 0.67 |
| title baseline (70) | 0.27–0.29 | 0.67 |

So the "veil too weak" effect is not a global density problem. The fade-out reaches the title line and meta while the eyebrow above still has full density. That explains why the owner's photos show the title washing out over red/orange posters while the eyebrow stays readable.

## Mechanism: the text-line hold, with exact parameters

The overlay comes out of the dissolve mask and gets its own vertical opacity profile (`JoePCStripHold.stops`). The profile is chosen so that **glass + overlay equals the eyebrow line's density all the way down to the bottom of the text block**:

- `target = 1 − (1 − 0.35)(1 − 0.5) = 0.675`. This is the density the strip's upper half already has in the owner-approved build. It is not a new level.
- `overlay(m) = 1 − (1 − target)/(1 − 0.35·m)`, where `m` is the glass's own dissolve-mask value at that y. Stops are placed at the strip top and at `dStart` (both 0.50), at the midpoint (≈0.59), and at `holdEnd = h/2 + 34` = 78 pt (≈0.65).
- Below the text the hold uses the house eased fade (×0.55 / ×0.22 / 0) over a **40 pt skirt** past the strip's bottom. That fade runs 0.65 → 0 over 50 pt, which is the same slope as the glass's own baseline dissolve (0.675 over 52 pt).
- The horizontal mask is the same eased streak mask as the glass (`hMask`, shared): solid to the measured text end, then a 340 pt tail.
- The hold is painted only while the strip is pinned (height 0 otherwise). **The at-rest state is unchanged.**

Nothing else changes: strip geometry (88 pt, 14 pt leading pad), text styles, the at-rest streak, the glass's masks and the width key are all as in the baseline.

## Worst case designed against, with numbers

`docs/strip-bench/hold.py` composites flat poster colours in sRGB, which is how Core Animation blends, through glass, overlay and streak (veil and sheen). It reports WCAG contrast for the strip's actual colours: ivory title #F2EEE5, meta #ACB7B8, celadon eyebrow. It is conservative: it counts zero darkening from ultraThinMaterial and assumes a flat poster, so blur does not help.

Design target: a **pure white poster** (#FFFFFF) under the strip. The convicted cases are bright red/orange; I also tested yellow and white because they are brighter.

| poster | title centre | title baseline | meta |
|---|---|---|---|
| white #FFFFFF | 4.35 → **7.19** | 2.87 → **7.42** | 1.82 → **4.15** |
| yellow #FFD21F | 5.49 → 8.39 | 3.81 → 8.67 | 2.38 → 4.85 |
| orange #FF7A1A | 7.61 → 10.31 | 5.80 → 10.66 | 3.54 → 5.96 |
| red #E0301E | 10.10 → 12.24 | 8.43 → 12.63 | 5.02 → 7.07 |

(These are for a strip pinned at minY 148; at 132 the results are within ±0.3.) After the fix the title is ≥ 7:1 even over pure white, and the meta clears 4.5:1 everywhere except pure white (4.15).

**At rest** (not changed): the strip sits at y 560–648 over the full-screen backdrop. The backdrop's left scrim (Ink 0.93 → 0.65 over the text x-range) and the page scrim (≈0.30–0.44 at that height) are already under the 0.30 streak. Computed total density behind the title is ≈0.90 at x ≤ 600 and ≈0.77 at x ≈ 1000 (very long titles). The owner's photos convict the pinned state, so I did not touch the at-rest look.

## Why this lands differently from the five rejected approaches

1. **Cách A (fade mask on the text):** no mask touches the text. The hold is a background gradient under the text's container.
2. **Cách B (local patches, bare middle):** there is no patch. The hold uses the *same* horizontal mask as the approved pinned streak: one continuous streak from the left edge to the text end plus a 340 pt tail. No gap, no second shape, and no short fade (the tail is the approved 340 pt eased one).
3. **Mirror-glass full-width strip:** nothing is full width. The hold's width is `textEnd + 340`, as in the baseline. No glass is added (it is Ink only), and nothing is painted mid-screen beyond the approved tail.
4. **Cách D1 (weak ellipse, invisible):** D1 added a third, blurred shape at 0.55 that the eye could not find. The hold changes no shape. It restores density where the baseline's dissolve had cut it to 0.27–0.47 under the glyphs, bringing it back to the 0.675 the owner already sees on the eyebrow line. The bench shows the gain lands under the title (2.87 → 7.42 at the baseline over white), not around it.
5. **Cách D2 (strong ellipse, too big):** D2 covered about +280 pt in height at black 0.82–0.85. The hold is never darker than 0.675 combined, which is the strip's existing top-half value. Its vertical extent is the strip (88 pt) plus a fading 40 pt skirt, and the skirt is 0.52 → 0 at exactly the glass's own dissolve slope. That is less footprint than D2, at the baseline's own density.

## Per-screen declaration (settled properties)

| property | Home | Phim | TVB | Torrent |
|---|---|---|---|---|
| right-hand text block deleted | ✓ | ✓ | ✓ | ✓ |
| one streak from the left, no full-width bar | ✓ | ✓ | ✓ | ✓ |
| fade follows measured title (`JoePCStripTextWidthKey`) | ✓ | ✓ | ✓ | ✓ |
| text never masked/faded/shadowed/clipped (no `.shadow`) | ✓ | ✓ | ✓ | ✓ |
| at rest: streak bg 0.30 + sheen, 460 pt eased tail | ✓ unchanged | ✓ | ✓ | ✓ |
| pinned: frosted streak, textEnd + 340, eased stops, bottom dissolve | ✓ glass masks unchanged; overlay now held to text bottom | ✓ | ✓ | ✓ |
| geometry 88 pt / 14 pt pad / text styles | ✓ | ✓ | ✓ | ✓ |

All four call sites share one `JoePCPinnedBandCover`, so they share one mechanism.

## Performance and concurrency

- No blur, material or blend mode was added. The hold is one static `LinearGradient` with one mask, built in the same `GeometryReader` body the cover already re-evaluates. It adds a few arithmetic operations (`JoePCStripHold`, pure statics). Focus changes do no new work beyond the width preference the baseline already publishes.
- `JoePCStripHold` is an enum with `static let` Double/CGFloat values only, so it is concurrency-clean. `JoePCStripTextWidthKey.defaultValue` stays `static let`.

## What was NOT verified

- **Neither commit has been compiled locally** (Linux session). The CI build run is linked on the PR.
- **Nothing has been seen on a TV.** The numbers are the bench's flat-colour model. Real posters are textured, and the material's real tint and blur only make the result darker.
- **Pinned minY.** The bench covers 132 (the drawn deep state) and 148 (the bar height). The code computes from the live frame either way.
- **The 40 pt skirt** paints a soft Ink fringe, 0.52 fading to 0, just below the pinned strip, where the baseline painted nothing. It matches the glass's own dissolve slope, but the owner should check it over a bright poster row. If it reads as an edge, the skirt is one constant (`JoePCStripHold.skirt`): 24 pt gives a shorter, slightly steeper fringe and the same text-line hold.
- **The text-block bottom** (`h/2 + 34`) is derived from the fixed text styles (eyebrow 15 + 4 + title 34, centred). It is not measured, because measuring would add a preference write.
