import SwiftUI

// MARK: - Settings (v1.0.46)

/// Pad color themes (v1.0.46, palette curated in v1.0.51): the pad
/// gradient and the app accent follow the chosen theme. Stored in
/// UserDefaults; views read it through PadTheme.current, or through
/// @AppStorage("padTheme") when they need to re-render live on a
/// change. The v1.0.51 set is modern, popular colors — not a rainbow.
/// Midnight is the default (the old blue, kept so existing installs
/// look the same); the rest are muted, premium tones. An old stored
/// value (blue/purple/teal/green/orange/pink) falls back to Midnight.
private enum PadTheme: String, CaseIterable {
    case midnight, sage, clay, graphite, lavender, blush

    var name: String {
        switch self {
        case .midnight: return "Midnight"
        case .sage: return "Sage"
        case .clay: return "Clay"
        case .graphite: return "Graphite"
        case .lavender: return "Lavender"
        case .blush: return "Blush"
        }
    }
    /// Gradient top / bottom for the pad.
    var top: Color {
        switch self {
        case .midnight: return Color(red: 0.10, green: 0.16, blue: 0.35)
        case .sage: return Color(red: 0.16, green: 0.24, blue: 0.20)
        case .clay: return Color(red: 0.32, green: 0.16, blue: 0.10)
        case .graphite: return Color(red: 0.20, green: 0.21, blue: 0.24)
        case .lavender: return Color(red: 0.24, green: 0.20, blue: 0.38)
        case .blush: return Color(red: 0.34, green: 0.16, blue: 0.22)
        }
    }
    var bottom: Color {
        switch self {
        case .midnight: return Color(red: 0.05, green: 0.07, blue: 0.18)
        case .sage: return Color(red: 0.08, green: 0.13, blue: 0.10)
        case .clay: return Color(red: 0.18, green: 0.08, blue: 0.05)
        case .graphite: return Color(red: 0.10, green: 0.10, blue: 0.12)
        case .lavender: return Color(red: 0.13, green: 0.10, blue: 0.22)
        case .blush: return Color(red: 0.19, green: 0.08, blue: 0.12)
        }
    }
    /// Light-mode pad gradient (v1.0.51): a pale tint of the theme,
    /// so the pad reads as a light surface instead of a dark slab
    /// floating on a white page.
    var lightTop: Color {
        switch self {
        case .midnight: return Color(red: 0.85, green: 0.90, blue: 0.99)
        case .sage: return Color(red: 0.87, green: 0.92, blue: 0.88)
        case .clay: return Color(red: 0.98, green: 0.89, blue: 0.84)
        case .graphite: return Color(red: 0.90, green: 0.91, blue: 0.93)
        case .lavender: return Color(red: 0.91, green: 0.88, blue: 0.99)
        case .blush: return Color(red: 0.99, green: 0.88, blue: 0.92)
        }
    }
    var lightBottom: Color {
        switch self {
        case .midnight: return Color(red: 0.74, green: 0.82, blue: 0.98)
        case .sage: return Color(red: 0.78, green: 0.88, blue: 0.80)
        case .clay: return Color(red: 0.96, green: 0.80, blue: 0.71)
        case .graphite: return Color(red: 0.82, green: 0.83, blue: 0.87)
        case .lavender: return Color(red: 0.84, green: 0.78, blue: 0.98)
        case .blush: return Color(red: 0.98, green: 0.78, blue: 0.85)
        }
    }
    /// Light-mode page background (v1.0.51, deepened in v1.0.52):
    /// a tint of the theme, so the page stops being flat white and
    /// ties to the pad. The first version was the palest tint and
    /// it washed everything out — gray text and pale cards
    /// disappeared into the bright page — so the tint is deeper
    /// now, enough for the white surfaces to stand against it.
    var pageBackground: Color {
        switch self {
        case .midnight: return Color(red: 0.89, green: 0.92, blue: 0.99)
        case .sage: return Color(red: 0.90, green: 0.93, blue: 0.91)
        case .clay: return Color(red: 0.95, green: 0.91, blue: 0.89)
        case .graphite: return Color(red: 0.91, green: 0.92, blue: 0.94)
        case .lavender: return Color(red: 0.92, green: 0.90, blue: 0.98)
        case .blush: return Color(red: 0.97, green: 0.91, blue: 0.93)
        }
    }
    /// The accent: pad border, TV icon, keyboard ring.
    var accent: Color {
        switch self {
        case .midnight: return Color(red: 0.15, green: 0.45, blue: 1.0)
        case .sage: return Color(red: 0.35, green: 0.65, blue: 0.45)
        case .clay: return Color(red: 0.85, green: 0.45, blue: 0.30)
        case .graphite: return Color(red: 0.60, green: 0.65, blue: 0.80)
        case .lavender: return Color(red: 0.65, green: 0.55, blue: 1.0)
        case .blush: return Color(red: 0.95, green: 0.45, blue: 0.60)
        }
    }
    static var current: PadTheme {
        PadTheme(rawValue: UserDefaults.standard.string(forKey: "padTheme") ?? "") ?? .midnight
    }
}

/// Pad border effect (v1.0.46): off is the plain static border;
/// glow puts a soft halo around the pad; flow runs a light around
/// the border, LED-keyboard style.
private enum PadBorder: String, CaseIterable {
    case off, glow, flow
    var name: String {
        switch self {
        case .off: return "Off"
        case .glow: return "Glow"
        case .flow: return "Flow"
        }
    }
    static var current: PadBorder {
        PadBorder(rawValue: UserDefaults.standard.string(forKey: "padBorder") ?? "") ?? .off
    }
}

/// Finger trail style (v1.0.46, Line removed in v1.0.51 — Nick:
/// keep Off, Glow, Dots only): how the swipe trail looks.
private enum TrailStyle: String, CaseIterable {
    case off, glow, dots
    var name: String {
        switch self {
        case .off: return "Off"
        case .glow: return "Glow"
        case .dots: return "Dots"
        }
    }
    static var current: TrailStyle {
        TrailStyle(rawValue: UserDefaults.standard.string(forKey: "trailStyle") ?? "") ?? .glow
    }
}

/// App appearance (v1.0.46, default System in v1.0.51 — Nick: the
/// app follows the phone unless the user picks Dark or Light, and
/// then it remembers that choice): system follows the phone, dark
/// and light pin it. The pad keeps its own theme gradient in both
/// modes.
private enum AppAppearance: String, CaseIterable {
    case system, dark, light
    var name: String {
        switch self {
        case .system: return "System"
        case .dark: return "Dark"
        case .light: return "Light"
        }
    }
    var scheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }
    static var current: AppAppearance {
        AppAppearance(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .system
    }
}

/// Page background (v1.0.48, retuned in v1.0.51): not the system
/// extremes. Dark is Chrome's dark gray (#202124), not solid black;
/// light is the palest tint of the pad theme — not flat white, so
/// the page ties to the pad. Resolved from the environment color
/// scheme, so System follows the phone.
private enum AppBackground {
    static func color(for scheme: ColorScheme) -> Color {
        switch scheme {
        case .dark: return Color(red: 0.125, green: 0.129, blue: 0.141)
        case .light: return PadTheme.current.pageBackground
        @unknown default: return Color(.systemBackground)
        }
    }
}

/// Page background with a glass wash (v1.0.53): the flat page color
/// plus soft radial glows in the theme accent — LIGHT MODE ONLY. A
/// thin material over a flat solid background shows almost no frost,
/// so the wash gives the glass cards something to blur and the frost
/// actually reads. Dark mode keeps the flat Chrome gray, exactly as
/// before.
private struct GlassWashBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            AppBackground.color(for: colorScheme)
            if colorScheme == .light {
                let accent = PadTheme.current.accent
                Rectangle()
                    .fill(RadialGradient(
                        colors: [accent.opacity(0.22), .clear],
                        center: .topLeading, startRadius: 10, endRadius: 340))
                Rectangle()
                    .fill(RadialGradient(
                        colors: [accent.opacity(0.18), .clear],
                        center: .bottomTrailing, startRadius: 10, endRadius: 380))
            }
        }
        .ignoresSafeArea()
    }
}

/// Frosted-glass surface for a card, pill, or round button (v1.0.53):
/// dark mode keeps the translucent primary fill exactly as before;
/// light mode is ultraThinMaterial over the glow wash with a soft
/// gray veil, so the surface reads as gray glass instead of flat
/// white — the TV list box and the remote pills were too much white
/// overall. The veil sits above the material: the blur still shows
/// through, just grayed.
private struct GlassSurface<S: Shape>: View {
    let shape: S
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if colorScheme == .light {
            shape.fill(.ultraThinMaterial)
                .overlay(shape.fill(Color.glassVeil))
        } else {
            shape.fill(Color.primary.opacity(0.10))
        }
    }
}

/// The gray veil over light-mode glass (v1.0.53): shared by the
/// surfaces above and the glass cards below, so every frosted
/// element reads the same gray.
private extension Color {
    static var glassVeil: Color { Color(white: 0.88).opacity(0.5) }
}

struct ContentView: View {
    @StateObject private var discovery = DiscoveryManager()
    @State private var session: RemoteSession?
    /// The launch scan runs once, when the app first opens — not on
    /// every appearance (returning from a remote keeps the list as is).
    @State private var didAutoScan = false
    /// Appearance (v1.0.46): the whole app follows this — dark is
    /// the default, the way the app has always looked.
    @AppStorage("appearance") private var appearanceRaw = "system"

    var body: some View {
        // NavigationView (not NavigationStack): the deployment target is
        // iOS 15, and NavigationStack needs iOS 16.
        NavigationView {
            if let session {
                // The remote draws its own top bar (Devices pill, TV
                // name, power), so the navigation bar stays hidden
                // here — no double header.
                RemoteView(session: session, onBack: { self.session = nil })
                    .navigationBarHidden(true)
            } else {
                DiscoveryListView(discovery: discovery) { device in
                    // Stop the scan first, then navigate: the auto-scan
                    // is still sweeping the subnet when the TV is tapped,
                    // and its steady stream of main-actor merges starves
                    // the navigation transition — that flood is the tap
                    // delay, not the session or the connection. Cancelling
                    // it frees the main thread, so the remote appears at
                    // once; the connection then starts in the remote's
                    // own .task, in the background, and the Connected
                    // pill follows Connecting / Not connected / Connected.
                    // The device list is kept (stop() never clears it),
                    // and pull-to-refresh re-scans on the way back.
                    discovery.stop()
                    session = RemoteSession(device: device)
                }
                // The list draws its own header ("Select a TV Device"),
                // so the navigation bar stays hidden here. The remote
                // screen shows the bar again with its own title.
                .navigationBarHidden(true)
            }
        }
        .preferredColorScheme((AppAppearance(rawValue: appearanceRaw) ?? .system).scheme)
        .task {
            // Scan automatically and silently on launch. There is no
            // scan button — pull-to-refresh re-scans. Discovery itself
            // is unchanged (subnet sweep, scan-only, no manual IP entry).
            guard !didAutoScan else { return }
            didAutoScan = true
            if !discovery.isScanning {
                discovery.scan()
            }
        }
    }
}

// MARK: - Discovery

/// Device picker, modeled on the reference "Select a TV Device" screen:
/// a centered title, one dark card holding the whole TV list, the
/// same-wifi note underneath, and a small spinner as the only scanning
/// indicator. The scan runs automatically and silently on launch (see
/// ContentView); there is no scan button and no scan progress UI — the
/// list simply populates as TVs are found. Pull-to-refresh re-scans.
private struct DiscoveryListView: View {
    @ObservedObject var discovery: DiscoveryManager
    var onSelect: (TVDevice) -> Void

    /// Resolved color scheme (v1.0.48): the page background comes
    /// from it, so System follows the phone.
    @Environment(\.colorScheme) private var colorScheme

