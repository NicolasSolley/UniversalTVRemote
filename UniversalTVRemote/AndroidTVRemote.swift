import Foundation
import Network
import CryptoKit
import Security

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
    enum AndroidTVError: Error, LocalizedError {
        case pairingDenied
        case pairingTimeout
        case connectionFailed
        case invalidCode
        case notConnected
        case identityUnavailable

        var errorDescription: String? {
            switch self {
            case .pairingDenied:
                return "Pairing was refused. Check the TV and try again."
            case .pairingTimeout:
                return "Pairing timed out. Make sure the TV is on and showing the code."
            case .connectionFailed:
                return "Couldn't connect to the TV. Make sure it's on and on the same Wi-Fi network."
            case .invalidCode:
                return "That code doesn't look right — enter the 6-digit code shown on your TV."
            case .notConnected:
                return "Not connected to the TV."
            case .identityUnavailable:
                return "Couldn't create the secure identity needed for pairing."
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
    private var pairingCodeContinuation: CheckedContinuation<Void, Error>?
    private var secretContinuation: CheckedContinuation<Void, Error>?
    private var pairingServerCertificateDER: Data?

    // MARK: - Public API

    /// Connect to the TV, pairing first if needed.
    /// `codeProvider` is called on the main actor when the TV shows its
    /// pairing code; it returns the 6-digit code the user types in.
    func connect(to host: String,
                 codeProvider: @escaping @MainActor () async throws -> String) async throws {
        if remoteHost == host, remoteConnection != nil { return }
        disconnect()

        let paired = UserDefaults.standard.bool(forKey: "androidtv.paired.\(host)")
        if !paired {
            // Cheap probe: the TV may already trust our certificate even
            // if the local flag was lost. Short timeout so pairing follows fast.
            do {
                try await openRemoteSession(host: host, timeout: 5)
                UserDefaults.standard.set(true, forKey: "androidtv.paired.\(host)")
                return
            } catch {
                disconnect()
            }
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

    func disconnect() {
        readyContinuation?.resume(throwing: CancellationError())
        readyContinuation = nil
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

    // MARK: - Remote session (port 6466)

    private func openRemoteSession(host: String, timeout: TimeInterval) async throws {
        let identity = try AndroidTVIdentity.loadOrCreate()
        let connection = TLSConnection(host: host, port: 6466, identity: identity.identity)
        remoteConnection = connection
        remoteHost = host
        connection.onMessage = { [weak self] data in
            Task { await self?.handleRemoteMessage(data) }
        }
        connection.onFailure = { [weak self] _ in
            Task { await self?.remoteFailed() }
        }
        connection.start()
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await self.waitForReady() }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    throw AndroidTVError.connectionFailed
                }
                try await group.next()
                group.cancelAll()
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
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            readyContinuation = continuation
        }
    }

    private func remoteFailed() {
        readyContinuation?.resume(throwing: AndroidTVError.connectionFailed)
        readyContinuation = nil
        remoteConnection = nil
        remoteHost = nil
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
        let identity = try AndroidTVIdentity.loadOrCreate()
        let connection = TLSConnection(host: host, port: 6467, identity: identity.identity)
        pairingConnection = connection
        pairingServerCertificateDER = nil
        connection.onServerCertificate = { [weak self] der in
            Task { await self?.setPairingServerCertificate(der) }
        }
        connection.onMessage = { [weak self] data in
            Task { await self?.handlePairingMessage(data) }
        }
        connection.onFailure = { [weak self] _ in
            Task { await self?.pairingFailed() }
        }
        connection.start()

        // 1. Pairing request.
        let request = Protobuf.stringField(1, "atvremote") // service_name
            + Protobuf.stringField(2, "UniversalTVRemote") // client_name
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
                    throw AndroidTVError.pairingDenied
                }
                try await group.next()
                group.cancelAll()
            }
        } catch {
            disconnect()
            throw error
        }

        pairingConnection?.stop()
        pairingConnection = nil
    }

    private func setPairingServerCertificate(_ der: Data) {
        pairingServerCertificateDER = der
    }

    private func waitForPairingCode() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pairingCodeContinuation = continuation
        }
    }

    private func waitForSecretAck() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            secretContinuation = continuation
        }
    }

    private func pairingFailed() {
        pairingCodeContinuation?.resume(throwing: AndroidTVError.connectionFailed)
        pairingCodeContinuation = nil
        secretContinuation?.resume(throwing: AndroidTVError.connectionFailed)
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
            pairingCodeContinuation?.resume(throwing: AndroidTVError.pairingDenied)
            pairingCodeContinuation = nil
            secretContinuation?.resume(throwing: AndroidTVError.pairingDenied)
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
    private func computeSecret(code: String, clientCertificateDER: Data) -> Data? {
        guard let serverDER = pairingServerCertificateDER,
              let clientKeys = X509.rsaModulusExponent(certificateDER: clientCertificateDER),
              let serverKeys = X509.rsaModulusExponent(certificateDER: serverDER),
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
}

// MARK: - TLS connection helper

/// A mutual-TLS connection that delivers complete varint-framed protobuf
/// messages via `onMessage`. Accepts any server certificate (TVs use
/// self-signed ones) and reports the presented certificate DER so pairing
/// can hash it.
final class TLSConnection {
    var onMessage: ((Data) -> Void)?
    var onReady: (() -> Void)?
    var onFailure: ((Error) -> Void)?
    var onServerCertificate: ((Data) -> Void)?

    private let connection: NWConnection
    private let tlsOptions: NWProtocolTLS.Options
    private let queue = DispatchQueue(label: "com.nicolassolley.universaltvremote.tls")
    private var buffer = Data()
    private var stopped = false

    init(host: String, port: UInt16, identity: SecIdentity) {
        let tlsOptions = NWProtocolTLS.Options()
        let secIdentity = sec_identity_create(identity)
        if let secIdentity {
            // This API takes only the identity — there is no queue parameter
            // (older examples show a three-argument form that no longer exists).
            sec_protocol_options_set_local_identity(
                tlsOptions.securityProtocolOptions, secIdentity)
        }
        self.tlsOptions = tlsOptions
        let parameters = NWParameters(tls: tlsOptions)
        // No `.interactive` case exists; `.responsiveData` is the service
        // class for traffic the user is actively waiting on.
        parameters.serviceClass = .responsiveData
        connection = NWConnection(host: NWEndpoint.Host(host),
                                  port: NWEndpoint.Port(rawValue: port)!,
                                  using: parameters)
    }

    func start() {
        // The verify block must be set before the handshake starts, but it
        // cannot be created in init: it captures self, and self is not
        // fully initialized until `connection` is assigned. Setting it
        // here (still before connection.start) takes effect for the
        // handshake. It accepts any server certificate (TVs use self-signed
        // ones) and reports the presented certificate DER so pairing can
        // hash it.
        sec_protocol_options_set_verify_block(
            tlsOptions.securityProtocolOptions, { [weak self] _, trust, complete in
                if let trust, let certificate = SecTrustGetCertificateAtIndex(trust, 0) {
                    let der = SecCertificateCopyData(certificate) as Data
                    self?.onServerCertificate?(der)
                }
                complete(true)
            }, queue)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onReady?()
            case .failed(let error):
                self.onFailure?(error)
            default:
                break
            }
        }
        connection.start(queue: queue)
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
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self, !self.stopped else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drainMessages()
            }
            if let error {
                self.onFailure?(error)
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
