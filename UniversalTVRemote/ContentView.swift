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
                RemoteView(session: session, onBack: { self.session = nil })
                    .navigationTitle(session.device.name)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button("Devices") { session.disconnect(); self.session = nil }
                        }
                    }
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

/// Apple TV-style remote, modeled on the reference "TV Remote" screen:
/// a header row (keyboard button, centered "TV Remote" title), a row
/// with Home, a D-pad/touchpad toggle, and Power, a big circular D-pad
/// (or the touchpad, behind the toggle), a button grid with a tall VOL
/// rocker on the right, and app shortcut cards at the bottom. Dark and
/// neutral throughout — no accent color, no ads, no promos. The screen
/// title in the navigation bar stays the TV's name (it identifies
/// which TV is being controlled); the in-content header reads
/// "TV Remote" as in the reference.
/// The big circular D-pad is the main navigation (default on open).
/// The touchpad stays as the alternate behind the toggle, but it is a
/// modest 230×230 square — the same footprint as the D-pad — not a
/// giant pad dominating the screen. Voice: a hold-to-talk mic button
/// in the lower section (Android TV only — the only platform whose
/// protocol carries phone mic audio).
/// Dropped to keep the layout clean: the number pad (digits were the
/// only way to type channel numbers directly) and the channel rocker
/// (channel up/down were the only way to change channels directly) —
/// neither has a replacement on this screen; use the TV's own remote
/// or the on-screen guide for channels. The Stop button is gone too
/// (no slot in the reference; Play/Pause covers transport). The
/// Input/exit button from the reference is omitted: no brand controller
/// has a verified source/input key, so it would be a dead button.
/// Replay sends Rewind (the closest transport command — the row below
/// has a Rewind button too, so both rewind). Star sends Info (on Roku
/// the * key IS the options/info key). Menu takes the omitted mic
/// button's slot in the last grid row. Play/Pause is one button with a
/// local toggle: it assumes the TV is playing, so the first tap sends
/// Pause, then it alternates — the TV's real play state is not tracked.
private struct RemoteView: View {
    @ObservedObject var session: RemoteSession
    var onBack: () -> Void

    @State private var navMode: NavMode = .dpad
    @State private var keyboardText = ""
    @State private var showKeyboard = false
    /// Assume the TV is playing until the user taps Play/Pause.
    @State private var isPlaying = true

    enum NavMode: String, CaseIterable {
        case touchpad = "Touchpad"
        case dpad = "D-Pad"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                statusBanner

                // Pairing code (Android TV): the TV shows a 6-character code.
                if session.awaitingPairingCode {
                    VStack(spacing: 10) {
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
                    .padding(14)
                    .background(Color.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.cyan.opacity(0.25), lineWidth: 1))
                    .padding(.horizontal)
                }

                // Header: keyboard button on the left (only where the
                // platform supports text input), "TV Remote" centered,
                // right kept empty (cast is out of scope — nothing in
                // its place).
                HStack {
                    if session.capabilities.supportsTextInput {
                        Button { showKeyboard.toggle() } label: {
                            Image(systemName: "keyboard")
                                .font(.headline)
                                .foregroundStyle(.white)
                                .frame(width: 44, height: 44)
                                .background(Color.white.opacity(0.10), in: Circle())
                        }
                        .buttonStyle(.plain)
                    } else {
                        Color.clear.frame(width: 44, height: 44)
                    }
                    Spacer()
                    Text("TV Remote")
                        .font(.headline.bold())
                        .foregroundStyle(.white)
                    Spacer()
                    Color.clear.frame(width: 44, height: 44)
                }
                .padding(.horizontal, 8)

                // Keyboard / text input, revealed by the header button.
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

