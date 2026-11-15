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
/// Back/Home/Exit pill row, and a bottom row (Volume rocker, keyboard,
/// Mute), with the diagnostic status text below. Dark with a blue
/// accent. No ads,
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
    var rockerWidth: CGFloat
    var rockerButtonHeight: CGFloat
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
        // The apps row is gone (v1.0.18), so its height goes to the
        // bottom row instead: volume and mute get much bigger. While
        // the pairing card is up the bottom row stays compact — the
        // card is the focus then, and the tall row would overflow
        // short screens.
        let bottomCell: CGFloat = pairingShown ? (extraCompact ? 90 : 110)
            : (extraCompact ? 184 : (compact ? 208 : 226))
        let circleSize = min(112, bottomCell * 0.55)
        let rockerWidth: CGFloat = extraCompact ? 88 : (compact ? 96 : 104)
        let rockerButtonHeight = max(36, min(80, bottomCell * 0.40))
        let showDiagnostic = !pairingShown && !keyboardShown
        let diagnosticLines = compact ? 2 : 3
        let showLGNote = isLG && !extraCompact

        // Budgeted heights of every section except the pad.
        var fixed: CGFloat = topPadding + topBarButton
        if pairingShown { fixed += extraCompact ? 155 : (compact ? 165 : 170) }
        if keyboardShown { fixed += extraCompact ? 36 : (compact ? 40 : 44) }
        fixed += 38 // connection pill
        if showLGNote { fixed += 16 }
        fixed += pillsButtonHeight + 6 + 16 // pills row + label
        fixed += bottomCell + 6 + 16 // bottom row + labels
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
        let floor: CGFloat = pairingShown ? 80 : (keyboardShown ? 60 : 100)
        let padSize = min(300, max(floor, h - fixed - gaps))

        return RemoteLayout(gap: gap, topPadding: topPadding, topBarButton: topBarButton,
                            pairingCardPadding: pairingCardPadding, pairingCardSpacing: pairingCardSpacing,
                            padSize: padSize,
                            pillsButtonHeight: pillsButtonHeight,
                            bottomCell: bottomCell, circleSize: circleSize,
                            rockerWidth: rockerWidth, rockerButtonHeight: rockerButtonHeight,
                            diagnosticLines: diagnosticLines, showDiagnostic: showDiagnostic,
                            showLGNote: showLGNote)
    }
}

private struct RemoteView: View {
    @ObservedObject var session: RemoteSession
    var onBack: () -> Void

    @State private var keyboardText = ""
    @State private var showKeyboard = false

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

                // Pairing code (Android TV): the TV shows a 6-character code.
                if session.awaitingPairingCode {
                    VStack(spacing: layout.pairingCardSpacing) {
                        Text("Enter the code shown on your TV")
                            .font(.headline)
                        Text("It has 6 characters (letters and numbers).")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        HStack {
                            TextField("Code", text: $session.pairingCode)
                                .textFieldStyle(.roundedBorder)
                                .autocorrectionDisabled(true)
                                .textInputAutocapitalization(.characters)
                                .keyboardType(.asciiCapable)
                                .multilineTextAlignment(.center)
                            Button("Pair") { session.submitPairingCode() }
                                .buttonStyle(.borderedProminent)
                        }
                        Button("Cancel", role: .cancel) { session.cancelPairing() }
                            .buttonStyle(.bordered)
                    }
                    .padding(layout.pairingCardPadding)
                    .background(Color.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.cyan.opacity(0.25), lineWidth: 1))
                    .padding(.horizontal)
                }

                // Keyboard / text input, revealed by the keyboard
                // button in the bottom row.
                if showKeyboard, session.capabilities.supportsTextInput {
                    HStack {
                        TextField("Type on the TV…", text: $keyboardText)
                            .textFieldStyle(.roundedBorder)
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
                SwipePadView(height: layout.padSize) { send($0) }
                    .padding(.horizontal)

                // Back / Home / Exit pill row with labels underneath.
                HStack(spacing: 16) {
                    pillButton(systemImage: "arrow.left", label: "Back", height: layout.pillsButtonHeight) { send(.back) }
                    pillButton(systemImage: "house", label: "Home", height: layout.pillsButtonHeight) { send(.home) }
                    pillButton(systemImage: "rectangle.portrait.and.arrow.right", label: "Exit", height: layout.pillsButtonHeight) { send(.exit) }
                }
                .padding(.horizontal)

                // Bottom row: equal columns on one axis — the Volume
                // rocker, the keyboard button (Roku/Samsung/LG), and
                // the Mute square. (The mic button is out for now; the
                // voice code stays dormant behind it. The apps row is
                // gone in v1.0.18 — its space went to this row instead.)
                // Every control sits in a layout-sized cell so they
                // share top and bottom edges, and the labels sit on one
                // shared baseline below. Nothing here is ever a dead button.
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 6) {
                        VolRockerView(buttonHeight: layout.rockerButtonHeight, width: layout.rockerWidth, onUp: { send(.volumeUp) }, onDown: { send(.volumeDown) })
                            .frame(height: layout.bottomCell)
                        Text("Volume")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    if session.capabilities.supportsTextInput {
                        VStack(spacing: 6) {
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
                            Text("Keyboard")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    VStack(spacing: 6) {
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
                        Text("Mute")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }

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
        }
        .task { await session.connect() }
        .onDisappear { session.disconnect() }
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
                HStack(spacing: 6) {
                    Image(systemName: "tv")
                        .font(.subheadline.bold())
                    Text("Devices")
                        .font(.subheadline.bold())
                }
                .foregroundStyle(remoteAccent)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.08), in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
            }
            .buttonStyle(.plain)
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
    /// in one place.
    private var connectionPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(connectionDotColor)
                .frame(width: 9, height: 9)
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

    private func send(_ command: RemoteCommand) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task { await session.send(command) }
    }

    /// Wide pill button with an icon and a label underneath
    /// (Back / Home / Exit row). The button height comes from the
    /// layout so the row shrinks on short screens.
    private func pillButton(systemImage: String, label: String, height: CGFloat, action: @escaping () -> Void) -> some View {
        VStack(spacing: 6) {
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: height)
                    .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 28))
                    .overlay(RoundedRectangle(cornerRadius: 28).stroke(Color.white.opacity(0.08), lineWidth: 1))
            }
            .buttonStyle(.plain)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

}

