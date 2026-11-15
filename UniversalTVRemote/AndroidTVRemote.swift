// Android TV / Google TV remote control — Android TV Remote protocol v2.
//
// v1.0.15 rebuild: the Android TV section is a port of the working
// implementation from open-tv-remote (https://github.com/iamnbutler/open-tv-remote,
// MIT License, Copyright (c) 2026 Nathan Butler), whose v1.3.0 IPA pairs
// and controls the TCL QM7 this app could not reach. Our v1.0.7–v1.0.14
// implementation (hand-rolled TLSConnection, X509, TLSHandshakeRecorder,
// diagnostic probes) is replaced by the fork's TLSChannel, ClientIdentity,
// DER and Protobuf code — see TLSChannel.swift, ClientIdentity.swift,
// DER.swift, Protobuf.swift. Those files are the fork's code, near-verbatim.
//
// What changed vs. the fork (deliberate, documented):
// - The fork's TVDriver protocol / TVDevice / delegate are not ported:
//   this file's AndroidTVDriver takes a host + paired flag and reports
//   state through closures, and AndroidTVRemote adapts it to the
//   RemoteSession / RemoteCommand interface this app's UI already uses.
// - The fork's connect() never pairs by design; this app pairs
//   automatically when the user taps the TV, so the adapter drives
//   pair-then-connect and shows the code prompt through RemoteSession.
// - Certificate pinning (ours, from v1.0.7): the fork trusts any server
//   certificate and binds trust to the pairing secret. This app also
//   pins the TV's certificate at pairing (AndroidTVPinStore) and the
//   driver checks the pin after the handshake, before any message is
//   sent — a changed certificate fails with certificateChanged instead
//   of silently re-trusting. Forget this TV clears the pin + flag.
// - Voice (ours — the fork has no voice): RemoteVoiceBegin / Payload /
//   End (fields 30/31/32, ≤20 KB payloads, 16-bit PCM mono 8 kHz), same
//   message bytes as v1.0.9–v1.0.14 (covered by VoiceMessageTests).
// - Key table: the fork's RemoteKey plus .play (126), .pause (127) and
//   .stop (86) — our RemoteCommand has distinct play/pause/stop, and
//   the old adapter sent those codes; .exit is 4, like the fork's.
// - The client name shown on the TV while pairing says
//   "Universal Remote (iPhone XXXX)" instead of the fork's "Open Remote".
// - Not ported (no caller here): sendInteractive, launch,
//   installedApps, supports(_:), the foreground-app tracking, and the
//   model-name learning — Android TV shows no app shortcuts in our UI.
// - The diagnostic probes and the handshake recorder are gone: the fork
//   never probes, and the probes were three extra failed handshakes
//   before the real attempt. A failure now reports the fork's
//   plain-language reason as the status text.
//
// Transport: mutual TLS. Pairing on port 6467 (TV shows a 6-character
// hex code; the client proves it saw the code with a SHA-256 secret
// bound to both certificates), control on port 6466 with varint-framed
// protobuf. No third-party dependencies.

import Foundation
import Network
import CryptoKit
import Security
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Adapter (the interface RemoteSession uses)

/// Android TV remote, as RemoteSession sees it: connect (pairing first
/// if needed), disconnect, sendKey, voice, forget. The connection work
/// is done by AndroidTVDriver (below); this class owns the paired flag,
/// the pin, the code-prompt handoff, and the connect timeout.
@MainActor
final class AndroidTVRemote {

    /// Pure value type — explicitly nonisolated so tests and other
    /// non-isolated code can read the failure reasons.
    nonisolated enum AndroidTVError: Error, LocalizedError {
        case notConnected
        case connectionFailed(detail: String)
        case pairingTimeout
        case certificateChanged

        var errorDescription: String? {
            switch self {
            case .notConnected:
                return "Not connected to the TV."
            case .connectionFailed(let detail):
                return detail
            case .pairingTimeout:
                return "Pairing timed out waiting for the TV to show its code."
            case .certificateChanged:
                return "This TV's certificate changed since you paired it. Forget the TV and pair again."
            }
        }
    }

