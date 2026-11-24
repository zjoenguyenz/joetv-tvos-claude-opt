import SwiftUI
import UIKit

// MARK: - Private Cinema shared pieces (v2.1.0 (Private Cinema))
//
// The shared building blocks of the Private Cinema theme
// (v2.1.0 (Private Cinema)) that live OUTSIDE any one
// screen: the shell's live clock and the trailer-preview
// chain for surfaces that are not JoeMovieDetail (the
// actor filmography page). (The PC detail compositions'
// text-line credits blocks live with their compositions:
// JoeActorNameLabel in JoeMovieDetail.swift and
// JoeTorNameLabel in JoeTorrent.swift.) Everything here
// follows the house
// rules: one render owner per control (the shared
// JoeCardButtonStyle via .joeCardButton()), value-only
// focus changes (no view structure conditional on
// @FocusState), and nothing recomputed in body on the
// focus path.

// MARK: - Live clock (shell top bar)

/// The Private Cinema top bar's live clock (v2.1.0
/// (Private Cinema)): "HH:mm", refreshed on a 30 s
/// periodic timeline so the minute flips without any
/// polling loop of the app's own. JoeTVApp's topBar
/// renders this under the PC theme only.
struct PCClockLabel: View {
    @Environment(\.joeTheme) private var theme

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(context.date, format: PCClockLabel.clockStyle)
                // FIX-213 (Fault 8): the design's bar clock
                // is plain ivory text at the nav's own size
                // (24) — no meta dimming.
                .font(JoePCType.outfit(24))
                .foregroundStyle(theme.text)
        }
    }

    static let clockStyle = Date.FormatStyle().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
}

/// FIX-213 (Faults 8/16): the PC design bar's height —
/// the single source both the bar itself (JoeTVApp
/// .topBar's PC arm) and the bar-clearance inset below
/// read, so the two can never drift apart.
/// FIX-214 (DESIGN-PASS-214 §1a): 132 → 148 — the raised
/// band is one half of the clearance system (bar 148 +
/// hero text zone 394 ≤ stage 560) that ends the
/// band/text collisions of the 2.1.3 round for good;
/// every reader of this constant (bar frame, inset,
/// the homes' −joePCBarHeight compensations) moves
/// together by construction.
let joePCBarHeight: CGFloat = 148

/// FIX-213 (Fault 16): the bar-clearance inset for the
/// PC homes' scroll views. The shell's PC bar OVERLAYS
/// the content (ZStack), and a pinned Section header
/// (the 88 pt context strip) pins at its scroll view's
/// top edge — which is the bar's own band, so the
/// strip's text line stood inside the band, colliding
/// with the wordmark and the nav items in EVERY pinned
/// state (owner 2026-11-22, corrected: "Ko hẳn là lúc
/// quay về mà hầu như lúc nào cũng vậy"). The design
/// pins its strip BELOW the header (deep context strip:
/// y132, directly under the 132 header, on plain Ink).
/// This inset reserves exactly the bar's height at the
/// scroll view's top: the strip now pins under the bar,
/// scrolled cards can never enter the band, and the
/// band's backdrop at rest is preserved by the homes'
/// own compensation (their stacks carry a matching
/// negative top padding, so the hero still paints
/// behind the transparent bar exactly as before).
/// PC-only: every other theme's scroll views are
/// untouched (their shell is a VStack — bar above
/// content, nothing pins into it).
private struct JoePCBarInset: ViewModifier {
    @Environment(\.joeTheme) private var theme

    @ViewBuilder
    func body(content: Content) -> some View {
        if theme.id == .privateCinema {
            content.safeAreaInset(edge: .top, spacing: 0) {
                Color.clear.frame(height: joePCBarHeight)
            }
        } else {
            content
        }
    }
}

extension View {
    func joePCBarInset() -> some View {
        modifier(JoePCBarInset())
    }
}

/// claude/opt-2 (FL-427, pinned state): the band cover for a
/// Private Cinema home's pinned context strip.
///
/// Mechanism of the fault: joePCBarInset reserves the bar's
/// height with a CLEAR safeAreaInset, and a scroll view's
/// content keeps scrolling UNDER its insets. Once the strip
/// pins, the rails therefore slide up behind the transparent
/// bar and through any gap above the strip, so rail titles
/// paint over whatever is behind (the poster backdrop). The
/// deep-state drawing (RECALC-SPEC §3.0 / §3.1 "Trạng thái
/// sâu"; TRIAL-Home-recalc-deep.png, measured: y0–131 flat
/// Ink #0C1215, strip y132–219 Ink) has NOTHING above the
/// strip but flat Ink under the bar's own text.
///
/// The cover is paint only (no state, no preference writes,
/// so no layout feedback): a GeometryReader in the strip's
/// background reads the strip's global frame; while the strip
/// sits at the pinned position (its top within the band
/// threshold below — the rest position is the hero stage's
/// foot, 560/600, far below it) it paints theme.bg (Ink) from
/// the screen's top edge down to the strip's bottom, across
/// the full 1920 canvas. The shell draws the bar ABOVE the
/// content, so the wordmark, nav and clock stay on top. At
/// rest it paints nothing, so the hero/backdrop at rest is
/// untouched.
/// claude/opt-2 (owner, 2026-11-22: "backdrop bị 1 thanh
/// ngang màu đen … làm theo dạng thanh kính để không bị
/// che"): the Private Cinema context strip and the pinned
/// band above it are GLASS, not opaque Ink. Once the backdrop
/// became full screen (FL-457) the opaque 88 pt strip read as
/// a black bar laid across the art. The glass is the system
/// ultra-thin material (frosted: the art stays visible, rail
/// text behind it is blurred illegible) under a light Ink
/// tint for the strip's own text. One definition for the four
/// homes' strips and the pinned band cover. Paint only.
///
/// claude/opt-2 (owner log 2026-11-22: "lag 1 chút xíu so với
/// cái cũ"): a live material blur re-samples everything
/// behind it on every frame. At rest nothing moves behind the
/// strip, so the strip itself is a plain tinted glass
/// (`frosted: false`, no blur, Ink 0.5). The frosted material
/// is used ONLY by the pinned band cover, which paints solely
/// while the strip is pinned and rails scroll beneath it; it
/// covers the strip's own area too, so the pinned strip reads
/// as frosted glass and rail text behind it stays illegible.
/// Owner's strip (2026-11-23): NOT a bar — one streak from the left. The veil
/// hugs the measured text block exactly (this view is the text block's
/// background, extended by `tail` on the trailing side); the extension is the
/// fade zone: the veil holds solid behind the text itself, then dissolves
/// gradually across the whole tail and disappears completely. The text is
/// never masked — only the veil fades.
struct JoeCinemaStreak: View {
    @Environment(\.joeTheme) private var theme
    var tail: CGFloat = 460
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let solid = w > tail ? (w - tail) / w : 0
            let tailFrac = w > tail ? tail / w : 1
            ZStack {
                theme.bg.opacity(0.30)
                LinearGradient(colors: [Color.white.opacity(0.09), Color.white.opacity(0)],
                               startPoint: .top, endPoint: .bottom)
            }
            .mask {
                // Cách C3 (owner polish): eased multi-stop fade — solid to
                // the end of the text, then 55% / 22% / gone, so the tail
                // dissolves softly instead of one straight ramp.
                LinearGradient(stops: [
                    Gradient.Stop(color: .black, location: 0),
                    Gradient.Stop(color: .black, location: solid),
                    Gradient.Stop(color: .black.opacity(0.55), location: solid + 0.45 * tailFrac),
                    Gradient.Stop(color: .black.opacity(0.22), location: solid + 0.78 * tailFrac),
                    Gradient.Stop(color: .clear, location: 1),
                ], startPoint: .leading, endPoint: .trailing)
            }
            .mask {
                LinearGradient(stops: [
                    Gradient.Stop(color: .clear, location: 0),
                    Gradient.Stop(color: .black, location: 0.22),
                    Gradient.Stop(color: .black, location: 0.78),
                    Gradient.Stop(color: .clear, location: 1),
                ], startPoint: .top, endPoint: .bottom)
            }
        }
        .allowsHitTesting(false)
    }
}

