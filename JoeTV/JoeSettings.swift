import SwiftUI
import UIKit
import CoreImage

/// Settings: ONLY the torrent/debrid credentials, exactly like
/// the Android app — the owner's own Torrentio URL and/or his
/// Real-Debrid / TorBox tokens, plus the OpenSubtitles addon.
/// Values live in this app's UserDefaults; token fields are
/// secure-entry and the saved state is shown masked.
///
/// Deliberately ABSENT on tvOS (owner brief, 2026-11-13):
/// - No tunnel switch — there is no keeper app on Apple TV;
///   routing is the OS-level Sing-box profile's job.
/// - No external-player picker — tvOS cannot hand playback to
///   VLC/MX the way Android can; shipping a dead control would
///   be worse than omitting it. Playback is AVPlayer everywhere.
struct JoeSettingsView: View {
    @EnvironmentObject private var nav: JoeNavigator
    @EnvironmentObject private var watch: WatchStore
    @Environment(\.joeTheme) private var theme
    /// v2.0.0 (UI-5): the design picker writes the same
    /// @AppStorage key the root reads; the Settings tree itself
    /// keeps ONE structure across themes (only token values
    /// change), so focus stays on the tapped chip through the
    /// switch — never stranded.
    @AppStorage("joeThemeID") private var themeIDRaw = JoeThemeID.ultra.rawValue
    /// v2.1.1 (owner ruling): the DEFAULT theme — the theme the
    /// app opens in. A SECOND persisted key, distinct from the
    /// current-theme key above: the root applies it once at
    /// launch (JoeTVApp); this screen's default-theme control
    /// (defaultThemeBlock) writes it. Empty = unset.
    @AppStorage("joetv.theme.default") private var defaultThemeIDRaw = ""
    @FocusState private var defaultThemeChipFocused: String?
    @State private var addonURL: String = TorrentSettings.addonURL
    @State private var rdToken: String = TorrentSettings.rdToken
    @State private var torboxToken: String = TorrentSettings.torboxToken
    @State private var premiumizeToken: String = TorrentSettings.premiumizeToken
    /// v2.0.16: the MediaFusion gateway's field + kill-switch.
    @State private var mfURL: String = TorrentSettings.mfURL
    @State private var mfEnabled: Bool = TorrentSettings.mfEnabled
    /// v2.0.45 (leg 3): the user-addon link's field (re TV
    /// is the first addon) — the MF field's storage shape.
    @State private var userAddonURL: String = TorrentSettings.userAddonURL
    /// v2.0.24: the Thể Thao Torrent primary source's field
    /// (Nuvio — the Sony 2.3.37 Settings parity).
    @State private var sportsURL: String = TorrentSettings.sportsURL
    @State private var subAddonURL: String = TorrentSettings.subAddonURL.isEmpty
        ? TorrentSettings.opensubtitlesDefault : TorrentSettings.subAddonURL
    @State private var tmdbKey: String = UserDefaults.standard.string(forKey: "tmdb_api_key") ?? ""
    @State private var savedTick = false
    @State private var probeResults: [SourceProbe.Result] = []
    @State private var probing = false
    /// Per-field guidance hints shown under a credential
    /// field after its "Nhập từ iPhone" button is pressed
    /// (1.9.2, item 7).
    @State private var inputHints: [String: String] = [:]
    /// KK route status for the tunnel-status row (item 5).
    @State private var kkStatus: KKRouteStatus = .idle
    @FocusState private var focusedField: String?
    @FocusState private var probeFocused: Bool
    @FocusState private var kkProbeFocused: Bool
    @FocusState private var themeChipFocused: String?
    @FocusState private var cwResetFocused: Bool
    @FocusState private var mfToggleFocused: Bool
    /// v2.0.48: the backdrop-preview toggle's state +
    /// focus (previewToggleBlock; storage is
    /// JoePreviewSettings, written on toggle, not via
    /// save() — the toggle is a display preference, not
    /// a credential).
    @State private var previewEnabled: Bool = JoePreviewSettings.enabled
    @FocusState private var previewToggleFocused: Bool
    /// v2.0.33: focus for the "Gửi log chẩn đoán" button
    /// (logExportBlock) and the cover it presents.
    @FocusState private var logExportFocused: Bool
    @State private var showLogExport = false
    /// TVB YouTube feature (design §3.1): the Gold session
    /// store the TVB row reads (presence only) + its focus.
    @ObservedObject private var ytSession = JoeYtSession.shared
    @FocusState private var tvbGoldFocused: Bool
    /// Confirmation for the history reset (historyBlock) —
    /// the app's standard destructive shape, the exit
    /// dialog's: destructive confirm + cancel.
    @State private var cwResetConfirm = false
    /// v2.0.49 (item 7, fix round): bumped by the
    /// section's Menu handler to make the settings
    /// ScrollViewReader jump to the top of the page
    /// (owner order 2026-11-21).
    @State private var topScrollSignal = 0
    /// v2.1.1 (Private Cinema Settings): the two-pane
    /// composition's state — the selected left-rail category,
    /// the rail's focus identity, the right pane's
    /// Menu-to-top scroll signal and the top row's back
    /// button focus. PC root only; the shared column never
    /// reads them.
    @State private var pcCategory: PCCategory = .appearance
    @FocusState private var pcCategoryFocused: String?
    @FocusState private var pcBackFocused: Bool
    @State private var pcTopScrollSignal = 0

    /// The Private Cinema Settings design's six categories
    /// (delivery-joetv-Settings.png, left rail, in order).
    private enum PCCategory: String, CaseIterable {
        case appearance, playback, language, deviceData, info, debrid

        var title: String {
            switch self {
            case .appearance: return "Giao diện"
            case .playback: return "Phát lại"
            case .language: return "Ngôn ngữ & phụ đề"
            case .deviceData: return "Dữ liệu thiết bị"
            case .info: return "Thông tin"
            case .debrid: return "Tài khoản debrid"
            }
        }
        var icon: String {
            switch self {
            case .appearance: return "paintpalette"
            case .playback: return "play"
            case .language: return "captions.bubble"
            case .deviceData: return "externaldrive"
            case .info: return "info.circle"
            case .debrid: return "link"
            }
        }
    }

    private enum KKRouteStatus {
        case idle, probing, ok(ms: Int), down
    }

    var body: some View {
        // v2.1.1: under Private Cinema this screen renders its
        // designed two-pane composition (pcSettingsRoot below);
        // every other theme keeps the shared column
        // (sharedSettingsRoot) byte-for-byte in behaviour. The
        // modifiers on this Group are the ones BOTH roots need
        // (the log-export cover, the auto-save observers, the
        // open-time probes) — they stood on the shared body
        // before and are hoisted here unchanged so the PC root
        // inherits the identical behaviour.
        Group {
            if theme.id == .privateCinema {
                pcSettingsRoot
            } else {
                sharedSettingsRoot
            }
        }
        // Item 5: the KK route probe runs when Settings opens.
        .task { await runKKProbe() }
        // TVB YouTube feature: the Gold row's state is a
        // fresh presence read when Settings opens.
        .task { await ytSession.refresh() }
        // v2.0.33: the log-export cover (see logExportBlock /
        // LogExportView at the end of this file).
        .fullScreenCover(isPresented: $showLogExport) {
            LogExportView()
        }
        .onDisappear { save(silent: true) }
        .onChange(of: addonURL) { save() }
        .onChange(of: rdToken) { save() }
        .onChange(of: torboxToken) { save() }
        .onChange(of: premiumizeToken) { save() }
        .onChange(of: mfURL) { save() }
        .onChange(of: mfEnabled) { save() }
        .onChange(of: userAddonURL) { save() }
        .onChange(of: sportsURL) { save() }
        .onChange(of: subAddonURL) { save() }
        .onChange(of: tmdbKey) { save() }
    }

