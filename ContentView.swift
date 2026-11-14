import SwiftUI

struct ContentView: View {
    @StateObject private var discovery = DiscoveryManager()
    @State private var selected: TVDevice?
    @State private var commandStatus = "Select a discovered device"
    @State private var showPairingNote = false

    var body: some View {
        NavigationStack {
            Group {
                if let device = selected {
                    remoteView(for: device)
                } else {
                    discoveryView
                }
            }
            .navigationTitle("Universal Remote")
            .toolbar {
                if selected != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Devices") { selected = nil }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .alert("Pairing may be required", isPresented: $showPairingNote) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Samsung, LG, and Google/Android TVs commonly require an on-TV permission prompt, PIN, or device-specific pairing. This starter build discovers those devices; Roku currently has basic network key commands.")
        }
    }

    private var discoveryView: some View {
        VStack(spacing: 18) {
            Image(systemName: "tv.and.mediabox")
                .font(.system(size: 54))
                .foregroundStyle(.cyan)
                .padding(.top, 24)
            Text("Find TVs on your Wi-Fi")
                .font(.title2.bold())
            Text("Connect your iPhone and TV to the same Wi-Fi network, then scan.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            HStack {
                Button {
                    discovery.scan()
                } label: {
                    Label("Scan network", systemImage: "dot.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button("Stop") { discovery.stop() }
                    .buttonStyle(.bordered)
                    .disabled(!discovery.isScanning)
            }
            .padding(.horizontal)
            Text(discovery.status)
                .font(.footnote)
                .foregroundStyle(.secondary)
            List(discovery.devices) { device in
                Button {
                    selected = device
                    showPairingNote = device.brand != "Roku"
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "tv")
                            .font(.title2)
                            .foregroundStyle(.cyan)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(device.name).foregroundStyle(.primary)
                            Text("\(device.brand) • \(device.host ?? "Address pending")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private func remoteView(for device: TVDevice) -> some View {
        VStack(spacing: 22) {
            VStack(spacing: 4) {
                Text(device.name).font(.headline)
                Text("\(device.brand) • \(device.host ?? "No address resolved")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                remoteButton("power", symbol: "power")
                remoteButton("volume down", symbol: "speaker")
                remoteButton("volume up", symbol: "speaker.wave.2")
                remoteButton("mute", symbol: "speaker.slash")
            }
            .padding(.top, 12)
            VStack(spacing: 8) {
                remoteButton("up", symbol: "chevron.up")
                HStack(spacing: 28) {
                    remoteButton("left", symbol: "chevron.left")
                    remoteButton("select", symbol: "checkmark")
                    remoteButton("right", symbol: "chevron.right")
                }
                remoteButton("down", symbol: "chevron.down")
            }
            HStack(spacing: 18) {
                remoteButton("back", symbol: "arrow.uturn.backward")
                remoteButton("home", symbol: "house")
                remoteButton("info", symbol: "info")
            }
            Text(commandStatus)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            Text(device.brand == "Roku"
                 ? "Roku key commands are implemented in this starter."
                 : "Discovery is implemented. Control protocol and pairing for this brand still need to be added.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    @ViewBuilder
    private func remoteButton(_ title: String, symbol: String) -> some View {
        Button {
            Task { await send(command: title, to: selected) }
        } label: {
            Image(systemName: symbol)
                .font(.title3.bold())
                .frame(width: 58, height: 52)
                .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(selected?.host == nil)
    }

    @MainActor
    private func send(command: String, to device: TVDevice?) async {
        guard let device, let host = device.host else {
            commandStatus = "The TV address is not available."
            return
        }
        guard device.brand == "Roku" else {
            commandStatus = "This TV was discovered, but its control protocol is not implemented yet."
            return
        }
        let mapping = [
            "up": "Up", "down": "Down", "left": "Left", "right": "Right",
            "select": "Select", "back": "Back", "home": "Home",
            "volume up": "VolumeUp", "volume down": "VolumeDown",
            "mute": "VolumeMute", "power": "Power", "info": "Info"
        ]
        guard let key = mapping[command] else { return }
        do {
            try await RokuRemote.send(key: key, to: host)
            commandStatus = "Sent \(command)."
        } catch {
            commandStatus = "Couldn't reach the TV. Check that network control is enabled."
        }
    }
}