struct JoeCinemaGlass: View {
    var frosted: Bool = false
    @Environment(\.joeTheme) private var theme

    var body: some View {
        ZStack {
            if frosted {
                Rectangle().fill(.ultraThinMaterial)
                theme.bg.opacity(0.35)
            } else {
                // claude/opt-2 (owner 2026-11-22 23:08: "hiệu ứng
                // gương khi đang ở trên rail đầu tiên, để nó không
                // bị che hoàn toàn backdrop"): at rest the strip is
                // a light MIRROR glass, not a tinted band — a faint
                // Ink veil for the text, a soft sheen falling from
                // the top edge and hairline edges top and bottom.
                // The backdrop reads through it. The darker pinned
                // look is painted by the pinned band cover instead
                // (see JoePCPinnedBandCover), unchanged.
                theme.bg.opacity(0.15)
                LinearGradient(colors: [Color.white.opacity(0.08),
                                        Color.white.opacity(0.0)],
                               startPoint: .top, endPoint: .bottom)
                VStack(spacing: 0) {
                    Color.white.opacity(0.14).frame(height: 1)
                    Spacer(minLength: 0)
                    Color.white.opacity(0.10).frame(height: 1)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

let joePCPinnedStripThreshold: CGFloat = 330

/// Cách C2 (owner, 2026-11-23): the strip publishes the measured width of its
/// text block; the pinned cover sizes its streak from that number (+ a fade
/// tail) instead of a fixed length — short title, short streak; long title,
/// long streak. ("làm nó dạng fade theo độ dài của chữ title")
struct JoePCStripTextWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// claude/strip-legibility: the pinned strip's text-line hold —
/// the vertical opacity profile of the Ink overlay that keeps the
/// title/meta line at the eyebrow line's density (see the call in
/// JoePCPinnedBandCover). Pure arithmetic on layout values the
/// cover already reads; no state, no per-focus work.
enum JoePCStripHold {
    /// Glass Ink tint inside JoeCinemaGlass(frosted: true).
    static let glassInk: Double = 0.35
    /// The baseline strip overlay (top of the strip).
    static let topOverlay: Double = 0.5
    /// Density the eyebrow line already gets: 1 − 0.65 × 0.5.
    static let target: Double = 1 - (1 - glassInk) * (1 - topOverlay)
    /// Fade below the text block: 40 pt past the strip's bottom
    /// edge, so the hold's fade (text bottom → skirt end, 50 pt on
    /// an 88 pt strip) has the same slope as the glass's own
    /// baseline dissolve (0.675 over 52 pt) — no new cut line.
    static let skirt: CGFloat = 40

    /// The glass's own bottom-dissolve mask value at strip-local y
    /// (1 down to 78 % of the cover, then linear to 0).
    static func glassMask(y: CGFloat, stripHeight h: CGFloat, above: CGFloat) -> Double {
        let coverH = above + h
        guard coverH > 0 else { return 0 }
        let f = Double((above + y) / coverH)
        return f <= 0.78 ? 1 : max(0, (1 - f) / 0.22)
    }

    /// Overlay opacity that makes glass + overlay = target.
    static func overlay(atGlassMask m: Double) -> Double {
        min(target, max(0, 1 - (1 - target) / (1 - glassInk * m)))
    }

    static func stops(stripHeight h: CGFloat, above: CGFloat,
                      ink: Color) -> [Gradient.Stop] {
        let total = h + skirt
        guard h > 0 else { return [Gradient.Stop(color: .clear, location: 0)] }
        // Text block (eyebrow 15 + 4 + title 34 ≈ 66 pt) is centred
        // in the strip: its bottom sits at h/2 + 33; +1 for descenders.
        let holdEnd = min(h, h / 2 + 34)
        let coverH = above + h
        let dStart = min(holdEnd, max(0, 0.78 * coverH - above))
        func stop(_ y: CGFloat, _ o: Double) -> Gradient.Stop {
            Gradient.Stop(color: ink.opacity(o), location: y / total)
        }
        let mid = dStart + (holdEnd - dStart) / 2
        let oMid = overlay(atGlassMask: glassMask(y: mid, stripHeight: h, above: above))
        let oEnd = overlay(atGlassMask: glassMask(y: holdEnd, stripHeight: h, above: above))
        let tail = total - holdEnd
        return [
            stop(0, topOverlay),
            stop(dStart, topOverlay),
            stop(mid, oMid),
            stop(holdEnd, oEnd),
            stop(holdEnd + 0.45 * tail, oEnd * 0.55),
            stop(holdEnd + 0.78 * tail, oEnd * 0.22),
            stop(total, 0),
        ]
    }
}

private struct JoePCPinnedBandCover: ViewModifier {
    @Environment(\.joeTheme) private var theme

    @ViewBuilder
    func body(content: Content) -> some View {
        if theme.id == .privateCinema {
            content.backgroundPreferenceValue(JoePCStripTextWidthKey.self) { textW in
                GeometryReader { geo in
                    let frame = geo.frame(in: .global)
                    let pinned = frame.minY <= joePCPinnedStripThreshold
                    let above = max(0, frame.minY)
                    // claude/opt-2: glass, not Ink (see JoeCinemaGlass).
                    // Owner's strip (2026-11-23): pinned is the same ONE
                    // streak — frosted glass from the left edge, solid
                    // across the longest-title zone, then a long soft fade
                    // to nothing. No right patch, no full-width slab.
                    // Cách C2: streak length follows the measured title —
                    // solid from the screen edge to the end of the text
                    // block (frame.minX + the strip's 14pt leading pad +
                    // textW), then the fade tail; fixed 1560/0.60 only as
                    // the pre-measure fallback.
                    let textEnd = frame.minX + 14 + textW
                    let streakW = textW > 0 ? min(1920, textEnd + 340) : 1560
                    let solidAt = textW > 0 ? min(0.85, textEnd / streakW) : 0.60
                    let fadeSpan = 1 - solidAt
                    let hMask = LinearGradient(stops: [
                        // Cách C3: same eased profile as the at-rest streak.
                        Gradient.Stop(color: .black, location: 0),
                        Gradient.Stop(color: .black, location: solidAt),
                        Gradient.Stop(color: .black.opacity(0.55), location: solidAt + 0.45 * fadeSpan),
                        Gradient.Stop(color: .black.opacity(0.22), location: solidAt + 0.78 * fadeSpan),
                        Gradient.Stop(color: .clear, location: 1),
                    ], startPoint: .leading, endPoint: .trailing)
                    let coverH = above + frame.height
                    ZStack(alignment: .topLeading) {
                        // The frosted streak — baseline geometry and
                        // masks unchanged; only the Ink 0.5 strip
                        // overlay moved out of it (see the hold below).
                        JoeCinemaGlass(frosted: true)
                            .frame(width: streakW, height: pinned ? coverH : 0)
                            .mask { hMask }
                            .mask {
                                // Cách C3: bottom edge dissolves over the last
                                // 22% (was 10%) — no visible cut line over the
                                // posters below the pinned strip.
                                LinearGradient(stops: [
                                    Gradient.Stop(color: .black, location: 0),
                                    Gradient.Stop(color: .black, location: 0.78),
                                    Gradient.Stop(color: .clear, location: 1),
                                ], startPoint: .top, endPoint: .bottom)
                            }
                        // claude/strip-legibility: the text-line hold.
                        // Pre-fix the Ink 0.5 strip overlay sat INSIDE
                        // the 22% bottom dissolve above, and with the
                        // strip pinned under the 148 pt bar that
                        // dissolve begins ~36 pt into the 88 pt strip —
                        // exactly the title/meta line, which therefore
                        // got ~0.43 → 0.24 cover density instead of
                        // the 0.675 the eyebrow line gets: the washout
                        // over bright posters. The hold paints the
                        // overlay on its own vertical profile, sized so
                        // glass + hold = the eyebrow line's 0.675 all
                        // the way down to the text block's bottom, then
                        // the house eased fade (×.55 / ×.22 / 0) over a
                        // 40 pt skirt. Same horizontal streak mask. No
                        // new density level, no new shape.
                        LinearGradient(
                            stops: JoePCStripHold.stops(
                                stripHeight: frame.height, above: above,
                                ink: theme.bg),
                            startPoint: .top, endPoint: .bottom)
                            .frame(width: streakW,
                                   height: pinned ? frame.height + JoePCStripHold.skirt : 0)
                            .mask { hMask }
                            .padding(.top, pinned ? above : 0)
                    }
                    .frame(width: 1920,
                           height: pinned ? coverH + JoePCStripHold.skirt : 0,
                           alignment: .topLeading)
                    .offset(x: -frame.minX, y: -above)
                    .allowsHitTesting(false)
                }
            }
        } else {
            content
        }
    }
}

extension View {
    func joePCPinnedBandCover() -> some View {
        modifier(JoePCPinnedBandCover())
    }
}

// MARK: - Design top bar pieces (FIX-213, Fault 8)
//
// The Private Cinema design set's own header (measured
// from delivery-joetv-HomeManyRails.png /
// delivery-joetv-Home.png and the many-rail spec: fixed
// height 132, side inset 88, transparent over the
// backdrop — NO band fill): a lowercase serif "joe" with
// a small outlined "tv" badge at the left, a centred
// text nav whose SELECTED item alone carries an ivory
// capsule, and the plain clock at the right. These two
// pieces are that header's wordmark and nav item; the
// bar itself is composed in JoeTVApp.topBar's PC arm.
// Focus follows the design's own language (the spec's
// focus treatment): an ivory 3 pt outline offset 5 pt
// outside the item's capsule shape — value-only, drawn
// by the label itself, exactly like the house's other
// PC labels.

/// The design's wordmark: "joe" in bold serif with the
/// outlined rounded-square "tv" badge (measured from the
/// design header: wordmark ≈38 pt against the nav's
/// 24 pt text; badge text ≈17 pt, stroke 2, radius 6).
struct PCWordmark: View {
    @Environment(\.joeTheme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: 7) {
            Text("joe")
                .font(JoePCType.editorial(38))
                .fontWeight(.bold)
                .foregroundStyle(theme.text)
            Text("tv")
                .font(JoePCType.outfit(17, weight: .semibold))
                .foregroundStyle(theme.text)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(theme.text, lineWidth: 2))
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
}

/// One item of the design's centred nav (spec: text
/// 24/400, item gap 16, the selected item's capsule
/// padded 13 vertical × 27 horizontal, radius 30):
/// unselected items are PLAIN ivory text — no fill, no
/// border, no icon (the search item alone carries the
/// magnifier, as drawn). Selected = ivory capsule with
/// ink text. Focus = the design's ivory outline, 3 pt,
/// offset 5 pt outside the capsule.
struct PCNavLabel: View {
    let title: String
    var systemImage: String? = nil
    let selected: Bool
    @Environment(\.isFocused) private var isFocused
    @Environment(\.joeTheme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 20))
            }
            Text(title)
                .font(JoePCType.outfit(24, weight: selected ? .semibold : .regular))
        }
        // FIX-214 (owner ruling 2026-11-22 14:46 CST —
        // Chỉ thị 10): menu focus is the RING ONLY. While
        // this item is focused, the selected treatment
        // (ivory capsule + ink text) is SUPPRESSED — the
        // celadon ring below is the only focus
        // presentation, for every item including the
        // selected one. Unfocused, the selected item
        // keeps its ivory capsule: that capsule is the
        // SELECTED marker (drawn), not a focus treatment.
        // (Pre-fix the two combined by addition, so a
        // selected + focused item wore fill AND ring
        // while its neighbour wore ring only — the
        // desync in the owner's clip.)
        // claude/opt-2 (FL-422, owner ruling): the nav fill is
        // GONE at every state — no ivory capsule, selected or
        // not, focused or not. Selected is carried by the text
        // alone (semibold, see the font below); focus stays the
        // celadon ring + scale. The 13 × 27 padding is kept so
        // the ring's geometry and the bar's spacing are
        // unchanged.
        .foregroundStyle(theme.text)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 27)
        .padding(.vertical, 13)
        .overlay {
            if isFocused {
                Capsule()
                    .stroke(JoeCinemaFocus.celadon, lineWidth: 3)
                    .padding(-5)
            }
        }
        .scaleEffect(isFocused ? 1.035 : 1.0)
        .animation(JoeCinemaFocus.tileCurve, value: isFocused)
    }
}