                // Home / nav toggle / Power.
                HStack {
                    remoteSquareButton(systemImage: "house") { send(.home) }
                    Spacer()
                    navToggle
                    Spacer()
                    remoteSquareButton(systemImage: "power", tint: .red) { send(.power) }
                }
                .padding(.horizontal)
                if session.device.brand == .lg {
                    Text("Power turns the TV off. Turn it back on with the TV's own remote.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                // Navigation: big circular D-pad or touchpad, behind the toggle.
                if navMode == .dpad {
                    CircularDPadView { send($0) }
                } else {
                    TouchpadView { send($0) }
                }

                // Button grid + tall VOL rocker on the right.
                HStack(alignment: .top, spacing: 12) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                        remoteButton(nil, systemImage: "arrow.left") { send(.back) }
                        remoteButton(nil, systemImage: "arrow.counterclockwise") { send(.rewind) }
                        remoteButton(nil, systemImage: "star.fill") { send(.info) }
                        if session.capabilities.supportsPlayback {
                            remoteButton(nil, systemImage: "backward.fill") { send(.rewind) }
                            remoteButton(nil, systemImage: isPlaying ? "pause.fill" : "play.fill") {
                                send(isPlaying ? .pause : .play)
                                isPlaying.toggle()
                            }
                            remoteButton(nil, systemImage: "forward.fill") { send(.fastForward) }
                        }
                        remoteButton(nil, systemImage: "line.3.horizontal") { send(.menu) }
                        remoteButton(nil, systemImage: "speaker.slash.fill") { send(.mute) }
                    }
                    VolRockerView(onUp: { send(.volumeUp) }, onDown: { send(.volumeDown) })
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
                                    .frame(height: 56)
                                    .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08), lineWidth: 1))
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                }

                // Voice (Android TV only): hold the mic button and
                // talk — the TV acts on it. Shown only where voice is
                // actually implemented; never a dead button. Sits in
                // the lower section, near the app shortcuts.
                if session.capabilities.supportsVoice {
                    VStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .fill(session.isRecordingVoice
                                      ? Color.red.opacity(0.85)
                                      : Color.white.opacity(0.10))
                            Circle()
                                .stroke(Color.white.opacity(session.isRecordingVoice ? 0.4 : 0.08), lineWidth: 1)
                            Image(systemName: session.isRecordingVoice ? "mic.fill" : "mic")
                                .font(.title2)
                                .foregroundStyle(.white)
                        }
                        .frame(width: 72, height: 72)
                        .accessibilityLabel("Hold to talk")
                        .onLongPressGesture(minimumDuration: 0.15, pressing: { pressing in
                            if pressing {
                                Task { await session.startVoice() }
                            } else {
                                Task { await session.stopVoice() }
                            }
                        }, perform: {})
                        Text(session.isRecordingVoice ? "Listening…" : "Hold to talk")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Text(session.status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .padding(.bottom, 24)

                // Android TV pairing can be reset: clears the pinned
                // certificate and the paired flag so the next connect
                // pairs from scratch (needed when the TV's certificate
                // changed, e.g. after a TV reset).
                if session.device.brand == .androidTV {
                    Button("Forget this TV", role: .destructive) { session.forgetPairedTV() }
                        .buttonStyle(.bordered)
                        .padding(.bottom, 24)
                }
            }
            .padding(.top, 8)
        }
        .task { await session.connect() }
        .onDisappear { session.disconnect() }
    }

    private var statusBanner: some View {
        Group {
            if session.isBusy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(session.awaitingTVPrompt
                         ? "Check your TV and accept the connection prompt."
                         : "Connecting…")
                        .font(.subheadline)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            } else if !session.isConnected, session.supportsControl {
                Text("Not connected — tap a button to reconnect.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func send(_ command: RemoteCommand) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Task { await session.send(command) }
    }

    /// Segmented D-pad / touchpad toggle: two icon segments in a dark
    /// pill; the selected segment is highlighted. The keyboard is NOT
    /// part of this toggle — it has its own button in the header.
    private var navToggle: some View {
        HStack(spacing: 0) {
            toggleSegment(icon: "dpad", selected: navMode == .dpad, label: "D-Pad") { navMode = .dpad }
            toggleSegment(icon: "hand.tap", selected: navMode == .touchpad, label: "Touchpad") { navMode = .touchpad }
        }
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private func toggleSegment(icon: String, selected: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(selected ? .white : .secondary)
                .frame(width: 56, height: 44)
                .background(selected ? Color.white.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                .padding(2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// Dark rounded-square button for Home and Power in the header row.
    /// Power's icon is red; Home's is white.
    private func remoteSquareButton(systemImage: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3.bold())
                .foregroundStyle(tint)
                .frame(width: 56, height: 56)
                .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func remoteButton(_ title: String?, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage).font(.title3.bold())
                if let title { Text(title).font(.caption2) }
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            .padding(.horizontal, 6)
            .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
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
// MARK: - Touchpad

private struct TouchpadView: View {
    var onCommand: (RemoteCommand) -> Void

    var body: some View {
        RoundedRectangle(cornerRadius: 20)
            .fill(
                LinearGradient(
                    colors: [Color.white.opacity(0.10), Color.white.opacity(0.04)],
                    startPoint: .top, endPoint: .bottom)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            )
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: "hand.draw")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("Swipe to move  •  Tap to select")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 230, height: 230)
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
private struct CircularDPadView: View {
    var onCommand: (RemoteCommand) -> Void

    private let size: CGFloat = 230
    private let gap: CGFloat = 3 // degrees of gap on each side of a sector

    var body: some View {
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
                    .frame(width: 84, height: 84)
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
/// mute is a grid button now.)
private struct VolRockerView: View {
    var onUp: () -> Void
    var onDown: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onUp) {
                Image(systemName: "plus")
                    .font(.title3.bold())
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 56)
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
                    .frame(width: 64, height: 56)
            }
            .buttonStyle(.plain)
        }
        .frame(width: 64)
        .frame(maxHeight: .infinity)
        .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08), lineWidth: 1))
    }
}
