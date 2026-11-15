import Foundation
import Network
import CryptoKit
import Security
#if canImport(UIKit)
import UIKit
#endif

/// Android TV / Google TV remote control — Android TV Remote protocol v2.
///
/// Verified against the actual protocol sources:
/// - `remotemessage.proto` / `polo.proto` / `pairing.py` / `remote.py` from
///   tronikos/androidtvremote2 (the same protocol the Google TV app uses).
///
/// Transport: mutual TLS. Pairing on port 6467 (TV shows a 6-digit hex
/// code; the client proves it saw the code with a SHA-256 secret bound to
/// both certificates), control on port 6466 with varint-framed protobuf.
/// No third-party dependencies: protobuf is hand-rolled, the client
/// certificate is minted with `X509`, TLS runs on Network.framework.
///
/// Text input is NOT implemented: IME batch edits need live counters from
/// `remote_ime_key_inject`, which are hardware-sensitive and cannot be
/// verified without a real TV. The UI hides the keyboard for Android TV.
actor AndroidTVRemote {
    /// Errors are step-named on purpose: the generic "Couldn't connect"
    /// hid which step failed. Each case says where the flow died, and
    /// the `detail` cases carry the underlying NWError/POSIX text.
    enum AndroidTVError: Error, LocalizedError {
        case pairingDenied
        case pairingTimeout
        case connectionFailed
        case invalidCode
        case notConnected
        case identityUnavailable(detail: String)
        case pairingTLSFailed(detail: String)
        case remoteSessionFailed(detail: String)
        case remoteSessionTimeout
        case secretRejected
        case certificateChanged

        var errorDescription: String? {
            switch self {
            case .pairingDenied:
                return "Pairing was refused. Check the TV and try again."
            case .pairingTimeout:
                return "Pairing timed out waiting for the TV to show its code."
            case .connectionFailed:
                return "Couldn't connect to the TV. Make sure it's on and on the same Wi-Fi network."
            case .invalidCode:
                return "That code doesn't look right — enter the 6-digit code shown on your TV."
            case .notConnected:
                return "Not connected to the TV."
            case .identityUnavailable(let detail):
                return "Couldn't create the secure identity needed for pairing. (\(detail))"
            case .pairingTLSFailed(let detail):
                return "Couldn't open the TV's secure pairing connection. (\(detail))"
            case .remoteSessionFailed(let detail):
                return "The TV's remote session failed. (\(detail))"
            case .remoteSessionTimeout:
                return "The TV didn't start the remote session in time."
            case .secretRejected:
                return "The TV didn't accept that code. Check the code on the TV and try again."
            case .certificateChanged:
                return "This TV's certificate changed since you paired it. Forget the TV and pair again."
            }
        }
    }

    /// Android key codes used (values from remotemessage.proto).
    enum Key: Int {
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

        static func digit(_ n: Int) -> Key? {
            Key(rawValue: 7 + n)
        }
    }

    /// The client name sent in PairingRequest — shown on the TV while
    /// pairing, tagged with the certificate's fingerprint so devices can
    /// be told apart. Mirrors the working reference app: its client name
    /// ("Open Remote (iPhone XXXX)") is NOT the certificate's CN, and
    /// the TV accepts it, so the name is a display string, not a
    /// protocol binding.
    static func clientName(for certificateDER: Data) -> String {
        #if os(macOS)
        let kind = "Mac"
        #else
        let kind = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
        return "Universal TV Remote (\(kind) \(X509.shortID(certificateDER: certificateDER)))"
    }

    /// Feature bits (RemoteConfigure code1) from remote.py.
    private static let featurePing = 1
    private static let featureKey = 2
    private static let featurePower = 32
    private static let featureVolume = 64
    private static let featureAppLink = 512
    /// We request everything except IME (text input is not implemented).
    private static let requestedFeatures = featurePing | featureKey | featurePower | featureVolume | featureAppLink // 611

    private var remoteConnection: TLSConnection?
    private var pairingConnection: TLSConnection?
    private var remoteHost: String?
    private var activeFeatures = 0
    private var readyContinuation: CheckedContinuation<Void, Error>?
    private var tlsReady = false
    private var tlsReadyContinuation: CheckedContinuation<Void, Error>?
    private var pairingCodeContinuation: CheckedContinuation<Void, Error>?
    private var secretContinuation: CheckedContinuation<Void, Error>?
    private var pairingServerCertificateDER: Data?
    /// The server certificate the remote session presented (port 6466),
    /// for pinning after a first connection succeeds.
    private var remoteServerCertificateDER: Data?
    /// What the (non-fatal) 6466 probe saw, when it failed — appended to
    /// the status if pairing then fails too, so the probe step is visible.
    private(set) var lastProbeNote: String?
    /// What the plain-TCP Network.framework check saw — appended to the
    /// status if pairing then fails too. Separates "Network.framework
    /// can't reach the TV from this guest" from "the TLS handshake fails".
    private(set) var lastTCPCheck: String?
    /// What the no-identity TLS probe saw — appended to the status if
    /// pairing then fails too. A TLS handshake with no client
    /// certificate: if the TV presents its certificate here while the
    /// mutual-TLS handshake dies with errSSLBadCert (-9808), our own
    /// client identity is what SecureTransport rejects.
    private(set) var lastNoIdentityProbe: String?
    /// What the raw-TLS handshake recorder saw on ports 6467 and 6466
    /// — appended to the status if pairing then fails too. The recorder
    /// opens a plain TCP connection, sends its own ClientHello, and
    /// reports the first thing the TV sends back (ServerHello version
    /// and cipher, whether a Certificate message arrived, and the
    /// certificate's CN / serial / signature algorithm) — the evidence
    /// for why the mutual-TLS handshake dies with -9808.
    private(set) var lastHandshakeRecord: String?

    // MARK: - Public API

    /// Connect to the TV, pairing first if needed.
    /// `codeProvider` is called on the main actor when the TV shows its
    /// pairing code; it returns the 6-digit code the user types in.
    func connect(to host: String,
                 codeProvider: @escaping @MainActor () async throws -> String) async throws {
        if remoteHost == host, remoteConnection != nil { return }
        disconnect()
        lastProbeNote = nil
        lastTCPCheck = nil
        lastNoIdentityProbe = nil
        lastHandshakeRecord = nil
        // Diagnostic only, run first: the sweep proved BSD sockets +
        // URLSession reach the TV from the guest, but the control path
        // uses NWConnection. If plain NW TCP also fails, the guest's
        // Network.framework path is broken — not the TLS handshake.
        // Cheap when healthy (ready arrives in milliseconds); 3s worst
        // case. Never thrown; the note is only surfaced if pairing fails.
        lastTCPCheck = await Self.plainTCPCheck(host: host, port: 6467)
        // Diagnostic only, same pattern: a TLS handshake to the pairing
        // port with NO client identity. If the TV presents its
        // certificate here while the mutual-TLS handshake dies with
        // errSSLBadCert (-9808), SecureTransport is rejecting OUR client
        // identity — not the TV. Never thrown; note only, never changes
        // the control path. 5s worst case, milliseconds when healthy.
        lastNoIdentityProbe = await Self.noIdentityTLSProbe(host: host, port: 6467)
        // Diagnostic only, same pattern: a raw-TLS handshake recorder
        // that sends its own ClientHello over plain TCP and reports
        // what the TV sends back. Both ports run at once (async let)
        // so the worst case is one 5s timeout, not two. Never thrown;
        // notes only, never changes the control path.
        async let record6467 = TLSHandshakeRecorder.record(host: host, port: 6467)
        async let record6466 = TLSHandshakeRecorder.record(host: host, port: 6466)
        let (rec6467, rec6466) = await (record6467, record6466)
        lastHandshakeRecord = "\(rec6467) \(rec6466)"

        // Try the remote session first: if the TV already trusts our
        // certificate (paired before, or the local flag was lost), this
        // just works — no code prompt. The session enforces the pinned
        // server certificate when one is stored for this host, and pins
        // the certificate on a first successful connection. (Previously
        // a paired TV went straight to pairing, which would demand a
        // code on every reconnect and silently re-pin over a changed
        // certificate — both wrong now that pinning exists.)
        do {
            try await openRemoteSession(host: host, timeout: 10)
            UserDefaults.standard.set(true, forKey: "androidtv.paired.\(host)")
            return
        } catch let error as AndroidTVError {
            // A pin mismatch is not a pairing problem: re-pairing here
            // would silently overwrite the pin, so surface it instead
            // and let the user forget the TV and pair again.
            if case .certificateChanged = error {
                disconnect()
                throw error
            }
            lastProbeNote = "Probe: \(error.localizedDescription)"
            disconnect()
        } catch {
            lastProbeNote = "Probe: \(error.localizedDescription)"
            disconnect()
        }
        do {
            try await pair(host: host, codeProvider: codeProvider)
        } catch {
            disconnect()
            throw error
        }
        try await openRemoteSession(host: host, timeout: 10)
        UserDefaults.standard.set(true, forKey: "androidtv.paired.\(host)")
    }

    /// Forget a TV: clears its pinned server certificate and the paired
    /// flag. The shared client identity is NOT deleted — it is bound to
    /// every TV this app has paired with, and deleting it would break
    /// the others. The next connect pairs from scratch and pins the
    /// TV's (new) certificate.
    func forget(host: String) {
        if remoteHost == host { disconnect() }
        Self.forgetTV(host: host)
    }

    /// Static forget: pin + paired flag only, no session needed.
    static func forgetTV(host: String) {
        AndroidTVPinStore.clear(for: host)
        UserDefaults.standard.removeObject(forKey: "androidtv.paired.\(host)")
    }

    func disconnect() {
        readyContinuation?.resume(throwing: CancellationError())
        readyContinuation = nil
        tlsReadyContinuation?.resume(throwing: CancellationError())
        tlsReadyContinuation = nil
        tlsReady = false
        pairingCodeContinuation?.resume(throwing: CancellationError())
        pairingCodeContinuation = nil
        secretContinuation?.resume(throwing: CancellationError())
        secretContinuation = nil
        remoteConnection?.stop()
        remoteConnection = nil
        pairingConnection?.stop()
        pairingConnection = nil
        remoteHost = nil
        activeFeatures = 0
    }

    func sendKey(_ key: Key, to host: String) async throws {
        guard remoteConnection != nil, remoteHost == host else {
            throw AndroidTVError.notConnected
        }
        // RemoteKeyInject: field 10 of RemoteMessage.
        let inject = Protobuf.varintField(1, UInt64(key.rawValue))
            + Protobuf.varintField(2, 3) // RemoteDirection.SHORT
        let message = Protobuf.messageField(10, inject)
        remoteConnection?.send(Protobuf.varint(UInt64(message.count)) + message)
    }

    // MARK: - Voice (port 6466 remote session)

    /// Voice messages (remotemessage.proto, verified against
    /// tronikos/androidtvremote2 main 387de891):
    /// RemoteVoiceBegin = RemoteMessage field 30 { session_id field 1,
    /// package_name field 2 — not required when sending audio };
    /// RemoteVoicePayload = field 31 { session_id field 1, samples
    /// field 2 — 16-bit PCM mono 8 kHz, split into 20 KB messages };
    /// RemoteVoiceEnd = field 32 { session_id field 1 }.
    /// One session id per utterance (incrementing), consistent across
    /// begin/payload/end. Sent on the same TLS remote session as key
    /// events — so on a TV whose handshake fails (-9808) voice cannot
    /// start either. No feature bit is requested for voice: the
    /// reference sends these messages on the established session.
    static let maxVoicePayloadBytes = 20 * 1024

    /// RemoteVoiceBegin for `sessionId` (no package_name — not required
    /// when sending audio).
    static func voiceBeginMessage(sessionId: Int) -> Data {
        Protobuf.messageField(30, Protobuf.varintField(1, UInt64(sessionId)))
    }

    /// RemoteVoicePayload carrying `samples` for `sessionId`.
    static func voicePayloadMessage(sessionId: Int, samples: Data) -> Data {
        Protobuf.messageField(31, Protobuf.varintField(1, UInt64(sessionId))
            + Protobuf.bytesField(2, samples))
    }

    /// RemoteVoiceEnd for `sessionId`.
    static func voiceEndMessage(sessionId: Int) -> Data {
        Protobuf.messageField(32, Protobuf.varintField(1, UInt64(sessionId)))
    }

    /// Split PCM samples into ≤20 KB payloads (the reference's message
    /// size). Empty input yields no chunks.
    static func voicePayloadChunks(samples: Data) -> [Data] {
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

    private var voiceSessionId = 0

    /// Begin a voice utterance: sends RemoteVoiceBegin and returns the
    /// session id to use for its payloads and end. Throws notConnected
    /// when the remote session is not up.
    func beginVoice() async throws -> Int {
        guard remoteConnection != nil else { throw AndroidTVError.notConnected }
        voiceSessionId += 1
        let id = voiceSessionId
        sendRemoteMessage(Self.voiceBeginMessage(sessionId: id))
        return id
    }

    /// Stream one chunk of 8 kHz mono Int16 PCM for the utterance
    /// `sessionId`, split into ≤20 KB payload messages.
    func sendVoiceSamples(_ samples: Data, sessionId: Int) async throws {
        guard remoteConnection != nil else { throw AndroidTVError.notConnected }
        for chunk in Self.voicePayloadChunks(samples: samples) {
            sendRemoteMessage(Self.voicePayloadMessage(sessionId: sessionId, samples: chunk))
        }
    }

    /// End a voice utterance.
    func endVoice(sessionId: Int) async throws {
        guard remoteConnection != nil else { throw AndroidTVError.notConnected }
        sendRemoteMessage(Self.voiceEndMessage(sessionId: sessionId))
    }

    // MARK: - Remote session (port 6466)

    private func openRemoteSession(host: String, timeout: TimeInterval) async throws {
        let identity: AndroidTVIdentity.Loaded
        do {
            identity = try AndroidTVIdentity.loadOrCreate()
        } catch {
            throw AndroidTVError.identityUnavailable(detail: error.localizedDescription)
        }
        guard let connection = TLSConnection(host: host, port: 6466, identity: identity.identity,
                                             expectedServerCertificateDER: AndroidTVPinStore.pinnedCertificateDER(for: host)) else {
            throw AndroidTVError.identityUnavailable(detail: "sec_identity_create returned nil")
        }
        remoteConnection = connection
        remoteHost = host
        remoteServerCertificateDER = nil
        connection.onServerCertificate = { [weak self] der in
            Task { await self?.setRemoteServerCertificate(der) }
        }
        connection.onMessage = { [weak self] data in
            Task { await self?.handleRemoteMessage(data) }
        }
        connection.onFailure = { [weak self] error in
            Task { await self?.remoteFailed(error) }
        }
        connection.start()
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await self.waitForReady() }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw AndroidTVError.remoteSessionTimeout
                }
                try await group.next()
                group.cancelAll()
            }
            // Trust on first use: if no pin is stored for this TV yet,
            // pin the certificate this session just verified. This
            // covers the probe first-connection and TVs paired before
            // pinning existed. A stored pin is never overwritten here —
            // the session only succeeded because the presented
            // certificate matched it.
            if AndroidTVPinStore.pinnedCertificateDER(for: host) == nil,
               let der = remoteServerCertificateDER {
                AndroidTVPinStore.set(der, for: host)
            }
            // The TV silently drops keys sent immediately after
            // remote_start; give it a beat before reporting ready.
            try await Task.sleep(nanoseconds: 400_000_000)
        } catch {
            disconnect()
            throw error
        }
    }

    private func waitForReady() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                readyContinuation = continuation
            }
        } onCancel: {
            Task { [weak self] in await self?.cancelPendingWait() }
        }
    }

    /// Resume whichever wait continuation is pending (only one ever is).
    /// `withCheckedThrowingContinuation` does not resume on cancellation,
    /// so without this a task-group timeout cancelling the wait would
    /// leave it suspended forever and the group would never return.
    private func cancelPendingWait() {
        readyContinuation?.resume(throwing: CancellationError())
        readyContinuation = nil
        tlsReadyContinuation?.resume(throwing: CancellationError())
        tlsReadyContinuation = nil
        pairingCodeContinuation?.resume(throwing: CancellationError())
        pairingCodeContinuation = nil
        secretContinuation?.resume(throwing: CancellationError())
        secretContinuation = nil
    }

    /// The error is passed in by the onFailure handler instead of being
    /// re-read from the connection: the handler's error is the one that
    /// killed the connection, and re-reading `lastFailure` loses it when
    /// the receive error beats the state update (the v1.0.4 race).
    private func remoteFailed(_ error: Error) {
        // A pin mismatch is a distinct, user-actionable failure: the
        // TV's certificate changed since pairing (e.g. the TV was
        // reset). Surface it as such — never silently fall back to
        // re-pairing.
        if remoteConnection?.pinMismatch == true {
            readyContinuation?.resume(throwing: AndroidTVError.certificateChanged)
            readyContinuation = nil
            remoteConnection = nil
            remoteHost = nil
            return
        }
        let detail = failureDetail(from: remoteConnection, error: error)
        readyContinuation?.resume(throwing: AndroidTVError.remoteSessionFailed(detail: detail))
        readyContinuation = nil
        remoteConnection = nil
        remoteHost = nil
    }

    private func setRemoteServerCertificate(_ der: Data) {
        remoteServerCertificateDER = der
    }

    /// One-line diagnosis for a dead TLS connection: the underlying
    /// NWError, plus whether the TV even presented its certificate.
    /// Server-cert-seen + handshake failure points at our client
    /// certificate being rejected; no cert seen means the handshake died
    /// before the TV's certificate arrived (TCP/TLS-level failure).
    /// The error passed in by the onFailure handler wins; `lastFailure`
    /// is only a fallback for paths that have no error to pass.
    private func failureDetail(from connection: TLSConnection?, error: Error?) -> String {
        var parts: [String] = []
        if let error = error ?? connection?.lastFailure {
            parts.append(Self.describeError(error))
        }
        if let connection {
            parts.append(connection.serverCertificateSeen
                ? "TV presented its certificate"
                : "no certificate received from the TV")
        }
        return parts.isEmpty ? "connection closed" : parts.joined(separator: "; ")
    }

    /// Readable text for an NWError: POSIX/DNS/TLS codes with their
    /// plain-language meaning, instead of the generic NSError string.
    private static func describeError(_ error: Error) -> String {
        guard let nw = error as? NWError else { return error.localizedDescription }
        switch nw {
        case .posix(let code):
            return "POSIX \(code.rawValue) (\(POSIXError(code).localizedDescription))"
        case .dns(let code):
            return "DNS error \(code)"
        case .tls(let status):
            // The OSStatus number identifies the failure (e.g. -9806 is
            // a handshake aborted by the peer); kept as a number on
            // purpose — SecCopyErrorMessageString is not used, to keep
            // the API surface minimal.
            return "TLS error \(status)"
        @unknown default:
            return String(describing: nw)
        }
    }

    // MARK: - Diagnostics

    /// Plain-TCP reachability via Network.framework, diagnostic only.
    /// Opens a non-TLS NWConnection to the pairing port and reports the
    /// outcome as a one-line note. Runs on its own serial queue so it
    /// never blocks the actor; the continuation is resumed exactly once.
    private static func plainTCPCheck(host: String, port: UInt16,
                                      timeout: TimeInterval = 3) async -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            let connection = NWConnection(host: NWEndpoint.Host(host),
                                          port: NWEndpoint.Port(rawValue: port)!,
                                          using: .tcp)
            let queue = DispatchQueue(label: "com.nicolassolley.universaltvremote.tcpcheck")
            var finished = false
            let finish: (String) -> Void = { note in
                guard !finished else { return }
                finished = true
                connection.cancel()
                continuation.resume(returning: note)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish("NW TCP to \(port): connected")
                case .failed(let error):
                    finish("NW TCP to \(port) failed: \(describeError(error))")
                case .cancelled:
                    finish("NW TCP to \(port): cancelled")
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                finish("NW TCP to \(port): no answer in \(Int(timeout))s")
            }
        }
    }

    /// TLS handshake to the pairing port WITHOUT a client identity,
    /// diagnostic only. Same TLS options and verify block as the real
    /// path, but no local identity is set, so SecureTransport has
    /// nothing of ours to reject. Reports whether the TV presents its
    /// certificate when we offer no identity at all — the decisive
    /// discriminator for errSSLBadCert (-9808): cert arrives here while
    /// mutual TLS dies => our client identity is the problem; identical
    /// failure here => the TV's certificate or the ClientHello itself.
    /// No pairing bytes are sent and the connection is torn down after
    /// the handshake outcome (or a timeout). Runs on its own serial
    /// queue; the continuation is resumed exactly once.
    private static func noIdentityTLSProbe(host: String, port: UInt16,
                                           timeout: TimeInterval = 5) async -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            let connection = TLSConnection(host: host, port: port)
            let queue = DispatchQueue(label: "com.nicolassolley.universaltvremote.noidprobe")
            var finished = false
            let finish: (String) -> Void = { note in
                guard !finished else { return }
                finished = true
                connection.stop()
                continuation.resume(returning: note)
            }
            // The verify block fires during the handshake, before .ready:
            // if it fires, the TV presented its certificate.
            connection.onServerCertificate = { _ in
                finish("TLS without client cert: TV presented its certificate")
            }
            connection.onReady = {
                finish("TLS without client cert: handshake completed, no certificate seen")
            }
            connection.onFailure = { error in
                finish("TLS without client cert: still failed before certificate (\(describeError(error)))")
            }
            connection.start()
            queue.asyncAfter(deadline: .now() + timeout) {
                finish("TLS without client cert: no answer in \(Int(timeout))s")
            }
        }
    }

    private func handleRemoteMessage(_ data: Data) {
        var reader = Protobuf.Reader(data: data)
        while let (field, wireType) = reader.readTag() {
            switch (field, wireType) {
            case (1, 2): // remote_configure
                guard let payload = reader.readBytes() else { return }
                replyToConfigure(payload)
            case (2, 2): // remote_set_active
                sendRemoteMessage(Protobuf.messageField(2, Protobuf.varintField(1, UInt64(activeFeatures))))
                // The reference marks the session connected on set_active
                // as well as remote_start; some TVs send only one of
                // them. The second resume is a no-op (continuation nilled).
                readyContinuation?.resume()
                readyContinuation = nil
            case (8, 2): // remote_ping_request
                guard let payload = reader.readBytes() else { return }
                replyToPing(payload)
            case (40, 2): // remote_start
                readyContinuation?.resume()
                readyContinuation = nil
            default:
                _ = reader.skipField(wireType: wireType)
            }
        }
    }

    private func replyToConfigure(_ payload: Data) {
        var reader = Protobuf.Reader(data: payload)
        var deviceFeatures = 0
        while let (field, wireType) = reader.readTag() {
            if field == 1, wireType == 0, let value = reader.readVarint() {
                deviceFeatures = Int(value)
            } else {
                _ = reader.skipField(wireType: wireType)
            }
        }
        activeFeatures = Self.requestedFeatures & deviceFeatures
        // Reply with our features + device info.
        let deviceInfo = Protobuf.varintField(3, 1) // unknown1 = 1
            + Protobuf.stringField(4, "1") // unknown2 = "1"
            + Protobuf.stringField(5, "atvremote") // package_name
            + Protobuf.stringField(6, "1.0.0") // app_version
        let configure = Protobuf.varintField(1, UInt64(activeFeatures))
            + Protobuf.messageField(2, deviceInfo)
        sendRemoteMessage(Protobuf.messageField(1, configure))
    }

    private func replyToPing(_ payload: Data) {
        var reader = Protobuf.Reader(data: payload)
        var val1: UInt64 = 0
        while let (field, wireType) = reader.readTag() {
            if field == 1, wireType == 0, let value = reader.readVarint() {
                val1 = value
            } else {
                _ = reader.skipField(wireType: wireType)
            }
        }
        let response = Protobuf.varintField(1, val1)
        sendRemoteMessage(Protobuf.messageField(9, response))
    }

    private func sendRemoteMessage(_ message: Data) {
        remoteConnection?.send(Protobuf.varint(UInt64(message.count)) + message)
    }

    // MARK: - Pairing (port 6467)

    private func pair(host: String,
                      codeProvider: @escaping @MainActor () async throws -> String) async throws {
        let identity: AndroidTVIdentity.Loaded
        do {
            identity = try AndroidTVIdentity.loadOrCreate()
        } catch {
            throw AndroidTVError.identityUnavailable(detail: error.localizedDescription)
        }
        guard let connection = TLSConnection(host: host, port: 6467, identity: identity.identity) else {
            throw AndroidTVError.identityUnavailable(detail: "sec_identity_create returned nil")
        }
        pairingConnection = connection
        pairingServerCertificateDER = nil
        tlsReady = false
        connection.onServerCertificate = { [weak self] der in
            Task { await self?.setPairingServerCertificate(der) }
        }
        connection.onMessage = { [weak self] data in
            Task { await self?.handlePairingMessage(data) }
        }
        connection.onFailure = { [weak self] error in
            Task { await self?.pairingFailed(error) }
        }
        connection.onReady = { [weak self] in
            Task { await self?.tlsReadyFired() }
        }
        connection.start()

        // Wait for the TLS handshake to finish before sending anything:
        // the reference sends the pairing request only after the
        // handshake completes, and app data sent pre-handshake may never
        // reach the TV.
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await self.waitForTLSReady() }
                group.addTask {
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                    throw AndroidTVError.pairingTLSFailed(detail: "secure handshake didn't finish in 10s")
                }
                try await group.next()
                group.cancelAll()
            }
        } catch {
            disconnect()
            throw error
        }

        // 1. Pairing request.
        let request = Protobuf.stringField(1, "atvremote") // service_name
            + Protobuf.stringField(2, Self.clientName(for: identity.certificateDER)) // client_name
        try await sendPairingMessage(outerMessage(Protobuf.messageField(10, request)))

        // 2. Wait until the TV shows the code (configuration_ack received).
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await self.waitForPairingCode() }
                group.addTask {
                    try await Task.sleep(nanoseconds: 60_000_000_000)
                    throw AndroidTVError.pairingTimeout
                }
                try await group.next()
                group.cancelAll()
            }
        } catch {
            disconnect()
            throw error
        }

        // 3. Ask the user for the code, then prove it with the secret hash.
        // No timeout: the user exits via Cancel, and disconnect() cancels
        // the wait. (A timeout that cancelled the provider task would
        // leave its continuation suspended forever.)
        let code: String
        do {
            code = try await codeProvider()
        } catch {
            disconnect()
            throw error
        }
        let cleanCode = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard cleanCode.count == 6, Int(cleanCode, radix: 16) != nil else {
            disconnect()
            throw AndroidTVError.invalidCode
        }
        guard let secret = computeSecret(code: cleanCode, clientCertificateDER: identity.certificateDER) else {
            disconnect()
            throw AndroidTVError.pairingDenied
        }
        let secretMessage = Protobuf.bytesField(1, secret)
        try await sendPairingMessage(outerMessage(Protobuf.messageField(40, secretMessage)))

        // 4. Wait for secret_ack.
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await self.waitForSecretAck() }
                group.addTask {
                    try await Task.sleep(nanoseconds: 30_000_000_000)
                    throw AndroidTVError.secretRejected
                }
                try await group.next()
                group.cancelAll()
            }
        } catch {
            disconnect()
            throw error
        }

        // Pairing succeeded: trust on first use — persist the TV's
        // certificate as the pin for this host, so later connections
        // enforce it. A re-pair (e.g. after the TV was reset) replaces
        // a stale pin with the TV's new certificate.
        if let der = pairingServerCertificateDER {
            AndroidTVPinStore.set(der, for: host)
        }

        pairingConnection?.stop()
        pairingConnection = nil
    }

    private func setPairingServerCertificate(_ der: Data) {
        pairingServerCertificateDER = der
    }

    private func tlsReadyFired() {
        tlsReady = true
        tlsReadyContinuation?.resume()
        tlsReadyContinuation = nil
    }

    private func waitForTLSReady() async throws {
        if tlsReady { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                tlsReadyContinuation = continuation
            }
        } onCancel: {
            Task { [weak self] in await self?.cancelPendingWait() }
        }
    }

    private func waitForPairingCode() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                pairingCodeContinuation = continuation
            }
        } onCancel: {
            Task { [weak self] in await self?.cancelPendingWait() }
        }
    }

    private func waitForSecretAck() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                secretContinuation = continuation
            }
        } onCancel: {
            Task { [weak self] in await self?.cancelPendingWait() }
        }
    }

    private func pairingFailed(_ error: Error) {
        let detail = failureDetail(from: pairingConnection, error: error)
        let error = AndroidTVError.pairingTLSFailed(detail: detail)
        tlsReadyContinuation?.resume(throwing: error)
        tlsReadyContinuation = nil
        pairingCodeContinuation?.resume(throwing: error)
        pairingCodeContinuation = nil
        secretContinuation?.resume(throwing: error)
        secretContinuation = nil
        // Tear down the dead pairing connection so a later send fails fast
        // (notConnected) instead of waiting out the secret_ack timeout.
        pairingConnection?.stop()
        pairingConnection = nil
    }

    private func sendPairingMessage(_ message: Data) async throws {
        guard let connection = pairingConnection else { throw AndroidTVError.notConnected }
        connection.send(Protobuf.varint(UInt64(message.count)) + message)
    }

    private func outerMessage(_ inner: Data) -> Data {
        // protocol_version = 2, status = STATUS_OK (200).
        Protobuf.varintField(1, 2) + Protobuf.varintField(2, 200) + inner
    }

    private func handlePairingMessage(_ data: Data) {
        var reader = Protobuf.Reader(data: data)
        var status = 200
        var presentField: Int?
        while let (field, wireType) = reader.readTag() {
            if field == 2, wireType == 0, let value = reader.readVarint() {
                status = Int(value)
            } else if wireType == 2, let payload = reader.readBytes() {
                // Remember which top-level field arrived; payload parsed by caller.
                if [11, 20, 31, 41].contains(field) {
                    presentField = field
                }
                _ = payload
            } else {
                _ = reader.skipField(wireType: wireType)
            }
        }
        guard status == 200 else {
            // Non-OK status: which step it kills depends on what we were
            // waiting for. Only one continuation is ever pending, so only
            // one of these resumes.
            pairingCodeContinuation?.resume(throwing: AndroidTVError.pairingDenied)
            pairingCodeContinuation = nil
            secretContinuation?.resume(throwing: AndroidTVError.secretRejected)
            secretContinuation = nil
            return
        }
        switch presentField {
        case 11: // pairing_request_ack → send options
            let encoding = Protobuf.varintField(1, 3) // HEXADECIMAL
                + Protobuf.varintField(2, 6) // symbol_length
            let options = Protobuf.messageField(1, encoding)
                + Protobuf.varintField(3, 1) // preferred_role INPUT
            Task { try? await self.sendPairingMessage(self.outerMessage(Protobuf.messageField(20, options))) }
        case 20: // options → send configuration
            let encoding = Protobuf.varintField(1, 3) + Protobuf.varintField(2, 6)
            let configuration = Protobuf.messageField(1, encoding)
                + Protobuf.varintField(2, 1) // client_role INPUT
            Task { try? await self.sendPairingMessage(self.outerMessage(Protobuf.messageField(30, configuration))) }
        case 31: // configuration_ack → TV is showing the code
            pairingCodeContinuation?.resume()
            pairingCodeContinuation = nil
        case 41: // secret_ack → paired
            secretContinuation?.resume()
            secretContinuation = nil
        default:
            break
        }
    }

    /// The pairing secret: SHA-256 over the minimal big-endian bytes of
    /// client modulus, client exponent, server modulus, server exponent,
    /// then the last 4 hex chars of the code as bytes. The first byte of
    /// the hash must equal the code's first byte (checked by the TV too).
    /// Static (and nonisolated) so unit tests can verify it against a
    /// known vector without a TV.
    static func pairingSecret(code: String, clientCertificateDER: Data,
                              serverCertificateDER: Data) -> Data? {
        guard let clientKeys = X509.rsaModulusExponent(certificateDER: clientCertificateDER),
              let serverKeys = X509.rsaModulusExponent(certificateDER: serverCertificateDER),
              let codeSuffix = Data(hexString: String(code.dropFirst(2))) else {
            return nil
        }
        var hasher = SHA256()
        hasher.update(data: clientKeys.modulus)
        hasher.update(data: clientKeys.exponent)
        hasher.update(data: serverKeys.modulus)
        hasher.update(data: serverKeys.exponent)
        hasher.update(data: codeSuffix)
        let digest = Data(hasher.finalize())
        guard digest.first == UInt8(code.prefix(2), radix: 16) else { return nil }
        return digest
    }

    private func computeSecret(code: String, clientCertificateDER: Data) -> Data? {
        guard let serverDER = pairingServerCertificateDER else { return nil }
        return Self.pairingSecret(code: code, clientCertificateDER: clientCertificateDER,
                                  serverCertificateDER: serverDER)
    }
}