    /// The shared Settings column — the ONE structure every
    /// non-PC theme uses (v2.1.1: extracted verbatim from the
    /// old `body`; composition, order, focus sections and the
    /// exit/defaultFocus declarations are unchanged).
    private var sharedSettingsRoot: some View {
        // v2.0.49 (item 7, fix round): the ScrollView sits
        // inside a ScrollViewReader so Menu can jump
        // straight to the top of the page (see
        // .onExitCommand below).
        ScrollViewReader { proxy in
        ScrollView(.vertical, showsIndicators: false) {
            // v2.0.8 (Phase 7): lazy root stack — identical
            // children, order and spacing; the eager VStack
            // built every block (all fields, all diagnostics
            // rows) before first paint.
            LazyVStack(alignment: .leading, spacing: 40) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Cài đặt")
                        .font(.system(size: 56, weight: .heavy))
                        .foregroundStyle(theme.text)
                    // v2.0.34 (item 6): the verdict text comes
                    // from torrentHeaderText — in 2.0.33 this
                    // line read isConfigured alone and turned
                    // green ("đã cấu hình ✓") on the bundled
                    // tokens while every field below was
                    // empty (proven by the owner's device
                    // log). The colour rule is unchanged:
                    // green whenever torrent is configured in
                    // either shape, orange when it is not.
                    Text(torrentHeaderText)
                        .font(theme.id == .privateCinema ? JoePCType.outfit(25) : .system(size: 25))
                        .foregroundStyle(TorrentSettings.isConfigured
                                         ? JoeTheme.okGreen : .orange)
                }

                // v2.0.8 (Phase 1): this screen was ONE
                // unsectioned column (zero .focusSection in
                // the file). The existing blocks are now
                // grouped into focus sections — theme /
                // fields / history / diagnostics — so the
                // focus engine moves section-to-section, then
                // within a section. Composition, order and
                // content of every block are unchanged.
                themeBlock
                    .focusSection()

                tunnelStatusBlock
                    .focusSection()

                Group {
                torrentioField
                rdField
                torboxField
                premiumizeField
                // v2.0.16: MediaFusion — the second torrent
                // gateway. With its link pasted, the torrent
                // detail pools both gateways' streams (ranked
                // top-30) and the TV section gains the Thể Thao
                // Torrent tab. The toggle is the kill-switch:
                // off ⇒ MediaFusion is fully absent.
                mfField
                mfToggleButton
                // v2.0.45 (leg 3): the user-addon link —
                // the owner's own Stremio addon as a
                // library section + backup stream source.
                // The field is the MF field's exact config
                // (secure, paste); its focus id is
                // "useraddon" — the design's "addon" id
                // is already the Torrentio field's in this
                // file, and two fields may not share one
                // focus identity. v2.0.49: the bundled
                // addon default was REMOVED by the owner's
                // order (2026-11-21 22:41 CST), so the
                // field is stored-only now — no bundled
                // fallback, and "in force" means a stored
                // link alone.
                userAddonField
                // v2.0.24: the Thể Thao Torrent tab's primary
                // source (Sony 2.3.37 parity). Empty = the
                // Nuvio public instance; the owner can paste
                // a self-hosted instance's base instead. This
                // slot never touches the MediaFusion link
                // above — that one also feeds the movie path.
                // v2.0.38 (Sony 2.3.41 parity, item 1): the
                // empty status now shows the EFFECTIVE base
                // in full ("đang dùng: https://…"), like
                // Sony's "Đang dùng" line — a plain public
                // URL, not a credential, so it may render.
                sportsField
                subAddonField
                tmdbFieldBlock

                saveNoteBlock
                }
                .focusSection()

                // TVB YouTube feature (design §3.1): the
                // TVB Gold session row, between the credential
                // fields and the history block.
                tvbGoldBlock
                    .focusSection()

                historyBlock
                    .focusSection()

                Group {
                diagnosticsBlock

                signpostBlock
                }
                .focusSection()

                // v2.0.48: the backdrop-preview toggle —
                // its own focus section, above the
                // log-export block.
                previewToggleBlock
                    .focusSection()

                // v2.0.33: the log-export block — its own
                // focus section, below the diagnostics group,
                // above the version footer (see logExportBlock).
                logExportBlock
                    .focusSection()

                // Hero forensics fix (2026-11-15): the real
                // bundle version, like the corner label — this
                // footer carried the same frozen "v2.0.0".
                Text("Joe TV v\(JoeRootView.appVersion)")
                    .font(.system(size: 23))
                    .foregroundStyle(theme.meta)
            }
            .id("joeSettingsTop")
        }
        // v2.0.49 (item 7, fix round): the Menu-to-top
        // jump's scroll hook, inside the reader.
        .onChange(of: topScrollSignal) { _, _ in
            proxy.scrollTo("joeSettingsTop", anchor: .top)
        }
        }
        // CONVERGENCE (Team 7 D4 + spec item 3, 2026-11-15):
        // the JoeSettingsMoveTrap (enabled: focusedField ==
        // "addon") and the focus-hub consumer that used to sit
        // here are REMOVED. The trap's flips rebuilt the whole
        // settings ScrollView; its routing — UP from the first
        // field to the pills, DOWN to the second field — is
        // what geometric focus movement does on this
        // single-column layout unaided.
        // v2.0.5 CORRECTION (N2 — error 6): the sentence that
        // stood here claimed "pill DOWN lands on the first
        // field geometrically". On device it did NOT: the
        // fields end at x ≤ 1330 while the Tìm phim pill sits
        // at x ≈ 1450–1670, so its DOWN column is empty, and
        // the topBar and this section are sibling subtrees
        // with no bridge — the pill was a complete dead end.
        // The route is DECLARED now, not assumed: the pill
        // row's handler owns the pill exits (JoeTVApp.pillMove),
        // its DOWN resigns focus into the content focus
        // section, and this view declares its top element —
        // the first theme chip — as the section's landing
        // (below). Inside the column, movement stays geometric
        // (one column, the reliable case); the first chip's UP
        // exits to the pill row as section-to-section movement.
        // 1.9.2 (Team 9 item 4): Menu in this SECTION returns
        // to the Phim section — the app's main menu — instead
        // of exiting the app (the owner's Android model).
        // On this section's own root.
        .onExitCommand {
            // v2.0.49 (item 7, fix round — owner order
            // 2026-11-21 22:32): Menu jumps straight to
            // the top of the page first. Focus on the
            // first theme chip (this page's declared
            // first element — see .defaultFocus below)
            // keeps the existing return to Phim; anywhere
            // else, Menu scrolls to the top and lands
            // focus on that chip, swallowing the exit.
            if themeChipFocused == JoeThemeID.billboard.rawValue {
                nav.section = .home  // FIX-213 (Fault 13): return to Trang chủ (.home), the home surface since the split
            } else {
                topScrollSignal += 1
                themeChipFocused = JoeThemeID.billboard.rawValue
            }
        }
        // v2.0.5 (N1/N2): the section's DECLARED top element —
        // the first theme chip (the column's first focusable).
        .defaultFocus($themeChipFocused, JoeThemeID.billboard.rawValue)
        // v2.1.1: the open-time probes, the log-export cover,
        // the disappear save and the auto-save observers that
        // stood here now live on `body`'s Group, shared with
        // the Private Cinema root — same behaviour, one home.
    }

    /// The "Giao diện" row (v2.0.0, UI-5): three chips, one per
    /// design. The active design's chip wears the accent fill;
    /// tapping another switches the whole app immediately —
    /// this screen's own structure does not change, only its
    /// token values, so focus remains on the chip row.
    private var themeBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Giao diện")
                .font(theme.id == .privateCinema ? JoePCType.outfit(34, weight: .bold)
                              : .system(size: 34, weight: .bold))
                .foregroundStyle(theme.text)
            HStack(spacing: 14) {
                ForEach(JoeThemeID.allCases, id: \.self) { id in
                    Button {
                        themeIDRaw = id.rawValue
                    } label: {
                        JoeChipLabel(title: id.pickerLabel,
                                     selected: themeIDRaw == id.rawValue)
                    }
                    .joeCardButton()
                    .focused($themeChipFocused, equals: id.rawValue)
                }
            }
            Text("Đổi giao diện áp dụng ngay cho toàn app: trang chủ, trang phim, tìm kiếm và trình phát.")
                .font(theme.id == .privateCinema ? JoePCType.outfit(25) : .system(size: 25))
                .foregroundStyle(theme.meta)
                .frame(maxWidth: 1250, alignment: .leading)
            defaultThemeBlock
        }
    }

    /// v2.1.1 (owner ruling): the DEFAULT-theme control — the
    /// theme the app OPENS in. A chip row in the same shape as
    /// the current-theme picker above, writing the SECOND key
    /// ("joetv.theme.default"); the root applies it once at
    /// launch. The selected chip is the stored default, or —
    /// while no default is stored — the current theme (which
    /// is what the launch falls back to, so the row never
    /// claims a default that is not in force). Its chips carry
    /// their OWN @FocusState, so the Settings first-chip trap
    /// (themeChipFocused / the billboard landing) is untouched.
    private var defaultThemeBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Giao diện mở app")
                .font(theme.id == .privateCinema ? JoePCType.outfit(29, weight: .bold)
                              : .system(size: 29, weight: .bold))
                .foregroundStyle(theme.text)
            HStack(spacing: 14) {
                ForEach(JoeThemeID.allCases, id: \.self) { id in
                    Button {
                        defaultThemeIDRaw = id.rawValue
                    } label: {
                        JoeChipLabel(title: id.pickerLabel,
                                     selected: effectiveDefaultThemeID == id)
                    }
                    .joeCardButton()
                    .focused($defaultThemeChipFocused, equals: id.rawValue)
                }
            }
            Text("App mở lên sẽ vào thẳng giao diện này. Đổi giao diện hiện tại ở hàng trên không làm thay đổi lựa chọn này.")
                .font(theme.id == .privateCinema ? JoePCType.outfit(25) : .system(size: 25))
                .foregroundStyle(theme.meta)
                .frame(maxWidth: 1250, alignment: .leading)
        }
    }

    /// The default theme actually in force at launch: the
    /// stored default when one is set and valid, else the
    /// current theme (the root's fallback — see JoeTVApp).
    private var effectiveDefaultThemeID: JoeThemeID {
        JoeThemeID(rawValue: defaultThemeIDRaw)
            ?? JoeThemeID(rawValue: themeIDRaw) ?? .ultra
    }

    // MARK: - Credential field rows (v2.1.1 extraction)
    //
    // The shared column's inline field(...) calls, extracted
    // VERBATIM into named rows (FL-390 stepwise composition)
    // so the Private Cinema two-pane composition renders the
    // SAME rows — one definition per field, no copy. The
    // shared column's order and content are unchanged.

    private var torrentioField: some View {
        field(title: "Link Torrentio của anh (tuỳ chọn)",
              hint: "Dán nguyên link Torrentio đã gắn Real-Debrid/TorBox/Premiumize của anh. Để trống thì app tự dựng link từ token bên dưới.",
              text: $addonURL, id: "addon", secure: true, allowsPaste: true,
              status: addonFieldStatus,
              inForce: !TorrentSettings.addonURL
                           .trimmingCharacters(in: .whitespaces).isEmpty
                       || TorrentSettings.effectiveBase != nil)
    }

    private var rdField: some View {
        field(title: "Token Real-Debrid",
              hint: "Mã tài khoản Real-Debrid của anh — dùng để giải link torrent và dựng Torrentio khi chưa có link ở trên.",
              text: $rdToken, id: "rd", secure: true, allowsPaste: true,
              status: fieldStatus(stored: TorrentSettings.rdToken,
                                  secret: true,
                                  bundledFallback: BundledTokens.rdToken),
              inForce: !TorrentSettings.effectiveRDToken.isEmpty)
    }

    private var torboxField: some View {
        field(title: "Token TorBox",
              hint: "Mã tài khoản TorBox của anh (nếu dùng TorBox thay Real-Debrid).",
              text: $torboxToken, id: "tb", secure: true, allowsPaste: true,
              status: fieldStatus(stored: TorrentSettings.torboxToken,
                                  secret: true,
                                  bundledFallback: BundledTokens.torboxToken),
              inForce: !TorrentSettings.effectiveTorBoxToken.isEmpty)
    }

    private var premiumizeField: some View {
        field(title: "Token Premiumize",
              hint: "Mã tài khoản Premiumize của anh (nếu dùng Premiumize cạnh Real-Debrid/TorBox).",
              text: $premiumizeToken, id: "pm", secure: true, allowsPaste: true,
              status: fieldStatus(stored: TorrentSettings.premiumizeToken,
                                  secret: true,
                                  bundledFallback: BundledTokens.premiumizeToken),
              inForce: !TorrentSettings.effectivePremiumizeToken.isEmpty)
    }

    private var mfField: some View {
        // v2.0.16: MediaFusion — the second torrent gateway.
        // With its link pasted, the torrent detail pools both
        // gateways' streams (ranked top-30) and the TV section
        // gains the Thể Thao Torrent tab. The toggle below is
        // the kill-switch: off ⇒ MediaFusion is fully absent.
        field(title: "Link MediaFusion (tuỳ chọn)",
              hint: "Dán link manifest MediaFusion của anh (trang cấu hình MediaFusion, đã gắn TorBox/Real-Debrid/Premiumize). Link này là khoá riêng — chỉ lưu trong app này trên Apple TV của anh.",
              text: $mfURL, id: "mf", secure: true, allowsPaste: true,
              status: fieldStatus(stored: TorrentSettings.mfURL,
                                  secret: false,
                                  bundledFallback: BundledTokens.mfURL,
                                  bundledText: "Chưa điền — đang dùng link MediaFusion tích hợp sẵn ✓",
                                  emptyText: "Chưa điền — chưa có link này thì MediaFusion không hoạt động"),
              inForce: !TorrentSettings.mfURL
                           .trimmingCharacters(in: .whitespaces).isEmpty
                       || !BundledTokens.mfURL
                           .trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private var mfToggleButton: some View {
        Button {
            mfEnabled.toggle()
        } label: {
            JoeSecondaryLabel(title: mfEnabled
                              ? "MediaFusion: đang bật ✓"
                              : "MediaFusion: đang tắt")
        }
        .joeCardButton()
        .focused($mfToggleFocused)
    }

    private var userAddonField: some View {
        // v2.0.45 (leg 3): the user-addon link — the owner's
        // own Stremio addon as a library section + backup
        // stream source. The field is the MF field's exact
        // config (secure, paste); its focus id is "useraddon"
        // — the design's "addon" id is already the Torrentio
        // field's in this file, and two fields may not share
        // one focus identity. v2.0.49: the bundled addon
        // default was REMOVED by the owner's order
        // (2026-11-21 22:41 CST), so the field is stored-only
        // now — no bundled fallback, and "in force" means a
        // stored link alone.
        field(title: "Link Addon (tuỳ chọn)",
              hint: "Dán link manifest của addon Stremio anh muốn thêm. Link này là khoá riêng — chỉ lưu trong app này trên Apple TV của anh.",
              text: $userAddonURL, id: "useraddon", secure: true, allowsPaste: true,
              status: fieldStatus(stored: TorrentSettings.userAddonURL,
                                  secret: false,
                                  bundledFallback: nil,
                                  emptyText: "Chưa điền — chưa có link addon nào"),
              inForce: !TorrentSettings.userAddonURL
                           .trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private var sportsField: some View {
        // v2.0.24: the Thể Thao Torrent tab's primary source
        // (Sony 2.3.37 parity). Empty = the Nuvio public
        // instance; the owner can paste a self-hosted
        // instance's base instead. This slot never touches
        // the MediaFusion link above — that one also feeds
        // the movie path. v2.0.38 (Sony 2.3.41 parity, item 1):
        // the empty status now shows the EFFECTIVE base in
        // full ("đang dùng: https://…"), like Sony's "Đang
        // dùng" line — a plain public URL, not a credential,
        // so it may render.
        field(title: "Thể Thao Torrent — nguồn chính (Nuvio)",
              hint: "Để trống thì dùng Nuvio công cộng. Dán link khác khi anh tự dựng Nuvio (ví dụ trên PC của anh). Mục Thể Thao Torrent lấy nguồn này trước, MediaFusion dự phòng sau.",
              text: $sportsURL, id: "sports", secure: false, allowsPaste: true,
              status: fieldStatus(stored: TorrentSettings.sportsURL,
                                  secret: false,
                                  emptyText: "Chưa điền — đang dùng: \(TorrentSettings.sportsBase ?? TorrentSettings.sportsDefault)"),
              // The built-in public base is always in force
              // here (the status line prints it), so the check
              // is always earned.
              inForce: true)
    }

    private var subAddonField: some View {
        field(title: "Addon phụ đề (OpenSubtitles)",
              hint: "Mặc định là OpenSubtitles v3 chính thức — app kiểm tra phụ đề Việt cho mỗi phim torrent.",
              text: $subAddonURL, id: "sub", secure: false,
              status: fieldStatus(stored: TorrentSettings.subAddonURL,
                                  secret: false),
              // The editor itself opens on the built-in
              // OpenSubtitles v3 default when nothing is stored
              // (see the @State initialiser), so the displayed
              // value is the in-force one.
              inForce: !subAddonURL
                           .trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private var tmdbFieldBlock: some View {
        // Spacing 40 = the shared column's LazyVStack spacing
        // these two rows carried as separate children before
        // the extraction — the shared rendering is unchanged.
        VStack(alignment: .leading, spacing: 40) {
            field(title: "TMDB API Key",
                  hint: "Chỉ nhập khi anh muốn dùng key TMDB riêng thay cho key tích hợp sẵn trong app.",
                  text: $tmdbKey, id: "tmdb", secure: true,
                  status: fieldStatus(stored: UserDefaults.standard.string(forKey: "tmdb_api_key") ?? "",
                                      secret: true,
                                      emptyText: "Chưa điền — đang dùng key tích hợp sẵn"),
                  // Same condition as the green-dot row under
                  // this field: a key (his own or the bundled
                  // one) is live.
                  inForce: !TMDBClient.apiKey.isEmpty)
            // C-13 / §7.8: the field starts empty on a fresh
            // install even though TMDB is already active via
            // the bundled key — v1.8's "Tuỳ chọn" hint made it
            // read as "not set up". Say which key is live.
            if !TMDBClient.apiKey.isEmpty {
                HStack(spacing: 10) {
                    Circle()
                        .fill(JoeTheme.okGreen)
                        .frame(width: 12, height: 12)
                    Text(tmdbKey.trimmingCharacters(in: .whitespaces).isEmpty
                         ? "TMDB: đang dùng key tích hợp sẵn ✓"
                         : "TMDB: đang dùng key anh nhập ✓")
                        .font(theme.id == .privateCinema ? JoePCType.outfit(25) : .system(size: 25))
                        .foregroundStyle(theme.meta)
                }
            }
        }
    }

    private var saveNoteBlock: some View {
        VStack(alignment: .leading, spacing: 40) {
            HStack(spacing: 14) {
                if savedTick {
                    Text("Đã lưu ✓")
                        .font(theme.id == .privateCinema ? JoePCType.outfit(25) : .system(size: 25))
                        .foregroundStyle(JoeTheme.okGreen)
                } else {
                    Text("Mọi thay đổi tự lưu ngay khi nhập — không cần bấm Lưu.")
                        .font(theme.id == .privateCinema ? JoePCType.outfit(25) : .system(size: 25))
                        .foregroundStyle(theme.meta)
                }
            }
            Text("Trên Apple TV không có công tắc hầm trong app: đường truyền Việt Nam do profile Sing-box của hệ thống đảm nhiệm. Token chỉ lưu trong app này trên Apple TV của anh, không gửi đi đâu ngoài dịch vụ tương ứng.")
                .font(theme.id == .privateCinema ? JoePCType.outfit(25) : .system(size: 25))
                .foregroundStyle(theme.meta)
                .frame(maxWidth: 1200, alignment: .leading)
        }
    }

    // MARK: - Private Cinema Settings (v2.1.1, audit §7)
    //
    // The designed two-pane composition from
    // delivery-joetv-Settings.png: top row ("← Quay lại" /
    // centred "JOETV / KHÔNG GIAN CỦA BẠN" / clock), a left
    // rail (eyebrow, serif "Cài đặt", tagline, the six
    // categories — the selected row wears the filled Panel
    // face), and a right pane showing the selected category's
    // EXISTING rows. Every row the shared column carries stays
    // reachable — the panes below render the same named blocks
    // and field rows the shared column renders, mapped:
    //   Giao diện          → theme CARDS + default-theme control
    //   Phát lại           → preview toggle + KK route status
    //   Ngôn ngữ & phụ đề  → OpenSubtitles addon field
    //   Dữ liệu thiết bị   → history reset + DiagLog export
    //   Thông tin          → source diagnostics + load signposts
    //                        + version line
    //   Tài khoản debrid   → torrent status + ALL credential
    //                        fields + MF toggle + addon/sports/
    //                        TMDB fields + TVB Gold sign-in row
    //                        + the auto-save note
    // (Mapping notes: the KK route row is a playback-delivery
    // check, so it sits under Phát lại; TVB Gold is an account
    // sign-in, so it sits with the other account rows under
    // Tài khoản debrid. FL-390: the composition is built from
    // these named stepwise helpers — no giant inline body.)

    private var pcSettingsRoot: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 36) {
                pcTopRow
                HStack(alignment: .top, spacing: 64) {
                    pcLeftRail
                        .focusSection()
                    ScrollView(.vertical, showsIndicators: false) {
                        pcCategoryPane
                            .id("joePCSettingsTop")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            // claude/opt-2 (owner photo 2026-11-22: "bị cắt
                            // khung"): the focused card's outset ring + scale
                            // reach past this scroll view's clipping frame, so the
                            // outermost card lost part of its frame. The content
                            // is inset 16 and the scroll view widened by the same
                            // 16 on both sides: the clip edge moves out, every
                            // card stays exactly where it was (net geometry 0).
                            .padding(.horizontal, 16)
                    }
                    .padding(.horizontal, -16)
                    .focusSection()
                }
            }
            // FIX-213 (Fault 7, settings arm): this root
            // carried NO horizontal padding of its own —
            // it borrowed the shell's ambient 80 like the
            // PC homes did, so its left rail stood 14 pt
            // proud of the design frame the rest of the
            // theme now owns (owner photo 2026-11-22: the
            // settings left column hard against the
            // screen's left edge). +14 both sides puts
            // the rail at the design's 94 and the pane's
            // right edge at 1826.
            .padding(.horizontal, 14)
            // FIX-214 (DESIGN-PASS-214 §3.3): the root
            // also gains the bar clearance — its content
            // starts at y148 under the raised bar (the
            // joePCBarInset arithmetic: bar height − the
            // 60 the safe area already grants). Settings
            // was one of the three surfaces the 2.1.3
            // clearance sweep missed (NO-REPEAT sweep:
            // root + TV section + Search all covered in
            // this round).
            .padding(.top, joePCBarHeight - 60)
            .onChange(of: pcTopScrollSignal) { _, _ in
                proxy.scrollTo("joePCSettingsTop", anchor: .top)
            }
        }
        .onChange(of: pcCategory) { _, _ in
            pcTopScrollSignal += 1
        }
        // Menu mirrors the shared column's rule: from the
        // declared first element (the Giao diện rail row) Menu
        // returns to Phim; from anywhere else it first goes
        // home inside the page (rail selection + pane to top).
        .onExitCommand {
            if pcCategoryFocused == PCCategory.appearance.rawValue {
                nav.section = .home  // FIX-213 (Fault 13): return to Trang chủ (.home), the home surface since the split
            } else {
                pcCategory = .appearance
                pcTopScrollSignal += 1
                pcCategoryFocused = PCCategory.appearance.rawValue
            }
        }
        // The PC root's declared entry landing: the first
        // rail row, exactly where the shared column declares
        // its first theme chip.
        .defaultFocus($pcCategoryFocused, PCCategory.appearance.rawValue)
    }

    private var pcTopRow: some View {
        ZStack {
            HStack(alignment: .center, spacing: 20) {
                Button {
                    nav.section = .home  // FIX-213 (Fault 13): return to Trang chủ (.home), the home surface since the split
                } label: {
                    PCBackLabel()
                }
                .joeCardButton()
                .focused($pcBackFocused)
                Spacer()
                // FIX-214 (DESIGN-PASS-214 §3.3): NO
                // second clock — this row carried its own
                // PCClockLabel while the shell bar's
                // clock rides above it (JoeTVApp): two
                // clocks on one screen. The bar's is the
                // only one now.
            }
            Text("JOETV / KHÔNG GIAN CỦA BẠN")
                // FIX-214 (FULL-THEME-AUDIT-214 B9): the
                // eyebrow standard — 15 medium (was 22
                // semibold).
                .font(JoePCType.outfit(15, weight: .medium))
                .tracking(3)
                .foregroundStyle(theme.accent2)
                .lineLimit(1)
        }
        .frame(height: 60)
    }

    private var pcLeftRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("PRIVATE CINEMA")
                // FIX-214 (FULL-THEME-AUDIT-214 B9): the
                // eyebrow standard — 15 medium (was 20
                // semibold).
                .font(JoePCType.outfit(15, weight: .medium))
                .tracking(4)
                .foregroundStyle(theme.accent2)
            Text("Cài đặt")
                // RECALC-213 correction: same Times-class
                // serif family as the Search headline
                // (RECALC-SPEC §2.3), not Instrument Serif.
                .font(JoePCType.timesSerif(64))
                .foregroundStyle(theme.text)
                .padding(.top, 16)
            Text("Một vài lựa chọn nhỏ.\nMột buổi xem đúng ý bạn.")
                // FIX-214 (FULL-THEME-AUDIT-214 B9): the
                // intro line is ≈20 (was 24).
                .font(JoePCType.outfit(20))
                .foregroundStyle(theme.meta)
                .padding(.top, 18)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(PCCategory.allCases, id: \.self) { category in
                    Button {
                        pcCategory = category
                    } label: {
                        PCCategoryRowLabel(title: category.title,
                                           icon: category.icon,
                                           selected: pcCategory == category)
                    }
                    .joeCardButton()
                    .focused($pcCategoryFocused, equals: category.rawValue)
                }
            }
            .padding(.top, 44)
        }
        // FIX-214 (FULL-THEME-AUDIT-214 B9): the rail is
        // ≈390 wide (was 440) — with the root's x94 and
        // the 64 gap the pane starts at ≈548, as drawn.
        .frame(width: 390, alignment: .leading)
    }

    @ViewBuilder
    private var pcCategoryPane: some View {
        switch pcCategory {
        case .appearance: pcAppearancePane
        case .playback: pcPlaybackPane
        case .language: pcLanguagePane
        case .deviceData: pcDevicePane
        case .info: pcInfoPane
        case .debrid: pcDebridPane
        }
    }

    private func pcPaneHeader(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(JoePCType.display(34))
                .foregroundStyle(theme.text)
            Text(subtitle)
                .font(JoePCType.outfit(24))
                .foregroundStyle(theme.meta)
        }
    }

    private var pcAppearancePane: some View {
        VStack(alignment: .leading, spacing: 32) {
            pcPaneHeader("Giao diện",
                         "Chọn không gian cho những câu chuyện bạn yêu thích.")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 24),
                                GridItem(.flexible(), spacing: 24)],
                      alignment: .leading, spacing: 24) {
                ForEach(JoeThemeID.allCases, id: \.self) { id in
                    pcThemeCard(id)
                }
            }
            defaultThemeBlock
            Divider()
                .overlay(theme.stroke)
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "info.circle")
                    .font(.system(size: 24))
                    .foregroundStyle(theme.meta)
                Text("Private Cinema là một lựa chọn bổ sung, không thay thế Ultra. Đổi giao diện áp dụng ngay cho toàn app: trang chủ, trang phim, tìm kiếm và trình phát.")
                    .font(JoePCType.outfit(24))
                    .foregroundStyle(theme.meta)
                    .frame(maxWidth: 1100, alignment: .leading)
            }
        }
    }

    /// One theme CARD (design: art header + name + a check on
    /// the selected card, a "Chọn" affordance on the others).
    /// The header is painted from the CANDIDATE theme's own
    /// tokens (its surface gradient + its name in its accent)
    /// — the app carries no per-theme still artwork, so the
    /// drawing's photographic header is substituted by the
    /// theme's own face, flagged in the WS-A report. The card
    /// buttons write the current-theme key and carry the
    /// SHARED themeChipFocused identity, so focus survives
    /// the switch into the shared column exactly as a chip
    /// tap there does.
    private func pcThemeCard(_ id: JoeThemeID) -> some View {
        let tokens = ThemeTokens.tokens(for: id)
        let selected = themeIDRaw == id.rawValue
        return Button {
            themeIDRaw = id.rawValue
        } label: {
            PCThemeCardLabel(tokens: tokens, selected: selected,
                             subtitle: pcThemeSubtitle(id))
        }
        .joeCardButton()
        .focused($themeChipFocused, equals: id.rawValue)
    }

    private func pcThemeSubtitle(_ id: JoeThemeID) -> String {
        switch id {
        case .billboard: return "Đỏ thẫm, phong cách Billboard."
        case .posterWall: return "Vàng trên đen, tương phản cao."
        case .sourceBoard: return "Xanh lá, bảng nguồn."
        case .ultra: return "Giao diện hiện có của JoeTV"
        case .privateCinema: return "Điện ảnh, theo cách riêng."
        }
    }

    private var pcPlaybackPane: some View {
        VStack(alignment: .leading, spacing: 40) {
            pcPaneHeader("Phát lại",
                         "Cách app chạy trước và kiểm tra đường truyền khi phát.")
            previewToggleBlock
            tunnelStatusBlock
        }
    }

    private var pcLanguagePane: some View {
        VStack(alignment: .leading, spacing: 40) {
            pcPaneHeader("Ngôn ngữ & phụ đề",
                         "Nguồn phụ đề app kiểm tra cho mỗi phim.")
            subAddonField
        }
    }

    private var pcDevicePane: some View {
        VStack(alignment: .leading, spacing: 40) {
            pcPaneHeader("Dữ liệu thiết bị",
                         "Dữ liệu app lưu trên Apple TV này và log chẩn đoán.")
            historyBlock
            logExportBlock
        }
    }

    private var pcInfoPane: some View {
        VStack(alignment: .leading, spacing: 40) {
            pcPaneHeader("Thông tin",
                         "Kiểm tra nguồn phim ngay trên máy này và thông tin bản dựng.")
            diagnosticsBlock
            signpostBlock
            Text("Joe TV v\(JoeRootView.appVersion)")
                .font(JoePCType.outfit(23))
                .foregroundStyle(theme.meta)
        }
    }

    private var pcDebridPane: some View {
        VStack(alignment: .leading, spacing: 40) {
            pcPaneHeader("Tài khoản debrid",
                         "Token và link nguồn torrent — chỉ lưu trong app này trên Apple TV của anh.")
            Text(torrentHeaderText)
                .font(JoePCType.outfit(25))
                .foregroundStyle(TorrentSettings.isConfigured
                                 ? JoeTheme.okGreen : .orange)
            torrentioField
            rdField
            torboxField
            premiumizeField
            mfField
            mfToggleButton
            userAddonField
            sportsField
            tmdbFieldBlock
            tvbGoldBlock
            saveNoteBlock
        }
    }

    /// v2.0.34 (item 6): true when the owner has entered at
    /// least one torrent credential himself — a pasted
    /// Torrentio link or one of the three debrid tokens, in
    /// STORAGE (the TorrentSettings accessors). The header
    /// reads this FIRST: the bundled fallback tokens make
    /// TorrentSettings.isConfigured true entirely on their
    /// own, and in 2.0.33 that turned the header green over
    /// fields that were all empty — the owner's device log
    /// proved every user value absent with only the bundled
    /// tokens present. The header must say WHICH of the two
    /// configurations is live, not just that one is.
    private var hasUserTorrentCredential: Bool {
        [TorrentSettings.addonURL, TorrentSettings.rdToken,
         TorrentSettings.torboxToken, TorrentSettings.premiumizeToken]
            .contains {
                !$0.trimmingCharacters(in: .whitespaces).isEmpty
            }
    }

    /// v2.0.34 (item 6): the header's configuration line —
    /// user-entered credentials, bundled-only, or nothing,
    /// stated as which. Both configured shapes keep the
    /// green ✓ (torrent works either way); only the words
    /// differ, so the line can never again claim a personal
    /// configuration over visibly empty fields.
    private var torrentHeaderText: String {
        if hasUserTorrentCredential {
            return "Nguồn Torrent: đã cấu hình ✓"
        }
        if TorrentSettings.isConfigured {
            return "Nguồn Torrent: đang dùng token tích hợp sẵn ✓"
        }
        return "Nguồn Torrent: chưa cấu hình — mục Phim Torrent cần ít nhất một mục dưới đây"
    }

    /// v2.0.34 (item 6): the truth line under one credential
    /// field, computed from the STORED value (the
    /// TorrentSettings accessor, trimmed as save() stores
    /// it) — never from the field's own rendering, which is
    /// precisely what could not be trusted: in 2.0.32/33
    /// the bars looked blank and there was no way to tell
    /// "empty" from "filled but not painting". A filled
    /// secret/token field shows its character count; NO
    /// part of any value is ever shown. An empty field with
    /// a bundled fallback in force says so, instead of
    /// implying nothing is configured at all.
    private func fieldStatus(stored: String, secret: Bool,
                             bundledFallback: String? = nil,
                             bundledText: String =
                                "Chưa điền — đang dùng token tích hợp sẵn",
                             emptyText: String = "Chưa điền")
        -> (text: String, filled: Bool) {
        let value = stored.trimmingCharacters(in: .whitespaces)
        if !value.isEmpty {
            return (secret ? "Đã điền ✓ (\(value.count) ký tự)"
                           : "Đã điền ✓", true)
        }
        if let bundledFallback,
           !bundledFallback.trimmingCharacters(in: .whitespaces).isEmpty {
            return (bundledText, false)
        }
        return (emptyText, false)
    }

    /// v2.0.38 (Sony 2.3.41 parity, item 1): the Addon URL
    /// field's truth line. Sony's Settings fault, present
    /// here in per-field form: the field renders only its
    /// stored value, and when that is empty the app's
    /// effective base is DERIVED — TorrentSettings
    /// .effectiveBase composes the Torrentio config URL
    /// from the debrid tokens (stored or bundled) — so a
    /// bare "Chưa điền" read as "nothing configured" over
    /// a working torrent setup, the owner's exact 2.0.33
    /// complaint one level down. The line now names that
    /// state and the segments composing it. Segment NAMES
    /// only, never the composed base itself: the base
    /// embeds the token values, and no credential is ever
    /// rendered (the fieldStatus rule above). Display
    /// only — nothing is written back to storage, and
    /// editing/saving the field is unchanged.
    private var addonFieldStatus: (text: String, filled: Bool) {
        let stored = TorrentSettings.addonURL
            .trimmingCharacters(in: .whitespaces)
        if !stored.isEmpty { return ("Đã điền ✓", true) }
        guard TorrentSettings.effectiveBase != nil else {
            return ("Chưa điền", false)
        }
        // effectiveBase non-nil with the stored URL empty
        // means the token composition produced it (a valid
        // pasted URL would have made the stored value
        // non-empty), so at least one segment exists here
        // by construction — the same segments, in the same
        // order, that effectiveBase composes from.
        var segments: [String] = []
        if !TorrentSettings.effectiveRDToken.isEmpty {
            segments.append("Real-Debrid ✓")
        }
        if !TorrentSettings.effectiveTorBoxToken.isEmpty {
            segments.append("TorBox ✓")
        }
        if !TorrentSettings.effectivePremiumizeToken.isEmpty {
            segments.append("Premiumize ✓")
        }
        return ("Chưa điền — đang dùng Torrentio tự ghép từ token (\(segments.joined(separator: " · ")))",
                false)
    }

    private func field(title: String, hint: String,
                       text: Binding<String>, id: String, secure: Bool,
                       allowsPaste: Bool = false,
                       status: (text: String, filled: Bool)? = nil,
                       inForce: Bool? = nil) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(theme.id == .privateCinema ? JoePCType.outfit(29, weight: .bold)
                              : .system(size: 29, weight: .bold))
                .foregroundStyle(theme.text)
            HStack(alignment: .center, spacing: 16) {
                Group {
                    if theme.id == .privateCinema {
                        // claude/opt-2 (owner photo 2026-11-22,
                        // FL-423 follow-up): under Private Cinema
                        // the system still painted its OWN rounded
                        // text-field pill inside the theme's bar
                        // even with .textFieldStyle(.plain), so
                        // every field read as a bar with a second
                        // capsule in it. The bar now shows ONLY
                        // the app's own text line: the value (or,
                        // for a secret, the bullet row the secure
                        // branch below already paints). The real
                        // TextField / SecureField stays in place,
                        // full size, for focus, the tvOS keyboard
                        // and the iPhone-keyboard hand-off — at
                        // 3 % opacity (UIKit drops a view from
                        // focus/hit-testing only below 1 %), so
                        // its pill no longer shows. Legacy themes
                        // keep the branch below unchanged.
                        ZStack(alignment: .leading) {
                            Text(secure
                                 ? String(repeating: "•",
                                          count: min(text.wrappedValue.count, 40))
                                 : text.wrappedValue)
                                .lineLimit(1)
                                .allowsHitTesting(false)
                            Group {
                                if secure {
                                    SecureField("", text: text)
                                } else {
                                    TextField("", text: text)
                                }
                            }
                            .opacity(0.03)
                        }
                    } else if secure {
                        // v2.0.3: a secure field's own masked
                        // rendering drops out while focus moves
                        // or the page scrolls (tvOS redraws the
                        // secure text lazily), which made a saved
                        // token read as an empty field. The
                        // bullet row UNDER the field is painted
                        // from the stored string itself — always
                        // installed, same font and colour the
                        // chrome applies — so the masked state
                        // is stable in every focus/scroll state;
                        // the field's own dots coincide with it
                        // whenever the system does draw them.
                        // The value itself is never rendered —
                        // one bullet per stored character, capped.
                        ZStack(alignment: .leading) {
                            Text(String(repeating: "•",
                                        count: min(text.wrappedValue.count, 40)))
                                .allowsHitTesting(false)
                            SecureField("", text: text)
                        }
                    } else {
                        TextField("", text: text)
                    }
                }
                .textFieldStyle(.plain)
                // UI-6 defect D-22: field text is 31 pt at
                // every field site (the shared token).
                // RECALC-213 (R3): under Private Cinema the
                // field family takes the designer's one
                // measured input size — Outfit 29/300 (the
                // Type sheet's search-input value; the
                // drawing set carries no Settings-field
                // size, so the input family rules). The
                // legacy themes keep the 31 pt token.
                .font(theme.id == .privateCinema
                      ? JoePCType.outfit(29,
                                         weight: .light)
                      : .system(size: ThemeTokens.fieldTextSize))
                // v2.0.39 (owner order 2026-11-19): Settings
                // fields wear the Settings-only chrome — no
                // light outer plate, one per-theme bar, and a
                // green check inside the bar when a value is
                // in force (inForce, computed by each call
                // site from the same effective-value sources
                // its status line reads; the default below is
                // the status's own filled flag, then the
                // field's current text).
                .joeSettingsFieldChrome(
                    focused: focusedField == id,
                    filled: inForce ?? status?.filled
                        ?? !text.wrappedValue
                            .trimmingCharacters(in: .whitespaces).isEmpty)
                .focused($focusedField, equals: id)
                .onSubmit { save() }
                if allowsPaste {
                    iphoneInputButton(id: id)
                }
            }
            .frame(maxWidth: 1250, alignment: .leading)
            // v2.0.34 (item 6): the field's truth line (see
            // fieldStatus) — additive only, in the hint's own
            // style: 25 pt, okGreen when filled, theme.meta
            // when not. It sits between the field and its
            // hint so the state reads as the field's own.
            if let status {
                Text(status.text)
                    .font(theme.id == .privateCinema ? JoePCType.outfit(25) : .system(size: 25))
                    .foregroundStyle(status.filled
                                     ? JoeTheme.okGreen : theme.meta)
                    .frame(maxWidth: 1250, alignment: .leading)
            }
            Text(hint)
                .font(theme.id == .privateCinema ? JoePCType.outfit(25) : .system(size: 25))
                .foregroundStyle(theme.meta)
                .frame(maxWidth: 1250, alignment: .leading)
            if let inputHint = inputHints[id] {
                Text(inputHint)
                    .font(theme.id == .privateCinema ? JoePCType.outfit(25) : .system(size: 25))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: 1250, alignment: .leading)
            }
        }
    }

    /// The credential-entry helper for a field (1.9.2, Team 9
    /// item 7, rewritten by TEAM 10-FIXUP-2). tvOS has NO
    /// pasteboard API — the pasteboard class is marked
    /// API_UNAVAILABLE on tvOS and build #16 failed
    /// compiling it — so the app
    /// cannot read the clipboard itself. The route tvOS does
    /// support is the iPhone keyboard: while a field is
    /// focused, the owner's iPhone offers the Apple TV
    /// keyboard (a notification appears on the iPhone), where
    /// he pastes the code he copied and the text lands in the
    /// field directly, saved by the fields' existing
    /// auto-save. This button therefore only focuses the
    /// field and shows the guidance hint under it — it does
    /// not, and must not claim to, paste anything itself.
    /// Typing a long token with the remote was the dead end
    /// that left torrent unconfigured on this device.
    private func iphoneInputButton(id: String) -> some View {
        Button {
            inputHints[id] = "Đã chọn ô nhập — mở bàn phím Apple TV trên iPhone của anh (thông báo hiện trên iPhone khi ô đang được chọn), dán mã vào đó, chữ sẽ tự vào ô này."
            focusedField = id
        } label: {
            JoePrimaryLabel(title: "Nhập từ iPhone")
        }
        .joeCardButton()
        .focused($focusedField, equals: "paste|" + id)
    }

    /// Tunnel status row (1.9.2, Team 9 item 5): READ-ONLY —
    /// whether the Vietnam route is answering right now,
    /// probed through KKPhim with a short fuse when Settings
    /// opens and on demand. Display only: no switch, no
    /// control (routing stays the Sing-box profile's job, per
    /// this screen's standing rule). The copy labels the
    /// verdict as what it is — an inference from KK answering,
    /// not a read of the profile's actual state.
    @ViewBuilder
    private var tunnelStatusBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Circle()
                    .fill(kkStatusColor)
                    .frame(width: 16, height: 16)
                Text(kkStatusText)
                    .font(theme.id == .privateCinema
                          ? JoePCType.outfit(29) : .system(size: 29))
                    .foregroundStyle(theme.text)
                    .frame(maxWidth: 1250, alignment: .leading)
            }
            Button {
                // The owner's explicit re-check: never
                // throttled (FIX-214 — the throttle below
                // gates only the automatic open-time run).
                Task { await runKKProbe(force: true) }
            } label: {
                JoePrimaryLabel(title: "Kiểm tra lại")
            }
            .joeCardButton()
            .focused($kkProbeFocused)
            .disabled(kkProbing)
        }
    }

    private var kkProbing: Bool {
        if case .probing = kkStatus { return true }
        return false
    }

    private var kkStatusColor: Color {
        switch kkStatus {
        case .ok: return JoeTheme.okGreen
        case .down: return JoeTheme.accentRed
        case .idle, .probing: return .white.opacity(0.4)
        }
    }

    private var kkStatusText: String {
        switch kkStatus {
        case .ok(let ms):
            return "Đường KKPhim: đang thông (~\(ms) ms) — đường Việt Nam đang tới được, hầm có vẻ đang bật"
        case .down:
            return "Đường KKPhim: không thông — kiểm tra profile hầm trên Apple TV"
        case .idle, .probing:
            return "Đang kiểm tra đường KKPhim…"
        }
    }

    /// FIX-214 (DESIGN-PASS-214 §3.2): the automatic
    /// open-time probe is throttled to once per 900 s
    /// per process — through 2.1.3 EVERY Settings enter
    /// fired this network probe (a KKPhim search
    /// round-trip) as part of the per-enter re-work the
    /// lag conviction names. The owner's "Kiểm tra lại"
    /// button passes force: true and always runs.
    /// (nonisolated(unsafe) per the tree's latched-state
    /// idiom — the stamp is touched only from this
    /// view's MainActor tasks and button actions.)
    private nonisolated(unsafe) static var lastKKProbeAt: Date?

    private func runKKProbe(force: Bool = false) async {
        if kkProbing { return }
        if !force, let last = Self.lastKKProbeAt,
           Date().timeIntervalSince(last) < 900 { return }
        Self.lastKKProbeAt = Date()
        kkStatus = .probing
        let r = await SourceProbe.probeKK()
        kkStatus = r.ok ? .ok(ms: r.millis) : .down
    }

    /// TVB Gold (YouTube) — design §3.1. One focusable row:
    /// the session state as a presence dot (the Settings
    /// law the owner set 2026-11-19: a green dot marks a
    /// filled / in-use value, readable at a glance) and a
    /// tap that opens the sign-in door. Signing IN is the
    /// owner's act, in the door's web view, once per install.
    private var tvbGoldBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("TVB Gold (YouTube)")
                .font(theme.id == .privateCinema ? JoePCType.outfit(34, weight: .bold)
                              : .system(size: 34, weight: .bold))
                .foregroundStyle(theme.text)
            Button {
                nav.ytSignInOpen = true
            } label: {
                JoeTVBGoldRowLabel(signedIn: ytSession.signedIn)
            }
            .joeCardButton()
            .focused($tvbGoldFocused)
            Text("Đăng nhập một lần bằng tài khoản Gold của anh; app chỉ ghi nhớ trạng thái đăng nhập, không lưu mật khẩu. Mỗi lần cài lại app qua Signulous cần đăng nhập lại một lần.")
                .font(theme.id == .privateCinema ? JoePCType.outfit(25) : .system(size: 25))
                .foregroundStyle(theme.meta)
                .frame(maxWidth: 1200, alignment: .leading)
        }
    }

    /// Opened-movies history reset (v2.0.7, owner requirement:
    /// all three themes lacked any reset for accidentally
    /// opened films). Every opened film lands in Continue
    /// Watching (the store caps it at 40 entries) and until
    /// now the ONLY removal route was the per-card long-press
    /// menu — a rail full of mis-taps could never be cleared.
    /// This block is the one-press route, and it lives here
    /// rather than in a theme's home for two structural
    /// reasons: this screen is the ONE structure shared by
    /// all three themes (so one button cures all three), and
    /// the homes' CW rail cards carry the first-rail move
    /// handler whose arithmetic is built from rail entries
    /// only — a non-entry control inside that rail would be
    /// skipped by its own DOWN routing. The button clears
    /// the whole progress history (every provider AND the
    /// torrent entries — both tabs read the same store);
    /// favorites live in a separate array and are never
    /// touched. Focus: a plain member of this screen's single
    /// column, whose movement is geometric (the convergence
    /// note on the body), exactly like the "Kiểm tra lại" and
    /// "Kiểm tra ngay" buttons — no boundary handler, no dead
    /// end; it is disabled while the history is empty (the
    /// "Kiểm tra lại" disabled-while-probing precedent), so
    /// it can never hold focus with nothing to do. The
    /// confirmation is the app's standard destructive shape
    /// (the exit dialog's): destructive confirm + cancel.
    @ViewBuilder
    private var historyBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Lịch sử đã mở")
                .font(theme.id == .privateCinema ? JoePCType.outfit(34, weight: .bold)
                              : .system(size: 34, weight: .bold))
                .foregroundStyle(theme.text)
            Text(watch.progress().isEmpty
                 ? "Chưa có phim nào trong mục Đang xem dở."
                 : "Đang lưu \(watch.progress().count) mục xem tiếp — gồm cả những phim chỉ mở lỡ một lần. Xoá hết để danh sách sạch lại; phim Yêu thích không bị xoá.")
                .font(theme.id == .privateCinema ? JoePCType.outfit(25) : .system(size: 25))
                .foregroundStyle(theme.meta)
                .frame(maxWidth: 1200, alignment: .leading)
            Button {
                cwResetConfirm = true
            } label: {
                JoePrimaryLabel(title: "Xoá hết lịch sử đã mở")
            }
            .joeCardButton()
            .focused($cwResetFocused)
            .disabled(watch.progress().isEmpty)
        }
        .alert("Xoá hết lịch sử đã mở?", isPresented: $cwResetConfirm) {
            Button("Xoá hết", role: .destructive) {
                watch.clearAllProgress()
            }
            Button("Huỷ", role: .cancel) { }
        } message: {
            Text("Mọi mục trong Đang xem dở sẽ bị xoá. Phim Yêu thích vẫn được giữ nguyên.")
        }
    }

    /// Source diagnostics (§7.9, board contract): one lightweight
    /// probe per provider, run ON THIS device, results rendered
    /// in place — the block exists so a dead route shows a named
    /// verdict on the TV instead of a silent spinner elsewhere.
    /// Focus stays on the button; result rows are not focusable.
    @ViewBuilder
    private var diagnosticsBlock: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Kiểm tra nguồn phim")
                .font(theme.id == .privateCinema ? JoePCType.outfit(34, weight: .bold)
                              : .system(size: 34, weight: .bold))
                .foregroundStyle(theme.text)
            Text("Đo từng nguồn phim ngay trên máy này.")
                .font(theme.id == .privateCinema ? JoePCType.outfit(25) : .system(size: 25))
                .foregroundStyle(theme.meta)
            if probing {
                HStack(spacing: 14) {
                    ProgressView()
                        .tint(.white)
                    Text("Đang kiểm tra…")
                        .font(theme.id == .privateCinema
                              ? JoePCType.outfit(29) : .system(size: 29))
                        .foregroundStyle(theme.text)
                }
            } else if !probeResults.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(probeResults.enumerated()), id: \.offset) { _, result in
                        HStack(spacing: 12) {
                            Circle()
                                .fill(result.ok
                                      ? JoeTheme.okGreen
                                      : JoeTheme.accentRed)
                                .frame(width: 16, height: 16)
                            Text(result.name)
                                .font(theme.id == .privateCinema
                                      ? JoePCType.outfit(29) : .system(size: 29))
                                .foregroundStyle(theme.text)
                            Spacer()
                            Text("\(result.millis) ms")
                                .font(theme.id == .privateCinema ? JoePCType.outfit(25) : .system(size: 25))
                                .foregroundStyle(theme.meta)
                            Text(result.note)
                                .font(theme.id == .privateCinema ? JoePCType.outfit(25) : .system(size: 25))
                                .foregroundStyle(result.ok ? .white.opacity(0.7) : .orange)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .frame(height: 60)
                    }
                }
            }
            Button {
                probing = true
                Task {
                    probeResults = await SourceProbe.run()
                    probing = false
                }
            } label: {
                JoePrimaryLabel(title: "Kiểm tra ngay")
            }
            .joeCardButton()
            .focused($probeFocused)
            .disabled(probing)
        }
    }

    /// Phim load signposts (convergence spec 5d): the tail of
    /// the persisted LoadSignpost log, read-only. After any
    /// future stall the owner force-closes, relaunches, opens
    /// Settings and photographs this block — the last entries
    /// say where the load path stopped. No buttons, no writes.
    @ViewBuilder
    private var signpostBlock: some View {
        let entries = LoadSignpost.entries()
        VStack(alignment: .leading, spacing: 12) {
            Text("Nhật ký tải phim (chẩn đoán)")
                .font(theme.id == .privateCinema ? JoePCType.outfit(34, weight: .bold)
                              : .system(size: 34, weight: .bold))
                .foregroundStyle(theme.text)
            if entries.isEmpty {
                Text("Chưa có dữ liệu — mở trang Phim một lần rồi quay lại.")
                    .font(theme.id == .privateCinema ? JoePCType.outfit(25) : .system(size: 25))
                    .foregroundStyle(theme.meta)
                    .frame(maxWidth: 1200, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(entries.suffix(15).enumerated()), id: \.offset) { _, entry in
                        Text(entry)
                            .font(.system(size: 20, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: 1400, alignment: .leading)
                    }
                }
            }
        }
    }

    /// Log export (v2.0.33): the entry point for getting the
    /// diagnostic log OFF the Apple TV. The owner tests on a
    /// real box with no way to pull files from it, so faults
    /// arrived as photos and guesswork; DiagLog (JoeDiagLog.swift)
    /// now keeps a rolling, token-scrubbed log in the sandbox
    /// and this block opens the screen that serves it over the
    /// home LAN (tvOS has no share sheet / activity view /
    /// file exporter — Apple's HIG states activity views are
    /// not supported on tvOS — so LAN + QR is the route, not a
    /// preference). The block itself is deliberately plain:
    /// one heading, one honest explanation, one button.
    /// v2.0.48 (D4): the backdrop-preview toggle — the
    /// MediaFusion toggle's exact shape (one Button, one
    /// JoeSecondaryLabel naming the state). Default ON
    /// (JoePreviewSettings); the write lands on toggle,
    /// so no save() round-trip is involved.
    @ViewBuilder
    private var previewToggleBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Xem trước trên ảnh nền")
                .font(theme.id == .privateCinema ? JoePCType.outfit(34, weight: .bold)
                              : .system(size: 34, weight: .bold))
                .foregroundStyle(theme.text)
            Text("Khi mở một phim, ảnh nền của màn chi tiết tự chạy một đoạn ngắn của chính phim đó (tắt tiếng). Bấm phím bất kỳ là dừng ngay.")
                .font(theme.id == .privateCinema ? JoePCType.outfit(25) : .system(size: 25))
                .foregroundStyle(theme.meta)
                .frame(maxWidth: 1200, alignment: .leading)
            Button {
                previewEnabled.toggle()
                JoePreviewSettings.enabled = previewEnabled
            } label: {
                JoeSecondaryLabel(title: previewEnabled
                                  ? "Xem trước video trên ảnh nền: đang bật ✓"
                                  : "Xem trước video trên ảnh nền: đang tắt")
            }
            .joeCardButton()
            .focused($previewToggleFocused)
        }
    }

    @ViewBuilder
    private var logExportBlock: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Log chẩn đoán")
                .font(theme.id == .privateCinema ? JoePCType.outfit(34, weight: .bold)
                              : .system(size: 34, weight: .bold))
                .foregroundStyle(theme.text)
            Text("App ghi lại một bản log chẩn đoán để truy vết lỗi — không bao giờ ghi mật khẩu, token hay link vào log. Khi có lỗi cần bằng chứng, anh bấm nút dưới đây và gửi file log cho em.")
                .font(theme.id == .privateCinema ? JoePCType.outfit(25) : .system(size: 25))
                .foregroundStyle(theme.meta)
                .frame(maxWidth: 1200, alignment: .leading)
            Button {
                showLogExport = true
            } label: {
                JoeSecondaryLabel(title: "Gửi log chẩn đoán")
            }
            .joeCardButton()
            .focused($logExportFocused)
        }
    }

    private func save(silent: Bool = false) {
        TorrentSettings.addonURL = addonURL.trimmingCharacters(in: .whitespaces)
        TorrentSettings.rdToken = rdToken.trimmingCharacters(in: .whitespaces)
        TorrentSettings.torboxToken = torboxToken.trimmingCharacters(in: .whitespaces)
        TorrentSettings.premiumizeToken = premiumizeToken.trimmingCharacters(in: .whitespaces)
        TorrentSettings.mfURL = mfURL.trimmingCharacters(in: .whitespaces)
        TorrentSettings.mfEnabled = mfEnabled
        TorrentSettings.userAddonURL = userAddonURL.trimmingCharacters(in: .whitespaces)
        TorrentSettings.sportsURL = sportsURL.trimmingCharacters(in: .whitespaces)
        TorrentSettings.subAddonURL = subAddonURL.trimmingCharacters(in: .whitespaces)
        UserDefaults.standard.set(tmdbKey.trimmingCharacters(in: .whitespaces),
                                  forKey: "tmdb_api_key")
        if !silent {
            savedTick = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                savedTick = false
            }
        }
    }
}