// MARK: - Hero scrims (FIX-214, FULL-THEME-AUDIT-214 Phần C họ 1)
//
// The design's TWO static hero scrims, verbatim from the
// many-rail specification ("Scrim tĩnh phía trên cả 2:
// trái #0C1215ED 0% / A6 39% / 12 79%; đáy Ink32% /
// 8C60% / 1F100%") — Ink stops, NOT black: the shipped
// heroes painted a five-stop BLACK gradient (left) and a
// two-stop clear→bg ramp (bottom), a different colour
// family from the drawing on all three heroes
// (cinemaHeroBlock, tvbHeroBlock, the Torrent hero).
// One shared definition here; every hero paints these
// two and no other scrim. The bottom ramp's stop
// positions run top→bottom of the stage, exactly as the
// design team's approved trial render painted them
// (alpha 0x32 at the top, 0x8C at 60%, 0x1F at the
// bottom edge).
enum JoeCinemaScrims {
    private static let ink = Color(red: 0.047, green: 0.070,
                                   blue: 0.082) // #0C1215

    static var left: LinearGradient {
        // Exactly the spec's THREE stops — past 0.79
        // the 0x12 ink holds to the edge, as drawn
        // (gate R1 Lens 3: a fourth fade-to-clear stop
        // was NOT in the drawing).
        LinearGradient(stops: [
            .init(color: ink.opacity(237.0 / 255.0), location: 0),
            .init(color: ink.opacity(166.0 / 255.0), location: 0.39),
            .init(color: ink.opacity(18.0 / 255.0), location: 0.79)
        ], startPoint: .leading, endPoint: .trailing)
    }

