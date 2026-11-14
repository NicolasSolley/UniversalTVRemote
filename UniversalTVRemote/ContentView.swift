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
/// a header row (X, centered title, empty right), one dark card holding
/// the whole TV list, the same-wifi note underneath, and a small spinner
/// as the only scanning indicator. The scan runs automatically and
/// silently on launch (see ContentView); there is no scan button and no
/// scan progress UI — the list simply populates as TVs are found.
/// Pull-to-refresh re-scans.
private struct DiscoveryListView: View {
    @ObservedObject var discovery: DiscoveryManager
    var onSelect: (TVDevice) -> Void

    @Environment(\.dismiss) private var dismiss

    /// True once a scan has finished at least once — drives the empty
    /// state (still scanning vs. nothing found). View-side only; the
    /// discovery code is untouched.
    @State private var hasCompletedScan = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Header: X on the left, title centered, right kept
                // empty so the title stays centered. There is no ?
                // button (deliberately left out). The X dismisses this
                // screen; the device list is the app's root, so there
                // is no previous screen to return to and dismiss() is
                // a no-op here — the button exists to match the
                // reference layout.
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Text("Select a TV Device")
                        .font(.headline.bold())
                        .foregroundStyle(.white)
                    Spacer()
                    Color.clear.frame(width: 44, height: 44)
                }
                .padding(.horizontal, 8)

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

private struct RemoteView: View {
    @ObservedObject var session: RemoteSession
    var onBack: () -> Void

    @State private var navMode: NavMode = .touchpad
    @State private var keyboardText = ""
    @State private var showDigits = false

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

                // Power
                HStack {
                    Spacer()
                    Button { send(.power) } label: {
                        Image(systemName: "power")
                            .font(.title2.bold())
                            .foregroundStyle(.white)
                            .frame(width: 64, height: 64)
                            .background(Color.red.opacity(0.85), in: Circle())
                            .shadow(color: .red.opacity(0.4), radius: 14, y: 4)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                if session.device.brand == .lg {
                    Text("Power turns the TV off. Turn it back on with the TV's own remote.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                // Navigation: touchpad or D-pad
                Picker("Navigation", selection: $navMode) {
                    ForEach(NavMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                if navMode == .touchpad {
                    TouchpadView { send($0) }
                } else {
                    DPadView { send($0) }
                }

                // Volume + channel rockers
                HStack(spacing: 32) {
                    RockerView(
                        topIcon: "plus", topLabel: "Vol +",
                        centerIcon: "speaker.wave.2",
                        bottomIcon: "minus", bottomLabel: "Vol −",
                        onTop: { send(.volumeUp) },
                        onCenter: { send(.mute) },
                        onBottom: { send(.volumeDown) })
                    RockerView(
                        topIcon: "chevron.up", topLabel: "Ch +",
                        centerIcon: "list.bullet",
                        bottomIcon: "chevron.down", bottomLabel: "Ch −",
                        onTop: { send(.channelUp) },
                        onCenter: { send(.info) },
                        onBottom: { send(.channelDown) })
                }

                // Back / Home / Menu
                HStack(spacing: 18) {
                    remoteButton("Back", systemImage: "arrow.uturn.backward") { send(.back) }
                    remoteButton("Home", systemImage: "house") { send(.home) }
                    remoteButton("Menu", systemImage: "line.3.horizontal") { send(.menu) }
                }

                // Playback
                if session.capabilities.supportsPlayback {
                    HStack(spacing: 18) {
                        remoteButton(nil, systemImage: "backward.fill") { send(.rewind) }
                        remoteButton(nil, systemImage: "play.fill") { send(.play) }
                        if session.capabilities.supportsSeparatePause {
                            remoteButton(nil, systemImage: "pause.fill") { send(.pause) }
                            remoteButton(nil, systemImage: "stop.fill") { send(.stop) }
                        }
                        remoteButton(nil, systemImage: "forward.fill") { send(.fastForward) }
                    }
                }

                // Digits
                if session.capabilities.supportsDigits {
                    DisclosureGroup("Number pad", isExpanded: $showDigits) {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 10) {
                            ForEach(1...9, id: \.self) { n in
                                digitButton(n)
                            }
                            Color.clear.frame(height: 44)
                            digitButton(0)
                            Color.clear.frame(height: 44)
                        }
                        .padding(.top, 8)
                    }
                    .padding(12)
                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal)
                }

                // Keyboard / text input
                if session.capabilities.supportsTextInput {
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

                // Roku apps
                if session.capabilities.supportsApps, !session.rokuApps.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Apps")
                            .font(.headline)
                            .padding(.horizontal)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(session.rokuApps) { app in
                                    Button(app.name) {
                                        Task { await session.launchRokuApp(app) }
                                    }
                                    .buttonStyle(.bordered)
                                    .lineLimit(1)
                                }
                            }
                            .padding(.horizontal)
                        }
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

    @ViewBuilder
    private func remoteButton(_ title: String?, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage).font(.title3.bold())
                if let title { Text(title).font(.caption2) }
            }
            .frame(minWidth: 58, minHeight: 56)
            .padding(.horizontal, 6)
            .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func digitButton(_ n: Int) -> some View {
        Button("\(n)") { send(.digit(n)) }
            .font(.title3.bold())
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08), lineWidth: 1))
            .buttonStyle(.plain)
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
            .frame(height: 190)
            .padding(.horizontal)
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

// MARK: - D-Pad

private struct DPadView: View {
    var onCommand: (RemoteCommand) -> Void

    var body: some View {
        VStack(spacing: 10) {
            dpadButton(.up, systemImage: "chevron.up")
            HStack(spacing: 24) {
                dpadButton(.left, systemImage: "chevron.left")
                dpadButton(.enter, systemImage: "checkmark.circle.fill")
                dpadButton(.right, systemImage: "chevron.right")
            }
            dpadButton(.down, systemImage: "chevron.down")
        }
    }

    private func dpadButton(_ command: RemoteCommand, systemImage: String) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onCommand(command)
        } label: {
            Image(systemName: systemImage)
                .font(.title2.bold())
                .frame(width: 64, height: 56)
                .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Rocker (volume / channel)

private struct RockerView: View {
    var topIcon: String
    var topLabel: String
    var centerIcon: String
    var bottomIcon: String
    var bottomLabel: String
    var onTop: () -> Void
    var onCenter: () -> Void
    var onBottom: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Button(action: onTop) {
                VStack(spacing: 2) {
                    Image(systemName: topIcon).font(.title3.bold())
                    Text(topLabel).font(.caption2).foregroundStyle(.secondary)
                }
                .frame(width: 76, height: 56)
                .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08), lineWidth: 1))
            }
            .buttonStyle(.plain)
            Button(action: onCenter) {
                Image(systemName: centerIcon)
                    .font(.title3)
                    .frame(width: 76, height: 44)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08), lineWidth: 1))
            }
            .buttonStyle(.plain)
            Button(action: onBottom) {
                VStack(spacing: 2) {
                    Image(systemName: bottomIcon).font(.title3.bold())
                    Text(bottomLabel).font(.caption2).foregroundStyle(.secondary)
                }
                .frame(width: 76, height: 56)
                .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.white.opacity(0.08), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }
}