// CONVERGENCE RECORD (2026-11-15): JoeSettingsMoveTrap — this
// file's copy of the conditional move-trap pattern — is
// DELETED; see the record at the end of JoeTVApp.swift. The
// first-field routing it powered is geometric on this layout.

/// The TVB Gold row's label (design §3.1): the presence dot
/// + state word + hint, painted with the app's ONE button
/// construction — the JoeSecondaryLabel recipe (the house
/// button shape, surface2 fill, resting stroke, theme
/// focus ring inside when focused) — so the door's entry
/// point carries the same focus treatment as every other
/// Settings button. FIX-214 (gate R2 Lens 3 F2): the shape
/// follows the A3 unification like every action button —
/// rounded-rect r7 under Private Cinema, capsule on the
/// legacy legs (whose button family is capsule).
private struct JoeTVBGoldRowLabel: View {
    let signedIn: Bool
    @Environment(\.isFocused) private var isFocused
    @Environment(\.joeTheme) private var theme

    var body: some View {
        if theme.id == .privateCinema {
            chip(RoundedRectangle(cornerRadius: 7))
        } else {
            chip(Capsule())
        }
    }

    private func chip<S: InsettableShape>(_ shape: S) -> some View {
        HStack(spacing: 14) {
            Text(signedIn ? "●" : "○")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(signedIn ? JoeTheme.okGreen : theme.meta)
            Text(signedIn ? "Đã đăng nhập" : "Chưa đăng nhập")
                .font(theme.id == .privateCinema
                      ? JoePCType.outfit(29, weight: .semibold)
                      : .system(size: 29, weight: .semibold))
                .foregroundStyle(theme.text)
            Text("— bấm để mở trang đăng nhập")
                .font(theme.id == .privateCinema ? JoePCType.outfit(25) : .system(size: 25))
                .foregroundStyle(theme.meta)
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 17)
        .background(shape.fill(theme.surface2))
        // Fault 11 fix round: the resting hairline is its
        // own overlay and the focus ring is the chip
        // family's (JoeChipRing) — under Private Cinema the
        // ivory outset outline; under every other theme the
        // house JoeFocusRing over the hairline, which the
        // inside band covers exactly as the single-overlay
        // expression did.
        .overlay(shape.strokeBorder(theme.stroke, lineWidth: 1.5))
        .overlay(JoeChipRing(shape: shape))
    }
}