    /// claude/opt-2 (FL-457, owner ruling): the vertical scrim
    /// of the FULL-SCREEN page backdrop. The design's stage
    /// ramp (`bottom` below) ended at 0x1F Ink on the stage's
    /// foot, which is the hard cut the owner rejected once
    /// the art runs the whole screen. This ramp takes the
    /// melt of the theme's own full-screen detail backdrop
    /// (JoeMovieDetail.cinemaBackdrop: clear by 0.35, bg 0.88
    /// at 0.85, full bg at the bottom) so the rails sit on
    /// near-full Ink. Its top stays CLEAR (not the detail's
    /// 0.30): FIX-213 Fault 8 ruled out any top darkening of
    /// the art under the bar ("Làm che luôn backdrop").
    static var page: LinearGradient {
        LinearGradient(stops: [
            .init(color: ink.opacity(0), location: 0),
            .init(color: ink.opacity(0), location: 0.35),
            .init(color: ink.opacity(0.88), location: 0.85),
            .init(color: ink.opacity(1), location: 1)
        ], startPoint: .top, endPoint: .bottom)
    }

    static var bottom: LinearGradient {
        LinearGradient(stops: [
            .init(color: ink.opacity(50.0 / 255.0), location: 0),
            .init(color: ink.opacity(140.0 / 255.0), location: 0.6),
            .init(color: ink.opacity(31.0 / 255.0), location: 1)
        ], startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - Hero text measurement (FIX-214, DESIGN-PASS-214 §1a)
//
// The hero text-zone budget (bottom 394 of the 560 stage;
// 428 of the HomeTVBFocus form's own 600) is enforced by
// MEASURING the two variable rows — the title's wrapped
// line count and the synopsis' — with the bundled fonts
// themselves (UIFont metrics), then applying the pass's
// compression order: synopsis collapses 2→1→0 lines,
// then the origin-name row hides. Eyebrow · title ·
// meta · actions are always kept. A font that fails to
// load measures as the system font (a wider, conservative
// stand-in — the compression then errs toward MORE air,
// never toward the overlap this budget exists to kill).
enum JoeHeroMeasure {
    // claude/opt-2 (FL-447 R2): the hero bodies call these on
    // every render — i.e. on every focus move — and each call
    // did a UIFont(name:) lookup plus an NSString text layout.
    // Both answers depend only on (text, face, size, width),
    // and the bundled faces are registered once at launch
    // (UIAppFonts), so the results are memoised. NSCache is
    // thread-safe and evicts under memory pressure; a miss
    // runs the original computation unchanged.
    private nonisolated(unsafe) static let linesMemo: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>()
        cache.countLimit = 512
        return cache
    }()
    private nonisolated(unsafe) static let lineHeightMemo = NSCache<NSString, NSNumber>()

    private static func font(_ postScriptName: String,
                             _ size: CGFloat) -> UIFont {
        UIFont(name: postScriptName, size: size)
            ?? UIFont.systemFont(ofSize: size)
    }

    /// Wrapped line count of `text` in the given bundled
    /// face at `width`, at least 1.
    static func lines(of text: String, postScriptName: String,
                      size: CGFloat, width: CGFloat) -> Int {
        guard !text.isEmpty else { return 0 }
        let key = "\(postScriptName)|\(size)|\(width)|\(text)" as NSString
        if let hit = linesMemo.object(forKey: key) { return hit.intValue }
        let f = font(postScriptName, size)
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: f], context: nil)
        let count = max(1, Int(ceil(rect.height / f.lineHeight)))
        linesMemo.setObject(NSNumber(value: count), forKey: key)
        return count
    }

    static func lineHeight(postScriptName: String,
                           size: CGFloat) -> CGFloat {
        let key = "\(postScriptName)|\(size)" as NSString
        if let hit = lineHeightMemo.object(forKey: key) {
            return CGFloat(hit.doubleValue)
        }
        let height = font(postScriptName, size).lineHeight
        lineHeightMemo.setObject(NSNumber(value: Double(height)), forKey: key)
        return height
    }
}

// MARK: - Hero meta line (FIX-214, FULL-THEME-AUDIT-214 B2)
//
// The drawn meta line is IVORY text with only the ★
// celadon — the shipped heroes painted the whole line
// celadon (theme.heroMeta). One shared renderer for the
// homes' meta rows: the string is split on its " · "
// separators; a segment that carries the rating star
// paints the ★ glyph in celadon (theme.heroMeta) and
// the rest of the segment — like every other segment —
// in ivory (theme.text). The quality chip that rides
// beside the line stays the callers' own.
struct JoeCinemaMetaText: View {
    let meta: String
    @Environment(\.joeTheme) private var theme

    var body: some View {
        text
            .font(JoePCType.outfit(20))
            .lineLimit(1)
    }

    private var text: Text {
        let segments = meta.components(separatedBy: " · ")
        var out = Text("")
        for (index, segment) in segments.enumerated() {
            if index > 0 {
                out = out + Text(" · ").foregroundColor(theme.text)
            }
            if segment.hasPrefix("★") {
                out = out + Text("★").foregroundColor(theme.heroMeta)
                    + Text(String(segment.dropFirst()))
                        .foregroundColor(theme.text)
            } else {
                out = out + Text(segment).foregroundColor(theme.text)
            }
        }
        return out
    }
}

// MARK: - Focus-follows backdrop (v2.1.1, WS-I)
//
// Owner decision + designer treatment (leader steering
// 2026-11-22 02:26 CST): on the Private Cinema many-rail
// homes, focusing ANY title card updates the hero
// together — the hero TEXT changes first, immediately
// with focus (each home renders its text from the SAME
// focus derivation its context strip already uses, so
// text is synchronous by construction), and the BACKDROP
// follows after a 140 ms debounce, crossfading in over
// 520 ms while the PREVIOUS backdrop stays on screen (no
// black flash, no strobe, no placeholder). One shared
// controller (below) owns the backdrop leg for all three
// PC homes (Phim / TVB / Torrent); each home owns one
// instance and feeds it resolved items from its own
// focus state. FL-017 discipline: the debounce task is
// the ONLY work a focus change schedules — no catalogue
// searches, no spec builds on the focus path (the item
// resolution rides the strip helpers' existing lookups).

/// One focus-resolved hero item for the backdrop
/// controller (v2.1.1, WS-I): the text-facing identity of
/// the currently focused title plus its art ladder,
/// resolved by the owning home from REAL fields only.
/// `key` is the focus identity the home already mints
/// (the .focused binding value, or the featured movie's
/// id at rest) — the controller dedupes on it.
struct JoeCinemaHeroItem: Equatable {
    var key: String
    var title: String
    var meta: String
    var synopsis: String
    /// Primary backdrop art (the surface's own backdrop
    /// ladder's first leg); nil when the title carries
    /// no backdrop — the poster then becomes the backdrop.
    var backdropURL: URL?
    /// Poster art: the fallback leg, and the backdrop
    /// itself when `backdropURL` is nil.
    var posterURL: URL?
}

/// The shared focus-follows-backdrop controller
/// (v2.1.1, WS-I): one instance per PC home, owned as
/// @StateObject by the home view. All mutable state is
/// @MainActor-isolated (the class is @MainActor; the
/// @Published images are written only on the main actor).
///
/// Contract of focusChanged(to:):
///  - the text-facing `current` item is set
///    SYNCHRONOUSLY, in the call itself — the caller's
///    hero text re-renders from its own focus derivation
///    in the same focus transaction, so text always
///    leads the backdrop;
///  - the backdrop swap is (re)scheduled: any prior
///    pending task is cancelled, the new art loads after
///    a 140 ms debounce through the EXISTING pipeline
///    (JoeImagePipeline.shared.image(for:targetPixels:)
///    — JoeImagePipeline.swift:162 — the visible-load
///    entry whose loads run at .userInitiated priority
///    in a detached task, bucket 1920 for
///    targetPixels 1920, the hero legs' bucket), with
///    the poster-fix set's HEDGED fallback (the
///    JoeRemoteImage.resolve pattern,
///    JoeImagePipeline.swift:775): the backdrop leg runs
///    at once and starts the poster leg the moment it
///    fails; a 5 s hedge starts the same poster leg if
///    the backdrop leg is still grinding; the first
///    bitmap wins. A poster-only title loads its poster
///    directly (the poster IS its backdrop). No new
///    loader, no new URLSession anywhere;
///  - on success the new bitmap crossfades in over the
///    displayed one (two-layer opacity swap, 520 ms,
///    timingCurve(0.22, 0.61, 0.36, 1.0)); on failure
///    (BOTH legs failed) the backdrop clears to plain
///    Ink (FIX-10a). A title with NO art at all clears
///    to plain Ink after the same debounce (no
///    placeholder image is ever minted).
///  - Reduce Motion ON: the swap is instant — the new
///    bitmap replaces the base layer with no crossfade
///    animation (the layer view renders the top layer
///    only while a crossfade is in flight, and this
///    controller never starts one under Reduce Motion).
@MainActor
final class JoeCinemaBackdropController: ObservableObject {

