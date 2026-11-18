import Foundation
import Combine

/// The canonical set of remote commands the UI can issue. Each brand
/// controller maps these onto its own protocol; commands a brand cannot
/// perform are hidden from the UI via `RemoteCapabilities`.
/// Equatable so tests can assert the exact commands a pump or gesture sent.
enum RemoteCommand: Equatable {
    case power
    /// Hold-power / full power-off where the brand supports it
    /// (Samsung hold, LG turnOff). Roku has no separate power-off key.
    case powerOff
    case volumeUp, volumeDown, mute
    case channelUp, channelDown
    case up, down, left, right, enter
    /// Hold the OK key down / release it (swipe pad single-tap-hold,
    /// v1.0.25). Roku/Samsung/Android TV send a real key-down/up;
    /// LG has no hold in its protocol, so enterDown is one plain
    /// enter and enterUp is a no-op (see sendLG).
    case enterDown, enterUp
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
    /// The TV tells the app when a text field gains focus, so the
    /// keyboard can pop up on its own and the keyboard button can
    /// hide (v1.0.34). Android TV: the remote protocol's field-22
    /// show request announces the focused field. LG: the IME
    /// registerRemoteKeyboard subscription reports currentWidget
    /// focus. Samsung and Roku send no such signal, so the button
    /// stays there.
    let supportsAutoKeyboard: Bool

    static func forBrand(_ brand: TVDevice.Brand) -> RemoteCapabilities {
        switch brand {
        case .roku:
            return RemoteCapabilities(
                supportsDigits: false, supportsTextInput: true, supportsApps: true,
                supportsSeparatePause: false, supportsPlayback: true,
                supportsVoice: false, needsTVPrompt: false, needsPairingCode: false,
                supportsAutoKeyboard: false)
        case .samsung:
            return RemoteCapabilities(
                supportsDigits: true, supportsTextInput: true, supportsApps: true,
                supportsSeparatePause: true, supportsPlayback: true,
                supportsVoice: false, needsTVPrompt: true, needsPairingCode: false,
                supportsAutoKeyboard: false)
        case .lg:
            return RemoteCapabilities(
                supportsDigits: true, supportsTextInput: true, supportsApps: true,
                supportsSeparatePause: true, supportsPlayback: true,
                supportsVoice: false, needsTVPrompt: true, needsPairingCode: false,
                supportsAutoKeyboard: true)
        case .androidTV:
            // Text input IS implemented: AndroidTVDriver.sendText builds
            // the field-21 IME batch edit and the incoming-message
            // handler learns the counters from the TV's field-20 key
            // inject and field-22 show request (field 21 is only a
            // fallback) — the reference's exact flow, verified
            // against androidtvremote2's own tests in v1.0.22.
            // requestedFeatures (623) already includes the IME bit.
            // Voice IS implemented: the
            // remote session carries 8 kHz PCM (see AndroidTVDriver).
            return RemoteCapabilities(
                supportsDigits: true, supportsTextInput: true, supportsApps: false,
                supportsSeparatePause: true, supportsPlayback: true,
                supportsVoice: true, needsTVPrompt: false, needsPairingCode: true,
                supportsAutoKeyboard: true)
        case .airPlay, .other:
            return RemoteCapabilities(
                supportsDigits: false, supportsTextInput: false, supportsApps: false,
                supportsSeparatePause: false, supportsPlayback: false,
                supportsVoice: false, needsTVPrompt: false, needsPairingCode: false,
                supportsAutoKeyboard: false)
        }
    }
}