    /// Android key codes used (values from remotemessage.proto).
    /// Identical to v1.0.14 — RemoteSession maps RemoteCommand onto these.
    /// Pure value type — explicitly nonisolated.
    nonisolated enum Key: Int {
        case home = 3
        case back = 4
        case digit0 = 7
        case digit1 = 8
        case digit2 = 9
        case digit3 = 10
        case digit4 = 11
        case digit5 = 12
        case digit6 = 13
        case digit7 = 14
        case digit8 = 15
        case digit9 = 16
        case dpadUp = 19
        case dpadDown = 20
        case dpadLeft = 21
        case dpadRight = 22
        case dpadCenter = 23
        case volumeUp = 24
        case volumeDown = 25
        case power = 26
        case enter = 66
        case menu = 82
        case mediaPlayPause = 85
        case mediaStop = 86
        case mediaRewind = 89
        case mediaFastForward = 90
        case mediaPlay = 126
        case mediaPause = 127
        case volumeMute = 164
        case info = 165
        case channelUp = 166
        case channelDown = 167
        case backspace = 67
        case search = 84
        case input = 178

        static func digit(_ n: Int) -> Key? {
            Key(rawValue: 7 + n)
        }
    }

    private var driver: AndroidTVDriver?
    private var host: String?
    private var connectContinuation: CheckedContinuation<Void, Error>?
    /// Set once the driver reports the TV forgot us (.unpaired), so the
    /// auto-pair that follows happens exactly once per connect.
    private var pairingAttempted = false
    private var connectTimeoutTask: Task<Void, Never>?
    private var voiceSessionId = 0

    /// Connect to the TV, pairing first if needed.
    /// `codeProvider` is called on the main actor when the TV shows its
    /// pairing code; it returns the 6-character code the user types in.
    func connect(to host: String,
                 codeProvider: @escaping @MainActor () async throws -> String) async throws {
        if self.host == host, let driver, driver.state == .connected { return }
        disconnect()
        self.host = host
        // Paired before if the flag survived, or if a pin is stored:
        // the pin is set when pairing succeeds, so it covers a lost
        // flag too.
        let paired = UserDefaults.standard.bool(forKey: "androidtv.paired.\(host)")
            || AndroidTVPinStore.pinnedCertificateDER(for: host) != nil
        let driver = AndroidTVDriver(host: host, isPaired: paired)
        driver.expectedServerCertificateDER = AndroidTVPinStore.pinnedCertificateDER(for: host)
        driver.onStateChange = { [weak self] state in
            self?.driverStateChanged(state, codeProvider: codeProvider)
        }
        driver.onIsPairedChange = { paired in
            UserDefaults.standard.set(paired, forKey: "androidtv.paired.\(host)")
        }
        self.driver = driver
        pairingAttempted = false
        // 30s timeout on the pre-prompt phase only: a TV that accepts
        // TCP and then never answers would otherwise hang the UI
        // forever (the fork has no timeout; its channel's 6s TCP
        // timeout bounds the unreachable case, not the black-hole one).
        // The prompt cancels it, so a user mid-typing is never cut off
        // — and a timeout firing mid-prompt would strand RemoteSession's
        // code continuation, which is why the timeout lives here and not
        // around the prompt.
        armConnectTimeout()
        try await waitForConnected {
            if paired {
                driver.connect()
            } else {
                driver.pair()
            }
        }
        // Connected: pin the TV's certificate on first success (trust on
        // first use — the pin is what later connections are checked
        // against).
        if AndroidTVPinStore.pinnedCertificateDER(for: host) == nil,
           let serverDER = driver.remoteServerCertificateDER {
            AndroidTVPinStore.set(serverDER, for: host)
        }
        UserDefaults.standard.set(true, forKey: "androidtv.paired.\(host)")
    }

    /// Forget a TV: clears its pinned server certificate and the paired
    /// flag. The shared client identity is NOT deleted — it is bound to
    /// every TV this app has paired with, and deleting it would break
    /// the others. The next connect pairs from scratch and pins the
    /// TV's (new) certificate.
    func forget(host: String) {
        if self.host == host { disconnect() }
        Self.forgetTV(host: host)
    }

    /// Static forget: pin + paired flag only, no session needed.
    static func forgetTV(host: String) {
        AndroidTVPinStore.clear(for: host)
        UserDefaults.standard.removeObject(forKey: "androidtv.paired.\(host)")
    }

    func disconnect() {
        abortConnect(with: CancellationError())
    }