    /// The text-facing current item (set synchronously
    /// by focusChanged; the homes render hero text from
    /// their own focus derivations, this is the
    /// controller's record for dedupe + the load leg).
    @Published private(set) var current: JoeCinemaHeroItem?

    /// The displayed (base) backdrop bitmap. Stays up
    /// while the next backdrop loads — cleared only by
    /// a successful swap, by a no-art title's debounced
    /// clear, or by a both-legs-failed load's debounced
    /// clear (FIX-10a).
    @Published private(set) var baseImage: UIImage?
    /// The incoming bitmap during a crossfade, painted
    /// over baseImage at topOpacity; nil outside a fade.
    @Published private(set) var topImage: UIImage?
    /// The incoming layer's opacity (0 → 1 over the
    /// crossfade, animated with the spec's timing curve).
    @Published private(set) var topOpacity: Double = 0

    /// The pending debounce/load task — the ONLY task a
    /// focus change may schedule (FL-017).
    private var pendingTask: Task<Void, Never>?
    /// Monotonic focus generation: a superseded task
    /// (cancelled or not — the pipeline awaits inside it
    /// are uninterruptible) recognises itself as stale
    /// by generation before it may touch the layers.
    private var generation = 0
    /// The URL the displayed bitmap actually came from
    /// (the backdrop leg's URL, or the poster's when the
    /// fallback leg won) — a focus move to a title whose
    /// effective art is already on screen schedules no
    /// load and no fade.
    private var displayedSource: URL?

