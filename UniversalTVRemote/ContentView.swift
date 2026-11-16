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
        // row shrinks again. While the pairing card is up the bottom
        // row stays compact — the card is the focus then, and the
        // tall row would overflow short screens.
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
    /// Hardware volume buttons drive the TV volume (v1.0.23):
    /// the controller watches the iPhone's outputVolume while
    /// this view is up and turns each press into a .volumeUp /
    /// .volumeDown through the same session send path the rocker
    /// used — no haptics, the button press itself is the feedback.
    @StateObject private var hardwareVolume = HardwareVolumeController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        // No ScrollView on the remote (v1.0.15): everything fits on one
        // page. The layout sizes itself from the available height — the
        // swipe pad absorbs the slack, and on short screens the
        // bottom row, buttons and spacing shrink too. Nothing is dropped.
        GeometryReader { geo in
            let layout = RemoteLayout.make(
                height: geo.size.height,
                pairingShown: session.awaitingPairingCode,
                keyboardShown: showKeyboard && session.capabilities.supportsTextInput,
                isLG: session.device.brand == .lg)
            VStack(spacing: layout.gap) {
                topBar(layout)

                // Pairing code (Android TV): the TV shows a code.
                // Restyled in v1.0.21 to match the remote's dark UI —
                // the old teal card clashed with everything else.
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

                // Keyboard / text input, revealed by the keyboard
                // button in the bottom row.
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
                            Task { await session.send(.text(text)) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(keyboardText.isEmpty)
                    }
                    .padding(.horizontal)
                    // Focus on appear so the iOS keyboard pops up at
                    // once — no second tap on the text field.
                    .onAppear { keyboardFocused = true }
                }

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
                SwipePadView(height: layout.padSize) { send($0, haptic: $1) }
                    .padding(.horizontal)

                // Back / Home / Exit pill row — icons only, no labels.
                HStack(spacing: 16) {
                    pillButton(systemImage: "arrow.left", label: "Back", height: layout.pillsButtonHeight) { send(.back) }
                    pillButton(systemImage: "house", label: "Home", height: layout.pillsButtonHeight) { send(.home) }
                    pillButton(systemImage: "rectangle.portrait.and.arrow.right", label: "Exit", height: layout.pillsButtonHeight) { send(.exit) }
                }
                .padding(.horizontal)

                // Bottom row: equal columns on one axis — the
                // keyboard button and the Mute square. (The volume
                // rocker is gone in v1.0.23: the iPhone's physical
                // volume buttons drive the TV volume now. Mute stays
                // — it's a distinct command the volume buttons can't
                // do. The mic button is out for now; the voice code
                // stays dormant behind it. The apps row is gone in
                // v1.0.18 — its space went to this row instead.)
                // Every control sits in a layout-sized cell so they
                // share top and bottom edges. Icons only — the words
                // underneath were removed in v1.0.19. Nothing here is
                // ever a dead button.
                HStack(alignment: .top, spacing: 16) {
                    if session.capabilities.supportsTextInput {
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
                        .frame(maxWidth: .infinity)
                    }
                    Button { send(.mute) } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 24)
                                .fill(Color.white.opacity(0.10))
                            RoundedRectangle(cornerRadius: 24)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                            Image(systemName: "speaker.slash.fill")
                                .font(.title)
                                .foregroundStyle(.white)
                        }
                        .frame(width: layout.circleSize, height: layout.circleSize)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Mute")
                    .frame(height: layout.bottomCell)
                    .frame(maxWidth: .infinity)
                }
                .padding(.top, layout.bottomRowTopPadding)

                // Diagnostic status — capped to a few lines so the page
                // fits; the full text lives in Settings. Hidden while
                // the pairing card or keyboard is up (they show the
                // status themselves).
                if layout.showDiagnostic {
                    Text(session.status)
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
            .background(
                HiddenVolumeView(volumeView: hardwareVolume.volumeView)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
            )
        }
        .task { await session.connect() }
        .onAppear {
            // Hardware volume buttons → TV volume, scoped strictly
            // to this view: start here, stop on disappear (and on
            // backgrounding, below). The step goes through the
            // session send path, so the Samsung 200 ms throttle,
            // the Android TV direct path, and the per-brand behavior
            // all apply unchanged. No haptic — the button press
            // itself and the TV's volume change are the feedback.
            hardwareVolume.onStep = { [session] up in
                Task { await session.send(up ? .volumeUp : .volumeDown) }
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

    /// True while the session is actively connecting — busy, but
    /// not waiting on the TV's own allow prompt (that state shows
    /// "Check your TV" and needs the user, not a spinner).
    private var isConnecting: Bool {
        session.supportsControl && session.isBusy && !session.awaitingTVPrompt
    }

    /// `haptic` defaults to true — every tap buzzes once. (The
    /// volume rocker used to pass false for repeat steps of a hold,
    /// v1.0.20; the rocker is gone in v1.0.23, so no caller
    /// overrides it now. The hardware volume buttons don't use
    /// this at all — they call session.send directly, no haptic.)
    private func send(_ command: RemoteCommand, haptic: Bool = true) {
        if haptic { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        Task { await session.send(command) }
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
/// - Swipe (≥ slop): a held key is released first, then the normal
///   single directional press on release. A key is never left down.
struct SwipePadGesture {
    enum Output: Equatable {
        case enter(haptic: Bool)
        case enterDown
        case enterUp
        case up, down, left, right
    }

    private enum State {
        case idle
        case awaitingSecondTap
        case singleDown
        case singleHeld
        case doubleDown
        case doubleSpam
        case swiping
    }

    private var state: State = .idle

    /// True while a key-down has been sent and not yet released.
    var isKeyHeldDown: Bool { state == .singleHeld }
    /// True while double-tap-hold spam is active.
    var isSpamming: Bool { state == .doubleSpam }
    /// True after a quick tap lifted, while a second tap still
    /// counts as a double-tap.
    var isAwaitingSecondTap: Bool { state == .awaitingSecondTap }

    /// Finger down. Returns true when the view should start the hold
    /// onset timer (a fresh single or double tap); false when this
    /// touch is already a swipe that wandered back inside the slop.
    mutating func touchDown() -> Bool {
        switch state {
        case .idle:
            state = .singleDown
            return true
        case .awaitingSecondTap:
            state = .doubleDown
            return true
        default:
            return false
        }
    }

    /// The 0.3s hold onset fired: a single tap engages the hold
    /// (key down), a double-tap starts spamming enters.
    mutating func onsetTimerFired() -> [Output] {
        switch state {
        case .singleDown:
            state = .singleHeld
            return [.enterDown]
        case .doubleDown:
            state = .doubleSpam
            return [.enter(haptic: true)]
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

    /// Finger moved. Beyond the slop the gesture becomes a swipe: a
    /// held key is released first, then the swipe proceeds.
    mutating func moved(translation: CGSize, slop: CGFloat) -> [Output] {
        guard abs(translation.width) >= slop || abs(translation.height) >= slop else { return [] }
        switch state {
        case .singleHeld:
            state = .swiping
            return [.enterUp]
        case .singleDown, .doubleDown, .doubleSpam:
            state = .swiping
            return []
        default:
            return []
        }
    }

    /// Finger lifted. A swipe sends its direction; a quick tap sends
    /// one enter (and opens the double-tap window for a first tap
    /// only); a hold releases the key with no enter on lift; spam
    /// just stops.
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
        case .swiping:
            state = .idle
            return [direction(of: translation)]
        case .awaitingSecondTap, .idle:
            return []
        }
    }

    /// The double-tap window expired with no second tap: the first
    /// tap stands alone, and the next tap is a fresh single.
    mutating func secondTapWindowExpired() {
        if state == .awaitingSecondTap { state = .idle }
    }

    mutating func reset() { state = .idle }

    private func direction(of translation: CGSize) -> Output {
        if abs(translation.width) > abs(translation.height) {
            return translation.width > 0 ? .right : .left
        }
        return translation.height > 0 ? .down : .up
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
/// quick double-tap sends two, and swipes still send single
/// directional presses — swiping out of a hold releases the key
/// first, so a key is never left stuck down.
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

    @State private var gesture = SwipePadGesture()
    @State private var holdTask: Task<Void, Never>?
    @State private var windowTask: Task<Void, Never>?

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
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let t = value.translation
                        if abs(t.width) >= Self.tapSlop || abs(t.height) >= Self.tapSlop {
                            // It's a swipe — release a held key first,
                            // then cancel the hold timer.
                            emit(gesture.moved(translation: t, slop: Self.tapSlop))
                            cancelHoldTask()
                        } else if holdTask == nil {
                            // Finger down and still — the gesture
                            // decides single vs double-tap; start the
                            // hold timer when it says this is a tap.
                            cancelWindowTask()
                            if gesture.touchDown() {
                                startHoldTask()
                            }
                        }
                    }
                    .onEnded { value in
                        cancelHoldTask()
                        emit(gesture.touchUp(translation: value.translation, slop: Self.tapSlop))
                        if gesture.isAwaitingSecondTap {
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
                cancelHoldTask()
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
            case .up: onCommand(.up, true)
            case .down: onCommand(.down, true)
            case .left: onCommand(.left, true)
            case .right: onCommand(.right, true)
            }
        }
    }

    /// Hold timer: at onset the gesture either engages the hold
    /// (single tap) or starts spamming (double-tap-hold); spam then
    /// ticks every interval until the finger lifts or swipes.
    private func startHoldTask() {
        holdTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.holdOnset)
            guard !Task.isCancelled else { return }
            emit(gesture.onsetTimerFired())
            while gesture.isSpamming, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.holdInterval)
                guard !Task.isCancelled else { return }
                emit(gesture.spamTick())
            }
        }
    }

    /// Double-tap window timer: started on a quick tap's lift; if
    /// no second tap lands, the tap stands alone.
    private func startWindowTask() {
        windowTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.doubleTapWindow)
            guard !Task.isCancelled else { return }
            gesture.secondTapWindowExpired()
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