    func sendKey(_ key: Key, to host: String) async throws {
        guard let driver, self.host == host, driver.isPaired else {
            throw AndroidTVError.notConnected
        }
        // The driver queues the key and reconnects if the TV dropped
        // the idle session (the fork's behavior); a key to a TV that
        // was never paired is notConnected above.
        driver.send(Self.driverKey(for: key))
    }

    /// Text input (the fork's IME batch edit). RemoteSession wires
    /// .text here; the UI still hides the keyboard for Android TV
    /// (supportsTextInput is false), so this only runs if that changes.
    func sendText(_ text: String, to host: String) async throws {
        guard let driver, self.host == host else {
            throw AndroidTVError.notConnected
        }
        driver.sendText(text)
    }

    // MARK: - Voice (port 6466 remote session)

    /// Begin a voice utterance: sends RemoteVoiceBegin and returns the
    /// session id to use for its payloads and end. Throws notConnected
    /// when the remote session is not up.
    func beginVoice() async throws -> Int {
        guard let driver, driver.state == .connected else { throw AndroidTVError.notConnected }
        voiceSessionId += 1
        let id = voiceSessionId
        driver.sendVoiceBegin(sessionId: id)
        return id
    }

    /// Stream one chunk of 8 kHz mono Int16 PCM for the utterance
    /// `sessionId`, split into ≤20 KB payload messages.
    func sendVoiceSamples(_ samples: Data, sessionId: Int) async throws {
        guard let driver, driver.state == .connected else { throw AndroidTVError.notConnected }
        driver.sendVoiceSamples(samples, sessionId: sessionId)
    }

    /// End a voice utterance.
    func endVoice(sessionId: Int) async throws {
        guard let driver, driver.state == .connected else { throw AndroidTVError.notConnected }
        driver.sendVoiceEnd(sessionId: sessionId)
    }

    /// The pairing secret: SHA-256 over the minimal big-endian bytes of
    /// client modulus, client exponent, server modulus, server exponent,
    /// then the last 4 hex chars of the code as bytes. The first byte of
    /// the hash must equal the code's first byte (checked by the TV too).
    /// Static (and nonisolated) so unit tests can verify it against a
    /// known vector without a TV.
    nonisolated static func pairingSecret(code: String, clientCertificateDER: Data,
                                          serverCertificateDER: Data) -> Data? {
        guard let clientCert = SecCertificateCreateWithData(nil, clientCertificateDER as CFData),
              let serverCert = SecCertificateCreateWithData(nil, serverCertificateDER as CFData),
              let digest = AndroidTVDriver.pairingSecret(code: code, clientCertificate: clientCert,
                                                         serverCertificate: serverCert),
              code.count == 6,
              let firstByte = UInt8(code.prefix(2), radix: 16),
              digest.first == firstByte else {
            return nil
        }
        return digest
    }

    // MARK: - Driver state machine