    /// Focus moved (or the rest/featured item was
    /// seeded). `item == nil` is the TVB/Torrent rest
    /// state: no title focused, no featured hero — the
    /// backdrop clears to plain Ink after the debounce.
    func focusChanged(to item: JoeCinemaHeroItem?) {
        // Text first: the current item flips NOW, in the
        // focus transaction itself.
        current = item
        pendingTask?.cancel()
        pendingTask = nil
        generation += 1
        // FIX-214 (DESIGN-PASS-214 §3.3): crossfade
        // coalescing — a focus move during an in-flight
        // crossfade SETTLES that fade instantly (the
        // incoming bitmap becomes the base layer)
        // instead of leaving two fades to fight over the
        // top layer; the new item's own fade (if its art
        // differs) then starts from a settled base. The
        // same-art branch below has settled this way
        // since FIX-8; this is that settle generalised
        // to every focus move. The superseded fade's
        // promotion task identity-checks its bitmap
        // before settling, so it no-ops against the
        // cleared top layer. (No-op under Reduce Motion:
        // no top layer ever exists there.)
        if topImage != nil {
            baseImage = topImage
            topImage = nil
            topOpacity = 0
        }
        guard let item else {
            let gen = generation
            pendingTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 140_000_000)
                guard !Task.isCancelled, gen == self.generation
                else { return }
                self.baseImage = nil
                self.topImage = nil
                self.topOpacity = 0
                self.displayedSource = nil
            }
            return
        }
        // Same effective art already displayed: text was
        // the only change (e.g. the featured item's
        // backdrop URL resolving to the URL already up).
        let effective = item.backdropURL ?? item.posterURL
        if let effective, effective == displayedSource {
            // FIX-8 / R4 Lens A MINOR 1: this branch runs
            // AFTER generation += 1, so a focus move to a
            // different card carrying the SAME art inside
            // the 560 ms promotion window invalidates the
            // in-flight promotion (its settle checks
            // gen == generation) and re-arms nothing —
            // topImage would stay at opacity 1 over a
            // stale baseImage indefinitely. The wanted
            // bitmap IS the top layer (displayedSource
            // was assigned from it before swap), so settle
            // it into the base layer NOW, in this branch,
            // instead of just returning.
            if topImage != nil {
                baseImage = topImage
                topImage = nil
                topOpacity = 0
            }
            return
        }
        if item.backdropURL == nil, item.posterURL == nil {
            // No art at all: plain Ink + gradient + the
            // title text (spec point 3) — the previous
            // title's backdrop must not linger under a
            // title that has none.
            let gen = generation
            pendingTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 140_000_000)
                guard !Task.isCancelled, gen == self.generation
                else { return }
                self.baseImage = nil
                self.topImage = nil
                self.topOpacity = 0
                self.displayedSource = nil
            }
            return
        }
        let gen = generation
        let backdrop = item.backdropURL
        let poster = item.posterURL
        // CAPTURE MAP (debounce/load task): self (the
        // @StateObject-owned controller — retained for
        // the task's life by design, it IS the layer
        // owner), gen (Int, value), backdrop / poster
        // (URL?, values). Nothing else is captured; the
        // load itself touches only JoeImagePipeline
        // .shared (a singleton) from a static helper.
        pendingTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard !Task.isCancelled, gen == self.generation
            else { return }
            let loaded = await Self.loadBackdrop(
                backdrop: backdrop, poster: poster)
            guard !Task.isCancelled, gen == self.generation
            else { return }
            // FIX-10a / RECON-POWERMAX point 5: BOTH legs
            // failed for the CURRENT selection (the
            // generation guard above has passed, so this
            // load still belongs to it) — clear to plain
            // Ink, exactly as the no-art-URLs path does,
            // including nil-ing displayedSource (otherwise
            // a later title whose effective URL equals the
            // stale source would take the same-art early
            // return and never reload). The previous
            // title's backdrop must not linger.
            guard let loaded else {
                self.baseImage = nil
                self.topImage = nil
                self.topOpacity = 0
                self.displayedSource = nil
                return
            }
            self.displayedSource = loaded.source
            self.swap(to: loaded.image, generation: gen)
        }
    }

    /// Publish a loaded bitmap over the displayed one:
    /// the 520 ms crossfade (two-layer opacity swap,
    /// the spec's timing curve), then a promotion step
    /// settles the bitmap into the base layer. Reduce
    /// Motion swaps instantly with no animation and no
    /// top layer.
    ///
    /// CAPTURE MAP (promotion task): self, gen (Int,
    /// value), image (UIImage — the bitmap being
    /// promoted; identity-compared before settling so a
    /// newer fade's bitmap is never settled by an older
    /// fade's promotion).
    private func swap(to image: UIImage, generation gen: Int) {
        if UIAccessibility.isReduceMotionEnabled {
            baseImage = image
            topImage = nil
            topOpacity = 0
            return
        }
        topImage = image
        topOpacity = 0
        withAnimation(.timingCurve(0.22, 0.61, 0.36, 1.0,
                                   duration: 0.52)) {
            topOpacity = 1
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 560_000_000)
            guard gen == self.generation,
                  self.topImage === image else { return }
            self.baseImage = image
            self.topImage = nil
            self.topOpacity = 0
        }
    }

    /// The backdrop load leg (WS-I): backdrop URL first,
    /// poster as the hedged fallback — the poster-fix
    /// set's race (JoeRemoteImage.resolve,
    /// JoeImagePipeline.swift:775): the backdrop leg
    /// runs at once; if it finishes with no bitmap, the
    /// poster leg starts immediately (the old serial
    /// behaviour, preserved); a hedge leg sleeps 5 s
    /// and then starts the SAME poster load concurrently
    /// if no bitmap exists yet; the first bitmap wins.
    /// A poster-only title (backdrop == nil) loads the
    /// poster directly — it IS the backdrop. Every load
    /// is JoeImagePipeline.shared.image(for:
    /// targetPixels: 1920) — the pipeline's
    /// .userInitiated visible load at the hero bucket.
    /// Returns the winning bitmap + the URL it came
    /// from, or nil when every leg failed.
    ///
    /// FIX-8 / R4 Lens A MINOR 2: the race now runs on
    /// the poster pipeline's OWN race-box pattern
    /// (JoeResolveRaceBox, JoeImagePipeline.swift:898)
    /// instead of a task group. A task group's scope
    /// cannot exit until EVERY child finishes, and a
    /// hedge child already inside the pipeline's
    /// detached load cannot be interrupted by
    /// cancellation — so a backdrop win arriving while
    /// the hedge's poster load was still running was
    /// delayed by that losing load. Here the caller
    /// polls the box (JoeBackdropRaceBox below) and
    /// returns the moment a winner is published (or
    /// both legs are known done); the losing leg's
    /// wrapper is cancelled by the defer, which does
    /// NOT cancel the pipeline's own detached in-flight
    /// load — a losing load still lands in cache when
    /// it lands, and its late publication lands in a
    /// box nobody reads. The caller's generation guard
    /// is untouched: focusChanged re-checks
    /// gen == generation after this await, before any
    /// swap is applied, exactly as before.
    ///
    /// CAPTURE MAP (leg tasks): each Task captures only
    /// the box (JoeBackdropRaceBox, @unchecked Sendable,
    /// all fields under its NSLock), backdrop / poster
    /// (URL / URL?, Sendable values) and the static leg
    /// helpers via Self — no instance state, no view
    /// state; the legs touch only JoeImagePipeline
    /// .shared (a singleton).
    private static func loadBackdrop(
        backdrop: URL?, poster: URL?
    ) async -> (image: UIImage, source: URL)? {
        guard let backdrop else {
            guard let poster else { return nil }
            if let image = await JoeImagePipeline.shared.image(
                for: poster, targetPixels: 1920) {
                return (image, poster)
            }
            return nil
        }
        if backdrop == poster {
            if let image = await JoeImagePipeline.shared.image(
                for: backdrop, targetPixels: 1920) {
                return (image, backdrop)
            }
            return nil
        }
        let box = JoeBackdropRaceBox(posterLegExists: poster != nil)
        let backdropTask = Task {
            await Self.runBackdropLeg(box: box,
                                      backdrop: backdrop,
                                      poster: poster)
        }
        let hedgeTask = Task {
            await Self.runBackdropHedgeLeg(box: box, poster: poster)
        }
        defer { backdropTask.cancel(); hedgeTask.cancel() }
        while !box.settled {
            if Task.isCancelled { break }
            // claude/opt-1: same 50 ms ceiling, woken by the box.
            await box.wake.nap(nanoseconds: 50_000_000)
        }
        if let win = box.winner {
            return (win.image, win.source)
        }
        return nil
    }

    /// The backdrop leg of the loadBackdrop race
    /// (FIX-8): load the backdrop URL at once; publish
    /// a bitmap through the box, and on failure settle
    /// the leg in the box BEFORE handing off to the
    /// poster leg, so the box can settle the moment the
    /// poster outcome is also known — without waiting
    /// for the hedge timer.
    private static func runBackdropLeg(
        box: JoeBackdropRaceBox, backdrop: URL, poster: URL?
    ) async {
        if let image = await JoeImagePipeline.shared.image(
            for: backdrop, targetPixels: 1920) {
            box.complete(image: image, source: backdrop, leg: .backdrop)
            return
        }
        box.backdropLegFinished()
        await runBackdropPosterLeg(box: box, poster: poster)
    }

    /// The hedge leg of the loadBackdrop race (FIX-8):
    /// sleep 5 s, then start the SAME poster leg if no
    /// bitmap exists yet. A cancelled wrapper never
    /// starts new poster work (the JoeResolveRaceBox
    /// runFallbackLeg entry gate, mirrored).
    private static func runBackdropHedgeLeg(
        box: JoeBackdropRaceBox, poster: URL?
    ) async {
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        if Task.isCancelled { return }
        await runBackdropPosterLeg(box: box, poster: poster)
    }

    /// The ONE poster leg of the loadBackdrop race
    /// (FIX-8), shared by the backdrop leg (on failure)
    /// and the hedge leg (on deadline): claimed exactly
    /// once through the box — the second caller stands
    /// down and settles nothing; the claiming leg alone
    /// marks the poster leg done. A nil poster (no
    /// poster leg exists) counts as done the moment the
    /// claiming call determines that.
    private static func runBackdropPosterLeg(
        box: JoeBackdropRaceBox, poster: URL?
    ) async {
        guard !Task.isCancelled else { return }
        guard box.claimPosterLeg() else { return }
        guard let poster else {
            box.posterLegFinished()
            return
        }
        if let image = await JoeImagePipeline.shared.image(
            for: poster, targetPixels: 1920) {
            box.complete(image: image, source: poster, leg: .poster)
            return
        }
        box.posterLegFinished()
    }
}

/// Lock-guarded race box for the backdrop controller's
/// hedged load (v2.1.1, FIX-8 — the JoeResolveRaceBox
/// pattern, JoeImagePipeline.swift:898, mirrored for
/// the backdrop/poster leg pair): the backdrop leg and
/// the poster leg publish here; the FIRST bitmap wins
/// and later publications are dropped. The poster leg
/// is claimed exactly once. A race is settled as soon
/// as its outcome is DECIDED: a winner exists, OR the
/// backdrop leg has finished with no bitmap AND the
/// poster leg has finished with no bitmap — where a
/// poster leg that does not exist counts as finished
/// from the start, so a win (or a double failure)
/// returns immediately instead of waiting on a losing
/// leg still in flight. The two legs are tracked
/// SEPARATELY (backdropDone / posterDone), exactly as
/// the poster pipeline's box tracks its legs.
/// @unchecked Sendable — every field is touched only
/// under `lock`.
private final class JoeBackdropRaceBox: @unchecked Sendable {
    enum Leg { case backdrop, poster }

    struct Win {
        let image: UIImage
        let source: URL
    }

    private let lock = NSLock()
    private var win: Win?
    private var posterClaimed = false
    private var backdropDone = false
    private var posterDone: Bool
    /// Wakes loadBackdrop's wait loop whenever the settled
    /// state can have changed (claude/opt-1).
    let wake = JoeWake()

    init(posterLegExists: Bool) {
        posterDone = !posterLegExists
    }

    func complete(image: UIImage, source: URL, leg: Leg) {
        lock.lock()
        if win == nil { win = Win(image: image, source: source) }
        if leg == .backdrop { backdropDone = true }
        if leg == .poster { posterDone = true }
        lock.unlock()
        wake.signal()
    }

    /// The backdrop leg finished with NO bitmap. Its
    /// poster hand-off is a separate leg, tracked by
    /// posterLegFinished — this flag is what lets the
    /// box settle immediately once the poster outcome
    /// is also known.
    func backdropLegFinished() {
        lock.lock()
        backdropDone = true
        lock.unlock()
        wake.signal()
    }

