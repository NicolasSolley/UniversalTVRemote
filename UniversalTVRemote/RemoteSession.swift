import Foundation
import Combine

/// The canonical set of remote commands the UI can issue. Each brand
/// controller maps these onto its own protocol; commands a brand cannot
/// perform are hidden from the UI via `RemoteCapabilities`.
enum RemoteCommand {
    case power
    case volumeUp, volumeDown, mute
    case channelUp, channelDown
    case up, down, left, right, enter
    case back, home, info, menu
    case play, pause, stop, rewind, fastForward
    case digit(Int)
    case text(String)
}

/// What a brand's controller can actually do. The UI renders only the
/// controls a brand supports — a button that cannot work is absent, never
/// shown disabled-and-dead.
struct RemoteCapabilities {
    let supportsDigits: Bool
    let supportsTextInput: Bool
    let supportsApps: Bool
    let supportsSeparatePause: Bool
    let supportsPlayback: Bool
    /// Pairing needs an on-TV Allow prompt (Samsung, LG).
    let needsTVPrompt: Bool
    /// Pairing needs a code shown on the TV typed into the app (Android TV).
    let needsPairingCode: Bool

    static func forBrand(_ brand: TVDevice.Brand) -> RemoteCapabilities {
        switch brand {
        case .roku:
            return RemoteCapabilities(
                supportsDigits: false, supportsTextInput: true, supportsApps: true,
                supportsSeparatePause: false, supportsPlayback: true,
                needsTVPrompt: false, needsPairingCode: false)
        case .samsung:
            return RemoteCapabilities(
                supportsDigits: true, supportsTextInput: true, supportsApps: false,
                supportsSeparatePause: true, supportsPlayback: true,
                needsTVPrompt: true, needsPairingCode: false)
        case .lg:
            return RemoteCapabilities(
                supportsDigits: true, supportsTextInput: true, supportsApps: false,
                supportsSeparatePause: true, supportsPlayback: true,
                needsTVPrompt: true, needsPairingCode: false)
        case .androidTV:
            // Text input is not implemented (IME batch edits need live
            // counters that cannot be verified without a real TV), so the
            // keyboard is hidden for Android TV.
            return RemoteCapabilities(
                supportsDigits: true, supportsTextInput: false, supportsApps: false,
                supportsSeparatePause: true, supportsPlayback: true,
                needsTVPrompt: false, needsPairingCode: true)
        case .airPlay, .other:
            return RemoteCapabilities(
                supportsDigits: false, supportsTextInput: false, supportsApps: false,
                supportsSeparatePause: false, supportsPlayback: false,
                needsTVPrompt: false, needsPairingCode: false)
        }
    }
}

/// Owns the connection to one selected TV and translates `RemoteCommand`s
/// into the brand's real protocol. All failure states surface as
/// plain-language status text; nothing is faked.
@MainActor
final class RemoteSession: ObservableObject {
    let device: TVDevice
    let capabilities: RemoteCapabilities

    @Published var status: String = ""
    @Published var isConnected = false
    @Published var isBusy = false
    /// True while the user must do something on the TV (accept a prompt).
    @Published var awaitingTVPrompt = false
    /// True while the app is waiting for the user to type a pairing code.
    @Published var awaitingPairingCode = false
    /// The pairing code the user typed (6 hex characters for Android TV).
    @Published var pairingCode = ""
    @Published var rokuApps: [RokuRemote.RokuApp] = []

    private let samsung = SamsungRemote()
    private let lg: LGRemote
    private let androidTV = AndroidTVRemote()
    /// Continuation the Android TV code provider is waiting on.
    private var codeContinuation: CheckedContinuation<String, Error>?

    init(device: TVDevice) {
        self.device = device
        self.capabilities = RemoteCapabilities.forBrand(device.brand)
        self.lg = LGRemote(host: device.host ?? "")
    }

    var supportsControl: Bool { device.brand.supportsControl }

    // MARK: - Connection

