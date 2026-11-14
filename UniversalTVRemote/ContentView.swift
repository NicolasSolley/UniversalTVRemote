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
                .navigationTitle("Universal Remote")
            }
        }
        .preferredColorScheme(.dark)
        .task {
            // Scan automatically on launch. The manual Scan button stays
            // available for re-scans; discovery itself is unchanged
            // (subnet sweep, scan-only, no manual IP entry).
            guard !didAutoScan else { return }
            didAutoScan = true
            if !discovery.isScanning {
                discovery.scan()
            }
        }
    }
}

// MARK: - Discovery

private struct DiscoveryListView: View {
    @ObservedObject var discovery: DiscoveryManager
    var onSelect: (TVDevice) -> Void

    /// True once a scan has finished at least once — drives the empty
    /// state (still scanning vs. nothing found). View-side only; the
    /// discovery code is untouched.
    @State private var hasCompletedScan = false

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [.cyan.opacity(0.35), .blue.opacity(0.25)],
                                startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .frame(width: 84, height: 84)
                    Image(systemName: "tv.and.mediabox")
                        .font(.system(size: 36))
                        .foregroundStyle(.cyan)
                }
                Text("Find TVs on your Wi-Fi")
                    .font(.title2.bold())
                Text("Connect your iPhone and TV to the same Wi-Fi network, then scan. Only TVs that answer the scan appear here.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
            .padding(.top, 12)

            HStack {
                Button {
                    discovery.scan()
                } label: {
                    Label(discovery.isScanning ? "Scanning…" : "Scan network",
                          systemImage: "dot.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(discovery.isScanning)
                Button("Stop") { discovery.stop() }
                    .buttonStyle(.bordered)
                    .disabled(!discovery.isScanning)
            }
            .padding(.horizontal)

            HStack(spacing: 6) {
                if discovery.isScanning { ProgressView().controlSize(.small) }
                Text(discovery.status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)

            if discovery.devices.isEmpty {
                emptyState
            } else {
                List(discovery.devices) { device in
                    Button { onSelect(device) } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(brandTint(for: device.brand).opacity(0.18))
                                    .frame(width: 48, height: 48)
                                Image(systemName: brandIcon(for: device.brand))
                                    .font(.title3)
                                    .foregroundStyle(brandTint(for: device.brand))
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(device.name)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text(subtitle(for: device))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if device.brand.supportsControl {
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            } else {
                                Text("Discovery only")
                                    .font(.caption2)
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(Color.white.opacity(0.08), in: Capsule())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .disabled(!device.brand.supportsControl)
                    .listRowBackground(Color.white.opacity(0.05))
                }
                .listStyle(.insetGrouped)
                .refreshable { discovery.scan() }
            }
        }
        .onChange(of: discovery.isScanning) { scanning in
            if !scanning { hasCompletedScan = true }
        }
    }

    /// Shown when no devices are listed yet: a scanning state while a
    /// scan is running (or has never run), and a "nothing found" state
    /// once a scan has finished empty.
    private var emptyState: some View {
        VStack(spacing: 12) {
            if discovery.isScanning || !hasCompletedScan {
                ProgressView()
                    .controlSize(.large)
                Text("Scanning for TVs…")
                    .font(.headline)
                Text("This usually takes a few seconds.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "tv.slash")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text("No TVs found")
                    .font(.headline)
                Text("Make sure your TV is on and on the same Wi-Fi network, then scan again.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button("Scan again") { discovery.scan() }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private func subtitle(for device: TVDevice) -> String {
        var parts: [String] = [device.brand.rawValue]
        if let model = device.model { parts.append(model) }
        parts.append(device.addressLine)
        if !device.brand.supportsControl {
            parts.append("— no public remote API")
        }
        return parts.joined(separator: " • ")
    }

    private func brandIcon(for brand: TVDevice.Brand) -> String {
        switch brand {
        case .roku: return "play.tv"
        case .samsung: return "tv"
        case .lg: return "tv.fill"
        case .androidTV: return "tv.and.mediabox"
        case .airPlay: return "airplayvideo"
        case .other: return "tv"
        }
    }

    private func brandTint(for brand: TVDevice.Brand) -> Color {
        switch brand {
        case .roku: return .purple
        case .samsung: return .blue
        case .lg: return .red
        case .androidTV: return .green
        case .airPlay: return .gray
        case .other: return .gray
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