    /// The CLAIMED poster leg finished with NO bitmap
    /// (load failure, or no poster URL exists at all).
    /// Only the claiming leg calls this — a claim
    /// stand-down settles nothing.
    func posterLegFinished() {
        lock.lock()
        posterDone = true
        lock.unlock()
        wake.signal()
    }

    /// True exactly once — for the leg that runs the
    /// poster load; every other caller gets false.
    func claimPosterLeg() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if posterClaimed { return false }
        posterClaimed = true
        return true
    }

    var winner: Win? {
        lock.lock()
        defer { lock.unlock() }
        return win
    }

    var settled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return win != nil || (backdropDone && posterDone)
    }
}

/// The controller's backdrop layer (v2.1.1, WS-I): the
/// base bitmap, with the incoming bitmap fading over it
/// during a crossfade. Paints NOTHING while no bitmap
/// exists — the surface's own Ink ground + scrims are
/// the painted surface then (never a placeholder). Each
/// bitmap gets the hero band's treatment (the
/// JoeBandImage discipline, JoeImagePipeline.swift:1011):
/// a landscape bitmap is cover-sliced at the 0.20 top
/// anchor; a portrait bitmap (a poster standing in as
/// the backdrop) paints as a SHARP cover-slice at the
/// 0.35 anchor (FIX-12 / R7 C-F2 — the many-rail spec's
/// poster fallback: "poster crop cover center35% cùng
/// scrim", the poster-only state PNGs show the poster
/// sharp and legible under the heroes' fixed scrims;
/// no blur, no extra dark overlay of its own).
struct JoeCinemaBackdropLayer: View {
    @ObservedObject var controller: JoeCinemaBackdropController
    var anchor: CGFloat = 0.20

    var body: some View {
        ZStack {
            if let base = controller.baseImage {
                JoeCinemaBackdropImage(image: base, anchor: anchor)
            }
            if let top = controller.topImage {
                JoeCinemaBackdropImage(image: top, anchor: anchor)
                    .opacity(controller.topOpacity)
            }
        }
    }
}

/// claude/opt-2 (FL-457, owner ruling): the Private Cinema
/// home's FULL-SCREEN backdrop. The owner's standard
/// overrides RECALC-SPEC's confined hero stage: the art
/// fills the whole screen like the original theme and like
/// the detail backdrops. This is the same focus-follows
/// controller and crossfade layer the hero stage carried,
/// hoisted to page level BEHIND the home's ScrollView
/// (mounted with .background, ignoring the safe area), under
/// the design's left scrim and the full-height `page` ramp.
/// The hero stage above it is now text-only at its unchanged
/// 560/600 frame; the pinned strip keeps its opaque Ink.
struct JoeCinemaPageBackdrop: View {
    @ObservedObject var controller: JoeCinemaBackdropController