// MARK: - Swipe pad

/// Big swipe pad (the Swipe half of the toggle): near full-width,
/// a bare pad — no chevrons, no hand icon, no label.
/// One drag is one command on release (tap = select) — the same
/// gesture as the old touchpad, only the size and the look changed.
/// The height comes from the layout so the pad fits the
/// non-scrollable page on small phones.
private struct SwipePadView: View {
    var height: CGFloat
    var onCommand: (RemoteCommand) -> Void

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
                    .onEnded { value in
                        let t = value.translation
                        if abs(t.width) < 14, abs(t.height) < 14 {
                            onCommand(.enter)
                        } else if abs(t.width) > abs(t.height) {
                            onCommand(t.width > 0 ? .right : .left)
                        } else {
                            onCommand(t.height > 0 ? .down : .up)
                        }
                    }
            )
    }
}

// MARK: - Volume rocker

/// Tall volume rocker: + on top, a VOL label in the middle, − at the
/// bottom. It stretches to the height of the button grid beside it.
/// (The old volume/channel rocker pair is gone with the channel rocker;
/// mute is a grid button now.) The +/− buttons are big targets with
/// an explicit full-frame hit area, and they repeat while held — like
/// the fork's KeyCap — so holding + or − keeps turning the volume.
/// The button height comes from the layout so the rocker fits the
/// shrunken bottom cell on short screens.
private struct VolRockerView: View {
    var buttonHeight: CGFloat
    var width: CGFloat
    var onUp: () -> Void
    var onDown: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            RepeatButton(action: onUp) {
                Image(systemName: "plus")
                    .font(.title.bold())
                    .foregroundStyle(.white)
                    .frame(width: width, height: buttonHeight)
            }
            Spacer()
            Text("VOL")
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
            Spacer()
            RepeatButton(action: onDown) {
                Image(systemName: "minus")
                    .font(.title.bold())
                    .foregroundStyle(.white)
                    .frame(width: width, height: buttonHeight)
            }
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }
}

/// A button that fires once on tap and repeats while held (the fork's
/// KeyCap with repeats: true). A quick tap sends one command; holding
/// past ~0.45 s repeats it every ~0.18 s until release.
private struct RepeatButton<Label: View>: View {
    var action: () -> Void
    @ViewBuilder var label: () -> Label
    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        Button(action: action) { label() }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 0.45, pressing: { pressing in
                if !pressing {
                    repeatTask?.cancel()
                    repeatTask = nil
                }
            }, perform: {
                repeatTask = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 180_000_000)
                        guard !Task.isCancelled else { break }
                        action()
                    }
                }
            })
    }
}