    /// Connects (or verifies reachability) and reports progress in `status`.
    func connect() async {
        guard supportsControl else {
            status = "This device was found, but there's no public way to control it from an app."
            return
        }
        guard let host = device.host else {
            status = "Still waiting for this TV's address — try scanning again."
            return
        }
        isBusy = true
        defer { isBusy = false }
        switch device.brand {
        case .roku:
            status = "Checking the TV…"
            if let model = await RokuRemote.modelName(on: host) {
                isConnected = true
                status = "Connected to \(model)."
                await loadRokuApps()
            } else {
                isConnected = false
                status = "Couldn't reach the TV. Make sure it's on and on the same Wi-Fi network."
            }
        case .samsung:
            status = "Connecting… accept the prompt on your TV if one appears."
            awaitingTVPrompt = true
            defer { awaitingTVPrompt = false }
            do {
                try await samsung.connect(to: host)
                isConnected = true
                status = "Connected to \(device.name)."
            } catch let error as SamsungRemote.SamsungError {
                isConnected = false
                status = error.localizedDescription
            } catch {
                isConnected = false
                status = "Couldn't connect to the TV. Make sure it's on and on the same Wi-Fi network."
            }
        case .lg:
            status = "Connecting… accept the prompt on your TV if one appears."
            awaitingTVPrompt = true
            defer { awaitingTVPrompt = false }
            do {
                try await lg.connect()
                isConnected = true
                status = "Connected to \(device.name)."
            } catch let error as LGError {
                isConnected = false
                status = error.localizedDescription
            } catch {
                isConnected = false
                status = "Couldn't connect to the TV. Make sure it's on and on the same Wi-Fi network."
            }
        case .androidTV:
            status = "Connecting…"
            defer { awaitingPairingCode = false }
            do {
                try await androidTV.connect(to: host) { [weak self] in
                    guard let self else { throw CancellationError() }
                    self.awaitingPairingCode = true
                    self.status = "A 6-character code is showing on your TV — type it below."
                    // No timeout here: the user exits via Pair/Cancel, and
                    // disconnect() resumes this continuation if the view
                    // goes away. (A timeout that cancelled this task would
                    // leave the continuation suspended forever.)
                    return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                        self.codeContinuation = continuation
                    }
                }
                isConnected = true
                status = "Connected to \(device.name)."
            } catch is CancellationError {
                isConnected = false
                status = "Pairing cancelled."
            } catch let error as AndroidTVRemote.AndroidTVError {
                isConnected = false
                var text = error.localizedDescription
                // The 6466 probe is non-fatal, but if pairing then fails
                // too, what the probe saw is the first diagnostic clue.
                if let note = await androidTV.lastProbeNote {
                    text += " \(note)"
                }
                // Same for the plain-TCP Network.framework check: it says
                // whether the guest's NWConnection path itself reaches
                // the TV, as opposed to the TLS handshake failing.
                if let check = await androidTV.lastTCPCheck {
                    text += " \(check)"
                }
                // And the no-identity TLS probe: it says whether the TV
                // presents its certificate when we offer no client
                // identity at all — the discriminator for errSSLBadCert.
                if let probe = await androidTV.lastNoIdentityProbe {
                    text += " \(probe)"
                }
                status = text
            } catch {
                isConnected = false
                status = "Couldn't connect to the TV. Make sure it's on and on the same Wi-Fi network."
            }
        case .airPlay, .other:
            status = "This device was found, but there's no public way to control it from an app."
        }
    }

    func disconnect() {
        codeContinuation?.resume(throwing: CancellationError())
        codeContinuation = nil
        awaitingPairingCode = false
        Task { await samsung.disconnect() }
        Task { await lg.disconnect() }
        Task { await androidTV.disconnect() }
        isConnected = false
    }

    /// Called by the pairing-code UI when the user submits the code.
    func submitPairingCode() {
        let code = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count == 6 else {
            status = "Enter the 6-character code shown on your TV."
            return
        }
        pairingCode = ""
        awaitingPairingCode = false
        codeContinuation?.resume(returning: code)
        codeContinuation = nil
    }

    /// Called by the pairing-code UI when the user cancels pairing.
    func cancelPairing() {
        pairingCode = ""
        awaitingPairingCode = false
        codeContinuation?.resume(throwing: CancellationError())
        codeContinuation = nil
    }

    /// Forget the Android TV pairing: clears the pinned server
    /// certificate and the paired flag so the next connect pairs from
    /// scratch (e.g. after the TV's certificate changed). No-op for
    /// other brands.
    func forgetPairedTV() {
        guard device.brand == .androidTV, let host = device.host else { return }
        Task { await androidTV.forget(host: host) }
        isConnected = false
        status = "Forgot \(device.name). Pair again to connect."
    }

    // MARK: - Commands

    func send(_ command: RemoteCommand) async {
        guard supportsControl, let host = device.host else { return }
        do {
            switch device.brand {
            case .roku:
                try await sendRoku(command, to: host)
            case .samsung:
                try await sendSamsung(command, to: host)
            case .lg:
                try await sendLG(command)
            case .androidTV:
                try await sendAndroidTV(command, to: host)
            case .airPlay, .other:
                return
            }
            if case .text = command {
                status = "Text sent."
            } else {
                status = "Sent."
            }
        } catch let error as SamsungRemote.SamsungError {
            // A wake signal is a success of a different kind.
            status = error.localizedDescription
            if case .wakeSignalSent = error { isConnected = false }
        } catch let error as LGError {
            isConnected = false
            status = error.localizedDescription
        } catch let error as AndroidTVRemote.AndroidTVError {
            isConnected = false
            status = error.localizedDescription
        } catch {
            isConnected = false
            status = "Couldn't reach the TV. Check that it's on and on the same Wi-Fi network."
        }
    }

    private func sendRoku(_ command: RemoteCommand, to host: String) async throws {
        switch command {
        case .power: try await RokuRemote.send(key: "Power", to: host)
        case .volumeUp: try await RokuRemote.send(key: "VolumeUp", to: host)
        case .volumeDown: try await RokuRemote.send(key: "VolumeDown", to: host)
        case .mute: try await RokuRemote.send(key: "VolumeMute", to: host)
        case .channelUp: try await RokuRemote.send(key: "ChannelUp", to: host)
        case .channelDown: try await RokuRemote.send(key: "ChannelDown", to: host)
        case .up: try await RokuRemote.send(key: "Up", to: host)
        case .down: try await RokuRemote.send(key: "Down", to: host)
        case .left: try await RokuRemote.send(key: "Left", to: host)
        case .right: try await RokuRemote.send(key: "Right", to: host)
        case .enter: try await RokuRemote.send(key: "Select", to: host)
        case .back: try await RokuRemote.send(key: "Back", to: host)
        case .home: try await RokuRemote.send(key: "Home", to: host)
        case .info: try await RokuRemote.send(key: "Info", to: host)
        case .menu: try await RokuRemote.send(key: "Search", to: host)
        case .play, .pause: try await RokuRemote.send(key: "Play", to: host)
        case .stop: try await RokuRemote.send(key: "Play", to: host)
        case .rewind: try await RokuRemote.send(key: "Rev", to: host)
        case .fastForward: try await RokuRemote.send(key: "Fwd", to: host)
        case .digit: break // Roku has no digit keys; the UI hides them.
        case .text(let text): try await RokuRemote.sendText(text, to: host)
        }
    }

    private func sendSamsung(_ command: RemoteCommand, to host: String) async throws {
        switch command {
        case .power: try await samsung.sendPower(to: host)
        case .volumeUp: try await samsung.sendKey(.volumeUp, to: host)
        case .volumeDown: try await samsung.sendKey(.volumeDown, to: host)
        case .mute: try await samsung.sendKey(.mute, to: host)
        case .channelUp: try await samsung.sendKey(.channelUp, to: host)
        case .channelDown: try await samsung.sendKey(.channelDown, to: host)
        case .up: try await samsung.sendKey(.up, to: host)
        case .down: try await samsung.sendKey(.down, to: host)
        case .left: try await samsung.sendKey(.left, to: host)
        case .right: try await samsung.sendKey(.right, to: host)
        case .enter: try await samsung.sendKey(.enter, to: host)
        case .back: try await samsung.sendKey(.back, to: host)
        case .home: try await samsung.sendKey(.home, to: host)
        case .info: try await samsung.sendKey(.info, to: host)
        case .menu: try await samsung.sendKey(.menu, to: host)
        case .play: try await samsung.sendKey(.play, to: host)
        case .pause: try await samsung.sendKey(.pause, to: host)
        case .stop: try await samsung.sendKey(.stop, to: host)
        case .rewind: try await samsung.sendKey(.rewind, to: host)
        case .fastForward: try await samsung.sendKey(.fastForward, to: host)
        case .digit(let n):
            if let key = SamsungRemote.Key.digit(n) {
                try await samsung.sendKey(key, to: host)
            }
        case .text(let text): try await samsung.sendText(text, to: host)
        }
    }

    private func sendLG(_ command: RemoteCommand) async throws {
        switch command {
        // Power on LG is power-off only (no verified Wake-on-LAN source);
        // the UI says so next to the power button.
        case .power: try await lg.powerOff()
        case .volumeUp: try await lg.volumeUp()
        case .volumeDown: try await lg.volumeDown()
        case .mute: try await lg.toggleMute()
        case .channelUp: try await lg.channelUp()
        case .channelDown: try await lg.channelDown()
        case .up: try await lg.dpadUp()
        case .down: try await lg.dpadDown()
        case .left: try await lg.dpadLeft()
        case .right: try await lg.dpadRight()
        case .enter: try await lg.enter()
        case .back: try await lg.back()
        case .home: try await lg.home()
        case .info: try await lg.info()
        case .menu: try await lg.menu()
        case .play: try await lg.play()
        case .pause: try await lg.pause()
        case .stop: try await lg.stop()
        case .rewind: try await lg.rewind()
        case .fastForward: try await lg.fastForward()
        case .digit(let n): try await lg.digit(n)
        case .text(let text): try await lg.sendText(text)
        }
    }

    private func sendAndroidTV(_ command: RemoteCommand, to host: String) async throws {
        switch command {
        case .power: try await androidTV.sendKey(.power, to: host)
        case .volumeUp: try await androidTV.sendKey(.volumeUp, to: host)
        case .volumeDown: try await androidTV.sendKey(.volumeDown, to: host)
        case .mute: try await androidTV.sendKey(.volumeMute, to: host)
        case .channelUp: try await androidTV.sendKey(.channelUp, to: host)
        case .channelDown: try await androidTV.sendKey(.channelDown, to: host)
        case .up: try await androidTV.sendKey(.dpadUp, to: host)
        case .down: try await androidTV.sendKey(.dpadDown, to: host)
        case .left: try await androidTV.sendKey(.dpadLeft, to: host)
        case .right: try await androidTV.sendKey(.dpadRight, to: host)
        case .enter: try await androidTV.sendKey(.dpadCenter, to: host)
        case .back: try await androidTV.sendKey(.back, to: host)
        case .home: try await androidTV.sendKey(.home, to: host)
        case .info: try await androidTV.sendKey(.info, to: host)
        case .menu: try await androidTV.sendKey(.menu, to: host)
        case .play: try await androidTV.sendKey(.mediaPlay, to: host)
        case .pause: try await androidTV.sendKey(.mediaPause, to: host)
        case .stop: try await androidTV.sendKey(.mediaStop, to: host)
        case .rewind: try await androidTV.sendKey(.mediaRewind, to: host)
        case .fastForward: try await androidTV.sendKey(.mediaFastForward, to: host)
        case .digit(let n):
            if let key = AndroidTVRemote.Key.digit(n) {
                try await androidTV.sendKey(key, to: host)
            }
        case .text: break // Not implemented; the UI hides the keyboard.
        }
    }

    // MARK: - Roku apps

    func loadRokuApps() async {
        guard device.brand == .roku, let host = device.host else { return }
        rokuApps = await RokuRemote.apps(on: host)
    }

    func launchRokuApp(_ app: RokuRemote.RokuApp) async {
        guard let host = device.host else { return }
        do {
            try await RokuRemote.launch(appId: app.id, on: host)
            status = "Opening \(app.name)."
        } catch {
            status = "Couldn't open \(app.name)."
        }
    }
}