// MARK: - TLS connection helper

/// A mutual-TLS connection that delivers complete varint-framed protobuf
/// messages via `onMessage`. Accepts any server certificate on first
/// trust (TVs use self-signed ones) and reports the presented
/// certificate DER so pairing can hash it — but once a pin is set for
/// the host (`expectedServerCertificateDER`), only that exact
/// certificate is accepted. A mismatch fails the handshake and is
/// flagged via `pinMismatch` so the caller can surface it distinctly
/// instead of as a generic TLS failure.
final class TLSConnection {
    var onMessage: ((Data) -> Void)?
    var onReady: (() -> Void)?
    var onFailure: ((Error) -> Void)?
    var onServerCertificate: ((Data) -> Void)?

    private let connection: NWConnection
    private let tlsOptions: NWProtocolTLS.Options
    private var buffer = Data()
    private var stopped = false
    /// True once the TV presented its certificate during the handshake.
    var serverCertificateSeen = false
    /// The error the connection failed with, if any.
    var lastFailure: Error?
    /// The pinned server-certificate DER for this host, if one is
    /// stored. Nil means trust on first use (pairing / first connect).
    let expectedServerCertificateDER: Data?
    /// True when the handshake failed because the TV presented a
    /// certificate different from the pin (or none at all while a pin
    /// is set). Read by the actor to surface a distinct error.
    var pinMismatch = false

