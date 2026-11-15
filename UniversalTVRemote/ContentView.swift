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
                // name, power, gear), so the navigation bar stays hidden
                // here — no double header.
                RemoteView(session: session, onBack: { self.session = nil })
                    .navigationBarHidden(true)
            } else {
                DiscoveryListView(discovery: discovery) { device in
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
/// name, power, gear), a Connected pill, a wide D-Pad | Swipe toggle,
/// then the navigation area, a playback row, a Back/Home/Exit pill
/// row, and a bottom row (Volume rocker, mic or keyboard, Mute), with
/// app shortcuts and the diagnostic status text below. Dark with a
/// blue accent. No ads,
/// no promos, no cast button, no tab bar.
/// What stays ours: the D-pad is the default navigation (big circular
/// pad, 230×230, annular sectors + 84pt OK); the playback row stays
/// even though the reference has none; the mic is hold-to-talk and
/// Android TV only; app shortcut cards stay where launching works.
/// Dropped to keep the layout clean: the number pad and the channel
/// rocker (use the TV's own remote or the on-screen guide for
/// channels). Play/Pause is one button with a local toggle: it assumes
/// the TV is playing, so the first tap sends Pause, then it alternates
/// — the TV's real play state is not tracked.
/// Sizing for the non-scrollable remote screen (v1.0.15: the remote page
/// never scrolls). Every section has a budgeted height, the D-pad / swipe
/// pad absorbs whatever height is left (down to a floor), and on short
/// screens the bottom row, buttons and spacing shrink too. Nothing is
/// dropped — the only things that hide are the diagnostic line (while the
/// pairing card or keyboard is up, since they show the status themselves)
/// and the LG power note on the shortest screens (it also lives in
/// Settings). Validated against iPhone 15 Plus (845pt), iPhone 13 mini
/// (731pt) and iPhone SE (647pt) usable heights, with and without apps,
/// pairing card and keyboard — every combination fits.
private struct RemoteLayout {
    var gap: CGFloat
    var topPadding: CGFloat
    var topBarButton: CGFloat
    var pairingCardPadding: CGFloat
    var pairingCardSpacing: CGFloat
    var padSize: CGFloat
    var transportSize: CGFloat
    var playSize: CGFloat
    var pillsButtonHeight: CGFloat
    var appsButtonHeight: CGFloat
    var bottomCell: CGFloat
    var circleSize: CGFloat
    var rockerButtonHeight: CGFloat
    var diagnosticLines: Int
    var showDiagnostic: Bool
    var showLGNote: Bool

    static func make(height h: CGFloat, hasApps: Bool, pairingShown: Bool,
                     keyboardShown: Bool, isLG: Bool, hasPlayback: Bool) -> RemoteLayout {
        let compact = h < 760
        let extraCompact = h < 680
        let gap: CGFloat = extraCompact ? 6 : (compact ? 8 : 10)
        let topPadding: CGFloat = extraCompact ? 4 : 8
        let topBarButton: CGFloat = extraCompact ? 40 : 44
        let pairingCardPadding: CGFloat = extraCompact ? 10 : (compact ? 12 : 14)
        let pairingCardSpacing: CGFloat = extraCompact ? 8 : (compact ? 9 : 10)
        let transportSize: CGFloat = extraCompact ? 48 : (compact ? 52 : 56)
        let playSize: CGFloat = extraCompact ? 56 : (compact ? 60 : 64)
        let pillsButtonHeight: CGFloat = extraCompact ? 44 : (compact ? 48 : 56)
        let appsButtonHeight: CGFloat = extraCompact ? 44 : (compact ? 48 : 56)
        let bottomCell: CGFloat = pairingShown ? (extraCompact ? 90 : 110)
            : (extraCompact ? 110 : (compact ? 130 : 140))
        let circleSize = min(88, bottomCell * 0.55)
        let rockerButtonHeight = max(28, min(56, bottomCell * 0.32))
        let showDiagnostic = !pairingShown && !keyboardShown
        let diagnosticLines = compact ? 2 : 3
        let showLGNote = isLG && !extraCompact

        // Budgeted heights of every section except the pad.
        var fixed: CGFloat = topPadding + topBarButton
        if pairingShown { fixed += extraCompact ? 155 : (compact ? 165 : 170) }
        if keyboardShown { fixed += extraCompact ? 36 : (compact ? 40 : 44) }
        fixed += 38 // connection pill
        if showLGNote { fixed += 16 }
        fixed += 54 // nav toggle
        if hasPlayback { fixed += playSize }
        fixed += pillsButtonHeight + 6 + 16 // pills row + label
        if hasApps { fixed += 22 + 8 + appsButtonHeight } // "Apps" + buttons
        fixed += bottomCell + 6 + 16 // bottom row + labels
        if showDiagnostic { fixed += CGFloat(diagnosticLines) * 17 }
        // Gaps between sections.
        var sections = 8 // topBar, pill, toggle, pad, playback, pills, bottom, diagnostic
        if pairingShown { sections += 1 }
        if keyboardShown { sections += 1 }
        if showLGNote { sections += 1 }
        if hasApps { sections += 1 }
        if !hasPlayback { sections -= 1 }
        if !showDiagnostic { sections -= 1 }
        let gaps = CGFloat(sections - 1) * gap
        // The pad absorbs the rest, down to a floor (lower while the
        // pairing card or keyboard is up — the pad isn't the focus then).
        let floor: CGFloat = pairingShown ? 80 : (keyboardShown ? 60 : 100)
        let padSize = min(230, max(floor, h - fixed - gaps))

        return RemoteLayout(gap: gap, topPadding: topPadding, topBarButton: topBarButton,
                            pairingCardPadding: pairingCardPadding, pairingCardSpacing: pairingCardSpacing,
                            padSize: padSize, transportSize: transportSize, playSize: playSize,
                            pillsButtonHeight: pillsButtonHeight, appsButtonHeight: appsButtonHeight,
                            bottomCell: bottomCell, circleSize: circleSize,
                            rockerButtonHeight: rockerButtonHeight,
                            diagnosticLines: diagnosticLines, showDiagnostic: showDiagnostic,
                            showLGNote: showLGNote)
    }
}

private struct RemoteView: View {
    @ObservedObject var session: RemoteSession
    var onBack: () -> Void

    @State private var navMode: NavMode = .dpad
    @State private var keyboardText = ""
    @State private var showKeyboard = false
    @State private var showSettings = false
    /// Assume the TV is playing until the user taps Play/Pause.
    @State private var isPlaying = true

    enum NavMode: String, CaseIterable {
        case swipe = "Swipe"
        case dpad = "D-Pad"
    }

    var body: some View {
        // No ScrollView on the remote (v1.0.15): everything fits on one
        // page. The layout sizes itself from the available height — the
        // D-pad / swipe pad absorbs the slack, and on short screens the
        // bottom row, buttons and spacing shrink too. Nothing is dropped.
        GeometryReader { geo in
            let layout = RemoteLayout.make(
                height: geo.size.height,
                hasApps: session.capabilities.supportsApps && !sortedApps.isEmpty,
                pairingShown: session.awaitingPairingCode,
                keyboardShown: showKeyboard && session.capabilities.supportsTextInput,
                isLG: session.device.brand == .lg,
                hasPlayback: session.capabilities.supportsPlayback)
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

                // Wide D-Pad | Swipe toggle.
                navToggle

                // Navigation: big circular D-pad or the big swipe pad,
                // behind the toggle. D-pad is the default. Both size
                // from the layout so the page fits without scrolling.
                if navMode == .dpad {
                    CircularDPadView(size: layout.padSize) { send($0) }
                } else {
                    SwipePadView(height: layout.padSize) { send($0) }
                        .padding(.horizontal)
                }

                // Playback row (ours — the reference has none, but
                // transport is core): just Rewind / Play-Pause /
                // Fast-forward, centered as a trio. Play/Pause is the
                // blue-filled primary control.
                if session.capabilities.supportsPlayback {
                    HStack(spacing: 20) {
                        transportButton(systemImage: "backward.fill", size: layout.transportSize) { send(.rewind) }
                        Button {
                            send(isPlaying ? .pause : .play)
                            isPlaying.toggle()
                        } label: {
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.title2.bold())
                                .foregroundStyle(.white)
                                .frame(width: layout.playSize, height: layout.playSize)
                                .background(remoteAccent, in: Circle())
                        }
                        .buttonStyle(.plain)
                        transportButton(systemImage: "forward.fill", size: layout.transportSize) { send(.fastForward) }
                    }
                }

                // Back / Home / Exit pill row with labels underneath.
                HStack(spacing: 16) {
                    pillButton(systemImage: "arrow.left", label: "Back", height: layout.pillsButtonHeight) { send(.back) }
                    pillButton(systemImage: "house", label: "Home", height: layout.pillsButtonHeight) { send(.home) }
                    pillButton(systemImage: "rectangle.portrait.and.arrow.right", label: "Exit", height: layout.pillsButtonHeight) { send(.exit) }
                }
                .padding(.horizontal)

                // Installed apps: only the apps actually installed on
                // the TV (Netflix, YouTube, Apple TV first when
                // present). An empty list hides the row entirely — no
                // dead buttons.
                if session.capabilities.supportsApps, !sortedApps.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Apps")
                            .font(.headline)
                            .padding(.horizontal)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(sortedApps, id: \.id) { app in
                                    Button(app.name) {
                                        Task { await session.launchApp(id: app.id) }
                                    }
                                    .font(.subheadline.bold())
                                    .lineLimit(1)
                                    .padding(.horizontal, 16)
                                    .frame(height: layout.appsButtonHeight)
                                    .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08), lineWidth: 1))
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                }

                // Bottom row: three equal columns on one axis — the
                // Volume rocker, the big mic circle (Android TV only)
                // or the keyboard button (Roku/Samsung/LG), and the
                // Mute square. Every control sits in a layout-sized
                // cell so the three share top and bottom edges, and the
                // labels sit on one shared baseline below. Nothing
                // here is ever a dead button.
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 6) {
                        VolRockerView(buttonHeight: layout.rockerButtonHeight, onUp: { send(.volumeUp) }, onDown: { send(.volumeDown) })
                            .frame(height: layout.bottomCell)
                        Text("Volume")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    if session.capabilities.supportsVoice {
                        // Voice (Android TV only): hold the mic button
                        // and talk — the TV acts on it.
                        VStack(spacing: 6) {
                            ZStack {
                                Circle()
                                    .fill(session.isRecordingVoice
                                          ? Color.red.opacity(0.85)
                                          : Color.white.opacity(0.10))
                                Circle()
                                    .stroke(session.isRecordingVoice ? Color.red.opacity(0.6) : remoteAccent, lineWidth: 2.5)
                                Image(systemName: session.isRecordingVoice ? "mic.fill" : "mic")
                                    .font(.title)
                                    .foregroundStyle(.white)
                            }
                            .frame(width: layout.circleSize, height: layout.circleSize)
                            .accessibilityLabel("Hold to talk")
                            .onLongPressGesture(minimumDuration: 0.15, pressing: { pressing in
                                if pressing {
                                    Task { await session.startVoice() }
                                } else {
                                    Task { await session.stopVoice() }
                                }
                            }, perform: {})
                            .frame(height: layout.bottomCell)
                            Text(session.isRecordingVoice ? "Listening…" : "Hold to talk")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    } else if session.capabilities.supportsTextInput {
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
        .sheet(isPresented: $showSettings) {
            RemoteSettingsSheet(session: session)
        }
    }

    /// Top bar: Devices pill (back to the list), TV name centered,
    /// power and gear on the right. The gear opens the settings sheet.
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
            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.headline)
                    .foregroundStyle(.white)
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

    /// Wide D-Pad | Swipe segmented toggle: icon + label per segment,
    /// the selected one filled blue. D-pad is the default mode.
    private var navToggle: some View {
        HStack(spacing: 0) {
            toggleSegment(icon: "dpad", label: "D-Pad", selected: navMode == .dpad) { navMode = .dpad }
            toggleSegment(icon: "hand.tap", label: "Swipe", selected: navMode == .swipe) { navMode = .swipe }
        }
        .padding(3)
        .background(Color.white.opacity(0.08), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
        .padding(.horizontal)
    }

    private func toggleSegment(icon: String, label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title3)
                Text(label)
                    .font(.headline)
            }
            .foregroundStyle(selected ? .white : .secondary)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(selected ? remoteAccent : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// Circular transport button (Rewind, Fast-forward):
    /// dark circle, white icon.
    private func transportButton(systemImage: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3.bold())
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Color.white.opacity(0.10), in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
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

    /// Installed apps for the current brand, with the three big ones
    /// first (Netflix, YouTube, Apple TV) when the TV has them, then
    /// the rest in the TV's own order. Only installed apps are ever
    /// shown — no dead shortcut buttons.
    private var sortedApps: [(id: String, name: String)] {
        let apps: [(id: String, name: String)]
        switch session.device.brand {
        case .roku: apps = session.rokuApps.map { ($0.id, $0.name) }
        case .samsung: apps = session.samsungApps.map { ($0.id, $0.name) }
        case .lg: apps = session.lgApps.map { ($0.id, $0.name) }
        case .androidTV, .airPlay, .other: apps = []
        }
        let priority = ["netflix", "youtube", "apple tv"]
        return apps.sorted { a, b in
            let aRank = priority.firstIndex(of: a.name.lowercased()) ?? Int.max
            let bRank = priority.firstIndex(of: b.name.lowercased()) ?? Int.max
            return aRank < bRank
        }
    }
}
// MARK: - Swipe pad

/// Big swipe pad (the Swipe half of the toggle): near full-width,
/// with directional chevrons around a hand and "Swipe to navigate".
/// One drag is one command on release (tap = select) — the same
/// gesture as the old touchpad, only the size and the look changed.
/// The height comes from the layout; the inner content scales down
/// with it (and the label drops off when short) so the pad fits the
/// non-scrollable page on small phones.
private struct SwipePadView: View {
    var height: CGFloat
    var onCommand: (RemoteCommand) -> Void

    var body: some View {
        let scale = max(0.4, min(1, height / 300))
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
            .overlay {
                VStack(spacing: 22 * scale) {
                    Image(systemName: "chevron.up")
                        .font(.title2.bold())
                        .foregroundStyle(.secondary)
                    HStack(spacing: 56 * scale) {
                        Image(systemName: "chevron.left")
                            .font(.title2.bold())
                            .foregroundStyle(.secondary)
                        Image(systemName: "hand.tap")
                            .font(.system(size: 44 * scale))
                            .foregroundStyle(.white.opacity(0.85))
                        Image(systemName: "chevron.right")
                            .font(.title2.bold())
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.down")
                        .font(.title2.bold())
                        .foregroundStyle(.secondary)
                    if height >= 140 {
                        Text("Swipe to navigate")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
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

// MARK: - Circular D-Pad

/// Big circular D-pad: four curved directional segments (annular
/// sectors with small gaps) around a central round OK button. Dark and
/// neutral — no accent color. Taps are hit-tested against the sector
/// shape itself, so the corners of the square frame do nothing.
/// The size comes from the layout so the page fits without scrolling;
/// the OK button never shrinks below a tappable 44pt.
private struct CircularDPadView: View {
    var size: CGFloat
    var onCommand: (RemoteCommand) -> Void

    private let gap: CGFloat = 3 // degrees of gap on each side of a sector

    var body: some View {
        let okSize = max(44, size * 84 / 230)
        ZStack {
            // Base disc: shows through the gaps between segments.
            Circle()
                .fill(Color.white.opacity(0.05))
                .frame(width: size, height: size)
            sector(.up, systemImage: "chevron.up", startAngle: -135, endAngle: -45)
            sector(.right, systemImage: "chevron.right", startAngle: -45, endAngle: 45)
            sector(.down, systemImage: "chevron.down", startAngle: 45, endAngle: 135)
            sector(.left, systemImage: "chevron.left", startAngle: 135, endAngle: 225)
            // Central OK button.
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                onCommand(.enter)
            } label: {
                Text("OK")
                    .font(.headline.bold())
                    .foregroundStyle(.white)
                    .frame(width: okSize, height: okSize)
                    .background(Color.white.opacity(0.12), in: Circle())
                    .overlay(Circle().stroke(Color.white.opacity(0.10), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .frame(width: size, height: size)
    }

    private func sector(_ command: RemoteCommand, systemImage: String, startAngle: Double, endAngle: Double) -> some View {
        let shape = AnnularSector(startAngle: .degrees(startAngle + gap), endAngle: .degrees(endAngle - gap))
        let midAngle = (startAngle + endAngle) / 2
        let midRadius = (size / 2) * (1 + 0.38) / 2 // between inner and outer radius
        let radians = midAngle * .pi / 180
        let x = size / 2 + midRadius * cos(radians)
        let y = size / 2 + midRadius * sin(radians)
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onCommand(command)
        } label: {
            ZStack {
                shape.fill(Color.white.opacity(0.10))
                Image(systemName: systemImage)
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                    .position(x: x, y: y)
            }
            .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .contentShape(shape)
    }
}

/// One annular sector (a ring segment): an outer arc, an inner arc back,
/// closed. Angles use SwiftUI's convention (0° = east, positive =
/// clockwise, since y grows downward).
private struct AnnularSector: Shape {
    var startAngle: Angle
    var endAngle: Angle
    var innerFraction: CGFloat = 0.38

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * innerFraction
        var path = Path()
        path.addArc(center: center, radius: outer, startAngle: startAngle, endAngle: endAngle, clockwise: false)
        path.addArc(center: center, radius: inner, startAngle: endAngle, endAngle: startAngle, clockwise: true)
        path.closeSubpath()
        return path
    }
}

// MARK: - Volume rocker

/// Tall volume rocker: + on top, a VOL label in the middle, − at the
/// bottom. It stretches to the height of the button grid beside it.
/// (The old volume/channel rocker pair is gone with the channel rocker;
/// mute is a grid button now.) The +/− button height comes from the
/// layout so the rocker fits the shrunken bottom cell on short screens.
private struct VolRockerView: View {
    var buttonHeight: CGFloat
    var onUp: () -> Void
    var onDown: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onUp) {
                Image(systemName: "plus")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                    .frame(width: 64, height: buttonHeight)
            }
            .buttonStyle(.plain)
            Spacer()
            Text("VOL")
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: onDown) {
                Image(systemName: "minus")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                    .frame(width: 64, height: buttonHeight)
            }
            .buttonStyle(.plain)
        }
        .frame(width: 64)
        .frame(maxHeight: .infinity)
        .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }
}

// MARK: - Settings sheet

/// Settings sheet (gear in the top bar): connection status and
/// diagnostics, the TV's identity, and — for Android TV — the
/// "Forget this TV" reset. Nothing here sends a command to the TV
/// except Forget (which only clears local pairing state).
private struct RemoteSettingsSheet: View {
    @ObservedObject var session: RemoteSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Settings")
                    .font(.headline.bold())
                    .foregroundStyle(.white)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.bordered)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Connection")
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                HStack(spacing: 8) {
                    Circle()
                        .fill(session.isConnected ? Color.green : (session.isBusy ? Color.orange : Color.red))
                        .frame(width: 9, height: 9)
                    Text(session.isConnected ? "Connected to \(session.device.name)" : "Not connected")
                        .font(.subheadline)
                        .foregroundStyle(.white)
                }
                Text("Brand: \(session.device.brand.rawValue)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let host = session.device.host {
                    Text("Address: \(host)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Status")
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                Text(session.status.isEmpty ? "No status yet." : session.status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if session.device.brand == .lg {
                Text("Power turns the TV off. Turn it back on with the TV's own remote.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if session.device.brand == .androidTV {
                // Pairing reset: clears the pinned certificate and the
                // paired flag so the next connect pairs from scratch
                // (needed when the TV's certificate changed, e.g. after
                // a TV reset).
                Button("Forget this TV", role: .destructive) { session.forgetPairedTV() }
                    .buttonStyle(.bordered)
            }

            Spacer()
        }
        .padding()
        .background(Color(white: 0.08))
    }
}
