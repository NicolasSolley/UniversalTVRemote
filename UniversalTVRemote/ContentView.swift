import SwiftUI

struct ContentView: View {
    @StateObject private var discovery = DiscoveryManager()
    @State private var session: RemoteSession?
    /// The launch scan runs once, when the app first opens — not on
    /// every appearance (returning from a remote keeps the list as is).
    @State private var didAutoScan = false

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
        .preferredColorScheme(.dark)
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

    /// True once a scan has finished at least once — drives the empty
    /// state (still scanning vs. nothing found). View-side only; the
    /// discovery code is untouched.
    @State private var hasCompletedScan = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Header: just the centered title. The X from the
                // reference is gone (Nick's call, v1.0.9): the device
                // list is the app's root, so there is no previous
                // screen for it to return to. No ? button either.
                Text("Select a TV Device")
                    .font(.headline.bold())
                    .foregroundStyle(.white)

                // One dark card holding the whole TV list.
                VStack(spacing: 0) {
                    if discovery.devices.isEmpty {
                        emptyRow
                    } else {
                        ForEach(discovery.devices) { device in
                            deviceRow(device)
                            if device.id != discovery.devices.last?.id {
                                Divider()
                                    .background(Color.white.opacity(0.08))
                                    .padding(.leading, 76)
                            }
                        }
                    }
                }
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 20))
                .padding(.horizontal)

                Text("Make sure your phone and TV are connected to the same wifi network.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)
            } else {
                Text("No TVs found")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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
                        .foregroundStyle(.white)
                    Text(device.addressLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !device.brand.supportsControl {
                    Text("Discovery only")
                        .font(.caption2)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.white.opacity(0.08), in: Capsule())
                        .foregroundStyle(.secondary)
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
        case .airPlay: return Color.white.opacity(0.10)
        case .other: return Color.white.opacity(0.10)
        }
    }
}

// MARK: - Remote

/// Blue accent for the redesigned remote (v1.0.12): the selected
/// toggle segment, the mic ring, the Play/Pause button, the Devices
/// pill text. One accent, used sparingly — the rest stays dark and
/// neutral.
private let remoteAccent = Color(red: 0.15, green: 0.45, blue: 1.0)