    /// Whether the presented server certificate satisfies the pin: any
    /// certificate is accepted when no pin is set (trust on first use);
    /// with a pin set, only the exact pinned DER is accepted.
    static func certificateMatchesPin(presentedDER: Data, expectedDER: Data?) -> Bool {
        guard let expectedDER else { return true }
        return presentedDER == expectedDER
    }

    /// TLS options shared by both paths: bare defaults, exactly like
    /// the working reference app — no min/max TLS version is set, so
    /// the handshake negotiates the highest version the TV offers
    /// (TLS 1.3 included). v1.0.5 pinned min+max to TLS 1.2 and v1.0.9
    /// set min TLS 1.2; both failed identically on the QM7 (-9808),
    /// while the reference app pairs it with bare defaults, so the
    /// explicit version setting was itself a difference to remove.
    /// The client identity, verify block, and trust-on-first-use
    /// pinning are unchanged; nothing here disables TLS security.
    private static func baseTLSOptions() -> NWProtocolTLS.Options {
        NWProtocolTLS.Options()
    }

    /// Failable: if `sec_identity_create` returns nil there is no client
    /// identity to present, and mutual TLS cannot succeed — the caller
    /// must surface identityUnavailable instead of connecting without
    /// one (the TV would kill the handshake and the failure would look
    /// like a generic connection error).
    init?(host: String, port: UInt16, identity: SecIdentity,
          expectedServerCertificateDER: Data? = nil) {
        let tlsOptions = Self.baseTLSOptions()
        guard let secIdentity = sec_identity_create(identity) else { return nil }
        // This API takes only the identity — there is no queue parameter
        // (older examples show a three-argument form that no longer exists).
        sec_protocol_options_set_local_identity(
            tlsOptions.securityProtocolOptions, secIdentity)
        self.tlsOptions = tlsOptions
        self.expectedServerCertificateDER = expectedServerCertificateDER
        // TCP options mirror the reference app: a 6s connect timeout and
        // noDelay. No service class is set (the reference sets none).
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.connectionTimeout = 6
        tcpOptions.noDelay = true
        let parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        connection = NWConnection(host: NWEndpoint.Host(host),
                                  port: NWEndpoint.Port(rawValue: port)!,
                                  using: parameters)
    }