// MARK: - Private Cinema Settings labels (v2.1.1)
//
// The PC two-pane composition's three label shapes. All
// follow the house pattern (JoeTVBGoldRowLabel / PillLabel):
// the label reads its OWN focus from the environment and
// changes VALUES only (fill, stroke colour/width, text
// colour) inside shapes that are always installed — no
// scale, no hand-drawn competing ring, no structure
// conditional on focus.

/// The left rail's category row: icon + title on a rounded
/// panel face. The SELECTED row wears the filled Panel face
/// (theme.surface2 = #182024 under PC) per the drawing; an
/// unselected row is transparent. Focus adds the drawn
/// ivory outset outline (Fault 11 fix round — the inside
/// theme.focus stroke it first shipped with was the legacy
/// pattern).
private struct PCCategoryRowLabel: View {
    let title: String
    let icon: String
    let selected: Bool
    @Environment(\.isFocused) private var isFocused
    @Environment(\.joeTheme) private var theme

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .medium))
            Text(title)
                .font(JoePCType.outfit(28, weight: (selected || isFocused) ? .semibold : .regular))
                .lineLimit(1)
            Spacer()
        }
        .foregroundStyle(selected || isFocused ? theme.text : theme.meta)
        .padding(.horizontal, 26)
        .padding(.vertical, 18)
        // FIX-214 (gate R2 Lens 3 F1): the row's own face
        // takes the rail's drawn width 390 (the container
        // already did) — the approved demo draws the row
        // [SIDE, SIDE+390], not 440.
        .frame(width: 390, alignment: .leading)
        // claude/opt-2 (FL-422): the selected Panel face only
        // while NOT focused — focus is the ivory outset ring.
        .background(RoundedRectangle(cornerRadius: 14)
            .fill(selected && !isFocused ? theme.surface2 : Color.clear))
        // Fault 11 fix round: the drawn Settings rail focus
        // is an ivory OUTSET outline around the row (the
        // build-Settings render's focused "Giao diện" row),
        // not the legacy inside ring.
        .overlay(JoeOutsetRing(shape: RoundedRectangle(cornerRadius: 14),
                               color: JoeCinemaFocus.ivory,
                               lineWidth: 2, offset: 4))
    }
}

