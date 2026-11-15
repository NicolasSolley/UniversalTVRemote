import Foundation
import Combine

/// The canonical set of remote commands the UI can issue. Each brand
/// controller maps these onto its own protocol; commands a brand cannot
/// perform are hidden from the UI via `RemoteCapabilities`.
enum RemoteCommand {
    case power
    /// Hold-power / full power-off where the brand supports it
    /// (Samsung hold, LG turnOff). Roku has no separate power-off key.
    case powerOff
    case volumeUp, volumeDown, mute
    case channelUp, channelDown
    case up, down, left, right, enter
    case back, home, info, menu
    /// Exit the current app / back out to the previous screen (fork's
    /// Exit button; v1.0.12's Back/Home/Exit pill row needs this).
    case exit
    /// Switch the TV's input/source (Roku InputTuner, Samsung
    /// KEY_SOURCE). LG has no input key.
    case input
    /// Open the TV's search UI (Roku Search). Samsung/LG have none.
    case search
    /// Delete one character in a text field (Roku Backspace, LG
    /// deleteCharacters, Samsung KEY_RETURN).
    case backspace
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
    /// The phone's mic can drive the TV's voice input (hold the mic
    /// button and talk). Only Android TV: its Remote v2 protocol
    /// carries voice as 16-bit PCM mono 8 kHz on the remote session.
    /// Roku ECP cannot stream phone audio (its Search key only opens
    /// the TV's voice UI); Samsung's KEY_BT_VOICE only activates the
    /// TV's own voice recognition, which listens via the TV / physical
    /// remote mic, not the phone; LG has no public voice-injection API.
    let supportsVoice: Bool
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
                supportsVoice: false, needsTVPrompt: false, needsPairingCode: false)
        case .samsung:
            return RemoteCapabilities(
                supportsDigits: true, supportsTextInput: true, supportsApps: true,
                supportsSeparatePause: true, supportsPlayback: true,
                supportsVoice: false, needsTVPrompt: true, needsPairingCode: false)
        case .lg:
            return RemoteCapabilities(
                supportsDigits: true, supportsTextInput: true, supportsApps: true,
                supportsSeparatePause: true, supportsPlayback: true,
                supportsVoice: false, needsTVPrompt: true, needsPairingCode: false)
        case .androidTV:
            // Text input is not implemented (IME batch edits need live
            // counters that cannot be verified without a real TV), so the
            // keyboard is hidden for Android TV. Voice IS implemented:
            // the remote session carries 8 kHz PCM (see AndroidTVDriver).
            return RemoteCapabilities(
                supportsDigits: true, supportsTextInput: false, supportsApps: false,
                supportsSeparatePause: true, supportsPlayback: true,
                supportsVoice: true, needsTVPrompt: false, needsPairingCode: true)
        case .airPlay, .other:
            return RemoteCapabilities(
                supportsDigits: false, supportsTextInput: false, supportsApps: false,
                supportsSeparatePause: false, supportsPlayback: false,
                supportsVoice: false, needsTVPrompt: false, needsPairingCode: false)
        }
    }
}

/// Owns the connection to one selected TV and translates `RemoteCommand`s
/// into the brand's real protocol. All failure states surface as
/// plain-language status text; nothing is faked.
@MainActor
final class RemoteSession: ObservableObject, TVDriverDelegate {
    /// `var`, not `let`: the Roku connect updates the stored device
    /// name from /query/device-info (user-renamed Rokus).
    var device: TVDevice
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
    @Published var samsungApps: [SamsungRemote.SamsungApp] = []
    @Published var lgApps: [LGApp] = []
    /// True while the mic is capturing for a voice utterance.
    @Published var isRecordingVoice = false

