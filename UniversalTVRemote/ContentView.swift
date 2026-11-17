import SwiftUI

// Theme + surface helpers live in PadTheme.swift (split out in
// v1.0.53) — PadTheme, PadBorder, TrailStyle, AppAppearance,
// AppBackground, remoteAccent.

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

    /// Card/button surface (v1.0.52): dark mode keeps the
    /// translucent primary fill; light mode uses solid white with
    /// a soft shadow, so the list card and the round buttons read
    /// against the bright page instead of washing out into it.
    /// Same treatment as the remote page's pills (v1.0.51).
    private var surfaceFill: Color {
        colorScheme == .light ? .white : Color.primary.opacity(0.10)
    }
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
                                .background(surfaceFill, in: Circle())
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
                                .background(surfaceFill, in: Circle())
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
                .background(surfaceFill, in: RoundedRectangle(cornerRadius: 20))
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
        // Page background (v1.0.48): Chrome dark gray / soft light
        // gray, not the system black/white extremes.
        .background(AppBackground.color(for: colorScheme).ignoresSafeArea())
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

/// Remote, redesigned in v1.0.12. The fork's remote screen is the
/// design inspiration, not a template: a top bar (Devices pill, TV
/// name, power), a Connected pill, then the navigation area, a
/// bottom row (keyboard), with the diagnostic status text below.
/// Dark with a blue accent. No ads,
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
        // The apps row is gone (v1.0.18), so its height went to the
        // bottom row instead; the rocker is gone in v1.0.23 (the
        // iPhone's physical volume buttons drive the TV volume now),
        // so the bottom row is just the keyboard circle. The
        // Back/Home/Exit pill row is gone in v1.0.55 (the buttons
        // live in the pad as double-tap zones now), so its height
        // went to the pad instead — see the cap below.
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
        fixed += bottomCell // bottom row — icons only, no labels
        fixed += bottomRowTopPadding // breathing room above the bottom row (v1.0.20)
        if showDiagnostic { fixed += CGFloat(diagnosticLines) * 17 }
        // Gaps between sections.
        var sections = 5 // topBar, pill, pad, bottom, diagnostic
        if pairingShown { sections += 1 }
        if keyboardShown { sections += 1 }
        if showLGNote { sections += 1 }
        if !showDiagnostic { sections -= 1 }
        let gaps = CGFloat(sections - 1) * gap
        // The pad absorbs the rest, down to a floor (lower while the
        // pairing card or keyboard is up — the pad isn't the focus then).
        // Cap is the swipe pad's design height (500, v1.0.55 — was
        // 440; the Back/Home/Exit pill row moved into the pad, so
        // its height went to the pad instead). On an iPhone 15 Plus
        // the pad lands at 500 (the cap binds), so the page fills
        // up with no dead space at the bottom.
        let floor: CGFloat = pairingShown ? 80 : (keyboardShown ? 60 : 100)
        let padSize = min(500, max(floor, h - fixed - gaps))

        return RemoteLayout(gap: gap, topPadding: topPadding, topBarButton: topBarButton,
                            pairingCardPadding: pairingCardPadding, pairingCardSpacing: pairingCardSpacing,
                            padSize: padSize,
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
    /// Pill/card surface (v1.0.51): dark mode keeps the translucent
    /// primary fill; light mode uses solid white with a soft shadow,
    /// so the controls read as buttons on the tinted page instead
    /// of washed-out gray blobs.
    private var surfaceFill: Color {
        colorScheme == .light ? .white : Color.primary.opacity(0.10)
    }
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
        // Page background (v1.0.48): Chrome dark gray / soft light
        // gray, not the system black/white extremes.
        .background(AppBackground.color(for: colorScheme).ignoresSafeArea())
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
                // Backgrounding (v1.0.53): release a held key and
                // cancel hold/repeat tasks, so a key can't stick on
                // the TV while the app is away.
                session.releaseHeldInput()
            } else if phase == .inactive {
                session.releaseHeldInput()
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
            // Back / Home / Exit live in the pad now (v1.0.55):
            // double-tap the bottom-left, bottom-middle, or
            // bottom-right — the pill row is gone.
            SwipePadView(height: layout.padSize, onCommand: { send($0, haptic: $1) }, onRepeatCommand: { sendRepeat($0, haptic: $1) }, onCancelRepeats: { session.cancelRepeats() }, isKeyboardOpen: showKeyboard, onDismissKeyboard: { dismissKeyboard() })
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
            .background(surfaceFill, in: RoundedRectangle(cornerRadius: 16))
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
                    .background(surfaceFill, in: Capsule())
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
                    .background(surfaceFill, in: Circle())
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
        .background(surfaceFill, in: Capsule())
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
                            .fill(surfaceFill)
                        Circle()
                            .stroke(showKeyboard ? remoteAccent : Color.primary.opacity(0.08), lineWidth: 2.5)
                        Image(systemName: "keyboard")
                            .font(.title)
                            .foregroundStyle(.primary)
                    }
                    .frame(width: layout.circleSize, height: layout.circleSize)
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

}

// The swipe pad lives in SwipePad.swift (split out in v1.0.53) —
// SwipePadGesture, PadGeometry, the finger trail, SwipePadView.

// The pad-controls help sheet and its frosted-glass pieces live
// in PadHelpSheet.swift (split out in v1.0.53) — PadHelpSheet,
// GlassCardBackground, GlassHeaderPill, GlassSection,
// GlassSegmentedControl.

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
        .background(AppBackground.color(for: colorScheme).ignoresSafeArea())
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

// Pad cover art lives in PadCover.swift (split out in v1.0.53) —
// PadCoverStore, PadCoverPicker, PadCoverCropView.