    /// Card/button surface (v1.0.53, light-mode glass): the surfaces
    /// are GlassSurface now — frosted material with a gray veil in
    /// light mode, the translucent primary fill in dark mode.
    private var surfaceShadow: Color {
        colorScheme == .light ? .black.opacity(0.07) : .clear
    }
    /// Secondary text (v1.0.52): the system secondary gray is too
    /// pale on the bright light page to read — a darker gray in
    /// light mode, the system secondary in dark mode.
    private var secondaryText: Color {
        colorScheme == .light ? Color.primary.opacity(0.6) : .secondary
    }

    /// True once a scan has finished at least once — drives the empty
    /// state (still scanning vs. nothing found). View-side only; the
    /// discovery code is untouched.
    @State private var hasCompletedScan = false

    /// Pad-controls reminder sheet (v1.0.35), opened from the ?
    /// button in the header.
    @State private var showPadHelp = false
    /// Settings sheet (v1.0.46), opened from the gear at top left.
    @State private var showSettings = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Header: centered title, with a gear at top left
                // (v1.0.46, opens Settings) and a ? at top right
                // (v1.0.35, opens the pad-controls reminder) —
                // symmetric. The X from the reference is gone
                // (Nick's call, v1.0.9): the device list is the
                // app's root, so there is no previous screen for
                // it to return to. The title stays centered — the
                // buttons overlay the header row instead of
                // pushing the title off-center.
                ZStack {
                    Text("Select a TV Device")
                        .font(.headline.bold())
                        .foregroundStyle(.primary)
                    HStack {
                        Button { showSettings = true } label: {
                            Image(systemName: "gearshape")
                                .font(.subheadline.bold())
                                .foregroundStyle(.primary)
                                .frame(width: 30, height: 30)
                                .background { GlassSurface(shape: Circle()) }
                                .shadow(color: surfaceShadow, radius: 6, y: 2)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Settings")
                        Spacer()
                        Button { showPadHelp = true } label: {
                            Image(systemName: "questionmark")
                                .font(.subheadline.bold())
                                .foregroundStyle(.primary)
                                .frame(width: 30, height: 30)
                                .background { GlassSurface(shape: Circle()) }
                                .shadow(color: surfaceShadow, radius: 6, y: 2)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Pad controls")
                    }
                }
                .padding(.horizontal)

                // One dark card holding the whole TV list.
                VStack(spacing: 0) {
                    if discovery.devices.isEmpty {
                        emptyRow
                    } else {
                        ForEach(discovery.devices) { device in
                            deviceRow(device)
                            if device.id != discovery.devices.last?.id {
                                Divider()
                                    .background(Color.primary.opacity(0.08))
                                    .padding(.leading, 76)
                            }
                        }
                    }
                }
                .padding(.vertical, 6)
                .background { GlassSurface(shape: RoundedRectangle(cornerRadius: 20)) }
                .shadow(color: surfaceShadow, radius: 8, y: 2)
                .padding(.horizontal)

                Text("Make sure your phone and TV are connected to the same wifi network.")
                    .font(.footnote)
                    .foregroundStyle(secondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                // The only scanning indicator.
                if discovery.isScanning {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .refreshable { discovery.scan() }
        .onChange(of: discovery.isScanning) { scanning in
            if !scanning { hasCompletedScan = true }
        }
        // Page background (v1.0.48, glass wash in v1.0.53): Chrome
        // dark gray / soft light gray with an accent glow in light
        // mode, not the system black/white extremes.
        .background(GlassWashBackground())
        .sheet(isPresented: $showPadHelp) { PadHelpSheet() }
        .sheet(isPresented: $showSettings) { SettingsSheet() }
    }

    /// The card's single row while no devices are listed: a looking
    /// state while a scan is running (or has never run), and a
    /// "nothing found" state once a scan has finished empty.
    private var emptyRow: some View {
        HStack {
            Spacer()
            if discovery.isScanning || !hasCompletedScan {
                Text("Looking for TVs…")
                    .font(.subheadline)
                    .foregroundStyle(secondaryText)
            } else {
                Text("No TVs found")
                    .font(.subheadline)
                    .foregroundStyle(secondaryText)
            }
            Spacer()
        }
        .padding(.vertical, 16)
    }

    private func deviceRow(_ device: TVDevice) -> some View {
        Button { onSelect(device) } label: {
            HStack(spacing: 12) {
                brandBadge(for: device.brand)
                VStack(alignment: .leading, spacing: 3) {
                    Text(device.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    // A remembered TV the scan didn't find is asleep,
                    // not gone (v1.0.47): tapping it wakes it when the
                    // app knows its MAC, else it just tries to connect.
                    Text(device.isSleeping ? (device.canWake ? "Sleeping — tap to wake" : "Sleeping") : device.addressLine)
                        .font(.caption)
                        .foregroundStyle(secondaryText)
                }
                Spacer()
                if !device.brand.supportsControl {
                    Text("Discovery only")
                        .font(.caption2)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                        .foregroundStyle(secondaryText)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            // The whole row is the tap target. Without this, SwiftUI
            // hit-tests only the label's drawn content — the name text
            // (and the badge) — so taps on the empty space between the
            // text and the row's edge fell through to the ScrollView
            // and did nothing. The rectangle makes the badge, the text,
            // the spacer and the padding all tappable.
            .contentShape(Rectangle())
            // Sleeping rows sit back a little — the TV isn't here
            // right now (v1.0.47).
            .opacity(device.isSleeping ? 0.65 : 1)
        }
        .disabled(!device.brand.supportsControl)
        .buttonStyle(.plain)
    }

    /// Circular brand badge (text-based — no trademarked logo files).
    /// Android TV: light circle, green "androidtv" wordmark. Samsung:
    /// dark navy circle, white "SAMSUNG". Roku/LG: tinted circle with
    /// the brand name. AirPlay/Other: neutral circle with a TV glyph.
    private func brandBadge(for brand: TVDevice.Brand) -> some View {
        ZStack {
            Circle().fill(brandBadgeBackground(for: brand))
            brandBadgeLabel(for: brand)
        }
        .frame(width: 48, height: 48)
    }

    @ViewBuilder
    private func brandBadgeLabel(for brand: TVDevice.Brand) -> some View {
        switch brand {
        case .androidTV:
            Text("androidtv")
                .font(.system(size: 10, weight: .bold))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .foregroundStyle(Color(red: 0.24, green: 0.86, blue: 0.52))
                .padding(.horizontal, 6)
        case .samsung:
            Text("SAMSUNG")
                .font(.system(size: 10, weight: .bold))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
        case .roku:
            Text("Roku")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
        case .lg:
            Text("LG")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
        case .airPlay:
            Image(systemName: "airplayvideo")
                .font(.title3)
                .foregroundStyle(.secondary)
        case .other:
            Image(systemName: "tv")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private func brandBadgeBackground(for brand: TVDevice.Brand) -> Color {
        switch brand {
        case .androidTV: return Color(white: 0.88)
        case .samsung: return Color(red: 0.05, green: 0.09, blue: 0.25)
        case .roku: return .purple
        case .lg: return .red
        case .airPlay: return Color.primary.opacity(0.10)
        case .other: return Color.primary.opacity(0.10)
        }
    }
}

// MARK: - Remote

/// Accent for the redesigned remote (v1.0.12): the Devices pill
/// icon, the keyboard ring, the power-adjacent highlights. One
/// accent, used sparingly — the rest stays dark and neutral. Since
/// v1.0.46 it follows the pad color theme in Settings.
private var remoteAccent: Color { PadTheme.current.accent }

/// Remote, redesigned in v1.0.12. The fork's remote screen is the
/// design inspiration, not a template: a top bar (Devices pill, TV
/// name, power), a Connected pill, then the navigation area, a
/// Back/Home/Exit pill row, and a bottom row (keyboard, Mute), with
/// the diagnostic status text below. Dark with a blue accent. No ads,
/// no promos, no cast button, no tab bar.
/// What stays ours: the mic is hold-to-talk and Android TV only.
/// Dropped to keep the layout clean: the number pad, the channel
/// rocker, the app shortcut cards (v1.0.18), and the playback row
/// (v1.0.18 — left/right swipes already seek). The commands stay
/// in code and the rows can come back if missed.
/// Sizing for the non-scrollable remote screen (v1.0.15: the remote page
/// never scrolls). Every section has a budgeted height, the swipe pad
/// absorbs whatever height is left (down to a floor), and on short
/// screens the bottom row, buttons and spacing shrink too. Nothing is
/// dropped — the only things that hide are the diagnostic line (while the
/// pairing card or keyboard is up, since they show the status themselves)
/// and the LG power note on the shortest screens. Validated against iPhone 15 Plus (845pt), iPhone 13 mini
/// (731pt) and iPhone SE (647pt) usable heights, with pairing card and
/// keyboard — every combination fits.
private struct RemoteLayout {
    var gap: CGFloat
    var topPadding: CGFloat
    var topBarButton: CGFloat
    var pairingCardPadding: CGFloat
    var pairingCardSpacing: CGFloat
    var padSize: CGFloat
    var pillsButtonHeight: CGFloat
    var bottomCell: CGFloat
    var circleSize: CGFloat
    var bottomRowTopPadding: CGFloat
    var diagnosticLines: Int
    var showDiagnostic: Bool
    var showLGNote: Bool

    static func make(height h: CGFloat, pairingShown: Bool,
                     keyboardShown: Bool, isLG: Bool) -> RemoteLayout {
        let compact = h < 760
        let extraCompact = h < 680
        let gap: CGFloat = extraCompact ? 6 : (compact ? 8 : 10)
        let topPadding: CGFloat = extraCompact ? 4 : 8
        let topBarButton: CGFloat = extraCompact ? 40 : 44
        let pairingCardPadding: CGFloat = extraCompact ? 10 : (compact ? 12 : 14)
        let pairingCardSpacing: CGFloat = extraCompact ? 8 : (compact ? 9 : 10)
        let pillsButtonHeight: CGFloat = extraCompact ? 44 : (compact ? 48 : 56)
        // The apps row is gone (v1.0.18), so its height went to the
        // bottom row instead; the rocker is gone in v1.0.23 (the
        // iPhone's physical volume buttons drive the TV volume now),
        // so the bottom row is just two circles (keyboard, Mute).
        // While the pairing card is up the bottom row stays compact
        // — the card is the focus then, and the tall row would
        // overflow short screens.
        let bottomCell: CGFloat = pairingShown ? (extraCompact ? 90 : 110)
            : (extraCompact ? 120 : (compact ? 132 : 144))
        let circleSize = min(112, bottomCell * 0.55)
        // Breathing room above the bottom row (v1.0.20): the rocker
        // crowded the Back/Home/Exit pills, so the row sits clearly
        // lower now. Budgeted in `fixed` below, on top of the gap.
        let bottomRowTopPadding: CGFloat = extraCompact ? 10 : (compact ? 14 : 18)
        let showDiagnostic = !pairingShown && !keyboardShown
        let diagnosticLines = compact ? 2 : 3
        let showLGNote = isLG && !extraCompact

        // Budgeted heights of every section except the pad.
        var fixed: CGFloat = topPadding + topBarButton
        if pairingShown { fixed += extraCompact ? 155 : (compact ? 165 : 170) }
        if keyboardShown { fixed += extraCompact ? 36 : (compact ? 40 : 44) }
        fixed += 38 // connection pill
        if showLGNote { fixed += 16 }
        fixed += pillsButtonHeight // pills row — icons only, no labels
        fixed += bottomCell // bottom row — icons only, no labels
        fixed += bottomRowTopPadding // breathing room above the bottom row (v1.0.20)
        if showDiagnostic { fixed += CGFloat(diagnosticLines) * 17 }
        // Gaps between sections.
        var sections = 6 // topBar, pill, pad, pills, bottom, diagnostic
        if pairingShown { sections += 1 }
        if keyboardShown { sections += 1 }
        if showLGNote { sections += 1 }
        if !showDiagnostic { sections -= 1 }
        let gaps = CGFloat(sections - 1) * gap
        // The pad absorbs the rest, down to a floor (lower while the
        // pairing card or keyboard is up — the pad isn't the focus then).
        // Cap is the swipe pad's design height (440, v1.0.45 — the
        // 560 cap in v1.0.41 was way too tall, 320 too short). On an
        // iPhone 15 Plus the pad lands at ~436 (the available space
        // binds first), so the page fills up with no dead space at
        // the bottom.
        let floor: CGFloat = pairingShown ? 80 : (keyboardShown ? 60 : 100)
        let padSize = min(440, max(floor, h - fixed - gaps))

        return RemoteLayout(gap: gap, topPadding: topPadding, topBarButton: topBarButton,
                            pairingCardPadding: pairingCardPadding, pairingCardSpacing: pairingCardSpacing,
                            padSize: padSize,
                            pillsButtonHeight: pillsButtonHeight,
                            bottomCell: bottomCell, circleSize: circleSize,
                            bottomRowTopPadding: bottomRowTopPadding,
                            diagnosticLines: diagnosticLines, showDiagnostic: showDiagnostic,
                            showLGNote: showLGNote)
    }
}

private struct RemoteView: View {
    @ObservedObject var session: RemoteSession
    var onBack: () -> Void

    @State private var keyboardText = ""
    @State private var showKeyboard = false
    @FocusState private var keyboardFocused: Bool
    @FocusState private var pairingCodeFocused: Bool
    /// Hardware volume buttons drive the TV volume (v1.0.23):
    /// the controller watches the iPhone's outputVolume while this
    /// view is up and turns each press into a .volumeUp /
    /// .volumeDown through the session's coalescing pump (v1.0.28)
    /// — no haptics, the button press itself is the feedback.
    @StateObject private var hardwareVolume = HardwareVolumeController()
    @Environment(\.scenePhase) private var scenePhase
    /// Resolved color scheme (v1.0.48): the page background comes
    /// from it, so System follows the phone.
    @Environment(\.colorScheme) private var colorScheme
    /// Pill/card surface (v1.0.53, light-mode glass): the surfaces
    /// are GlassSurface now — frosted material with a gray veil in
    /// light mode, the translucent primary fill in dark mode.
    private var surfaceShadow: Color {
        colorScheme == .light ? .black.opacity(0.07) : .clear
    }

    var body: some View {
        // No ScrollView on the remote (v1.0.15): everything fits on one
        // page. The layout sizes itself from the available height — the
        // swipe pad absorbs the slack, and on short screens the
        // bottom row, buttons and spacing shrink too. Nothing is dropped.
        // The content lives in remoteContent(layout:) — the body got
        // too big for the compiler to type-check as one expression.
        GeometryReader { geo in
            let layout = RemoteLayout.make(
                height: geo.size.height,
                pairingShown: session.awaitingPairingCode,
                keyboardShown: showKeyboard && session.capabilities.supportsTextInput,
                isLG: session.device.brand == .lg)
            remoteContent(layout: layout)
        }
        // Page background (v1.0.48, glass wash in v1.0.53): Chrome
        // dark gray / soft light gray with an accent glow in light
        // mode, not the system black/white extremes.
        .background(GlassWashBackground())
        // Tap-to-dismiss (v1.0.53): a tap on empty space (or any
        // non-button area) with the keyboard open just closes the
        // keyboard. Buttons and the pad handle it themselves — a
        // Button wins over this tap, and the pad swallows its own
        // touches — so the dismissing tap never also acts.
        .onTapGesture { _ = dismissKeyboardIfOpen() }
        .task { await session.connect() }
        .onChange(of: session.tvTextFieldFocused) { focused in
            // Auto keyboard (v1.0.34): the TV announced a focused
            // text field, so the keyboard shows itself; focus
            // leaving hides it again. On Samsung/Roku this never
            // fires — the button stays the only way in.
            showKeyboard = focused
        }
        .onAppear {
            // Hardware volume buttons → TV volume, scoped strictly
            // to this view: start here, stop on disappear (and on
            // backgrounding, below). Steps go through the session's
            // coalescing pump (v1.0.28), so a hold stops the instant
            // the finger lifts and never blocks other keys.
            hardwareVolume.onStep = { [session] up in
                session.sendVolume(up: up)
            }
            hardwareVolume.start()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                hardwareVolume.stop()
            } else if phase == .active {
                hardwareVolume.start()
            }
        }
        .onDisappear {
            hardwareVolume.stop()
            session.disconnect()
        }
    }

    /// The remote page itself: the VStack of sections, split out
    /// of `body` (v1.0.34) so the compiler type-checks each piece
    /// on its own instead of one giant expression.
    @ViewBuilder
    private func remoteContent(layout: RemoteLayout) -> some View {
        VStack(spacing: layout.gap) {
            topBar(layout)

            pairingCard(layout: layout)

            keyboardInputRow

            connectionPill

            // LG power note — hidden on the shortest screens (it
            // also lives in Settings); the layout budgets for it
            // only when shown.
            if layout.showLGNote {
                Text("Power turns the TV off. Turn it back on with the TV's own remote.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            // Navigation: the swipe pad is the one and only
            // navigation control — no D-pad, no toggle. It sizes
            // from the layout so the page fits without scrolling.
            SwipePadView(height: layout.padSize, onCommand: { send($0, haptic: $1) }, onRepeatCommand: { sendRepeat($0, haptic: $1) }, onCancelRepeats: { session.cancelRepeats() }, isKeyboardOpen: showKeyboard, onDismissKeyboard: { dismissKeyboard() })
                .padding(.horizontal)

            // Back / Home / Exit pill row — icons only, no labels.
            HStack(spacing: 16) {
                pillButton(systemImage: "arrow.left", label: "Back", height: layout.pillsButtonHeight) { send(.back) }
                pillButton(systemImage: "house", label: "Home", height: layout.pillsButtonHeight) { send(.home) }
                pillButton(systemImage: "rectangle.portrait.and.arrow.right", label: "Exit", height: layout.pillsButtonHeight) { send(.exit) }
            }
            .padding(.horizontal)

            bottomRow(layout: layout)

            // Diagnostic status — capped to a few lines so the page
            // fits; the full text lives in Settings. Hidden while
            // the pairing card or keyboard is up (they show the
            // status themselves). When connected (v1.0.32) the pill
            // already says so, so the "Connected to …" line is
            // dropped — only a volume-capture problem still shows
            // down here. A volume-capture problem (audio session
            // failed, slider missing — v1.0.26) appends one line
            // here so a failed field test can say why.
            if layout.showDiagnostic, let diagnosticText {
                Text(diagnosticText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(layout.diagnosticLines)
                    .padding(.horizontal)
            }
        }
        .padding(.top, layout.topPadding)
        .frame(maxWidth: .infinity)
        // The hidden MPVolumeView must sit in the hierarchy to
        // suppress the system volume HUD while the remote is up.
        // Real-sized (200×44, v1.0.26) — MPVolumeView only
        // creates its slider when laid out at a real size, and
        // the view reports when it is in the hierarchy so the
        // anchor can be applied for real. Still near-invisible
        // and touch-disabled, in the background so it takes no
        // layout space and can never swallow pad input.
        .background(
            HiddenVolumeView(volumeView: hardwareVolume.volumeView) {
                hardwareVolume.volumeViewDidAppear()
            }
            .frame(width: 200, height: 44)
            .opacity(0.01)
        )
    }

    /// Pairing code card (Android TV): the TV shows a code.
    /// Restyled in v1.0.21 to match the remote's dark UI — the old
    /// teal card clashed with everything else. A separate view so
    /// the body stays small enough for the compiler to type-check.
    @ViewBuilder
    private func pairingCard(layout: RemoteLayout) -> some View {
        if session.awaitingPairingCode {
            VStack(spacing: layout.pairingCardSpacing) {
                Text("Enter the code shown on your TV")
                    .font(.headline)
                    .foregroundStyle(.primary)
                TextField("Code", text: $session.pairingCode)
                    .font(.system(.title3, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .autocorrectionDisabled(true)
                    .textInputAutocapitalization(.characters)
                    .keyboardType(.asciiCapable)
                    .focused($pairingCodeFocused)
                    // Auto-pair the moment the 6th character
                    // lands (v1.0.22): the code is exactly 6
                    // characters, so there is nothing to wait
                    // for. There is no Pair button anymore
                    // (v1.0.23) — a paste longer than the code
                    // is trimmed to 6 first, so it still
                    // pairs, and a failed attempt clears the
                    // field, so retyping the 6th character
                    // fires a fresh attempt.
                    .onChange(of: session.pairingCode) { code in
                        if code.count > 6 {
                            session.pairingCode = String(code.prefix(6))
                        } else if code.count == 6 {
                            session.submitPairingCode()
                        }
                    }
                    .padding(.vertical, 10)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08), lineWidth: 1))
                // A failed attempt (wrong code, or the TV
                // discarding the code and showing a new one)
                // shows its error here on the card — the
                // diagnostic line is hidden while the card
                // is up, so this is the only place it shows.
                if let pairingError = session.pairingError {
                    Text(pairingError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(layout.pairingCardPadding)
            .background { GlassSurface(shape: RoundedRectangle(cornerRadius: 16)) }
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.08), lineWidth: 1))
            .shadow(color: surfaceShadow, radius: 8, y: 2)
            .padding(.horizontal)
            .onAppear { pairingCodeFocused = true }
        }
    }

    /// Top bar: Devices pill (back to the list), TV name centered,
    /// power on the right. No gear — the Connected pill below already
    /// shows the connection state, so a settings sheet is redundant.
    private func topBar(_ layout: RemoteLayout) -> some View {
        HStack(spacing: 10) {
            Button {
                // Tap-to-dismiss (v1.0.53): with the keyboard open
                // this tap just closes it instead of leaving the
                // remote.
                if dismissKeyboardIfOpen() { return }
                session.disconnect()
                onBack()
            } label: {
                Image(systemName: "tv")
                    .font(.subheadline.bold())
                    .foregroundStyle(remoteAccent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background { GlassSurface(shape: Capsule()) }
                    .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1))
                    .shadow(color: surfaceShadow, radius: 6, y: 2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Devices")
            Spacer()
            Text(session.device.name)
                .font(.headline.bold())
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer()
            // No ? button here (v1.0.44): the pad-controls sheet
            // opens only from the devices page — the remote's top
            // bar is just the TV name and power.
            Button { send(.power) } label: {
                Image(systemName: "power")
                    .font(.headline.bold())
                    .foregroundStyle(.red)
                    .frame(width: layout.topBarButton, height: layout.topBarButton)
                    .background { GlassSurface(shape: Circle()) }
                    .shadow(color: surfaceShadow, radius: 6, y: 2)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
    }

    /// Connected pill: status dot + one-line state. Green when
    /// connected, amber while connecting (or waiting on the TV's
    /// prompt), red when not connected, gray for discovery-only
    /// devices. Replaces the old status banner — the same states,
    /// in one place. While genuinely connecting (v1.0.20) a small
    /// spinner sits next to the amber dot, so the remote shows
    /// something is happening before it can be used.
    private var connectionPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(connectionDotColor)
                .frame(width: 9, height: 9)
            if isConnecting {
                ProgressView()
                    .controlSize(.small)
                    .tint(.primary)
            }
            Text(connectionLabel)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background { GlassSurface(shape: Capsule()) }
        .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 1))
        .shadow(color: surfaceShadow, radius: 6, y: 2)
    }

    private var connectionDotColor: Color {
        if !session.supportsControl { return .gray }
        if session.isConnected { return .green }
        if session.isBusy { return .orange }
        return .red
    }

    private var connectionLabel: String {
        if !session.supportsControl { return "Discovery only" }
        if session.isConnected { return "Connected" }
        if session.isBusy {
            return session.awaitingTVPrompt ? "Check your TV" : "Connecting…"
        }
        return "Not connected"
    }

    /// Footer status text, or nil when there's nothing to say:
    /// connected with no capture problem is already covered by
    /// the pill (v1.0.32 — Nick: the "Connected to …" line at
    /// the bottom just repeated the pill). Unconnected states
    /// keep the full status (it carries the error detail the
    /// pill can't), and a capture problem always shows.
    private var diagnosticText: String? {
        if session.isConnected {
            return hardwareVolume.captureIssue
        }
        return session.status + (hardwareVolume.captureIssue.map { "\n" + $0 } ?? "")
    }

    /// True while the session is actively connecting — busy in any
    /// form, including waiting on the TV's own allow prompt. The
    /// prompt wait is the long part (Samsung/LG sit in it for the
    /// whole handshake), and a static pill there looks frozen, so
    /// a small spinner sits next to the dot while connecting.
    private var isConnecting: Bool {
        session.supportsControl && session.isBusy
    }

    /// The keyboard's own dismiss path (v1.0.53): the × button's
    /// action, extracted so every dismiss goes through the same
    /// three lines — clear the text, hide the row, unfocus (which
    /// is what actually drops the iOS keyboard). Send uses it too,
    /// after reading the text.
    private func dismissKeyboard() {
        keyboardText = ""
        showKeyboard = false
        keyboardFocused = false
    }

    /// The tap-to-dismiss gate (v1.0.53): when the keyboard is open,
    /// a tap anywhere on the remote UI dismisses it instead of
    /// acting — the dismissing tap sends nothing, exactly as if
    /// the × button was tapped. Returns true when it dismissed, so
    /// callers can bail out before doing anything else.
    @discardableResult
    private func dismissKeyboardIfOpen() -> Bool {
        guard showKeyboard else { return false }
        dismissKeyboard()
        return true
    }

    /// `haptic` defaults to true — every tap buzzes once. (The
    /// volume rocker used to pass false for repeat steps of a hold;
    /// the rocker is gone in v1.0.23. The hardware volume buttons
    /// don't use this at all — steps go through session.sendVolume
    /// (the pump). Mute comes from the pad's middle-right
    /// double-tap (v1.0.34), not a button anymore.)
    private func send(_ command: RemoteCommand, haptic: Bool = true) {
        // Tap-to-dismiss (v1.0.53): a tap with the keyboard open
        // just closes the keyboard — no command, no buzz.
        if dismissKeyboardIfOpen() { return }
        if haptic { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        Task { await session.send(command) }
    }

    /// A pad repeat press (v1.0.34): enqueues on the session's
    /// coalescing pump instead of spawning a send Task, so repeats
    /// stop dead on lift. Same buzz rule as send.
    private func sendRepeat(_ command: RemoteCommand, haptic: Bool = true) {
        // Tap-to-dismiss (v1.0.53): same gate as send — a repeat
        // that fires while the keyboard is open just closes it.
        if dismissKeyboardIfOpen() { return }
        if haptic { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        session.sendRepeat(command)
    }

    /// Keyboard / text input, revealed by the keyboard button — or
    /// on its own when the TV announces a focused text field
    /// (v1.0.34 auto keyboard). Send closes it (v1.0.34): the text
    /// is on the TV, so there is nothing left to type. The ×
    /// dismisses without sending — and so does a tap anywhere else
    /// on the remote UI (v1.0.53 tap-to-dismiss): the dismissing
    /// tap sends nothing, exactly as if the × was tapped. A
    /// separate view so the body stays small enough for the
    /// compiler to type-check.
    @ViewBuilder
    private var keyboardInputRow: some View {
        if showKeyboard, session.capabilities.supportsTextInput {
            HStack {
                TextField("Type on the TV…", text: $keyboardText)
                    .textFieldStyle(.roundedBorder)
                    .focused($keyboardFocused)
                    .autocorrectionDisabled(true)
                    .textInputAutocapitalization(.never)
                Button("Send") {
                    let text = keyboardText
                    guard !text.isEmpty else { return }
                    dismissKeyboard()
                    Task { await session.send(.text(text)) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(keyboardText.isEmpty)
                Button {
                    dismissKeyboard()
                } label: {
                    Image(systemName: "xmark")
                        .font(.subheadline.bold())
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close keyboard")
            }
            .padding(.horizontal)
            // Focus on appear so the iOS keyboard pops up at
            // once — no second tap on the text field.
            .onAppear { keyboardFocused = true }
        }
    }

    /// Bottom row (v1.0.34): just the keyboard button, centered.
    /// The row only exists where the button is needed: on TVs that
    /// announce a focused text field (Android TV, LG) the keyboard
    /// pops up on its own and the button hides.
    /// The control sits in a layout-sized cell. Icons only — the
    /// words underneath were removed in v1.0.19. Nothing here is
    /// ever a dead button. A separate view so the body stays small
    /// enough for the compiler to type-check.
    @ViewBuilder
    private func bottomRow(layout: RemoteLayout) -> some View {
        if session.capabilities.supportsTextInput && !session.capabilities.supportsAutoKeyboard {
            HStack(alignment: .top, spacing: 16) {
                Spacer()
                Button { showKeyboard.toggle() } label: {
                    ZStack {
                        Circle()
                            .stroke(showKeyboard ? remoteAccent : Color.primary.opacity(0.08), lineWidth: 2.5)
                        Image(systemName: "keyboard")
                            .font(.title)
                            .foregroundStyle(.primary)
                    }
                    .frame(width: layout.circleSize, height: layout.circleSize)
                    .background { GlassSurface(shape: Circle()) }
                    .shadow(color: surfaceShadow, radius: 8, y: 2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Keyboard")
                .frame(height: layout.bottomCell)
                Spacer()
            }
            .padding(.top, layout.bottomRowTopPadding)
        }
    }

    /// Wide pill button with an icon only (Back / Home / Exit row).
    /// The `label` is VoiceOver-only now — the visible words
    /// underneath were removed in v1.0.19; the icons are
    /// self-explanatory. The button height comes from the layout
    /// so the row shrinks on short screens.
    private func pillButton(systemImage: String, label: String, height: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title2.bold())
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, minHeight: height)
                .background { GlassSurface(shape: RoundedRectangle(cornerRadius: 28)) }
                .overlay(RoundedRectangle(cornerRadius: 28).stroke(Color.primary.opacity(0.08), lineWidth: 1))
                .shadow(color: surfaceShadow, radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

}

// MARK: - Swipe pad

/// Pure gesture decision logic for the swipe pad (v1.0.25) — no
/// timers, no SwiftUI, so unit tests can drive it directly. The view
/// owns the two timers (hold onset, double-tap window) and feeds this
/// type touch events; it returns the commands to send.
///
/// Modes:
/// - Quick tap (lift before the 0.3s onset): exactly one enter, on
///   lift. A second tap within the window is a second enter; held
///   past onset it spams enters instead (double-tap-hold).
/// - Single tap held past onset: the OK key goes DOWN at onset and
///   UP on lift — no enter on lift. A hold-lift is not a tap, so it
///   never opens a double-tap window.
/// - Swipe (≥ slop): a held key is released first, then the first
///   directional press fires at once, with the direction locked in
///   for the touch. Hold past the 0.3s onset and that direction
///   repeats every 0.12s until lift; a quick swipe-and-lift is still
///   exactly one press. A key is never left down.
struct SwipePadGesture {
    enum Output: Equatable {
        case enter(haptic: Bool)
        case enterDown
        case enterUp
        case mute(haptic: Bool)
        case up(haptic: Bool), down(haptic: Bool), left(haptic: Bool), right(haptic: Bool)
    }

    private enum State {
        case idle
        case awaitingSecondTap
        case singleDown
        case singleHeld
        case doubleDown
        case doubleSpam
        case swiping
        /// First tap down inside the mute zone (v1.0.34): no hold
        /// timer, no enter yet — the window decides.
        case muteZoneDown
        /// First tap in the mute zone lifted, waiting to see if a
        /// second zone tap mutes or the window expires (one enter).
        case awaitingSecondTapZone
        /// Second tap down inside the mute zone: lift mutes.
        case muteZoneDoubleDown
    }

    private var state: State = .idle

    /// The direction locked in when the current swipe was
    /// recognized; nil when not swiping.
    private var swipeDirection: Output?
    /// True once a repeat of the held swipe has fired, so only the
    /// first repeat buzzes and later ones stay silent.
    private var swipeRepeatFired = false

    /// True while a key-down has been sent and not yet released.
    var isKeyHeldDown: Bool { state == .singleHeld }
    /// True while double-tap-hold spam is active.
    var isSpamming: Bool { state == .doubleSpam }
    /// True after a quick tap lifted, while a second tap still
    /// counts as a double-tap.
    var isAwaitingSecondTap: Bool { state == .awaitingSecondTap }
    /// True after a quick tap in the mute zone lifted, while a
    /// second tap in the zone still counts as a mute.
    var isAwaitingSecondTapZone: Bool { state == .awaitingSecondTapZone }
    /// True while a swipe is being held down (repeats active).
    var isSwiping: Bool { state == .swiping }

    /// Finger down. Returns true when the view should start the hold
    /// onset timer (a fresh single or double tap); false when this
    /// touch is already a swipe that wandered back inside the slop.
    mutating func touchDown() -> Bool {
        touchDown(inMuteZone: false).startHold
    }

    /// Finger down, with the mute-zone flag (v1.0.34). Returns the
    /// outputs to emit now and whether the view should start the
    /// hold onset timer. A tap inside the mute zone never starts
    /// the hold timer — a hold in the zone is not a key hold — and
    /// its enter is held back until the double-tap window decides:
    /// a second zone tap mutes, the window expiring leaves one
    /// enter, and a second tap outside the zone turns the held-back
    /// enter into half of a normal double-tap. Muting needs both
    /// taps in the zone: a zone tap after a middle tap is just the
    /// second tap of a normal double-tap.
    mutating func touchDown(inMuteZone: Bool) -> (outputs: [Output], startHold: Bool) {
        if inMuteZone {
            switch state {
            case .idle:
                state = .muteZoneDown
                return ([], false)
            case .awaitingSecondTapZone:
                state = .muteZoneDoubleDown
                return ([], false)
            case .awaitingSecondTap:
                state = .doubleDown
                return ([], true)
            default:
                return ([], false)
            }
        }
        switch state {
        case .idle:
            state = .singleDown
            return ([], true)
        case .awaitingSecondTap:
            state = .doubleDown
            return ([], true)
        case .awaitingSecondTapZone:
            state = .singleDown
            return ([.enter(haptic: true)], true)
        default:
            return ([], false)
        }
    }

    /// The 0.3s hold onset fired: a single tap engages the hold
    /// (key down), a double-tap starts spamming enters, and a held
    /// swipe fires its first directional repeat.
    mutating func onsetTimerFired() -> [Output] {
        switch state {
        case .singleDown:
            state = .singleHeld
            return [.enterDown]
        case .doubleDown:
            state = .doubleSpam
            return [.enter(haptic: true)]
        case .swiping:
            // First repeat of a held swipe — buzzes once, like the
            // first repeat of a double-tap-hold.
            return nextSwipeRepeat()
        default:
            return []
        }
    }

    /// One spam interval (0.12s) while double-tap-hold is active.
    /// Later repeats are silent; the first repeat (from
    /// onsetTimerFired) buzzed once.
    mutating func spamTick() -> [Output] {
        state == .doubleSpam ? [.enter(haptic: false)] : []
    }

    /// One repeat interval (0.12s) while a swipe is held down.
    /// The first repeat buzzes once; later repeats are silent.
    mutating func swipeTick() -> [Output] {
        state == .swiping ? nextSwipeRepeat() : []
    }

    /// The next repeat of the held swipe: the first one buzzes,
    /// later ones are silent.
    private mutating func nextSwipeRepeat() -> [Output] {
        guard let direction = swipeDirection else { return [] }
        if swipeRepeatFired { return [silent(direction)] }
        swipeRepeatFired = true
        return [direction]
    }

    /// The same direction with its haptic silenced.
    private func silent(_ output: Output) -> Output {
        switch output {
        case .up(_): return .up(haptic: false)
        case .down(_): return .down(haptic: false)
        case .left(_): return .left(haptic: false)
        case .right(_): return .right(haptic: false)
        default: return output
        }
    }

    /// Finger moved. Beyond the slop the gesture becomes a swipe: a
    /// held key is released first, then the first directional press
    /// fires at once and the direction locks in for the touch —
    /// further movement never changes it. Holding past the onset
    /// repeats that direction (see onsetTimerFired / swipeTick).
    mutating func moved(translation: CGSize, slop: CGFloat) -> [Output] {
        guard abs(translation.width) >= slop || abs(translation.height) >= slop else { return [] }
        switch state {
        case .singleHeld:
            state = .swiping
            let direction = direction(of: translation)
            swipeDirection = direction
            return [.enterUp, direction]
        case .singleDown, .doubleDown, .doubleSpam, .muteZoneDown, .muteZoneDoubleDown:
            // A swipe starting in the mute zone is still a swipe:
            // the zone only changes what a tap does, and no key
            // was held down, so there is nothing to release first.
            state = .swiping
            let direction = direction(of: translation)
            swipeDirection = direction
            return [direction]
        case .swiping:
            return []
        default:
            return []
        }
    }

    /// Finger lifted. A swipe whose press never fired (a flick too
    /// fast for moved() to see) sends its direction; a swipe already
    /// recognized sends nothing more — its press fired in moved()
    /// and its repeats stop. A quick tap sends one enter (and opens
    /// the double-tap window for a first tap only); a hold releases
    /// the key with no enter on lift; spam just stops.
    mutating func touchUp(translation: CGSize, slop: CGFloat) -> [Output] {
        let isSwipe = abs(translation.width) >= slop || abs(translation.height) >= slop
        switch state {
        case .singleDown:
            if isSwipe {
                state = .idle
                return [direction(of: translation)]
            }
            state = .awaitingSecondTap
            return [.enter(haptic: true)]
        case .singleHeld:
            state = .idle
            return isSwipe ? [.enterUp, direction(of: translation)] : [.enterUp]
        case .doubleDown:
            if isSwipe {
                state = .idle
                return [direction(of: translation)]
            }
            state = .idle
            return [.enter(haptic: true)]
        case .doubleSpam:
            state = .idle
            return isSwipe ? [direction(of: translation)] : []
        case .muteZoneDown:
            // First tap in the zone lifted: hold its enter until
            // the window decides — a second zone tap mutes, the
            // window expiring leaves one enter.
            state = .awaitingSecondTapZone
            return []
        case .muteZoneDoubleDown:
            if isSwipe {
                state = .idle
                return [direction(of: translation)]
            }
            state = .idle
            return [.mute(haptic: true)]
        case .swiping:
            state = .idle
            swipeDirection = nil
            swipeRepeatFired = false
            return []
        case .awaitingSecondTap, .awaitingSecondTapZone, .idle:
            return []
        }
    }

    /// The double-tap window expired with no second tap. Returns
    /// the outputs to emit: a zone-first tap's held-back enter
    /// stands alone; a normal first tap already sent its enter.
    /// The next tap is a fresh single either way.
    mutating func secondTapWindowExpired() -> [Output] {
        switch state {
        case .awaitingSecondTapZone:
            state = .idle
            return [.enter(haptic: true)]
        case .awaitingSecondTap:
            state = .idle
            return []
        default:
            return []
        }
    }

    mutating func reset() {
        state = .idle
        swipeDirection = nil
        swipeRepeatFired = false
    }

    private func direction(of translation: CGSize, haptic: Bool = true) -> Output {
        if abs(translation.width) > abs(translation.height) {
            return translation.width > 0 ? .right(haptic: haptic) : .left(haptic: haptic)
        }
        return translation.height > 0 ? .down(haptic: haptic) : .up(haptic: haptic)
    }
}

/// Pad controls reminder: each gesture is its own card — a colored
/// icon tile, the gesture name, what it does — matching the mockup
/// Nick sent. No picture of the remote (v1.0.39).
/// Pad controls help, glassmorphic (v1.0.50): Nick's screenshot —
/// frosted glass cards on the page background, floating pill
/// header, same six gesture cards.
private struct PadHelpSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            GlassHeaderPill(title: "Pad controls") { dismiss() }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            ScrollView {
                VStack(spacing: 12) {
                    helpCard(icon: "touchid", tint: .blue, title: "Tap", subtitle: "Select / OK")
                    helpCard(icon: "hand.raised.fill", tint: .yellow, title: "Tap + hold", subtitle: "Hold OK down")
                    helpCard(icon: "repeat", tint: .green, title: "Double-tap + hold", subtitle: "Repeat OK")
                    helpCard(icon: "arrow.up.and.down.and.arrow.left.and.right", tint: .cyan, title: "Swipe", subtitle: "Move that way")
                    helpCard(icon: "forward.fill", tint: .indigo, title: "Swipe + hold", subtitle: "Keep moving")
                    helpCard(icon: "speaker.slash.fill", tint: .red, title: "Double-tap right side", subtitle: "Mute audio")
                }
                .padding(16)
                .padding(.bottom, 24)
            }
        }
        // Same background as the home screen (v1.0.48): the
        // sheet was showing the system black/white while the
        // home screen uses the Chrome gray / soft gray.
        .background(GlassWashBackground())
    }

    /// One gesture card: colored icon tile, name + what it does.
    /// No chevron (v1.0.42): the rows aren't tappable, and the
    /// arrow made them look clickable.
    private func helpCard(icon: String, tint: Color, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 52, height: 52)
                .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(GlassCardBackground())
    }
}

/// Settings (v1.0.46): a customization menu opened from the gear
/// on the devices page — pad color, pad border effect, trail
/// style, and light/dark mode. Everything persists in UserDefaults
/// and applies at once; the pad keeps its own theme gradient in
/// both appearances.
/// Frosted-glass card fill (v1.0.50): ultraThinMaterial in a big
/// rounded rect, hairline stroke, soft shadow. The material
/// adapts to light and dark on its own, so the same card reads
/// as glass on both appearances.
private struct GlassCardBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: 28)
            .fill(.ultraThinMaterial)
            .overlay(
                // Light mode only (v1.0.53): the same gray veil as
                // the glass surfaces, so the card reads gray glass
                // instead of flat white. Dark mode keeps the bare
                // material exactly as before.
                Group {
                    if colorScheme == .light {
                        RoundedRectangle(cornerRadius: 28)
                            .fill(Color.glassVeil)
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 28)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
    }
}

/// Floating glass header pill for the sheets (v1.0.50): title
/// centered, Done on the right, like Nick's screenshot.
private struct GlassHeaderPill: View {
    let title: String
    var onDone: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(
                    // Light mode only (v1.0.53): the gray veil, as
                    // on the cards — the pill read as flat white.
                    Group {
                        if colorScheme == .light {
                            Capsule().fill(Color.glassVeil)
                        }
                    }
                )
                .overlay(
                    Capsule()
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                )
            Text(title)
                .font(.headline)
            HStack {
                Spacer()
                Button("Done", action: onDone)
            }
            .padding(.horizontal, 20)
        }
        .frame(height: 52)
    }
}

/// A glass section (v1.0.50): title on its own — no icon next to
/// it, Nick's call — then a frosted card holding the controls.
private struct GlassSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(16)
            .background(GlassCardBackground())
        }
    }
}

/// A segmented control that looks like the one in Nick's
/// screenshot (v1.0.50): dark track, the selected segment a solid
/// blue pill. The stock .segmented picker reads as a plain form
/// control next to the glass cards.
private struct GlassSegmentedControl: View {
    let options: [(value: String, name: String)]
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                Button {
                    withAnimation(.snappy) { selection = option.value }
                } label: {
                    Text(option.name)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(selection == option.value ? Color.blue : Color.clear)
                        )
                        .foregroundStyle(selection == option.value ? .white : .primary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.primary.opacity(0.08))
        )
    }
}

/// Settings, glassmorphic (v1.0.50): Nick's screenshot — frosted
/// glass cards on the page background, floating pill header,
/// title-only section headers. Also adds the pad cover picker.
private struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("padTheme") private var padThemeRaw = "midnight"
    @AppStorage("padBorder") private var padBorderRaw = "off"
    @AppStorage("trailStyle") private var trailStyleRaw = "glow"
    @AppStorage("appearance") private var appearanceRaw = "system"
    @AppStorage("padCoverVersion") private var coverVersion = 0
    /// One sheet for the whole cover flow (v1.0.51): picker and
    /// cropper are one sheet whose content swaps, so picking a
    /// photo opens the cropper at once — the old two-sheet dance
    /// (dismiss picker, wait 0.5s, present cropper) dropped the
    /// cropper whenever the dismiss ran long, so the photo looked
    /// unselected.
    private enum CoverSheet: Identifiable {
        case picker
        case cropper(UIImage)
        var id: String {
            switch self {
            case .picker: return "picker"
            case .cropper: return "cropper"
            }
        }
    }
    @State private var coverSheet: CoverSheet?
    @State private var showRemoveCoverAlert = false

    var body: some View {
        VStack(spacing: 0) {
            GlassHeaderPill(title: "Settings") { dismiss() }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            ScrollView {
                VStack(spacing: 24) {
                    GlassSection("PAD COLOR") {
                        HStack(spacing: 16) {
                            ForEach(PadTheme.allCases, id: \.self) { theme in
                                Button { padThemeRaw = theme.rawValue } label: {
                                    ZStack {
                                        Circle()
                                            .fill(LinearGradient(colors: [theme.top, theme.bottom], startPoint: .top, endPoint: .bottom))
                                            .frame(width: 40, height: 40)
                                        if padThemeRaw == theme.rawValue {
                                            Image(systemName: "checkmark")
                                                .font(.subheadline.bold())
                                                .foregroundStyle(.white)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(theme.name)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        Divider()
                        Text((PadTheme(rawValue: padThemeRaw) ?? .midnight).name)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    GlassSection("PAD BORDER") {
                        GlassSegmentedControl(options: PadBorder.allCases.map { ($0.rawValue, $0.name) }, selection: $padBorderRaw)
                        Text("Flow runs a light around the pad, like an LED keyboard.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    GlassSection("TRAIL") {
                        GlassSegmentedControl(options: TrailStyle.allCases.map { ($0.rawValue, $0.name) }, selection: $trailStyleRaw)
                        Text("How the swipe trail looks on the pad.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    GlassSection("APPEARANCE") {
                        GlassSegmentedControl(options: AppAppearance.allCases.map { ($0.rawValue, $0.name) }, selection: $appearanceRaw)
                    }
                    GlassSection("PAD COVER") {
                        if let cover = PadCoverStore.image(for: coverVersion) {
                            Image(uiImage: cover)
                                .resizable()
                                .scaledToFill()
                                .frame(height: 120)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                            // Text buttons only hit-test their words
                            // (v1.0.52, fixed in v1.0.53): the padding
                            // + contentShape have to live on the LABEL,
                            // like the Choose row — on the Button itself
                            // they don't extend the hit area, so only
                            // the words were tappable. With them on the
                            // label, each button's full padded frame
                            // is its tap target.
                            HStack(spacing: 16) {
                                Button { coverSheet = .picker } label: {
                                    Text("Change photo")
                                        .padding(.vertical, 8)
                                        .contentShape(Rectangle())
                                }
                                Button {
                                    coverSheet = .cropper(PadCoverStore.loadOriginal() ?? cover)
                                } label: {
                                    Text("Adjust crop")
                                        .padding(.vertical, 8)
                                        .contentShape(Rectangle())
                                }
                                Spacer()
                                Button(role: .destructive) { showRemoveCoverAlert = true } label: {
                                    Text("Remove")
                                        .padding(.vertical, 8)
                                        .contentShape(Rectangle())
                                }
                            }
                            .font(.subheadline)
                        } else {
                            Button { coverSheet = .picker } label: {
                                HStack {
                                    Image(systemName: "photo")
                                    Text("Choose a photo")
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundStyle(.secondary)
                                }
                                // The whole row is the tap target
                                // (v1.0.51, fixed in v1.0.53): the
                                // contentShape has to live on the
                                // LABEL, like the device rows — on
                                // the Button itself it doesn't extend
                                // the hit area, so only the words
                                // were tappable. The maxWidth makes
                                // the row span the card, so the
                                // spacer's empty stretch is tappable
                                // too.
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Text("Crop it to the pad and use it as the pad's cover art.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(16)
                .padding(.bottom, 24)
            }
        }
        .background(GlassWashBackground())
        // Live appearance (v1.0.48): a sheet's color scheme is
        // frozen at presentation — the root view's
        // preferredColorScheme flips the app behind it, but the
        // sheet itself stays in the old appearance until it's
        // closed and reopened. Applying the setting here too, from
        // the sheet's own @AppStorage, flips it the moment the
        // picker changes.
        .preferredColorScheme((AppAppearance(rawValue: appearanceRaw) ?? .system).scheme)
        .sheet(item: $coverSheet) { sheet in
            switch sheet {
            case .picker:
                PadCoverPicker(
                    onPick: { image in coverSheet = .cropper(image) },
                    onCancel: { coverSheet = nil }
                )
            case .cropper(let image):
                PadCoverCropView(
                    image: image,
                    onSaved: {
                        // The cropper already saved (v1.0.53): bump
                        // the version so the pad re-reads the cover,
                        // then dismiss.
                        coverVersion += 1
                        coverSheet = nil
                    },
                    onCancel: { coverSheet = nil }
                )
            }
        }
        .alert("Remove pad cover?", isPresented: $showRemoveCoverAlert) {
            Button("Remove cover", role: .destructive) {
                PadCoverStore.remove()
                coverVersion += 1
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The pad goes back to its color theme.")
        }
    }
}

/// Pad cover art (v1.0.50): a user-picked photo, cropped to the
/// pad's shape in Settings, saved as JPEGs in Documents. The pad
/// reads it through a version counter in @AppStorage so it
/// re-renders when the cover changes.
private enum PadCoverStore {
    private static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    static var coverURL: URL { documents.appendingPathComponent("pad-cover.jpg") }
    static var originalURL: URL { documents.appendingPathComponent("pad-cover-original.jpg") }

    private static var cachedImage: UIImage?
    private static var cachedVersion = -1

    static func image(for version: Int) -> UIImage? {
        if cachedVersion != version {
            cachedImage = UIImage(contentsOfFile: coverURL.path)
            cachedVersion = version
        }
        return cachedImage
    }

    static func loadOriginal() -> UIImage? {
        UIImage(contentsOfFile: originalURL.path)
    }

    /// Returns false when the JPEG can't be encoded or the write
    /// fails (v1.0.53): the caller surfaces that instead of
    /// silently doing nothing.
    @discardableResult
    static func saveCover(_ image: UIImage) -> Bool {
        guard let data = image.jpegData(compressionQuality: 0.9) else { return false }
        do {
            try data.write(to: coverURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    static func saveOriginal(_ image: UIImage) -> Bool {
        guard let data = image.jpegData(compressionQuality: 0.92) else { return false }
        do {
            try data.write(to: originalURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    static func remove() {
        try? FileManager.default.removeItem(at: coverURL)
        try? FileManager.default.removeItem(at: originalURL)
        cachedImage = nil
    }

    /// The pad's measured aspect (width / height), saved by the
    /// pad itself so the cropper frames the photo to the real
    /// pad shape. 0.91 is the iPhone 15 Plus fallback.
    static var padAspect: CGFloat {
        let w = UserDefaults.standard.double(forKey: "padMeasuredWidth")
        let h = UserDefaults.standard.double(forKey: "padMeasuredHeight")
        guard w > 0, h > 0 else { return 0.91 }
        return w / h
    }
}

/// The system photo picker (v1.0.50): UIImagePickerController
/// works back to iOS 15, where PhotosPicker doesn't exist.
/// Needs NSPhotoLibraryUsageDescription in Info.plist.
private struct PadCoverPicker: UIViewControllerRepresentable {
    var onPick: (UIImage) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        var onPick: (UIImage) -> Void
        var onCancel: () -> Void

        init(onPick: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            // Defer out of the UIKit callback (v1.0.53): swapping
            // the sheet's content synchronously inside the delegate
            // call raced the picker's dismissal and left the
            // cropper's buttons dead until the transition settled.
            // One run loop later the picker is gone and the swap
            // lands cleanly.
            if let image = info[.originalImage] as? UIImage {
                DispatchQueue.main.async { self.onPick(image) }
            } else {
                DispatchQueue.main.async { self.onCancel() }
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            DispatchQueue.main.async { self.onCancel() }
        }
    }
}

/// Crop a photo to the pad's shape (v1.0.50): drag to move, pinch
/// to zoom, double-tap to reset. The frame is the pad — same
/// aspect, same rounded corners — so what you see is what the pad
/// shows.
private struct PadCoverCropView: View {
    let image: UIImage
    /// Called after the crop + save succeed (v1.0.53): the caller
    /// bumps the version so the pad re-reads the cover, then
    /// dismisses. The cropper owns the save, so the caller never
    /// sees a half-saved cover.
    var onSaved: () -> Void
    var onCancel: () -> Void

    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastScale: CGFloat = 1
    @State private var lastOffset: CGSize = .zero
    /// Saving state (v1.0.53): while the crop + save runs, both
    /// buttons are disabled so a cancel can't race the save — and
    /// the button reads "Saving…" so the tap visibly lands.
    @State private var isSaving = false
    /// Set when a save fails (v1.0.53): surfaces an alert instead
    /// of silently doing nothing.
    @State private var saveFailed = false

    private var frameSize: CGSize {
        let w = min(UIScreen.main.bounds.width - 32, 520)
        return CGSize(width: w, height: w / PadCoverStore.padAspect)
    }
    private var fitScale: CGFloat {
        max(frameSize.width / image.size.width, frameSize.height / image.size.height)
    }
    private var totalScale: CGFloat { fitScale * scale }

    private func clampedOffset(_ o: CGSize) -> CGSize {
        let sw = image.size.width * totalScale
        let sh = image.size.height * totalScale
        let mx = max(0, (sw - frameSize.width) / 2)
        let my = max(0, (sh - frameSize.height) / 2)
        return CGSize(width: min(max(o.width, -mx), mx),
                      height: min(max(o.height, -my), my))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { onCancel() } label: {
                    Text("Cancel")
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
                .disabled(isSaving)
                Spacer()
                Text("Crop pad cover")
                    .font(.headline)
                Spacer()
                Button { confirmCover() } label: {
                    Text(isSaving ? "Saving…" : "Set cover")
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
                .font(.headline)
                .disabled(isSaving)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Spacer()
            ZStack {
                Image(uiImage: image)
                    .resizable()
                    .frame(width: image.size.width * totalScale,
                           height: image.size.height * totalScale)
                    .offset(offset)
            }
            .frame(width: frameSize.width, height: frameSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .stroke(Color.white.opacity(0.7), lineWidth: 2)
            )
            .gesture(
                SimultaneousGesture(
                    DragGesture()
                        .onChanged { value in
                            offset = clampedOffset(CGSize(
                                width: lastOffset.width + value.translation.width,
                                height: lastOffset.height + value.translation.height))
                        }
                        .onEnded { _ in lastOffset = offset },
                    MagnificationGesture()
                        .onChanged { value in
                            scale = min(4, max(1, lastScale * value))
                            offset = clampedOffset(offset)
                        }
                        .onEnded { _ in lastScale = scale }
                )
            )
            .onTapGesture(count: 2) {
                scale = 1
                lastScale = 1
                offset = .zero
                lastOffset = .zero
            }
            Spacer()
            Text("Drag to move · Pinch to zoom · Double-tap to reset")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.bottom, 24)
        }
        .background(Color.black.ignoresSafeArea())
        .alert("Couldn't save the cover", isPresented: $saveFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("The photo couldn't be saved. Check storage and try again.")
        }
    }

    /// Confirm (v1.0.53): one ordered flow — crop + save the image,
    /// then bump the version so the pad re-reads it (onSaved), then
    /// dismiss. The crop + JPEG encodes run off the main thread:
    /// on the main thread they blocked the UI for up to a second,
    /// so the first tap on "Set cover" looked dead and only
    /// repeated taps worked. A failed save surfaces the alert
    /// above instead of silently doing nothing — the sheet stays
    /// up so he can try again.
    private func confirmCover() {
        guard !isSaving else { return }
        isSaving = true
        let image = image
        let scale = scale
        let offset = offset
        let frameSize = frameSize
        Task {
            let (originalOK, coverOK) = await Task.detached(priority: .userInitiated) {
                let cropped = Self.crop(image: image, scale: scale, offset: offset, frameSize: frameSize)
                return (PadCoverStore.saveOriginal(image), PadCoverStore.saveCover(cropped))
            }.value
            isSaving = false
            if originalOK && coverOK {
                onSaved()
            } else {
                saveFailed = true
            }
        }
    }

    /// The visible rect, in the photo's own points: invert the
    /// display transform (fit scale × user zoom, plus offset).
    private func croppedImage() -> UIImage {
        Self.crop(image: image, scale: scale, offset: offset, frameSize: frameSize)
    }

    /// Pure crop (v1.0.53): the crop math as a static function of
    /// its inputs, so the confirm path can run it off the main
    /// thread. The render uses UIGraphicsImageRenderer + Core
    /// Graphics, both safe off the main thread for offscreen work.
    private static func crop(image: UIImage, scale: CGFloat, offset: CGSize, frameSize: CGSize) -> UIImage {
        let normalized = image.normalizedOrientation()
        let fitScale = max(frameSize.width / image.size.width, frameSize.height / image.size.height)
        let ts = fitScale * scale
        let vw = frameSize.width / ts
        let vh = frameSize.height / ts
        let cx = normalized.size.width / 2 - offset.width / ts
        let cy = normalized.size.height / 2 - offset.height / ts
        var rect = CGRect(x: cx - vw / 2, y: cy - vh / 2, width: vw, height: vh)
        rect.origin.x = min(max(rect.origin.x, 0), max(0, normalized.size.width - rect.width))
        rect.origin.y = min(max(rect.origin.y, 0), max(0, normalized.size.height - rect.height))
        rect.size.width = min(rect.width, normalized.size.width)
        rect.size.height = min(rect.height, normalized.size.height)
        let s = normalized.scale
        let pixelRect = CGRect(x: rect.origin.x * s, y: rect.origin.y * s,
                               width: rect.width * s, height: rect.height * s)
        guard let cg = normalized.cgImage?.cropping(to: pixelRect) else { return normalized }
        let cropped = UIImage(cgImage: cg, scale: s, orientation: .up)
        let targetW: CGFloat = 1200
        guard cropped.size.width > targetW else { return cropped }
        let k = targetW / cropped.size.width
        let size = CGSize(width: cropped.size.width * k, height: cropped.size.height * k)
        return UIGraphicsImageRenderer(size: size).image { _ in
            cropped.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

private extension UIImage {
    /// Redraw with the orientation baked in, so pixel math
    /// (cropping) and point math (display) agree.
    func normalizedOrientation() -> UIImage {
        guard imageOrientation != .up else { return self }
        return UIGraphicsImageRenderer(size: size).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

/// Big swipe pad (the Swipe half of the toggle): near full-width,
/// a bare pad — no chevrons, no hand icon, no label.
/// One drag is one command on release (tap = select) — the same
/// gesture as the old touchpad, only the size and the look changed.
/// Modes (decided by the pure SwipePadGesture above):
/// - Quick tap: exactly one OK press on lift; quick double-tap two.
/// - Single tap held past the 0.3s onset: the OK key goes DOWN at
///   onset and UP on lift — no enter on lift (v1.0.25).
/// - Double-tap held past onset: spams OK presses (first repeat at
///   onset, then one every 0.12s) until lift (v1.0.25).
/// - Swipe: the first directional press fires at once, and held past
///   onset it repeats that same direction every 0.12s until lift;
///   a quick swipe-and-lift is still exactly one press (v1.0.27).
///   Swiping out of a hold releases the key first, so a key is never
///   left stuck down.
/// - Mute zone (v1.0.34): a double-tap on the middle-right of the pad
///   mutes/unmutes; the middle keeps its taps and holds exactly as
///   before — the zone never starts a hold, and a swipe starting in
///   it is still a swipe.
/// The height comes from the layout so the pad fits the
/// non-scrollable page on small phones.
/// One finger position on the trail (v1.0.44): where the finger
/// was, and when — the trail drops points older than 0.8s.
private struct TrailPoint {
    var point: CGPoint
    var time: Date
}

/// The finger trail (v1.0.44, styles in v1.0.46), drawn in the
/// pad's own coordinates. Each touch is its own stroke (v1.0.47):
/// lifting and touching elsewhere starts a new streak instead of
/// drawing a connector line across the pad. Glow is a soft wide
/// line with a faint core, plus a soft dot under the finger. Dots
/// is a row of circles that shrink and fade with age. Off draws
/// nothing. Fades as a whole after lift (see trailOpacity).
/// Everything is very faint — just enough to know the touch registered.
private struct PadTrailOverlay: View {
    var strokes: [[TrailPoint]]
    var opacity: Double
    var style: TrailStyle
    /// Trail color (v1.0.51): white on the dark pad, the theme
    /// accent on the light pad — a white trail is invisible on a
    /// light surface.
    var color: Color = .white

    var body: some View {
        ZStack {
            switch style {
            case .off:
                EmptyView()
            case .glow:
                ForEach(strokes.indices, id: \.self) { i in
                    if strokes[i].count > 1 {
                        trailPath(strokes[i])
                            .stroke(color.opacity(0.07), style: StrokeStyle(lineWidth: 12, lineCap: .round, lineJoin: .round))
                        trailPath(strokes[i])
                            .stroke(color.opacity(0.16), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    }
                }
                if let last = strokes.last?.last {
                    Circle()
                        .fill(color.opacity(0.3))
                        .frame(width: 12, height: 12)
                        .shadow(color: color.opacity(0.25), radius: 8)
                        .position(last.point)
                }
            case .dots:
                ForEach(strokes.indices, id: \.self) { i in
                    ForEach(strokes[i].indices, id: \.self) { j in
                        let point = strokes[i][j]
                        let age = Date().timeIntervalSince(point.time)
                        Circle()
                            .fill(color.opacity(max(0, 0.35 - age)))
                            .frame(width: dotSize(age), height: dotSize(age))
                            .position(point.point)
                    }
                }
            }
        }
        .opacity(opacity)
        .allowsHitTesting(false)
    }

    /// The path through one stroke's points.
    private func trailPath(_ stroke: [TrailPoint]) -> Path {
        var path = Path()
        if let first = stroke.first {
            path.move(to: first.point)
            for point in stroke.dropFirst() { path.addLine(to: point.point) }
        }
        return path
    }

    /// A dot's size by age: 12pt fresh, shrinking to 3pt.
    private func dotSize(_ age: TimeInterval) -> CGFloat {
        max(3, 12 - age * 10)
    }
}

private struct SwipePadView: View {
    var height: CGFloat
    /// Second parameter: whether the command should buzz. A tap
    /// buzzes once, the hold onset buzzes once, and the first spam
    /// repeat of a double-tap-hold buzzes once; later repeats of a
    /// hold are silent — the same rule as the volume hold (v1.0.20),
    /// because buzzing at repeat rate is faster than the TV moves.
    /// A key release never buzzes.
    var onCommand: (RemoteCommand, Bool) -> Void
    /// Repeat presses (double-tap-hold spam, swipe-and-hold ticks)
    /// go through the session's coalescing pump (v1.0.34), not the
    /// direct send: the pump keeps one pending press and drops it
    /// on lift, so repeats stop dead the instant the finger lifts
    /// instead of draining a backlog. Discrete presses never use
    /// this path.
    var onRepeatCommand: (RemoteCommand, Bool) -> Void
    /// Called on finger lift (and when the pad goes away): drops
    /// the pump's pending repeat press, if any.
    var onCancelRepeats: () -> Void
    /// True while the iOS keyboard is up (v1.0.53): a touch that
    /// lands then is a keyboard dismiss, not a command — the pad
    /// swallows the whole touch and reports it through
    /// onDismissKeyboard instead.
    var isKeyboardOpen: Bool
    /// The keyboard-dismiss path (v1.0.53): the same dismiss the
    /// keyboard's own × button runs — clear the text, hide the row,
    /// unfocus. The pad calls this for a touch that landed while
    /// the keyboard was open; the touch itself sends nothing.
    var onDismissKeyboard: () -> Void
    /// A touch that landed while the keyboard was open (v1.0.53):
    /// the whole touch stays consumed as a dismiss even if the
    /// finger is still down when the keyboard finishes closing and
    /// isKeyboardOpen flips back to false mid-touch — otherwise the
    /// hold onset would fire a key press from the dismissing tap.
    @State private var dismissedTouch = false

    @State private var gesture = SwipePadGesture()
    @State private var holdTask: Task<Void, Never>?
    @State private var windowTask: Task<Void, Never>?
    /// The pad's rendered size, for the mute zone (v1.0.34): the
    /// zone is a fraction of the pad, so taps are located against
    /// this, not against fixed points.
    @State private var padSize: CGSize = .zero

    /// Records the pad's measured size (v1.0.52): read straight off
    /// the geometry in the background, no PreferenceKey in between.
    /// The key never delivered — the size stayed .zero, so the tilt
    /// never tilted and the mute zone never matched a tap. The size
    /// is also remembered for the cover cropper (v1.0.50).
    private func setPadSize(_ size: CGSize) {
        // Only write on change: onAppear fires on every appear and
        // the geometry fires on every layout pass, so an unconditional
        // write churned UserDefaults (and re-rendered the pad) for
        // the same size.
        guard size != padSize else { return }
        padSize = size
        UserDefaults.standard.set(size.width, forKey: "padMeasuredWidth")
        UserDefaults.standard.set(size.height, forKey: "padMeasuredHeight")
    }
    /// Press feedback (v1.0.34, retuned in v1.0.47 and v1.0.51,
    /// simplified in v1.0.52 — the tilt does the talking now: 8°
    /// toward the finger (v1.0.53: back from 14° — his field test
    /// found 14° over-rotated), scale barely 0.995 — so a tap reads
    /// as a tilt, not a press inward): while a finger is down the pad
    /// dips toward it and springs back on lift.
    @State private var isPressed = false
    @State private var pressLocation: CGPoint? = nil
    /// Finger trail (v1.0.44): a short faint line that follows the
    /// finger across the pad and fades shortly after lift, so the
    /// pad feels alive to touch. Points older than 0.8s drop off
    /// while dragging; on lift the whole trail fades out. One
    /// stroke per touch (v1.0.47): lifting and touching elsewhere
    /// starts a new streak — the strokes never connect.
    @State private var trail: [[TrailPoint]] = []
    @State private var trailStrokeOpen = false
    @State private var trailOpacity: Double = 1
    @State private var trailFadeTask: Task<Void, Never>?
    /// Settings (v1.0.46), read live so the pad re-renders when
    /// they change: color theme, border effect, trail style.
    @AppStorage("padTheme") private var padThemeRaw = "midnight"
    @AppStorage("padBorder") private var padBorderRaw = "off"
    @AppStorage("trailStyle") private var trailStyleRaw = "glow"
    /// Pad cover art (v1.0.50): bumped whenever the cover is
    /// set, re-cropped, or removed, so the pad re-renders.
    @AppStorage("padCoverVersion") private var coverVersion = 0
    private var theme: PadTheme { PadTheme(rawValue: padThemeRaw) ?? .midnight }
    private var borderEffect: PadBorder { PadBorder(rawValue: padBorderRaw) ?? .off }
    private var trailStyle: TrailStyle { TrailStyle(rawValue: trailStyleRaw) ?? .glow }
    /// Glass tint over a cover photo (v1.0.52): the pad's own
    /// gradient colors at low opacity, so the frosted photo still
    /// ties to the theme — dark gradient in dark mode, light
    /// gradient in light mode.
    private var coverTint: (top: Color, bottom: Color) {
        if colorScheme == .light {
            return (theme.lightTop.opacity(0.30), theme.lightBottom.opacity(0.30))
        }
        return (theme.top.opacity(0.30), theme.bottom.opacity(0.30))
    }
    /// Resolved color scheme (v1.0.51): the pad follows the page —
    /// a light pad in light mode, dark in dark mode.
    @Environment(\.colorScheme) private var colorScheme

    /// Same timing as the volume hold (v1.0.19/20): the hold engages
    /// 0.3s after touch down, then spam repeats one press every
    /// 0.12s (~8/s).
    private static let holdOnset: UInt64 = 300_000_000
    private static let holdInterval: UInt64 = 120_000_000
    /// A second tap within this long of the first tap's lift counts
    /// as a double-tap; after it, the next tap is a fresh single.
    /// 0.5s in v1.0.51 (was 0.3s): the tight window made a natural
    /// double-tap on the mute zone land as two separate selects
    /// instead of a mute — the second tap kept missing the window.
    private static let doubleTapWindow: UInt64 = 500_000_000
    /// Finger movement within this box counts as a tap/hold;
    /// beyond it, the gesture is a swipe.
    private static let tapSlop: CGFloat = 14
    /// Mute zone (v1.0.34): the middle-right of the pad — the right
    /// third horizontally, the middle half vertically. A double-tap
    /// with both taps here mutes; the middle stays for taps/holds.
    private static let muteZoneMinX: CGFloat = 0.67
    private static let muteZoneMinY: CGFloat = 0.25
    private static let muteZoneMaxY: CGFloat = 0.75

    /// True when a tap location (in the pad's own coordinates)
    /// falls inside the mute zone. False until the size is known.
    private func isMuteZone(_ location: CGPoint) -> Bool {
        guard padSize.width > 0, padSize.height > 0 else { return false }
        let x = location.x / padSize.width
        let y = location.y / padSize.height
        return x >= Self.muteZoneMinX && y >= Self.muteZoneMinY && y <= Self.muteZoneMaxY
    }

    /// Tilt toward the finger while pressed (v1.0.34, stronger in
    /// v1.0.44, stronger again in v1.0.47, and again in v1.0.51,
    /// simplified in v1.0.52): at most 8°, around the axis
    /// perpendicular to the offset from center, so the pad feels
    /// like a platform tipping toward the thumb — strongest at the
    /// corners. A dead-center press doesn't tilt at all — it only
    /// scales (barely, now). The axis sign is toward the finger.
    private var tiltAngle: Double {
        guard isPressed, let loc = pressLocation,
              padSize.width > 0, padSize.height > 0 else { return 0 }
        let dx = loc.x / padSize.width - 0.5
        let dy = loc.y / padSize.height - 0.5
        return min(1, sqrt(dx * dx + dy * dy) * 2.5) * 8
    }
    private var tiltAxis: (x: CGFloat, y: CGFloat, z: CGFloat) {
        guard let loc = pressLocation,
              padSize.width > 0, padSize.height > 0 else { return (x: 0, y: 1, z: 0) }
        let dx = loc.x / padSize.width - 0.5
        let dy = loc.y / padSize.height - 0.5
        return (x: -dy, y: dx, z: 0)
    }

    /// The pad's border (v1.0.46, Flow fixed in v1.0.51, inset in
    /// v1.0.52): off is the plain static stroke; glow adds a soft
    /// halo in the theme color; flow runs a bright segment around
    /// the border, LED-keyboard style — a trimmed stroke whose
    /// trim window slides along the path, driven by a TimelineView
    /// so it stays smooth with no timer to manage. (The first
    /// version rotated the trimmed shape instead — on a rounded
    /// rectangle that swings the piece off the border.) All strokes
    /// are inset (strokeBorder): a centered stroke hangs half its
    /// width past the pad's edge, so against a cover photo it read
    /// as a line that didn't line up with the image — inset, the
    /// border's outer edge is exactly the photo's edge.
    @ViewBuilder
    private var padBorder: some View {
        switch borderEffect {
        case .off:
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(theme.accent.opacity(0.55), lineWidth: 1.5)
        case .glow:
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(theme.accent, lineWidth: 2)
                .shadow(color: theme.accent.opacity(0.8), radius: 14)
        case .flow:
            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .strokeBorder(theme.accent.opacity(0.25), lineWidth: 2)
                TimelineView(.animation) { timeline in
                    let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3) / 3
                    let end = phase + 0.15
                    // The segment is inset by half its width first:
                    // strokeBorder doesn't exist on a trimmed shape
                    // (trim drops the InsettableShape conformance,
                    // so the v1.0.52 build failed to compile), and
                    // a centered stroke on the inset path lands its
                    // outer edge exactly on the photo's edge anyway.
                    RoundedRectangle(cornerRadius: 24)
                        .inset(by: 1.5)
                        .trim(from: phase, to: min(1, end))
                        .stroke(theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .shadow(color: theme.accent.opacity(0.9), radius: 8)
                    if end > 1 {
                        RoundedRectangle(cornerRadius: 24)
                            .inset(by: 1.5)
                            .trim(from: 0, to: end - 1)
                            .stroke(theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .shadow(color: theme.accent.opacity(0.9), radius: 8)
                    }
                }
            }
        }
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 24)
            .fill(
                LinearGradient(
                    // Light pad (v1.0.51): a pale tint of the theme
                    // instead of the dark gradient — the dark pad
                    // on a light page read as a hole in the page.
                    colors: colorScheme == .light ? [theme.lightTop, theme.lightBottom] : [theme.top, theme.bottom],
                    startPoint: .top, endPoint: .bottom)
            )
            // Pad cover art (v1.0.50): a user photo cropped to the
            // pad's shape replaces the theme gradient. The border
            // and trail still draw on top, in the theme accent.
            // Glass over the photo (v1.0.52): the bare photo read
            // as a picture, not a pad — a frosted layer in the
            // theme tint makes it feel like a pad surface, like
            // the glass Settings cards, and keeps the trail
            // readable over bright photos.
            .overlay(
                Group {
                    if let cover = PadCoverStore.image(for: coverVersion) {
                        Image(uiImage: cover)
                            .resizable()
                            .scaledToFill()
                            .overlay(
                                Rectangle()
                                    .fill(.ultraThinMaterial)
                                    .overlay(
                                        LinearGradient(
                                            colors: [coverTint.top, coverTint.bottom],
                                            startPoint: .top, endPoint: .bottom)
                                    )
                            )
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 24))
            )
            .overlay(padBorder)
            // Finger trail (v1.0.44): drawn on the pad itself, so
            // it tilts and scales with the pad. Clipped to the
            // rounded corners so it never spills outside the pad.
            .overlay(
                PadTrailOverlay(strokes: trail, opacity: trailOpacity, style: trailStyle, color: colorScheme == .light ? theme.accent : .white)
                    .clipShape(RoundedRectangle(cornerRadius: 24))
            )
            .frame(maxWidth: .infinity)
            .frame(height: height)
            // Press feedback (v1.0.47, retuned in v1.0.51,
            // simplified in v1.0.52): the pad tips toward the
            // finger like a platform — up to 8° at the corners —
            // and barely shrinks (0.995), so a tap reads as a tilt,
            // not a press inward. One spring, on the press state
            // only: the drag already delivers locations
            // continuously, so the tilt follows the finger directly
            // instead of chasing it through a second spring — the
            // second spring kept re-targeting on every move and
            // the tilt never got anywhere, which is why it read
            // as not tilting at all.
            .scaleEffect(isPressed ? 0.995 : 1.0)
            .rotation3DEffect(.degrees(tiltAngle), axis: tiltAxis)
            .animation(.spring(response: 0.1, dampingFraction: 0.85), value: isPressed)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { setPadSize(geo.size) }
                        .onChange(of: geo.size) { setPadSize($0) }
                }
            )
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if isKeyboardOpen || dismissedTouch {
                            // The dismissing touch sends nothing —
                            // not even a key hold if the finger
                            // stays down past the onset.
                            dismissedTouch = true
                            abortTouch()
                            onDismissKeyboard()
                            return
                        }
                        isPressed = true
                        pressLocation = value.location
                        addTrailPoint(value.location)
                        let t = value.translation
                        if abs(t.width) >= Self.tapSlop || abs(t.height) >= Self.tapSlop {
                            // It's a swipe — release a held key first,
                            // then fire the first directional press.
                            // The hold task keeps running: if the
                            // onset hasn't fired yet it drives the
                            // first swipe repeat at onset and the
                            // ticks after that. If it already fired
                            // (swiped out of a key hold) start the
                            // repeat loop directly.
                            emit(gesture.moved(translation: t, slop: Self.tapSlop))
                            if gesture.isSwiping, holdTask == nil {
                                startSwipeRepeatTask()
                            }
                        } else if holdTask == nil {
                            // Finger down and still — the gesture
                            // decides single vs double-tap (and, in
                            // the mute zone, mute vs enter); start
                            // the hold timer when it says this is
                            // a tap that can be held.
                            cancelWindowTask()
                            let down = gesture.touchDown(inMuteZone: isMuteZone(value.location))
                            emit(down.outputs)
                            if down.startHold {
                                startHoldTask()
                            }
                        }
                    }
                    .onEnded { value in
                        if isKeyboardOpen || dismissedTouch {
                            dismissedTouch = false
                            abortTouch()
                            onDismissKeyboard()
                            return
                        }
                        isPressed = false
                        pressLocation = nil
                        trailStrokeOpen = false
                        fadeTrail()
                        cancelHoldTask()
                        onCancelRepeats()
                        emit(gesture.touchUp(translation: value.translation, slop: Self.tapSlop))
                        if gesture.isAwaitingSecondTap || gesture.isAwaitingSecondTapZone {
                            cancelWindowTask()
                            startWindowTask()
                        }
                    }
            )
            .onDisappear {
                abortTouch()
            }
    }

    /// Aborts the touch in flight (v1.0.53): releases a held key,
    /// drops the trail and any timers, and resets the gesture — the
    /// shared cleanup for the pad going away and for a touch
    /// consumed as a keyboard dismiss (a dismiss that swallows a
    /// touch which already held a key down must still release it,
    /// or the key sticks on the TV).
    private func abortTouch() {
        if gesture.isKeyHeldDown {
            onCommand(.enterUp, false)
        }
        isPressed = false
        pressLocation = nil
        trailStrokeOpen = false
        trailFadeTask?.cancel()
        trailFadeTask = nil
        trail.removeAll()
        trailOpacity = 1
        cancelHoldTask()
        onCancelRepeats()
        cancelWindowTask()
        gesture.reset()
    }

    /// Records one finger position for the trail (v1.0.44): points
    /// older than 0.8s drop off, so the tail shortens behind the
    /// finger, and points closer than 4pt to the last one are
    /// skipped. A new touch cancels any fade in flight. Each touch
    /// is its own stroke (v1.0.47): lifting and touching elsewhere
    /// starts a new streak — the strokes never connect.
    private func addTrailPoint(_ location: CGPoint) {
        trailFadeTask?.cancel()
        trailFadeTask = nil
        trailOpacity = 1
        let now = Date()
        // Drop points older than 0.8s, and strokes that emptied.
        trail = trail.map { stroke in stroke.filter { now.timeIntervalSince($0.time) <= 0.8 } }
            .filter { !$0.isEmpty }
        // A new touch — or a stroke that aged out mid-touch —
        // opens a fresh streak.
        if !trailStrokeOpen || trail.isEmpty {
            trail.append([])
            trailStrokeOpen = true
        }
        guard var stroke = trail.last else { return }
        if let last = stroke.last,
           hypot(location.x - last.point.x, location.y - last.point.y) < 4 { return }
        stroke.append(TrailPoint(point: location, time: now))
        if stroke.count > 60 { stroke.removeFirst(stroke.count - 60) }
        trail[trail.count - 1] = stroke
    }

    /// Fades the trail out after lift (v1.0.44): it lingers a beat,
    /// then fades over 0.4s and clears.
    private func fadeTrail() {
        trailFadeTask?.cancel()
        trailFadeTask = Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.4)) { trailOpacity = 0 }
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            trail.removeAll()
            trailOpacity = 1
        }
    }

    /// Sends gesture outputs through the pad's callback. enterDown
    /// buzzes once at onset; a key release never buzzes. With
    /// `viaPump`, the same outputs enqueue on the session's
    /// coalescing pump instead of sending directly (v1.0.34): spam
    /// ticks and swipe repeats use the pump so the stream stops
    /// dead on lift; discrete presses always go direct.
    private func emit(_ outputs: [SwipePadGesture.Output], viaPump: Bool = false) {
        for output in outputs {
            switch output {
            case .enter(let haptic):
                if viaPump { onRepeatCommand(.enter, haptic) } else { onCommand(.enter, haptic) }
            case .enterDown:
                if viaPump { onRepeatCommand(.enterDown, true) } else { onCommand(.enterDown, true) }
            case .enterUp:
                if viaPump { onRepeatCommand(.enterUp, false) } else { onCommand(.enterUp, false) }
            case .mute(let haptic):
                if viaPump { onRepeatCommand(.mute, haptic) } else { onCommand(.mute, haptic) }
            case .up(let haptic):
                if viaPump { onRepeatCommand(.up, haptic) } else { onCommand(.up, haptic) }
            case .down(let haptic):
                if viaPump { onRepeatCommand(.down, haptic) } else { onCommand(.down, haptic) }
            case .left(let haptic):
                if viaPump { onRepeatCommand(.left, haptic) } else { onCommand(.left, haptic) }
            case .right(let haptic):
                if viaPump { onRepeatCommand(.right, haptic) } else { onCommand(.right, haptic) }
            }
        }
    }

    /// Hold timer: at onset the gesture either engages the hold
    /// (single tap), starts spamming (double-tap-hold), or fires
    /// the first repeat of a held swipe; spam and swipe repeats
    /// then tick every interval until the finger lifts. Clears its
    /// own slot when it finishes, so a later swipe out of a hold
    /// can start a fresh repeat task.
    private func startHoldTask() {
        holdTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.holdOnset)
            guard !Task.isCancelled else { return }
            // A held swipe's first repeat is a repeat, not a
            // discrete press: it goes through the pump so the
            // stream can be dropped on lift. A hold onset and the
            // first spam press are discrete and go direct.
            if gesture.isSwiping {
                emit(gesture.onsetTimerFired(), viaPump: true)
            } else {
                emit(gesture.onsetTimerFired())
            }
            while gesture.isSpamming || gesture.isSwiping, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.holdInterval)
                guard !Task.isCancelled else { return }
                emit(gesture.isSpamming ? gesture.spamTick() : gesture.swipeTick(), viaPump: true)
            }
            holdTask = nil
        }
    }

    /// Repeat loop for a swipe that started after the hold onset
    /// already fired (swiped out of a key hold): the onset gate
    /// has passed, so repeats tick every interval from here — the
    /// first one buzzes once, later ones are silent. Ticks go
    /// through the pump (v1.0.34) so they stop dead on lift.
    private func startSwipeRepeatTask() {
        holdTask = Task { @MainActor in
            while gesture.isSwiping, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.holdInterval)
                guard !Task.isCancelled else { return }
                emit(gesture.swipeTick(), viaPump: true)
            }
            holdTask = nil
        }
    }

    /// Double-tap window timer: started on a quick tap's lift; if
    /// no second tap lands, the tap stands alone. A zone-first tap
    /// sends its held-back enter here when the window expires.
    private func startWindowTask() {
        windowTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.doubleTapWindow)
            guard !Task.isCancelled else { return }
            emit(gesture.secondTapWindowExpired())
        }
    }

    private func cancelHoldTask() {
        holdTask?.cancel()
        holdTask = nil
    }

    private func cancelWindowTask() {
        windowTask?.cancel()
        windowTask = nil
    }
}