    /// Suspends until the driver reports .connected, or fails. The
    /// `start` closure runs once the continuation exists, so a failure
    /// that fires synchronously (e.g. no client identity) cannot be
    /// lost. Resumed by driverStateChanged, abortConnect, or the
    /// timeout — and by RemoteSession.disconnect() when the view goes
    /// away (which calls disconnect() here).
    private func waitForConnected(start: @escaping () -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            if Task.isCancelled {
                continuation.resume(throwing: CancellationError())
                return
            }
            self.connectContinuation = continuation
            start()
        }
    }

    private func driverStateChanged(_ state: AndroidTVDriver.ConnectionState,
                                    codeProvider: @escaping @MainActor () async throws -> String) {
        switch state {
        case .connected:
            disarmConnectTimeout()
            connectContinuation?.resume()
            connectContinuation = nil
        case .failed(let reason):
            disarmConnectTimeout()
            if reason == AndroidTVError.certificateChanged.localizedDescription {
                connectContinuation?.resume(throwing: AndroidTVError.certificateChanged)
            } else {
                connectContinuation?.resume(throwing: AndroidTVError.connectionFailed(detail: reason))
            }
            connectContinuation = nil
        case .pairing(.enterCode):
            // The TV is showing a code: the prompt is up, so the
            // connect timeout no longer applies (the user is in control
            // now). Ask for the code and submit what they type; a wrong
            // code re-prompts through this same state.
            disarmConnectTimeout()
            Task { [weak self] in
                guard let self, let driver = self.driver else { return }
                do {
                    let code = try await codeProvider()
                    driver.submitPairingCode(code)
                } catch {
                    // The user cancelled the prompt (or the session went
                    // away): stop pairing.
                    self.disconnect()
                }
            }
        case .unpaired:
            // The TV no longer knows our certificate (reset, or pairing
            // removed on the TV): pair from scratch — auto-pair-on-select.
            // Only once per connect; a second .unpaired is a real failure.
            if !pairingAttempted {
                pairingAttempted = true
                driver?.pair()
            } else {
                disarmConnectTimeout()
                connectContinuation?.resume(throwing: AndroidTVError.connectionFailed(
                    detail: "The TV isn't paired. Try connecting again."))
                connectContinuation = nil
            }
        case .pairing(.verifying), .pairing(.acceptOnTV), .connecting, .idle:
            break
        }
    }

    private func armConnectTimeout() {
        disarmConnectTimeout()
        connectTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard let self else { return }
            self.abortConnect(with: AndroidTVError.pairingTimeout)
        }
    }

    private func disarmConnectTimeout() {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
    }

    /// Tear the connection down and fail any in-flight connect with
    /// `error`. Idempotent: safe to call from disconnect, the timeout,
    /// and task cancellation paths.
    private func abortConnect(with error: Error) {
        disarmConnectTimeout()
        connectContinuation?.resume(throwing: error)
        connectContinuation = nil
        driver?.disconnect()
        driver = nil
        host = nil
    }

    /// Our Key (raw Android key codes) onto the driver's key enum.
    private static func driverKey(for key: Key) -> AndroidTVKey {
        if (7...16).contains(key.rawValue) { return .digit(key.rawValue - 7) }
        switch key {
        case .home: return .home
        case .back: return .back
        case .dpadUp: return .up
        case .dpadDown: return .down
        case .dpadLeft: return .left
        case .dpadRight: return .right
        case .dpadCenter: return .select
        case .volumeUp: return .volumeUp
        case .volumeDown: return .volumeDown
        case .power: return .power
        case .enter: return .enter
        case .menu: return .menu
        case .mediaPlayPause: return .playPause
        case .mediaStop: return .stop
        case .mediaRewind: return .rewind
        case .mediaFastForward: return .fastForward
        case .mediaPlay: return .play
        case .mediaPause: return .pause
        case .volumeMute: return .mute
        case .info: return .info
        case .channelUp: return .channelUp
        case .channelDown: return .channelDown
        case .backspace: return .backspace
        case .search: return .search
        case .input: return .input
        case .digit0, .digit1, .digit2, .digit3, .digit4,
             .digit5, .digit6, .digit7, .digit8, .digit9:
            // Handled by the rawValue branch above.
            return .digit(0)
        }
    }
}

// MARK: - Driver (ported from the fork's AndroidTVDriver)

/// A brand-agnostic remote button. Each driver maps these onto whatever its TV speaks.
/// (Ported from the fork's RemoteKey, plus .play / .pause / .stop —
/// our RemoteCommand has distinct play/pause/stop keys and the old
/// adapter sent codes 126 / 127 / 86 for them.)
/// Pure value type — explicitly nonisolated.
nonisolated enum AndroidTVKey: Hashable, Sendable {
    case power
    /// A full power-off, for TVs where the power key only toggles a standby or art mode.
    case powerOff
    case up, down, left, right, select
    case back, home, menu, info, input, search
    case volumeUp, volumeDown, mute
    case channelUp, channelDown
    case playPause, play, pause, stop, rewind, fastForward
    case backspace, enter, exit
    case digit(Int)
}

/// Android TV Remote Service protocol v2 — the same one Google's own TV remote uses.
/// Works with every Google TV / Android TV (Sony, TCL, Hisense, Philips, Chromecast, Shield…).
///
/// Port 6467: one-time pairing. The TV shows a 6-hex-digit code; we prove we saw it by
///            hashing it together with both certificates' RSA keys.
/// Port 6466: the remote session itself, authenticated by our client certificate.
///
/// Ported from the fork's AndroidTVDriver, adapted: no TVDevice / delegate
/// (host + paired flag + state closures instead), no app launching, no
/// foreground-app tracking, plus the certificate-pin check and voice.
/// (Ported from open-tv-remote, MIT License, Copyright (c) 2026 Nathan Butler.)
@MainActor
final class AndroidTVDriver {