/// The Demo TV's fake app lineup (v1.0.66): the streaming apps
/// Nick tests with. Real brand tiles where the catalog has them
/// (Netflix, Hulu, HBO Max, Disney+, Prime Video, YouTube,
/// Peacock, Paramount+, Crunchyroll, Apple TV, Tubi, Spotify);
/// the rest get monogram tiles (Kanopy, MUBI, Shudder). Ids are
/// "demo:<name>" launch keys — the session never sends them
/// anywhere; launching just says "Opening …".
enum DemoTV {
    static let apps: [SamsungRemote.SamsungApp] = [
        SamsungRemote.SamsungApp(id: "demo:netflix", name: "Netflix", actionType: "NATIVE_LAUNCH"),
        SamsungRemote.SamsungApp(id: "demo:hulu", name: "Hulu", actionType: "NATIVE_LAUNCH"),
        SamsungRemote.SamsungApp(id: "demo:hbo-max", name: "HBO Max", actionType: "NATIVE_LAUNCH"),
        SamsungRemote.SamsungApp(id: "demo:disney-plus", name: "Disney+", actionType: "NATIVE_LAUNCH"),
        SamsungRemote.SamsungApp(id: "demo:prime-video", name: "Prime Video", actionType: "NATIVE_LAUNCH"),
        SamsungRemote.SamsungApp(id: "demo:youtube", name: "YouTube", actionType: "NATIVE_LAUNCH"),
        SamsungRemote.SamsungApp(id: "demo:peacock", name: "Peacock", actionType: "NATIVE_LAUNCH"),
        SamsungRemote.SamsungApp(id: "demo:paramount-plus", name: "Paramount+", actionType: "NATIVE_LAUNCH"),
        SamsungRemote.SamsungApp(id: "demo:crunchyroll", name: "Crunchyroll", actionType: "NATIVE_LAUNCH"),
        SamsungRemote.SamsungApp(id: "demo:apple-tv", name: "Apple TV", actionType: "NATIVE_LAUNCH"),
        SamsungRemote.SamsungApp(id: "demo:tubi", name: "Tubi", actionType: "NATIVE_LAUNCH"),
        SamsungRemote.SamsungApp(id: "demo:spotify", name: "Spotify", actionType: "NATIVE_LAUNCH"),
        SamsungRemote.SamsungApp(id: "demo:kanopy", name: "Kanopy", actionType: "NATIVE_LAUNCH"),
        SamsungRemote.SamsungApp(id: "demo:mubi", name: "MUBI", actionType: "NATIVE_LAUNCH"),
        SamsungRemote.SamsungApp(id: "demo:shudder", name: "Shudder", actionType: "NATIVE_LAUNCH"),
    ]
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
    /// The latest pairing error to show on the pairing card (v1.0.23):
    /// a wrong code, or the TV discarding the code and showing a new
    /// one. Nil on the first prompt and while an attempt is in flight.
    /// (The diagnostic line is hidden while the card is up, so the
    /// error would otherwise be invisible.)
    @Published var pairingError: String? = nil
    @Published var rokuApps: [RokuRemote.RokuApp] = []
    @Published var samsungApps: [SamsungRemote.SamsungApp] = []
    @Published var lgApps: [LGApp] = []
    /// Android TV cannot list installed apps (v1.0.63): the curated
    /// deep-link set the Apps sheet offers instead.
    @Published var androidTVApps: [TVApp] = []
    /// True while the TV has a text field focused (v1.0.34 auto
    /// keyboard): Android TV reports it from the field-22 show
    /// request, LG from the registerRemoteKeyboard subscription.
    /// The view shows the keyboard on true and hides it on false.
    /// Always false on Samsung/Roku — those TVs send no signal.
    @Published var tvTextFieldFocused = false
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
    /// Hardware volume steps funnel through one coalescing pump
    /// (v1.0.28) instead of spawning one Task per step — a hold
    /// stops the instant the finger lifts and never blocks other
    /// keys behind a throttle backlog. Wired in init.
    private let volumePump = CoalescingPump<Bool>()
    /// Pad repeat streams (double-tap-hold spam, swipe-and-hold)
    /// funnel through one coalescing pump (v1.0.34) instead of
    /// spawning one Task per press — otherwise presses pile up in
    /// flight and keep arriving after the finger lifts. Wired in
    /// init, alongside the volume pump.
    private let repeatPump = CoalescingPump<RemoteCommand>()
    /// Audio chunks flow capture -> continuation -> pump -> TV, in
    /// order: the AsyncStream preserves chunk order, so speech cannot
    /// arrive scrambled.
    private var voiceContinuation: AsyncStream<Data>.Continuation?
    private var voicePumpTask: Task<Void, Never>?