    /// No-identity TLS connection (diagnostic probe only): same TLS
    /// options and verify block as the mutual-TLS path, but no client
    /// certificate is presented, so SecureTransport has nothing of ours
    /// to reject. Never used for pairing or control.
    init(host: String, port: UInt16) {
        let tlsOptions = Self.baseTLSOptions()
        self.tlsOptions = tlsOptions
        self.expectedServerCertificateDER = nil
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.connectionTimeout = 6
        tcpOptions.noDelay = true
        let parameters = NWParameters(tls: tlsOptions, tcp: tcpOptions)
        connection = NWConnection(host: NWEndpoint.Host(host),
                                  port: NWEndpoint.Port(rawValue: port)!,
                                  using: parameters)
    }

    func start() {
        // The verify block must be set before the handshake starts, but it
        // cannot be created in init: it captures self, and self is not
        // fully initialized until `connection` is assigned. Setting it
        // here (still before connection.start) takes effect for the
        // handshake. It reports the presented certificate DER so pairing
        // can hash it, and enforces the pin when one is set: with no pin
        // (trust on first use) any certificate is accepted; with a pin,
        // only the exact pinned DER is accepted, and a mismatch fails
        // the handshake and is flagged via `pinMismatch` — never
        // silently accepted. The trust is read the reference app's way
        // (sec_trust_copy_ref + SecTrustCopyCertificateChain, leaf
        // first), on the main queue, like the reference app.
        sec_protocol_options_set_verify_block(
            tlsOptions.securityProtocolOptions, { [weak self] _, trust, complete in
                let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                if let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
                   let certificate = chain.first {
                    let der = SecCertificateCopyData(certificate) as Data
                    self?.serverCertificateSeen = true
                    self?.onServerCertificate?(der)
                    if !Self.certificateMatchesPin(presentedDER: der,
                                                   expectedDER: self?.expectedServerCertificateDER) {
                        self?.pinMismatch = true
                        complete(false)
                        return
                    }
                } else if self?.expectedServerCertificateDER != nil {
                    // A pin is set but the TV presented no certificate at
                    // all: fail closed rather than accepting a
                    // certificate-less handshake.
                    self?.pinMismatch = true
                    complete(false)
                    return
                }
                complete(true)
            }, .main)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.stopped else { return }
            switch state {
            case .ready:
                self.onReady?()
            case .failed(let error):
                self.lastFailure = error
                self.onFailure?(error)
            case .waiting(let error):
                // Unreachable host or refused connection: don't hang
                // around for the caller's timeout — fail fast, like the
                // reference app.
                self.lastFailure = error
                self.onFailure?(error)
            case .cancelled:
                self.lastFailure = nil
                self.onFailure?(NSError(domain: "TLSConnection", code: 0,
                    userInfo: [NSLocalizedDescriptionKey: "The TV closed the connection."]))
            default:
                break
            }
        }
        connection.start(queue: .main)
        receiveLoop()
    }

    func send(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    func stop() {
        stopped = true
        connection.cancel()
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, !self.stopped else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drainMessages()
            }
            if let error {
                // Record the failure here too: the stateUpdateHandler's
                // .failed branch is a separate, racy delivery, and if
                // this receive error wins the race the actor would
                // otherwise read lastFailure == nil and lose the real
                // NWError text entirely (exactly what v1.0.4 showed).
                self.lastFailure = error
                self.onFailure?(error)
                return
            }
            if isComplete {
                // The TV closed the connection cleanly: stop receiving
                // and surface the close instead of looping on a dead
                // socket (the reference app cancels + finishes here).
                self.lastFailure = nil
                self.onFailure?(NSError(domain: "TLSConnection", code: 0,
                    userInfo: [NSLocalizedDescriptionKey: "The TV closed the connection."]))
                return
            }
            self.receiveLoop()
        }
    }

    private func drainMessages() {
        while let (length, prefix) = Protobuf.readLengthPrefix(buffer) {
            guard length >= 0, buffer.count >= prefix + length else { return }
            let message = Data(buffer[prefix..<(prefix + length)])
            buffer.removeFirst(prefix + length)
            onMessage?(message)
        }
    }
}

private extension Data {
    /// Hex string (even length, case-insensitive) → bytes. Nil on bad input.
    init?(hexString: String) {
        guard hexString.count % 2 == 0 else { return nil }
        var data = Data()
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}