    /// Pure value types — explicitly nonisolated.
    nonisolated enum PairingPrompt: Equatable, Sendable {
        /// The TV is showing a code the user must type in.
        case enterCode(length: Int, error: String?)
        /// The TV is showing an Allow / Deny dialog.
        case acceptOnTV
        /// We've sent the code and are waiting for the TV to confirm it.
        case verifying
    }

    nonisolated enum ConnectionState: Equatable, Sendable {
        case idle
        case connecting
        /// We have no credentials yet. Pairing only starts when the user asks,
        /// so nothing pops up on a TV someone else is watching.
        case unpaired
        case pairing(PairingPrompt)
        case connected
        case failed(String)

        var isConnected: Bool { self == .connected }
    }

    /// Called on every state change (the adapter watches this).
    var onStateChange: ((ConnectionState) -> Void)?
    /// Called when the paired flag changes (the adapter persists it).
    var onIsPairedChange: ((Bool) -> Void)?

    private(set) var state: ConnectionState = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    private(set) var isPaired: Bool {
        didSet { if isPaired != oldValue { onIsPairedChange?(isPaired) } }
    }

    /// The pinned server-certificate DER, when one is stored for this
    /// host (ours — the fork trusts any certificate). Checked after the
    /// remote handshake, before any message is sent; a mismatch fails
    /// with certificateChanged instead of silently re-trusting.
    var expectedServerCertificateDER: Data?

    /// DER of the certificate the remote channel's TV presented, if any.
    /// The adapter pins it on first successful connect (trust on first use).
    var remoteServerCertificateDER: Data? {
        remote?.peerCertificate.map { SecCertificateCopyData($0) as Data }
    }

    private let host: String
    private var remote: TLSChannel?
    private var pairing: TLSChannel?
    private var pendingKeys: [AndroidTVKey] = []
    private var imeCounter = 0
    private var imeFieldCounter = 0
    /// Shown alongside the next code prompt (e.g. after a wrong code forces a fresh one).
    private var nextPairingError: String?

    /// PING | KEY | IME | POWER | VOLUME | APP_LINK
    private static let requestedFeatures = 1 | 2 | 4 | 32 | 64 | 512
    private var activeFeatures = requestedFeatures

    init(host: String, isPaired: Bool) {
        self.host = host
        self.isPaired = isPaired
    }

    // MARK: Connection

    func connect() {
        guard isPaired else {
            state = .unpaired
            return
        }
        openRemote()
    }

    func disconnect() {
        pendingKeys = []
        remote?.onClose = nil
        remote?.cancel()
        remote = nil
        pairing?.onClose = nil
        pairing?.cancel()
        pairing = nil
        state = .idle
    }

    private func openRemote() {
        guard remote == nil else { return }
        let identity: ClientIdentity.Material
        do { identity = try ClientIdentity.loadOrCreate() } catch {
            state = .failed(error.localizedDescription)
            return
        }
        state = .connecting
        let channel = TLSChannel(host: host, port: 6466, identity: identity.identity)
        channel.onReady = { [weak self] in
            guard let self, let channel = self.remote else { return }
            // Pin check (ours — see expectedServerCertificateDER): after
            // the handshake, before any message is sent. A missing
            // certificate fails closed when a pin is set.
            if let expected = self.expectedServerCertificateDER {
                let presented = channel.peerCertificate.map { SecCertificateCopyData($0) as Data }
                guard let presented,
                      Self.certificateMatchesPin(presentedDER: presented, expectedDER: expected) else {
                    channel.onClose = nil
                    channel.cancel()
                    self.remote = nil
                    self.state = .failed(AndroidTVRemote.AndroidTVError.certificateChanged.localizedDescription)
                    return
                }
            }
        }
        channel.onMessage = { [weak self] in self?.handleRemote($0) }
        channel.onClose = { [weak self] error, tlsRejected in
            guard let self else { return }
            let wasConnected = self.state == .connected
            self.remote = nil
            if tlsRejected && !wasConnected {
                // The TV no longer knows our certificate (reset, or pairing removed on the TV).
                self.isPaired = false
                self.state = .unpaired
            } else if wasConnected {
                // TVs drop idle sessions. Go quiet; the next key press reconnects.
                self.state = .idle
            } else {
                self.state = .failed(Self.describe(error))
            }
        }
        remote = channel
        channel.start()
    }