    init(device: TVDevice) {
        self.device = device
        self.capabilities = RemoteCapabilities.forBrand(device.brand)
        self.lg = LGRemote(host: device.host ?? "")
        // The pump's send is one volume step through the normal
        // send path (per-brand throttle included). Weak capture:
        // the pump is owned by the session, so a strong capture
        // would be a retain cycle.
        volumePump.send = { [weak self] up in
            _ = await self?.send(up ? .volumeUp : .volumeDown)
        }
        // The pad repeat pump's send is one repeat press through the
        // normal send path (per-brand throttle included). Same weak
        // capture: the pump is owned by the session.
        repeatPump.send = { [weak self] command in
            _ = await self?.send(command)
        }
        // The stuck-key report (v1.0.53): when a Samsung Release
        // doesn't go out, the key may still be held down on the TV
        // — say so in the status instead of leaving the user
        // wondering why the TV keeps doing the thing. A fresh press
        // of the same key (a Click sends Press then Release) frees it.
        Task { [weak self] in
            await self?.samsung.setDroppedReleaseHandler { [weak self] key in
                Task { @MainActor in
                    self?.status = "The \(key.rawValue) key may still be held down on the TV — the release didn't go through. Press it again to free it."
                }
            }
        }
    }

    var supportsControl: Bool { device.brand.supportsControl }

    // MARK: - Connection