/// Remote, redesigned in v1.0.12. The fork's remote screen is the
/// design inspiration, not a template: a top bar (Devices pill, TV
/// name, power), a Connected pill, then the navigation area, a
/// Back/Home/Exit pill row, and a bottom row (keyboard, Mute), with
/// the diagnostic status text below. Dark with a blue accent. No ads,
/// no promos, no cast button, no tab bar.
/// What stays ours: the mic is hold-to-talk and Android TV only.
/// Dropped to keep the layout clean: the number pad and the channel
/// rocker (use the TV's own remote or the on-screen guide for
/// channels), the app shortcut cards (v1.0.18 — the space went to the
/// volume and mute buttons instead; launching still works in code, the
/// row is just gone), and the playback row (v1.0.18 — left/right swipes
/// already seek, so it was redundant with the swipe pad as master
/// control; the play/pause/seek commands stay in code and the row can
/// come back if missed).
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
        // bottom row instead — but v1.0.20 shrank the row back (the
        // rocker was way too big and crowded the pills above it),
        // and v1.0.23 removes the rocker entirely: the iPhone's
        // physical volume buttons drive the TV volume now, so the
        // bottom row is just two circles (keyboard, Mute) and the
        // row shrinks again. v1.0.28 removed the mute button (both
        // volume buttons at once toggled mute instead); v1.0.29
        // puts it back — pressing both buttons at once was awkward,
        // and mute belongs on a button of its own.
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
        // Cap is the swipe pad's design height: it is the master control
        // now, so it takes the space the old toggle used to take.
        // v1.0.23 raises the cap 300 → 320: the rocker is gone, so the
        // freed space goes to the pad on tall phones.
        let floor: CGFloat = pairingShown ? 80 : (keyboardShown ? 60 : 100)
        let padSize = min(320, max(floor, h - fixed - gaps))

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
    /// Hardware volume buttons drive the TV volume (v1.0.23,
    /// fixed in v1.0.26): the controller watches the iPhone's
    /// outputVolume while this view is up and turns each press into
    /// a .volumeUp / .volumeDown through the session's coalescing
    /// pump (v1.0.28) — no haptics, the button press itself is the
    /// feedback. v1.0.26: the anchor is verified, not assumed
    /// (lastVolume always tracks the phone's real volume), session
    /// activation is retried, and a capture failure shows in the
    /// diagnostic line instead of vanishing. v1.0.28: a hold stops
    /// the instant the finger lifts (the pump drops the pending
    /// step instead of draining a backlog).
    @StateObject private var hardwareVolume = HardwareVolumeController()
    @Environment(\.scenePhase) private var scenePhase

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
            // the finger lifts and never blocks other keys — no
            // haptic, the button press itself and the TV's volume
            // change are the feedback.
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
            SwipePadView(height: layout.padSize, onCommand: { send($0, haptic: $1) }, onRepeatCommand: { sendRepeat($0, haptic: $1) }, onCancelRepeats: { session.cancelRepeats() })
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
                    .foregroundStyle(.white)
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
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.08), lineWidth: 1))
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
            .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08), lineWidth: 1))
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
                session.disconnect()
                onBack()
            } label: {
                Image(systemName: "tv")
                    .font(.subheadline.bold())
                    .foregroundStyle(remoteAccent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(0.08), in: Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Devices")
            Spacer()
            Text(session.device.name)
                .font(.headline.bold())
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer()
            Button { send(.power) } label: {
                Image(systemName: "power")
                    .font(.headline.bold())
                    .foregroundStyle(.red)
                    .frame(width: layout.topBarButton, height: layout.topBarButton)
                    .background(Color.white.opacity(0.08), in: Circle())
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
                    .tint(.white)
            }
            Text(connectionLabel)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Color.white.opacity(0.08), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
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
    /// whole handshake), and a static pill there looks frozen:
    /// v1.0.31, Nick never saw the spinner because it was
    /// suppressed exactly while "Check your TV" showed. The label
    /// already says what to do ("Check your TV" vs "Connecting…");
    /// the spinner just shows something is happening.
    private var isConnecting: Bool {
        session.supportsControl && session.isBusy
    }

    /// `haptic` defaults to true — every tap buzzes once. (The
    /// volume rocker used to pass false for repeat steps of a hold,
    /// v1.0.20; the rocker is gone in v1.0.23, so no caller
    /// overrides it now. The hardware volume buttons don't use
    /// this at all — steps go through session.sendVolume (the
    /// pump). Mute comes from the pad's middle-right double-tap
    /// (v1.0.34), not a button anymore.)
    private func send(_ command: RemoteCommand, haptic: Bool = true) {
        if haptic { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        Task { await session.send(command) }
    }

    /// A pad repeat press (v1.0.34): enqueues on the session's
    /// coalescing pump instead of spawning a send Task, so repeats
    /// stop dead on lift. Same buzz rule as send.
    private func sendRepeat(_ command: RemoteCommand, haptic: Bool = true) {
        if haptic { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        session.sendRepeat(command)
    }

    /// Keyboard / text input, revealed by the keyboard button — or
    /// on its own when the TV announces a focused text field
    /// (v1.0.34 auto keyboard). Send closes it (v1.0.34): the text
    /// is on the TV, so there is nothing left to type. The ×
    /// dismisses without sending — the only way to close it on a
    /// TV where the button hides, and the escape hatch everywhere
    /// else. A separate view so the body stays small enough for
    /// the compiler to type-check.
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
                    keyboardText = ""
                    showKeyboard = false
                    keyboardFocused = false
                    Task { await session.send(.text(text)) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(keyboardText.isEmpty)
                Button {
                    keyboardText = ""
                    showKeyboard = false
                    keyboardFocused = false
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
    /// pops up on its own and the button hides. (The volume rocker
    /// is gone in v1.0.23: the iPhone's physical volume buttons
    /// drive the TV volume now. The mic button is out for now; the
    /// voice code stays dormant behind it. The apps row is gone in
    /// v1.0.18 — its space went to this row instead.)
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
                            .fill(Color.white.opacity(0.10))
                        Circle()
                            .stroke(showKeyboard ? remoteAccent : Color.white.opacity(0.08), lineWidth: 2.5)
                        Image(systemName: "keyboard")
                            .font(.title)
                            .foregroundStyle(.white)
                    }
                    .frame(width: layout.circleSize, height: layout.circleSize)
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
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: height)
                .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 28))
                .overlay(RoundedRectangle(cornerRadius: 28).stroke(Color.white.opacity(0.08), lineWidth: 1))
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

/// Reports the pad's rendered size up through the view tree
/// (v1.0.34): the mute zone is a fraction of the pad, so taps are
/// located against the measured size. A PreferenceKey, not
/// onChange(of: geo.size) — a zero-parameter onChange closure
/// resolves to the iOS 17 overload, and the target is iOS 15.
private struct PadSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

/// Big swipe pad (the Swipe half of the toggle): near full-width,
/// a bare pad — no chevrons, no hand icon, no label.
/// One drag is one command on release (tap = select) — the same
/// gesture as the old touchpad, only the size and the look changed.
/// HOLDING the pad (v1.0.24) repeated the regular OK/select press
/// while held. v1.0.25 splits that into two modes, decided by the
/// pure SwipePadGesture above: a single tap held past the 0.3s
/// onset holds the OK key DOWN until lift (a long-press, e.g. for
/// a context menu), while a double-tap held past onset spams OK
/// presses at the old cadence (first repeat at onset, then one
/// every 0.12s). A quick tap still sends exactly one OK press, a
/// quick double-tap sends two. v1.0.27 adds swipe-and-hold: a swipe
/// fires its first directional press at once and, held past the
/// 0.3s onset, repeats that same direction every 0.12s until lift;
/// a quick swipe-and-lift is still exactly one press. Swiping out
/// of a hold releases the key first, so a key is never left stuck
/// down. v1.0.34 adds a mute zone: a double-tap on the middle-right
/// of the pad mutes/unmutes, while the middle keeps its taps and
/// holds exactly as before — the zone never starts a hold, and a
/// swipe starting in it is still a swipe.
/// The height comes from the layout so the pad fits the
/// non-scrollable page on small phones.
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

    @State private var gesture = SwipePadGesture()
    @State private var holdTask: Task<Void, Never>?
    @State private var windowTask: Task<Void, Never>?
    /// The pad's rendered size, for the mute zone (v1.0.34): the
    /// zone is a fraction of the pad, so taps are located against
    /// this, not against fixed points.
    @State private var padSize: CGSize = .zero
    /// Press feedback (v1.0.34): while a finger is down the pad
    /// dips subtly toward it — a small scale plus a faint tilt —
    /// and springs back on lift.
    @State private var isPressed = false
    @State private var pressLocation: CGPoint? = nil

    /// Same timing as the volume hold (v1.0.19/20): the hold engages
    /// 0.3s after touch down, then spam repeats one press every
    /// 0.12s (~8/s).
    private static let holdOnset: UInt64 = 300_000_000
    private static let holdInterval: UInt64 = 120_000_000
    /// A second tap within this long of the first tap's lift counts
    /// as a double-tap; after it, the next tap is a fresh single.
    private static let doubleTapWindow: UInt64 = 300_000_000
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

    /// Tilt toward the finger while pressed (v1.0.34): at most 3°,
    /// around the axis perpendicular to the offset from center, so
    /// the pad feels like it dips under the thumb. A dead-center
    /// press doesn't tilt at all — it only scales.
    private var tiltAngle: Double {
        guard isPressed, let loc = pressLocation,
              padSize.width > 0, padSize.height > 0 else { return 0 }
        let dx = loc.x / padSize.width - 0.5
        let dy = loc.y / padSize.height - 0.5
        return min(1, sqrt(dx * dx + dy * dy) * 2) * 3
    }
    private var tiltAxis: (x: CGFloat, y: CGFloat, z: CGFloat) {
        guard let loc = pressLocation,
              padSize.width > 0, padSize.height > 0 else { return (x: 0, y: 1, z: 0) }
        let dx = loc.x / padSize.width - 0.5
        let dy = loc.y / padSize.height - 0.5
        return (x: -dy, y: dx, z: 0)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 24)
            .fill(
                LinearGradient(
                    colors: [Color(red: 0.10, green: 0.16, blue: 0.35),
                             Color(red: 0.05, green: 0.07, blue: 0.18)],
                    startPoint: .top, endPoint: .bottom)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .stroke(remoteAccent.opacity(0.55), lineWidth: 1.5)
            )
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .scaleEffect(isPressed ? 0.98 : 1.0)
            .rotation3DEffect(.degrees(tiltAngle), axis: tiltAxis)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: isPressed)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: PadSizePreferenceKey.self, value: geo.size)
                }
            )
            .onPreferenceChange(PadSizePreferenceKey.self) { padSize = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isPressed = true
                        pressLocation = value.location
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
                        isPressed = false
                        pressLocation = nil
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
                // Safety: never leave a key stuck down if the pad
                // goes away mid-hold.
                if gesture.isKeyHeldDown {
                    onCommand(.enterUp, false)
                }
                isPressed = false
                pressLocation = nil
                cancelHoldTask()
                onCancelRepeats()
                cancelWindowTask()
                gesture.reset()
            }
    }

    /// Sends gesture outputs through the pad's callback. enterDown
    /// buzzes once at onset; a key release never buzzes.
    private func emit(_ outputs: [SwipePadGesture.Output]) {
        for output in outputs {
            switch output {
            case .enter(let haptic): onCommand(.enter, haptic)
            case .enterDown: onCommand(.enterDown, true)
            case .enterUp: onCommand(.enterUp, false)
            case .mute(let haptic): onCommand(.mute, haptic)
            case .up(let haptic): onCommand(.up, haptic)
            case .down(let haptic): onCommand(.down, haptic)
            case .left(let haptic): onCommand(.left, haptic)
            case .right(let haptic): onCommand(.right, haptic)
            }
        }
    }

    /// Sends repeat outputs through the pump path (v1.0.34): the
    /// same outputs as emit, but they enqueue on the session's
    /// coalescing pump instead of spawning one send Task each, so
    /// the stream stops dead on lift. Only spam ticks and swipe
    /// repeats use this — discrete presses always use emit.
    private func emitRepeat(_ outputs: [SwipePadGesture.Output]) {
        for output in outputs {
            switch output {
            case .enter(let haptic): onRepeatCommand(.enter, haptic)
            case .enterDown: onRepeatCommand(.enterDown, true)
            case .enterUp: onRepeatCommand(.enterUp, false)
            case .mute(let haptic): onRepeatCommand(.mute, haptic)
            case .up(let haptic): onRepeatCommand(.up, haptic)
            case .down(let haptic): onRepeatCommand(.down, haptic)
            case .left(let haptic): onRepeatCommand(.left, haptic)
            case .right(let haptic): onRepeatCommand(.right, haptic)
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
                emitRepeat(gesture.onsetTimerFired())
            } else {
                emit(gesture.onsetTimerFired())
            }
            while gesture.isSpamming || gesture.isSwiping, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.holdInterval)
                guard !Task.isCancelled else { return }
                emitRepeat(gesture.isSpamming ? gesture.spamTick() : gesture.swipeTick())
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
                emitRepeat(gesture.swipeTick())
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