    private func handleRemote(_ msg: ProtoMessage) {
        var reply = ProtoWriter()
        if let configure = msg.message(1) {
            let supported = configure.int(1) ?? Self.requestedFeatures
            activeFeatures = Self.requestedFeatures & (supported == 0 ? Self.requestedFeatures : supported)
            reply.message(1) { c in
                c.int(1, activeFeatures)
                c.message(2) { d in
                    d.int(3, 1)
                    d.string(4, "1")
                    d.string(5, "atvremote")
                    d.string(6, "1.0.0")
                }
            }
        } else if msg.has(2) {
            reply.message(2) { $0.int(1, activeFeatures) }
            markConnected()
        } else if let ping = msg.message(8) {
            reply.message(9) { $0.int(1, ping.int(1) ?? 0) }
        } else if msg.has(40) {
            markConnected()
            return
        } else if msg.has(20) {
            // RemoteImeKeyInject (foreground-app report): nothing to reply.
            return
        } else if let edit = msg.message(21) {
            imeCounter = edit.int(1) ?? imeCounter
            imeFieldCounter = edit.int(2) ?? imeFieldCounter
            return
        } else {
            return
        }
        remote?.send(reply)
    }

    private func markConnected() {
        guard state != .connected else { return }
        state = .connected
        let queued = pendingKeys
        pendingKeys = []
        queued.forEach(send)
    }

    // MARK: Pairing

    func pair() {
        disconnect()
        state = .connecting
        openPairingChannel()
    }

    /// Opens the pairing socket without touching `state`, so a retry can keep the code prompt on screen.
    private func openPairingChannel() {
        let identity: ClientIdentity.Material
        do { identity = try ClientIdentity.loadOrCreate() } catch {
            state = .failed(error.localizedDescription)
            return
        }
        let channel = TLSChannel(host: host, port: 6467, identity: identity.identity)
        channel.onReady = { [weak self] in
            self?.sendPairing { m in
                m.message(10) { r in
                    r.string(1, "atvremote")
                    r.string(2, Self.clientName(for: identity.certificate))
                }
            }
        }
        channel.onMessage = { [weak self] in self?.handlePairing($0) }
        channel.onClose = { [weak self] error, _ in
            guard let self, self.pairing != nil else { return }
            self.pairing = nil
            if !self.isPaired {
                self.state = .failed("Pairing was interrupted. \(Self.describe(error))")
            }
        }
        pairing = channel
        channel.start()
    }

    private func sendPairing(_ build: (inout ProtoWriter) -> Void) {
        var m = ProtoWriter()
        m.uint(1, 2)   // protocol_version
        m.uint(2, 200) // STATUS_OK
        build(&m)
        pairing?.send(m)
    }

    private func handlePairing(_ msg: ProtoMessage) {
        let status = msg.uint(2) ?? 0
        guard status == 200 else {
            pairing?.onClose = nil
            pairing?.cancel()
            pairing = nil
            if status == 402 {
                // The TV discards a code after one failed attempt; ask for a fresh one,
                // keeping the prompt up so the sheet doesn't close and reopen.
                let message = "That code didn't work. Your TV is showing a new one."
                nextPairingError = message
                state = .pairing(.enterCode(length: 6, error: message))
                openPairingChannel()
                return
            }
            state = .failed("The TV declined pairing (status \(status)).")
            return
        }
        // Hexadecimal code, 6 symbols, we are the input side.
        let encoding: (inout ProtoWriter) -> Void = { e in
            e.uint(1, 3)
            e.uint(2, 6)
        }
        if msg.has(11) {
            sendPairing { m in
                m.message(20) { o in
                    o.message(1, encoding)
                    o.uint(3, 1)
                }
            }
        } else if msg.has(20) {
            sendPairing { m in
                m.message(30) { c in
                    c.message(1, encoding)
                    c.uint(2, 1)
                }
            }
        } else if msg.has(31) {
            state = .pairing(.enterCode(length: 6, error: nextPairingError))
            nextPairingError = nil
        } else if msg.has(41) {
            isPaired = true
            let channel = pairing
            pairing = nil
            channel?.cancel()
            openRemote()
        }
    }