    /// Connects (or verifies reachability) and reports progress in `status`.
    func connect() async {
        // Demo TV (v1.0.66): instantly "connected" — nothing is
        // ever sent over the network, so there is nothing to
        // connect to. The fake app lineup loads here, so the
        // Apps tab works on it like a real TV.
        if device.isDemo {
            isConnected = true
            status = "Connected to \(device.name)."
            samsungApps = DemoTV.apps
            return
        }
        guard supportsControl else {
            status = "This device was found, but there's no public way to control it from an app."
            return
        }
        guard let host = device.host else {
            status = "Still waiting for this TV's address — try scanning again."
            return
        }
        // A second connect while one is in flight is a no-op
        // (v1.0.53): two overlapping connects raced the socket and
        // the busy state.
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        switch device.brand {
        case .roku:
            status = "Checking the TV…"
            RokuRemote.resetQueue()
            if let info = await RokuRemote.deviceInfo(on: host) {
                await rokuConnected(info: info, host: host)
            } else if device.isSleeping {
                // The TV was listed as sleeping — try waking it
                // (v1.0.47): magic packet, then device-info again.
                status = "Waking the TV…"
                if await RokuRemote.wakeAndCheck(host: host),
                   let info = await RokuRemote.deviceInfo(on: host) {
                    await rokuConnected(info: info, host: host)
                } else {
                    isConnected = false
                    status = "Couldn't reach the TV. Make sure it's on and on the same Wi-Fi network."
                }
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
                await samsungConnected(host: host)
            } catch {
                let message = (error as? SamsungRemote.SamsungError)?.localizedDescription
                    ?? "Couldn't connect to the TV. Make sure it's on and on the same Wi-Fi network."
                if device.isSleeping {
                    // The TV was listed as sleeping — try waking it
                    // (v1.0.47) instead of reporting the failure.
                    status = "Waking the TV…"
                    if await samsung.wakeIfNeededAndConnect(to: host) {
                        await samsungConnected(host: host)
                    } else {
                        isConnected = false
                        status = message
                    }
                } else {
                    isConnected = false
                    status = message
                }
            }
        case .lg:
            status = "Connecting… accept the prompt on your TV if one appears."
            awaitingTVPrompt = true
            defer { awaitingTVPrompt = false }
            do {
                try await lg.connect()
                // The IME subscription reports focus changes from
                // here on (v1.0.34 auto keyboard). The callback hops
                // to the main actor: the subscription fires from the
                // LG actor's receive loop.
                await lg.setKeyboardFocusHandler { [weak self] focused in
                    Task { @MainActor in self?.tvTextFieldFocused = focused }
                }
                isConnected = true
                status = "Connected to \(device.name)."
                RememberedTVStore.record(device)
                NotificationCenter.default.post(name: .tvDidConnect, object: nil, userInfo: ["host": host])
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
        volumePump.cancel()
        repeatPump.cancel()
        tvTextFieldFocused = false
        awaitingPairingCode = false
        pairingError = nil
        // Demo TV (v1.0.66): no drivers ever started, so there is
        // nothing to tear down.
        guard !device.isDemo else { isConnected = false; return }
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
        pairingError = nil
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
            isBusy = false
            awaitingTVPrompt = false
            pairingError = nil
            status = "Connected to \(device.name)."
            RememberedTVStore.record(device)
            if let host = device.host {
                NotificationCenter.default.post(name: .tvDidConnect, object: nil, userInfo: ["host": host])
            }
        case .failed(let reason):
            isConnected = false
            isBusy = false
            awaitingPairingCode = false
            awaitingTVPrompt = false
            pairingError = nil
            status = reason
        case .pairing(.enterCode(_, let error)):
            isBusy = true
            awaitingPairingCode = true
            pairingError = error
            status = error ?? "A 6-character code is showing on your TV — type it below."
        case .pairing(.verifying):
            isBusy = true
            status = "Checking the code…"
        case .pairing(.acceptOnTV):
            isBusy = true
            awaitingTVPrompt = true
            status = "Accept the prompt on your TV."
        case .unpaired:
            // The TV doesn't know our certificate: pair from scratch.
            // Only once per connect; a second .unpaired is a real
            // failure, not a retry loop.
            if !pairingAttempted {
                pairingAttempted = true
                isBusy = true
                androidTVDriver?.pair()
            } else {
                isConnected = false
                isBusy = false
                status = "The TV isn't paired. Try connecting again."
            }
        case .connecting, .idle:
            isBusy = true
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

    /// The TV announced a text field gaining or losing focus
    /// (v1.0.34 auto keyboard). The view shows the keyboard while
    /// a field is focused and hides it when focus leaves.
    func driver(_ driver: TVDriver, didChangeTextFieldFocus focused: Bool) {
        guard device.brand == .androidTV else { return }
        tvTextFieldFocused = focused
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
    /// (The UI calls this itself the moment the 6th character lands —
    /// there is no Pair button anymore, v1.0.23.)
    func submitPairingCode() {
        let code = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count == 6 else {
            status = "Enter the 6-character code shown on your TV."
            return
        }
        pairingCode = ""
        pairingError = nil
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

    /// One hardware volume step (v1.0.28): enqueued on the
    /// coalescing pump, not sent directly. Rapid steps overwrite
    /// the single pending slot, so a hold sends at the TV's pace
    /// and stops the instant the finger lifts — and a pad tap
    /// waits behind at most one volume send, never a backlog.
    /// Non-volume commands use `send(_:)` and never touch the pump.
    func sendVolume(up: Bool) {
        volumePump.enqueue(up)
    }

    /// One pad repeat press (v1.0.34): double-tap-hold spam and
    /// swipe-and-hold repeats enqueue on the coalescing pump, not
    /// sent directly. Rapid repeats overwrite the single pending
    /// slot, so a hold sends at the TV's pace and stops the instant
    /// the finger lifts — and a discrete press never waits behind
    /// a repeat backlog. Discrete presses use `send(_:)` and never
    /// touch the pump.
    func sendRepeat(_ command: RemoteCommand) {
        repeatPump.enqueue(command)
    }

    /// Drop the pending repeat press, if any. Called on finger lift
    /// (and on disconnect), so no repeat fires after the hold ends.
    func cancelRepeats() {
        repeatPump.cancel()
    }

    /// Release a held key when the app backgrounds or goes inactive
    /// (v1.0.53): a key held down when the phone locks or the app is
    /// interrupted would otherwise stay stuck on the TV. Cancels
    /// both pumps, and if connected sends an enter-up — guarded so
    /// a disconnected session doesn't flash a status.
    func releaseHeldInput() {
        volumePump.cancel()
        repeatPump.cancel()
        guard isConnected else { return }
        Task { await send(.enterUp) }
    }

    func send(_ command: RemoteCommand) async {
        // Demo TV (v1.0.66): every command is a no-op by design —
        // the UI feedback (tap ripple, haptics) still fires, but
        // nothing leaves the phone.
        if device.isDemo { return }
        // A send that cannot go out says so in the status instead
        // of returning silently (v1.0.53): a dead button with no
        // explanation reads as a broken remote.
        guard supportsControl else {
            status = "This device was found, but there's no public way to control it from an app."
            return
        }
        guard let host = device.host else {
            status = "Still waiting for this TV's address — try scanning again."
            return
        }
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
            // Only connection-level errors drop `isConnected`
            // (v1.0.53): an unexpected reply means the TV answered.
            if error.isConnectionLevel { isConnected = false }
            status = error.localizedDescription
        } catch let error as RokuRemote.RokuError {
            if error.isConnectionLevel { isConnected = false }
            status = error.localizedDescription
        } catch let error as LGError {
            if error.isConnectionLevel { isConnected = false }
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
        case .enterDown: try await RokuRemote.sendKeyDown(key: "Select", to: host)
        case .enterUp: try await RokuRemote.sendKeyUp(key: "Select", to: host)
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
        case .enterDown: await samsung.sendKeyDown(.enter, to: host)
        case .enterUp: await samsung.sendKeyUp(.enter, to: host)
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
        // LG has no key-down/up in its pointer-socket protocol
        // (discrete `type:button` presses only), so a hold is a
        // single plain enter at onset and nothing on lift — a
        // fallback, not a faked hold.
        case .enterDown: try await lg.enter()
        case .enterUp: break
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
        case .enterDown: driver.sendKeyDown(.select)
        case .enterUp: driver.sendKeyUp(.select)
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

    /// A Roku answered device-info: name, connected state, apps,
    /// MAC + remembered record (v1.0.47).
    private func rokuConnected(info: RokuRemote.RokuDeviceInfo, host: String) async {
        // Update the stored device name: a user-renamed Roku
        // reports its own name in device-info (fork's connect()).
        if let name = info.name, !name.isEmpty, name != device.name {
            device.name = name
        }
        isConnected = true
        status = "Connected to \(info.model ?? device.name)."
        if let mac = info.mac {
            RokuRemote.storeMAC(mac, for: host)
            RememberedTVStore.updateMAC(host: host, mac: mac)
        }
        device.macAddress = info.mac ?? RokuRemote.macAddress(for: host)
        RememberedTVStore.record(device)
        NotificationCenter.default.post(name: .tvDidConnect, object: nil, userInfo: ["host": host])
        await loadRokuApps()
    }

    /// A Samsung connected: state, apps, MAC + remembered record
    /// (v1.0.47). The MAC itself is learned in the background by
    /// the driver after connect; the stored value (if any) goes on
    /// the record now, and fetchAndStoreMAC updates it when it lands.
    private func samsungConnected(host: String) async {
        isConnected = true
        status = "Connected to \(device.name)."
        device.macAddress = SamsungRemote.macAddress(for: host)
        RememberedTVStore.record(device)
        NotificationCenter.default.post(name: .tvDidConnect, object: nil, userInfo: ["host": host])
        await loadSamsungApps()
    }

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
        guard !device.isDemo, device.brand == .samsung, let host = device.host else { return }
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
        // Demo TV (v1.0.66): nothing is sent — launchAppItem
        // already said "Opening …" for the tap.
        if device.isDemo { return }
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

    /// Load the Apps sheet's list for the connected brand (v1.0.63):
    /// the TV's real installed apps on Roku / Samsung / LG, the
    /// curated deep-link set on Android TV.
    func loadApps() async {
        // Demo TV (v1.0.66): the fake lineup, no network fetch.
        if device.isDemo {
            samsungApps = DemoTV.apps
            return
        }
        switch device.brand {
        case .roku: await loadRokuApps()
        case .samsung: await loadSamsungApps()
        case .lg: await loadLGApps()
        case .androidTV: androidTVApps = AndroidTVAppCatalog.apps
        case .airPlay, .other: break
        }
    }

    /// Launch one Apps-sheet item (v1.0.63): by app id on Roku /
    /// Samsung / LG, by deep link on Android TV (the item's id IS
    /// the deep link there).
    func launchAppItem(_ item: TVAppItem) async {
        // Demo TV (v1.0.66): "launching" just says so — nothing
        // is sent, and the tab still switches back to the remote
        // like a real launch.
        if device.isDemo {
            status = "Opening \(item.name)."
            return
        }
        if device.brand == .androidTV {
            launchAndroidTVApp(TVApp(name: item.name, launchID: item.id, iconURL: nil))
            return
        }
        await launchApp(id: item.id)
    }

    /// Launch a deep-link app on Android TV (v1.0.63): the fork
    /// driver's launch sends the link in field 90.
    func launchAndroidTVApp(_ app: TVApp) {
        guard device.brand == .androidTV else { return }
        status = "Opening \(app.name)."
        androidTVDriver?.launch(app)
    }
}