/// The top row's "← Quay lại" (the drawing's plain text
/// affordance): focus recolours the text to theme.focus —
/// value-only, no shape change.
private struct PCBackLabel: View {
    @Environment(\.isFocused) private var isFocused
    @Environment(\.joeTheme) private var theme

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.left")
                .font(.system(size: 24, weight: .medium))
            Text("Quay lại")
                .font(JoePCType.outfit(26))
        }
        .foregroundStyle(isFocused ? theme.focus : theme.text)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

/// One theme card in the PC Giao diện pane: an art header
/// painted from the CANDIDATE theme's own tokens (surface
/// gradient + its name in its accent — the app carries no
/// per-theme still artwork; see the flag in the WS-A
/// report), over a Panel footer carrying the theme's name,
/// its line, and — per the drawing — a check on the
/// selected card or a "Chọn" affordance on the others.
private struct PCThemeCardLabel: View {
    let tokens: ThemeTokens
    let selected: Bool
    let subtitle: String
    @Environment(\.isFocused) private var isFocused
    @Environment(\.joeTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                tokens.surfaceGradient
                Text(tokens.id.pickerLabel)
                    .font(.system(size: 44, weight: .heavy))
                    .foregroundStyle(tokens.accent2)
                    .padding(24)
            }
            .frame(maxWidth: .infinity)
            // FIX-214 (FULL-THEME-AUDIT-214 B9): the
            // drawn header is ≈245 tall (was 190); with
            // the name/subtitle row below, the card
            // totals ≈390 as drawn.
            .frame(height: 245)
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(tokens.id.pickerLabel)
                        .font(JoePCType.outfit(29, weight: .semibold))
                        .foregroundStyle(theme.text)
                    Text(subtitle)
                        .font(JoePCType.outfit(23))
                        .foregroundStyle(theme.meta)
                        .lineLimit(1)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(theme.accent2)
                } else {
                    Text("Chọn")
                        .font(JoePCType.outfit(22, weight: .semibold))
                        .foregroundStyle(theme.text)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        // FIX-214 (FULL-THEME-AUDIT-214
                        // B9/A3): the drawn chip is a
                        // small rounded rect — r7, not a
                        // capsule.
                        .background(RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(theme.stroke, lineWidth: 1.5))
                }
            }
            // FIX-214 (gate R1 Lens 3): the drawn card
            // total is ≈390 — header 245 (above) + this
            // footer row. The footer's vertical padding
            // rises 24 → 44 so the total lands at ≈390
            // (245 + ≈145), not the ≈351 the header fix
            // alone produced. Horizontal stays 24.
            .padding(.horizontal, 24)
            .padding(.vertical, 44)
            .background(theme.surface2)
        }
        .background(RoundedRectangle(cornerRadius: 16).fill(theme.surface2))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        // Fault 11 fix round: the concept Settings render's
        // selected card wears an ivory OUTSET outline (the
        // tile family's 3 px / offset 5 px at this size);
        // the selected hairline stays as its own overlay
        // under it.
        .overlay(RoundedRectangle(cornerRadius: 16)
            .strokeBorder(selected ? theme.stroke : .clear,
                          lineWidth: 1.5))
        .overlay(JoeOutsetRing(shape: RoundedRectangle(cornerRadius: 16),
                               color: JoeCinemaFocus.ivory,
                               lineWidth: 2, offset: 4))
    }
}