    func submitPairingCode(_ raw: String) {
        let code = raw.uppercased().filter { !$0.isWhitespace }
        guard code.count == 6, code.allSatisfy(\.isHexDigit) else {
            state = .pairing(.enterCode(length: 6, error: "Codes are 6 characters: 0–9 and A–F."))
            return
        }
        guard let serverCert = pairing?.peerCertificate,
              let identity = try? ClientIdentity.loadOrCreate(),
              let secret = Self.pairingSecret(code: code, clientCertificate: identity.certificate,
                                              serverCertificate: serverCert) else {
            state = .failed("Lost the pairing connection. Start pairing again.")
            return
        }
        let codeBytes = stride(from: 0, to: 6, by: 2).map { i -> UInt8 in
            let start = code.index(code.startIndex, offsetBy: i)
            return UInt8(code[start..<code.index(start, offsetBy: 2)], radix: 16)!
        }
        // The first byte of the code is a checksum: catches typos without a round trip.
        guard secret[0] == codeBytes[0] else {
            state = .pairing(.enterCode(length: 6, error: "That code doesn't match. Check the TV and try again."))
            return
        }
        state = .pairing(.verifying)
        sendPairing { m in m.message(40) { $0.data(1, Array(secret)) } }
    }

    /// The pairing secret: SHA-256 over the minimal big-endian bytes of
    /// client modulus, client exponent, server modulus, server exponent,
    /// then the code's last 4 hex chars (bytes 2–3) as bytes. Returns nil
    /// when the code isn't 6 hex chars or the certificates' RSA keys
    /// can't be read. The first-byte checksum is NOT checked here — the
    /// caller checks it (submitPairingCode re-prompts on a mismatch;
    /// the adapter's DER-based wrapper returns nil on a mismatch).
    nonisolated static func pairingSecret(code: String, clientCertificate: SecCertificate,
                                          serverCertificate: SecCertificate) -> Data? {
        guard code.count == 6, code.allSatisfy(\.isHexDigit),
              let client = ClientIdentity.rsaComponents(of: clientCertificate),
              let server = ClientIdentity.rsaComponents(of: serverCertificate) else { return nil }
        let codeBytes = stride(from: 0, to: 6, by: 2).map { i -> UInt8 in
            let start = code.index(code.startIndex, offsetBy: i)
            return UInt8(code[start..<code.index(start, offsetBy: 2)], radix: 16)!
        }
        var hash = SHA256()
        hash.update(data: client.modulus)
        hash.update(data: client.exponent)
        hash.update(data: server.modulus)
        hash.update(data: server.exponent)
        hash.update(data: Array(codeBytes.dropFirst()))
        return Data(hash.finalize())
    }

    // MARK: Commands

    func send(_ key: AndroidTVKey) {
        guard let code = Self.keyCode(key) else { return }
        guard state == .connected, let remote else {
            if isPaired {
                if pendingKeys.count < 10 { pendingKeys.append(key) }
                openRemote()
            }
            return
        }
        var m = ProtoWriter()
        m.message(10) { k in
            k.uint(1, UInt64(code))
            k.uint(2, 3) // SHORT press
        }
        remote.send(m)
    }

    func sendText(_ text: String) {
        guard !text.isEmpty, state == .connected else { return }
        let cursor = text.count - 1
        var m = ProtoWriter()
        m.message(21) { b in
            b.int(1, imeCounter)
            b.int(2, imeFieldCounter)
            b.message(3) { e in
                e.int(1, 1)
                e.message(2) { o in
                    o.int(1, cursor)
                    o.int(2, cursor)
                    o.string(3, text)
                }
            }
        }
        remote?.send(m)
    }

    // MARK: - Voice (port 6466 remote session; ours — the fork has no voice)

    /// Voice messages (remotemessage.proto, verified against
    /// tronikos/androidtvremote2 main 387de891):
    /// RemoteVoiceBegin = RemoteMessage field 30 { session_id field 1,
    /// package_name field 2 — not required when sending audio };
    /// RemoteVoicePayload = field 31 { session_id field 1, samples
    /// field 2 — 16-bit PCM mono 8 kHz, split into 20 KB messages };
    /// RemoteVoiceEnd = field 32 { session_id field 1 }.
    /// One session id per utterance (incrementing), consistent across
    /// begin/payload/end. Sent on the same TLS remote session as key
    /// events. No feature bit is requested for voice: the reference
    /// sends these messages on the established session.
    static let maxVoicePayloadBytes = 20 * 1024

    /// RemoteVoiceBegin for `sessionId` (no package_name — not required
    /// when sending audio). Unframed bytes; the channel frames on send.
    nonisolated static func voiceBeginMessage(sessionId: Int) -> Data {
        var m = ProtoWriter()
        m.message(30) { $0.uint(1, UInt64(sessionId)) }
        return Data(m.bytes)
    }