    var body: some View {
        ZStack {
            JoeCinemaBackdropLayer(controller: controller)
            Rectangle().fill(JoeCinemaScrims.left)
            Rectangle().fill(JoeCinemaScrims.page)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        // claude/opt-2 (owner log 2026-11-22, lag vs 2.1.4):
        // the full-screen backdrop now sits under the rails
        // the whole time you browse, so every scroll frame
        // re-blended the bitmap(s) + two full-screen gradients.
        // drawingGroup flattens the stack into ONE offscreen-
        // rendered layer that is redrawn only when its content
        // changes (a new backdrop / the crossfade), not per
        // scroll frame. Same pixels.
        .drawingGroup()
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Mounts JoeCinemaPageBackdrop behind a home's scroll view,
/// Private Cinema only (other themes: unchanged).
private struct JoePCPageBackdrop: ViewModifier {
    @ObservedObject var controller: JoeCinemaBackdropController
    @Environment(\.joeTheme) private var theme

    @ViewBuilder
    func body(content: Content) -> some View {
        if theme.id == .privateCinema {
            content.background {
                JoeCinemaPageBackdrop(controller: controller)
            }
        } else {
            content
        }
    }
}

extension View {
    func joePCPageBackdrop(_ controller: JoeCinemaBackdropController) -> some View {
        modifier(JoePCPageBackdrop(controller: controller))
    }
}

/// One backdrop bitmap with the band treatment (the
/// JoeBandImage slice math, mirrored so the
/// controller's decoded bitmaps — not URLs — can paint
/// through the identical geometry).
private struct JoeCinemaBackdropImage: View {
    let image: UIImage
    var anchor: CGFloat

    var body: some View {
        GeometryReader { geo in
            if image.size.width >= image.size.height {
                slice(image, in: geo.size)
            } else {
                // FIX-12 / R7 C-F2: a portrait bitmap (a
                // poster standing in as the backdrop) takes
                // the SAME sharp slice, anchored at the
                // spec's 0.35 centre — never the blurred,
                // darkened field it used to take. Both
                // crossfade layers route through this one
                // view, so a poster-only swap keeps the
                // same character through the fade.
                slice(image, in: geo.size, anchor: 0.35)
            }
        }
    }

    /// Cover-slice anchored near the top (JoeBandImage
    /// .slice): scale to cover, shift up by anchor × the
    /// vertical overflow. `anchor` overrides the view's
    /// own anchor for this one slice (the portrait
    /// poster's 0.35, FIX-12 / R7 C-F2).
    private func slice(_ image: UIImage, in size: CGSize,
                       anchor sliceAnchor: CGFloat? = nil) -> some View {
        let scale = max(size.width / image.size.width,
                        size.height / image.size.height)
        let w = image.size.width * scale
        let h = image.size.height * scale
        let overflow = max(h - size.height, 0)
        return Image(uiImage: image)
            .resizable()
            .frame(width: w, height: h)
            .offset(x: (size.width - w) / 2,
                    y: -overflow * (sliceAnchor ?? anchor))
    }
}

// MARK: - Trailer chain for non-detail surfaces

/// The trailer attempt for surfaces outside
/// JoeMovieDetail (v2.1.0 (Private Cinema)): a verbatim
/// mirror of JoeMovieDetail.startTrailerPreview /
/// attemptTrailerKey (JoeMovieDetail.swift, the v2.0.49
/// trailer-only contract) so the actor filmography page
/// runs the IDENTICAL chain — TMDB's trailer key first,
/// the title's own source trailer (mined from the
/// source trailer URL) as fallback, each key resolved
/// through JoeYtResolver (the player's own route), the
/// ≥720p known-height gates, the HLS assembly session
/// via JoeYtHlsServer with the tv_samsung user agent,
/// the muxed/direct fallbacks, the hand-over at
/// startFraction 0, and one abort with the last key's
/// reason only when every key failed. Every decision
/// writes the same PREVIEW DiagLog lines the detail
/// writes, so a device log proves this chain the same
/// way it proves the detail's.
enum JoeCinemaTrailer {

    /// Sentinel reason returned by attemptTrailerKey when
    /// the attempt was superseded (Task cancelled) after an
    /// uninterruptible await. Distinct from every real
    /// failure reason: run() treats it as an immediate,
    /// silent exit and must NOT abort the attempt (see
    /// run()'s doc comment for the cross-film leak race).
    private static let cancelledReason = "trailer-cancelled"

    /// The runPreview gates that do not depend on a
    /// surface (v2.1.0 (Private Cinema)): the Settings
    /// preview toggle and Reduce Motion, with the same
    /// skip log lines JoeMovieDetail.runPreview writes.
    /// The surface gate is the CALLER's (the filmography
    /// page exists only under the PC composition, which
    /// has a backdrop layer by construction). Returns
    /// true when a trailer attempt may proceed.
    @MainActor
    static func allowedByRules() -> Bool {
        guard JoePreviewSettings.enabled else {
            DiagLog.write("PREVIEW", "preview skipped rule=settings-off")
            return false
        }
        guard !UIAccessibility.isReduceMotionEnabled else {
            DiagLog.write("PREVIEW", "preview skipped rule=reduce-motion")
            return false
        }
        return true
    }

    /// Run one trailer attempt into `preview` for the
    /// title identified by (tmdbId, tmdbType), with
    /// `sourceTrailerUrl` as the fallback trailer source
    /// (the provider payload's trailer URL; "" when the
    /// record carries none — TVB snapshot titles carry
    /// no source trailer, so their chain is TMDB-only).
    ///
    /// Cross-film leak race (F-B1): the resolver/HLS
    /// awaits are uninterruptible, so a superseded film's
    /// chain can resume after the page has moved on to
    /// the next film. Because this chain runs on
    /// @MainActor, a Task.isCancelled check placed
    /// immediately after the last await before each
    /// preview.play(...) is airtight (no suspension
    /// between check and play). attemptTrailerKey
    /// performs those checks and returns cancelledReason
    /// on cancellation; run() then returns IMMEDIATELY
    /// and SILENTLY — it must NOT call
    /// preview.abortAttempt, because the attempt slot may
    /// already belong to the next film (the page's
    /// stop() already tore down this film's own attempt).
    /// The same discipline applies between keys and at
    /// loop end: a cancelled run never aborts.
    @MainActor
    static func run(tmdbId: String, tmdbType: String,
                    sourceTrailerUrl: String,
                    into preview: JoePreviewController) async {
        var keys: [String] = []
        if !tmdbId.isEmpty, tmdbId != "0",
           let tmdbKey = await TMDBClient.fetchTrailerKey(
               tmdbId: tmdbId, type: tmdbType),
           !tmdbKey.isEmpty {
            keys.append(tmdbKey)
        }
        // Mirror of the detail's F-B1 guard: the key
        // fetch above runs BEFORE beginAttempt, so a
        // dismissal during the fetch must not let this
        // orphaned task go on to begin an attempt on a
        // dead view.
        guard !Task.isCancelled else { return }
        if let sourceKey = youtubeVideoId(
               fromTrailerURL: sourceTrailerUrl),
           !keys.contains(sourceKey) {
            keys.append(sourceKey)
        }
        guard !keys.isEmpty else {
            DiagLog.write("PREVIEW", "preview skipped rule=no-trailer")
            return
        }
        guard preview.beginAttempt(kind: "trailer") else { return }
        var lastReason = "trailer-unresolved"
        for key in keys {
            guard !Task.isCancelled else { return }
            if let reason = await attemptTrailerKey(key, into: preview) {
                // Superseded: exit silently — never abort,
                // the attempt slot may be the next film's.
                if reason == cancelledReason { return }
                lastReason = reason
                continue
            }
            return
        }
        guard !Task.isCancelled else { return }
        preview.abortAttempt(reason: lastReason)
    }

    /// One trailer key's resolve + hand-over. Returns
    /// nil when the playable was handed to the preview
    /// player (the attempt is under way); otherwise the
    /// abort reason for this key — the caller decides
    /// whether another key remains before aborting.
    /// Verbatim mirror of JoeMovieDetail.attemptTrailerKey.
    ///
    /// F-B1 cure: after each uninterruptible await (the
    /// resolver, then the HLS session) and immediately
    /// before every preview.play(...) — all three play
    /// sites — guard !Task.isCancelled and return
    /// cancelledReason on cancellation. On @MainActor
    /// there is no suspension between the final check
    /// and play(), so a superseded film's late play()
    /// can never land in the next film's attempt.
    @MainActor
    private static func attemptTrailerKey(
        _ videoKey: String,
        into preview: JoePreviewController
    ) async -> String? {
        let result = await JoeYtResolver.shared.resolve(videoId: videoKey)
        guard !Task.isCancelled else { return cancelledReason }
        switch result {
        case .playable(let playable, _):
            switch playable.kind {
            case .assembly:
                // QUALITY GATE (17:50 ruling): the
                // resolver already KNOWS this variant's
                // height — a known sub-720 height
                // suppresses HERE, before any hand-over.
                // An unknown height (0) proceeds; the
                // controller's item-level gates still
                // apply.
                if playable.height > 0, playable.height < 720 {
                    return "trailer-low-quality-\(playable.height)p"
                }
                if let session = await JoeYtHlsServer.shared.makeSession(
                    playable: playable,
                    userAgent: JoeYtClientSpec.tvSamsung.userAgent) {
                    guard !Task.isCancelled else { return cancelledReason }
                    DiagLog.write("PREVIEW", "preview resolve kind=trailer-assembly")
                    preview.play(url: session.url, headers: [:],
                                 startFraction: 0)
                    return nil
                }
                if let direct = playable.fallbackDirectURL {
                    // The muxed fallback's OWN known
                    // height gates it the same way.
                    if playable.fallbackHeight > 0, playable.fallbackHeight < 720 {
                        return "trailer-low-quality-muxed-\(playable.fallbackHeight)p"
                    }
                    guard !Task.isCancelled else { return cancelledReason }
                    DiagLog.write("PREVIEW", "preview resolve kind=trailer-muxed-fallback")
                    preview.play(url: direct, headers: [:],
                                 startFraction: 0)
                    return nil
                }
                return "trailer-assembly-failed"
            case .muxed, .hlsManifest:
                // Known-height gate, same as the assembly
                // branch.
                if playable.height > 0, playable.height < 720 {
                    return "trailer-low-quality-\(playable.height)p"
                }
                if let direct = playable.directURL {
                    guard !Task.isCancelled else { return cancelledReason }
                    DiagLog.write("PREVIEW", "preview resolve kind=trailer-direct")
                    preview.play(url: direct, headers: [:],
                                 startFraction: 0)
                    return nil
                }
                return "trailer-no-direct-url"
            }
            // Unreachable — every kind path above returns;
            // present so the compiler sees the case return.
            return "trailer-unresolved"
        case .needsIdentity:
            return "trailer-needs-identity"
        case .membersRequired(let reason):
            return "trailer-members-required \(reason)"
        case .unplayable(let status, let reason):
            return "trailer-unplayable \(status) \(reason)"
        case .httpFailure(let status):
            return "trailer-http-\(status)"
        case .transportFailure(let message):
            return "trailer-transport \(message)"
        case .solverFailed(let step, let message):
            return "trailer-solver \(step) \(message)"
        }
    }

    /// Mine a YouTube video id out of a source trailer
    /// URL: a local copy of JoeMovieDetail's
    /// youtubeVideoId(fromTrailerURL:) (v2.0.49) — the
    /// shapes the provider payloads carry — watch?v=…,
    /// youtu.be/…, /embed/…, /shorts/… The id is the run
    /// of id characters right after the marker; anything
    /// else (a non-YouTube URL, an empty field) yields
    /// nil and the caller treats it as "no source
    /// trailer". The URL itself is never logged — only
    /// the extracted key is used.
    static func youtubeVideoId(fromTrailerURL raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let markers = ["youtu.be/", "watch?v=", "/embed/", "/shorts/"]
        for marker in markers {
            guard let r = s.range(of: marker) else { continue }
            let tail = s[r.upperBound...]
            let id = tail.prefix {
                $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_"
            }
            if !id.isEmpty { return String(id) }
        }
        return nil
    }
}