// MARK: - Log export screen (v2.0.33)
//
// The full-screen cover behind "Gửi log chẩn đoán" (see
// logExportBlock above). v2.0.48 (FL-378): it owns NO
// server — it displays the state of the ONE app-lifetime
// DiagLogServer.shared, which was started once at app
// launch and is never stopped by any screen. (The old
// shape — a per-screen instance started on appear and
// stopped fire-and-forget on disappear — is the FL-378
// fault: a reopened screen re-bound port 18080 while the
// previous listener's asynchronous cancel still held
// it, and the channel died with NWError 48.)
//
// tvOS constraint that shapes the whole screen: there is NO
// share sheet on tvOS (Apple's HIG: activity views are not
// supported; UIActivityViewController, ShareLink and
// fileExporter are unavailable and do not compile), so the
// file cannot be "shared" anywhere from the TV itself. The
// working route is the one the server provides: the Apple
// TV serves joetv-diag.txt over the home LAN and this
// screen shows the address two ways — in large type for
// typing into Safari on the iPhone, and as a QR code for
// the iPhone Camera — and the OWNER's iPhone does the
// downloading and the sending. The QR is rendered on a
// white rounded rect on purpose: a QR code needs its light
// background and quiet zone to scan, on every theme — that
// white card is a functional element, not a theme surface.
private struct LogExportView: View {
    @Environment(\.joeTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    /// The app-lifetime server (v2.0.48, FL-378) — this
    /// screen displays its state; it creates nothing.
    private var server: DiagLogServer { DiagLogServer.shared }
    @State private var serverState: DiagLogServer.State = .starting
    @FocusState private var closeFocused: Bool

    var body: some View {
        ZStack {
            theme.bg.ignoresSafeArea()
            VStack(alignment: .center, spacing: 36) {
                Text("Gửi log chẩn đoán")
                    .font(theme.id == .privateCinema ? JoePCType.outfit(44, weight: .bold) : .system(size: 44, weight: .bold))
                    .foregroundStyle(theme.text)

                switch serverState {
                case .starting:
                    ProgressView()
                        .tint(.white)
                    Text("Đang mở kênh gửi log…")
                        .font(theme.id == .privateCinema ? JoePCType.outfit(29) : .system(size: 29))
                        .foregroundStyle(theme.text)
                case .serving(let url):
                    Text(url)
                        .font(theme.id == .privateCinema ? JoePCType.outfit(44, weight: .bold) : .system(size: 44, weight: .bold))
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                    // v2.0.40 (P0.2 / H-1): the address above
                    // already carries the one-time PIN; it is
                    // also shown on its own line so the owner
                    // can type it separately if he opened the
                    // bare address. The code is minted when
                    // the app-lifetime server starts (once
                    // per app launch, v2.0.48), and 3 wrong
                    // tries pause the channel for 60 seconds.
                    if !server.pin.isEmpty {
                        Text("Mã PIN một lần: \(server.pin)")
                            .font(theme.id == .privateCinema ? JoePCType.outfit(36, weight: .semibold) : .system(size: 36, weight: .semibold))
                            .foregroundStyle(theme.text)
                    }
                    if let qr = Self.qrImage(for: url) {
                        // White card = the QR's quiet zone
                        // (see the header note): constant
                        // white on every theme, by necessity.
                        Image(uiImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 360, height: 360)
                            .padding(28)
                            .background(RoundedRectangle(cornerRadius: 28)
                                .fill(Color.white))
                    }
                    Text("Trên iPhone, mở Safari và nhập đúng địa chỉ trên (địa chỉ đã gồm mã PIN một lần) — file log sẽ tải về máy. Hoặc dùng Camera của iPhone quét mã QR. Kênh gửi log mở sẵn từ khi app khởi động và mở trong suốt lúc app đang chạy. Lấy xong, gửi file vào cuộc trò chuyện với em.")
                        .font(theme.id == .privateCinema ? JoePCType.outfit(25) : .system(size: 25))
                        .foregroundStyle(theme.meta)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 1250, alignment: .center)
                case .failed(let message):
                    Text(message)
                        .font(theme.id == .privateCinema ? JoePCType.outfit(29) : .system(size: 29))
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 1250, alignment: .center)
                }

                Button {
                    dismiss()
                } label: {
                    JoePrimaryLabel(title: "Đóng")
                }
                .joeCardButton()
                .focused($closeFocused)
            }
            .padding(60)
        }
        .defaultFocus($closeFocused, true)
        .onAppear {
            server.onStateChange = { state in
                serverState = state
            }
            // v2.0.48 (FL-378): start() on the shared
            // server is a state re-report when it is
            // already serving (the normal case — it was
            // started at app launch), never a second
            // bind; after a failure it is the one retry.
            server.start()
        }
        .onDisappear {
            // v2.0.48 (FL-378): detach this screen's
            // callback ONLY — the app-lifetime server
            // keeps serving after the screen closes.
            server.onStateChange = nil
        }
    }

    /// QR code for the serving URL (CoreImage's
    /// CIQRCodeGenerator): the filter's output is a tiny
    /// bitmap (one pixel per module), so it is scaled up
    /// with a plain transform and rendered through a
    /// CIContext into a UIImage; the SwiftUI Image above
    /// then draws it with interpolation OFF, so the modules
    /// stay hard-edged and scannable at 360 pt.
    private static func qrImage(for string: String) -> UIImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator")
        else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(
            by: CGAffineTransform(scaleX: 12, y: 12))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled,
                                                  from: scaled.extent)
        else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