    /// RemoteVoicePayload carrying `samples` for `sessionId`. Unframed.
    nonisolated static func voicePayloadMessage(sessionId: Int, samples: Data) -> Data {
        var m = ProtoWriter()
        m.message(31) { b in
            b.uint(1, UInt64(sessionId))
            b.data(2, Array(samples))
        }
        return Data(m.bytes)
    }

    /// RemoteVoiceEnd for `sessionId`. Unframed.
    nonisolated static func voiceEndMessage(sessionId: Int) -> Data {
        var m = ProtoWriter()
        m.message(32) { $0.uint(1, UInt64(sessionId)) }
        return Data(m.bytes)
    }

    /// Split PCM samples into ≤20 KB payloads (the reference's message
    /// size). Empty input yields no chunks.
    nonisolated static func voicePayloadChunks(samples: Data) -> [Data] {
        guard !samples.isEmpty else { return [] }
        var chunks: [Data] = []
        var offset = 0
        while offset < samples.count {
            let end = min(offset + maxVoicePayloadBytes, samples.count)
            chunks.append(samples[offset..<end])
            offset = end
        }
        return chunks
    }

    func sendVoiceBegin(sessionId: Int) {
        guard state == .connected, let remote else { return }
        var m = ProtoWriter()
        m.message(30) { $0.uint(1, UInt64(sessionId)) }
        remote.send(m)
    }

    func sendVoiceSamples(_ samples: Data, sessionId: Int) {
        guard state == .connected, let remote else { return }
        for chunk in Self.voicePayloadChunks(samples: samples) {
            var m = ProtoWriter()
            m.message(31) { b in
                b.uint(1, UInt64(sessionId))
                b.data(2, Array(chunk))
            }
            remote.send(m)
        }
    }

    func sendVoiceEnd(sessionId: Int) {
        guard state == .connected, let remote else { return }
        var m = ProtoWriter()
        m.message(32) { $0.uint(1, UInt64(sessionId)) }
        remote.send(m)
    }

    // MARK: Helpers

    /// The pin predicate: with no pin stored, any certificate is accepted
    /// (trust on first use); with a pin, only the exact pinned DER.
    /// openRemote applies it after the handshake; tested directly.
    nonisolated static func certificateMatchesPin(presentedDER: Data, expectedDER: Data?) -> Bool {
        guard let expectedDER else { return true }
        return presentedDER == expectedDER
    }

    /// Shown on the TV while pairing. Tagged with the certificate's fingerprint so people can tell
    /// their devices apart. (What keeps pairings separate is the certificate; see ClientIdentity.)
    static func clientName(for certificate: SecCertificate) -> String {
        #if os(macOS)
        let kind = "Mac"
        #else
        let kind = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
        return "Universal Remote (\(kind) \(ClientIdentity.shortID(of: certificate)))"
    }

    private static func describe(_ error: NWError?) -> String {
        guard let error else { return "The TV closed the connection." }
        switch error {
        case .posix(let code) where code == .ECONNREFUSED: return "The TV refused the connection."
        case .posix(let code) where code == .ETIMEDOUT || code == .EHOSTUNREACH || code == .EHOSTDOWN:
            return "Couldn't reach the TV. Is it on and on the same Wi-Fi?"
        default: return "Couldn't connect to the TV."
        }
    }

    /// Android KeyEvent codes. (The fork's table, plus .play 126,
    /// .pause 127 and .stop 86 — our RemoteCommand has distinct
    /// play/pause/stop; .exit is 4, like .back.)
    private static func keyCode(_ key: AndroidTVKey) -> Int? {
        switch key {
        case .power: 26
        case .powerOff: nil
        case .up: 19
        case .down: 20
        case .left: 21
        case .right: 22
        case .select: 23
        case .back, .exit: 4
        case .home: 3
        case .menu: 82
        case .info: 165
        case .input: 178
        case .search: 84
        case .volumeUp: 24
        case .volumeDown: 25
        case .mute: 164
        case .channelUp: 166
        case .channelDown: 167
        case .playPause: 85
        case .play: 126
        case .pause: 127
        case .stop: 86
        case .rewind: 89
        case .fastForward: 90
        case .backspace: 67
        case .enter: 66
        case .digit(let n): (0...9).contains(n) ? 7 + n : nil
        }
    }
}