    private let samsung = SamsungRemote()
    private let lg: LGRemote
    /// The fork's Android TV driver (TVDriver.swift): RemoteSession is
    /// its delegate. Created per connect, like the fork's AppModel.
    private var androidTVDriver: AndroidTVDriver?
    /// Auto-pair guard: the tap is the explicit pair action in our UI
    /// (the fork's Pair button), but only once per connect — a second
    /// .unpaired is a real failure, not a retry loop.
    private var pairingAttempted = false
    private let voiceCapture = VoiceCapture()
    /// Session id of the utterance in progress, if any.
    private var voiceSessionId: Int?
    /// Audio chunks flow capture -> continuation -> pump -> TV, in
    /// order: the AsyncStream preserves chunk order, so speech cannot
    /// arrive scrambled.
    private var voiceContinuation: AsyncStream<Data>.Continuation?
    private var voicePumpTask: Task<Void, Never>?

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
            RokuRemote.resetQueue()
            if let info = await RokuRemote.deviceInfo(on: host) {
                // Update the stored device name: a user-renamed Roku
                // reports its own name in device-info (fork's connect()).
                if let name = info.name, !name.isEmpty, name != device.name {
                    device.name = name
                }
                isConnected = true
                status = "Connected to \(info.model ?? device.name)."
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
                await loadSamsungApps()
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
                await loadLGApps()
            } catch let error as LGError {
                isConnected = false
                status = error.localizedDescription
            } catch {
                isConnected = false
                status = "Couldn't connect to the TV. Make sure it's on and on the same Wi-Fi network."
            }
        case .androidTV:
            // The fork's driver reports state through the delegate
            // (below); connectAndroidTV only starts it and returns.
            // Pairing starts from the .unpaired callback — the tap is
            // the explicit pair action in our UI (the fork's Pair
            // button).
            connectAndroidTV(host: host)
        case .airPlay, .other:
            status = "This device was found, but there's no public way to control it from an app."
        }
    }

    func disconnect() {
        stopVoiceCapture()
        awaitingPairingCode = false
        RokuRemote.resetQueue()
        Task { await samsung.disconnect() }
        Task { await lg.disconnect() }
        androidTVDriver?.disconnect()
        isConnected = false
    }

    // MARK: - Android TV (the fork's driver; RemoteSession is the delegate)

    /// Starts the fork's Android TV driver for `host`. One-time identity
    /// migration first (v1.0.16): any identity minted by the pre-fork
    /// code is discarded and a fresh one is minted with the fork's exact
    /// code, so the TV sees the same certificate shape the working
    /// reference app presents.
    private func connectAndroidTV(host: String) {
        ClientIdentity.migrateToFreshIdentityIfNeeded()
        androidTVDriver?.disconnect()
        pairingAttempted = false
        status = "Connecting…"
        // Paired flag from either store (UserDefaults or the container
        // file) — UserDefaults alone does not reliably survive a
        // LiveContainer relaunch, and a lost flag means re-pairing.
        let paired = AndroidTVPersistence.isPaired(host: host)
        let tvDevice = AndroidTVDevice(name: device.name, brand: .androidTV, host: host, isPaired: paired)
        let driver = AndroidTVDriver(device: tvDevice)
        driver.delegate = self
        androidTVDriver = driver
        driver.connect()
    }

    // MARK: TVDriverDelegate

    func driver(_ driver: TVDriver, didChangeState state: ConnectionState) {
        guard device.brand == .androidTV else { return }
        switch state {
        case .connected:
            isConnected = true
            awaitingTVPrompt = false
            status = "Connected to \(device.name)."
        case .failed(let reason):
            isConnected = false
            awaitingPairingCode = false
            awaitingTVPrompt = false
            status = reason
        case .pairing(.enterCode(_, let error)):
            awaitingPairingCode = true
            status = error ?? "A 6-character code is showing on your TV — type it below."
        case .pairing(.verifying):
            status = "Checking the code…"
        case .pairing(.acceptOnTV):
            awaitingTVPrompt = true
            status = "Accept the prompt on your TV."
        case .unpaired:
            // The TV doesn't know our certificate: pair from scratch.
            // Only once per connect; a second .unpaired is a real
            // failure, not a retry loop.
            if !pairingAttempted {
                pairingAttempted = true
                androidTVDriver?.pair()
            } else {
                isConnected = false
                status = "The TV isn't paired. Try connecting again."
            }
        case .connecting, .idle:
            status = "Connecting…"
        }
    }

    func driver(_ driver: TVDriver, didUpdateDevice device: AndroidTVDevice) {
        guard self.device.brand == .androidTV, let host = self.device.host else { return }
        // Persist the paired flag in both stores (UserDefaults and the
        // container file — see AndroidTVPersistence) so a relaunch
        // reconnects straight to the control channel instead of
        // pairing again. Only the flag is persisted here — the
        // driver's model learning is internal; our UI doesn't
        // display it.
        AndroidTVPersistence.setPaired(host: host, paired: device.isPaired)
    }

    /// Starts a voice utterance (Android TV only): opens a voice session
    /// with the TV, then opens the mic and streams 8 kHz PCM until
    /// stopVoice(). Hold-to-talk: the UI calls this on press-down and
    /// stopVoice() on release. A no-op when voice is unsupported or
    /// already recording.
    /// The session follows the reference (androidtvremote2): the TV opens
    /// it — we send SEARCH, the TV answers with RemoteVoiceBegin, we echo
    /// it — and only then do we capture and stream. (Our old code sent
    /// our own begin unprompted; the TV never opened a session, so it
    /// dropped the audio and nothing the user said appeared.)
    func startVoice() async {
        guard capabilities.supportsVoice, !isRecordingVoice else { return }
        guard isConnected, let driver = androidTVDriver else {
            status = "Not connected — tap a button to connect first."
            return
        }
        status = "Opening voice session…"
        let sessionId: Int
        do {
            sessionId = try await driver.beginVoiceSession()
        } catch {
            status = "The TV didn't open a voice session. Try again."
            return
        }
        // AsyncStream.makeStream() needs iOS 17; the closure init below
        // works back to iOS 15 (the app's deployment target).
        var streamContinuation: AsyncStream<Data>.Continuation!
        let stream = AsyncStream<Data> { streamContinuation = $0 }
        voiceContinuation = streamContinuation
        do {
            try await voiceCapture.start { [weak self] samples in
                self?.voiceContinuation?.yield(samples)
            }
            voiceSessionId = sessionId
            voicePumpTask = Task {
                for await samples in stream {
                    driver.sendVoiceSamples(samples, sessionId: sessionId)
                }
            }
            isRecordingVoice = true
            status = "Listening… speak now."
        } catch let error as VoiceCapture.VoiceCaptureError {
            stopVoiceCapture()
            driver.sendVoiceEnd(sessionId: sessionId)
            status = error.localizedDescription
        } catch {
            stopVoiceCapture()
            driver.sendVoiceEnd(sessionId: sessionId)
            status = "Couldn't start voice input."
        }
    }

    /// Ends a voice utterance: stops capture, drains the remaining
    /// audio to the TV in order, then sends RemoteVoiceEnd.
    func stopVoice() async {
        guard isRecordingVoice, let id = voiceSessionId else { return }
        voiceCapture.stop()
        voiceContinuation?.finish()
        voiceContinuation = nil
        await voicePumpTask?.value
        voicePumpTask = nil
        voiceSessionId = nil
        isRecordingVoice = false
        androidTVDriver?.flushVoiceBuffer(sessionId: id)
        androidTVDriver?.sendVoiceEnd(sessionId: id)
    }

    /// Stop capture and drop all voice state without sending
    /// RemoteVoiceEnd — used on error paths and disconnect, where the
    /// session is gone or was never begun.
    private func stopVoiceCapture() {
        voiceCapture.stop()
        voiceContinuation?.finish()
        voiceContinuation = nil
        voicePumpTask?.cancel()
        voicePumpTask = nil
        voiceSessionId = nil
        isRecordingVoice = false
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
        // The fork's driver validates the code itself and re-prompts
        // (via the delegate) when it doesn't check out.
        androidTVDriver?.submitPairingCode(code)
    }

    /// Called by the pairing-code UI when the user cancels pairing.
    func cancelPairing() {
        pairingCode = ""
        awaitingPairingCode = false
        // The fork's cancel: drop the pairing channel and go back to
        // unpaired. Block the auto-pair — the user chose to stop.
        pairingAttempted = true
        androidTVDriver?.disconnect()
        androidTVDriver?.connect()
        status = "Pairing cancelled."
    }

    /// Forget the Android TV pairing: clears the paired flag so the next
    /// connect pairs from scratch. The shared client identity is kept
    /// (the fork's forget removes the device, not the identity).
    /// No-op for other brands.
    func forgetPairedTV() {
        guard device.brand == .androidTV, let host = device.host else { return }
        AndroidTVPersistence.removePaired(host: host)
        androidTVDriver?.disconnect()
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
            // A successful send leaves `status` untouched — the TV
            // reflecting the change is the confirmation, so nothing
            // flashes "Sent." at the bottom after every press.
        } catch let error as SamsungRemote.SamsungError {
            status = error.localizedDescription
        } catch let error as RokuRemote.RokuError {
            isConnected = false
            status = error.localizedDescription
        } catch let error as LGError {
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
        case .powerOff: break // Roku has no separate power-off key.
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
        case .exit: try await RokuRemote.send(key: "Home", to: host)
        case .info: try await RokuRemote.send(key: "Info", to: host)
        // Menu is the options/info menu — NOT Search (the old mapping
        // opened Roku search instead of the menu; fork's keyName).
        case .menu: try await RokuRemote.send(key: "Info", to: host)
        case .input: try await RokuRemote.send(key: "InputTuner", to: host)
        case .search: try await RokuRemote.send(key: "Search", to: host)
        case .backspace: try await RokuRemote.send(key: "Backspace", to: host)
        case .play, .pause: try await RokuRemote.send(key: "Play", to: host)
        case .stop: try await RokuRemote.send(key: "Play", to: host)
        case .rewind: try await RokuRemote.send(key: "Rev", to: host)
        case .fastForward: try await RokuRemote.send(key: "Fwd", to: host)
        case .digit(let n): try await RokuRemote.send(key: "Lit_\(n)", to: host)
        case .text(let text): try await RokuRemote.sendText(text, to: host)
        }
    }

    private func sendSamsung(_ command: RemoteCommand, to host: String) async throws {
        switch command {
        case .power: try await samsung.sendPower(to: host)
        case .powerOff: try await samsung.sendPowerOff(to: host)
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
        case .exit: try await samsung.sendKey(.exit, to: host)
        case .info: try await samsung.sendKey(.info, to: host)
        case .menu: try await samsung.sendKey(.menu, to: host)
        case .input: try await samsung.sendKey(.source, to: host)
        case .search: break // Samsung has no search key.
        case .backspace: try await samsung.sendKey(.back, to: host) // KEY_RETURN
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
        case .powerOff: try await lg.powerOff()
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
        case .exit: try await lg.exit()
        case .info: try await lg.info()
        case .menu: try await lg.menu()
        case .input, .search: break // LG has no input/search keys.
        case .backspace: try await lg.deleteCharacters()
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
        // The fork's driver sends (and queues + reconnects when paired)
        // and never throws; `host` is unused — the driver holds it.
        guard let driver = androidTVDriver else { return }
        switch command {
        case .power: driver.send(.power)
        case .powerOff: break // No distinct power-off key; .power toggles.
        case .volumeUp: driver.send(.volumeUp)
        case .volumeDown: driver.send(.volumeDown)
        case .mute: driver.send(.mute)
        case .channelUp: driver.send(.channelUp)
        case .channelDown: driver.send(.channelDown)
        case .up: driver.send(.up)
        case .down: driver.send(.down)
        case .left: driver.send(.left)
        case .right: driver.send(.right)
        case .enter: driver.send(.select)
        case .back: driver.send(.back)
        case .home: driver.send(.home)
        case .exit: driver.send(.exit) // fork: exit == back (code 4)
        case .info: driver.send(.info)
        case .menu: driver.send(.menu)
        case .input: driver.send(.input)
        case .search: driver.send(.search)
        case .backspace: driver.send(.backspace)
        case .play: driver.send(.play)
        case .pause: driver.send(.pause)
        case .stop: driver.send(.stop)
        case .rewind: driver.send(.rewind)
        case .fastForward: driver.send(.fastForward)
        case .digit(let n): driver.send(.digit(n))
        case .text(let text): driver.sendText(text)
        }
    }

    // MARK: - Apps

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

    func loadSamsungApps() async {
        guard device.brand == .samsung, let host = device.host else { return }
        samsungApps = await samsung.installedApps(on: host) ?? []
    }

    func launchSamsungApp(_ app: SamsungRemote.SamsungApp) async {
        guard let host = device.host else { return }
        do {
            try await samsung.launch(app, to: host)
            status = "Opening \(app.name)."
        } catch {
            status = "Couldn't open \(app.name)."
        }
    }

    func loadLGApps() async {
        guard device.brand == .lg else { return }
        lgApps = await lg.installedApps() ?? []
    }

    func launchLGApp(_ app: LGApp) async {
        do {
            try await lg.launch(app)
            status = "Opening \(app.name)."
        } catch {
            status = "Couldn't open \(app.name)."
        }
    }

    /// Launches an installed app by id, dispatching to the brand's
    /// launcher (used by the app shortcut cards).
    func launchApp(id: String) async {
        switch device.brand {
        case .roku:
            if let app = rokuApps.first(where: { $0.id == id }) { await launchRokuApp(app) }
        case .samsung:
            if let app = samsungApps.first(where: { $0.id == id }) { await launchSamsungApp(app) }
        case .lg:
            if let app = lgApps.first(where: { $0.id == id }) { await launchLGApp(app) }
        case .androidTV, .airPlay, .other:
            return
        }
    }
}
