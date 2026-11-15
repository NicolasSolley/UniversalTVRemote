import Foundation
import CryptoKit
import Network

/// Raw-TLS handshake recorder (diagnostic only).
///
/// Opens a plain TCP connection to a TV's port, sends a hand-built TLS
/// ClientHello (offering TLS 1.2 and 1.3, no SNI — the TV is addressed
/// by IP), and reports the first thing the TV sends back. That is the
/// evidence for why the mutual-TLS handshake dies with errSSLBadCert
/// (-9808) before the TV's certificate arrives: the negotiated version
/// and cipher, whether a Certificate message arrived, and the
/// certificate's subject, serial, and signature algorithm parsed from
/// its DER. Runs alongside the normal connect path, never instead of
/// it, and never sends pairing bytes.
enum TLSHandshakeRecorder {

    /// One-line summary for one port, e.g.:
    /// "Recorder 6467: ServerHello TLS 1.3, cipher 0x1301; following
    /// records encrypted — cert not visible in cleartext"
    /// "Recorder 6467: ServerHello TLS 1.2, cipher 0xC02F; Certificate:
    /// 1 cert, CN=AndroidTV, serial=0x3E8, sig=sha256WithRSAEncryption"
    /// "Recorder 6467: alert fatal 70 (protocol_version)"
    /// "Recorder 6467: TV closed the connection without sending
    /// anything (no ServerHello)"
    /// "Recorder 6467: no answer in 5s"
    static func record(host: String, port: UInt16, timeout: TimeInterval = 5) async -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            let connection = NWConnection(host: NWEndpoint.Host(host),
                                          port: NWEndpoint.Port(rawValue: port)!,
                                          using: .tcp)
            let queue = DispatchQueue(label: "com.nicolassolley.universaltvremote.tlsrecorder")
            var finished = false
            var received = Data()
            let finish: (String) -> Void = { note in
                guard !finished else { return }
                finished = true
                connection.cancel()
                continuation.resume(returning: "Recorder \(port): \(note)")
            }
            func receive() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                    guard !finished else { return }
                    if let data, !data.isEmpty {
                        received.append(data)
                        if let summary = summarize(received) {
                            finish(summary)
                            return
                        }
                    }
                    if isComplete || error != nil {
                        finish(describeIncomplete(received))
                        return
                    }
                    receive()
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: Self.clientHello(),
                                    completion: .contentProcessed { _ in })
                    receive()
                case .failed(let error):
                    if received.isEmpty {
                        finish("TCP connect failed: \(describeError(error))")
                    } else {
                        finish(describeIncomplete(received))
                    }
                case .cancelled:
                    finish(describeIncomplete(received))
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                finish(received.isEmpty
                    ? "no answer in \(Int(timeout))s"
                    : "only \(received.count) bytes in \(Int(timeout))s: \(describeIncomplete(received))")
            }
        }
    }

    // MARK: - Pure parsing (offline-testable)

    /// Walk the received bytes as TLS records and handshake messages.
    /// Returns a summary string once the bytes settle the question
    /// (alert, ServerHello + Certificate, ServerHelloDone without a
    /// Certificate, or encrypted TLS 1.3 records), or nil when more
    /// bytes are needed.
    static func summarize(_ bytes: Data) -> String? {
        var offset = 0
        var helloVersion: UInt16?
        var helloCipher: UInt16?
        var handshake = Data()
        while true {
            guard offset + 5 <= bytes.count else { return nil }
            let type = bytes[bytes.startIndex + offset]
            let length = (Int(bytes[bytes.startIndex + offset + 3]) << 8)
                | Int(bytes[bytes.startIndex + offset + 4])
            guard offset + 5 + length <= bytes.count else { return nil }
            let payload = bytes[(bytes.startIndex + offset + 5)..<(bytes.startIndex + offset + 5 + length)]
            switch type {
            case 21: // alert
                guard payload.count >= 2 else { return nil }
                let level = payload[payload.startIndex]
                let desc = payload[payload.startIndex + 1]
                return "alert \(level == 2 ? "fatal" : "warning") \(desc) (\(alertName(desc)))"
            case 22: // handshake
                handshake.append(payload)
            case 23: // application data — in TLS 1.3 this is where the encrypted handshake lives
                if helloVersion == 0x0304 {
                    return "ServerHello TLS 1.3, cipher 0x\(hex(helloCipher)); following records encrypted — cert not visible in cleartext"
                }
                return "unexpected application-data record before ServerHello"
            case 20:
                // change_cipher_spec: legal anywhere after ClientHello
                // (RFC 8446 §5) — the QM7 sends one before ServerHello.
                // Drop it and keep parsing the rest of the flight
                // instead of stopping here.
                break
            default:
                return "unexpected first record type \(type)"
            }
            offset += 5 + length
            if let summary = summarizeHandshake(handshake,
                                                helloVersion: &helloVersion,
                                                helloCipher: &helloCipher) {
                return summary
            }
            if offset >= bytes.count { return nil }
        }
    }

    /// Parse concatenated handshake messages. Returns a summary once
    /// the messages settle the question, nil when the buffer ends
    /// mid-message (more bytes needed). `helloVersion` / `helloCipher`
    /// are filled in from the ServerHello when one is seen.
    static func summarizeHandshake(_ data: Data,
                                   helloVersion: inout UInt16?,
                                   helloCipher: inout UInt16?) -> String? {
        var offset = 0
        while offset + 4 <= data.count {
            let type = data[data.startIndex + offset]
            let length = (Int(data[data.startIndex + offset + 1]) << 16)
                | (Int(data[data.startIndex + offset + 2]) << 8)
                | Int(data[data.startIndex + offset + 3])
            guard offset + 4 + length <= data.count else { return nil }
            let body = data[(data.startIndex + offset + 4)..<(data.startIndex + offset + 4 + length)]
            switch type {
            case 2: // ServerHello
                guard body.count >= 35 else { return nil }
                let version = (UInt16(body[body.startIndex]) << 8)
                    | UInt16(body[body.startIndex + 1])
                let sessionIdLength = Int(body[body.startIndex + 34])
                guard body.count >= 35 + sessionIdLength + 2 else { return nil }
                let cipher = (UInt16(body[body.startIndex + 35 + sessionIdLength]) << 8)
                    | UInt16(body[body.startIndex + 35 + sessionIdLength + 1])
                helloVersion = version
                helloCipher = cipher
            case 11: // Certificate
                return certificateSummary(body: body,
                                          helloVersion: helloVersion,
                                          helloCipher: helloCipher)
            case 14: // ServerHelloDone
                return "ServerHello \(tlsName(helloVersion)), cipher 0x\(hex(helloCipher)); no Certificate message (ServerHelloDone)"
            case 15, 20: // CertificateVerify / Finished without a Certificate
                return "ServerHello \(tlsName(helloVersion)), cipher 0x\(hex(helloCipher)); no Certificate message"
            default:
                break // EncryptedExtensions, NewSessionTicket, etc. — keep reading
            }
            offset += 4 + length
        }
        return nil
    }

    /// Summarize a TLS 1.2 Certificate handshake message: the list
    /// length (3 bytes) followed by 3-byte-length-prefixed DER
    /// certificates. The first certificate is described by CN, serial,
    /// and signature algorithm.
    static func certificateSummary(body: Data, helloVersion: UInt16?, helloCipher: UInt16?) -> String {
        let prefix = "ServerHello \(tlsName(helloVersion)), cipher 0x\(hex(helloCipher)); Certificate: "
        guard body.count >= 3 else { return prefix + "malformed (short)" }
        let listLength = (Int(body[body.startIndex]) << 16)
            | (Int(body[body.startIndex + 1]) << 8)
            | Int(body[body.startIndex + 2])
        var certOffset = 3
        var count = 0
        var firstSummary: String?
        while certOffset + 3 <= body.count, count < 10 {
            let certLength = (Int(body[body.startIndex + certOffset]) << 16)
                | (Int(body[body.startIndex + certOffset + 1]) << 8)
                | Int(body[body.startIndex + certOffset + 2])
            guard certOffset + 3 + certLength <= body.count else { break }
            let der = body[(body.startIndex + certOffset + 3)..<(body.startIndex + certOffset + 3 + certLength)]
            if count == 0 {
                firstSummary = describeCertificate(Data(der))
            }
            count += 1
            certOffset += 3 + certLength
        }
        guard count > 0, let first = firstSummary else {
            return prefix + "arrived but list unparseable (list len \(listLength))"
        }
        return prefix + "\(count) cert\(count == 1 ? "" : "s"), \(first)"
    }

    /// Describe one certificate's DER: CN, serial (hex), signature
    /// algorithm. A DER our own reader cannot parse is itself the
    /// finding — it is consistent with iOS's parser rejecting the TV's
    /// certificate before the verify block ever runs.
    static func describeCertificate(_ der: Data) -> String {
        guard X509.readTLV(der, offset: 0) != nil else {
            return "DER unparseable by iOS-style reader (len \(der.count))"
        }
        var parts: [String] = []
        if let cn = X509.subjectCommonName(certificateDER: der) { parts.append("CN=\(cn)") }
        if let serial = X509.serialNumberHex(certificateDER: der) { parts.append("serial=\(serial)") }
        if let sig = X509.signatureAlgorithm(certificateDER: der) { parts.append("sig=\(sig)") }
        if parts.isEmpty { return "DER parsed, no CN/serial/sig readable" }
        return parts.joined(separator: ", ")
    }

    /// What the TV sent before the connection closed (or the timeout
    /// hit): a ServerHello without a Certificate, a lone record type,
    /// or nothing at all.
    static func describeIncomplete(_ bytes: Data) -> String {
        if bytes.isEmpty {
            return "TV closed the connection without sending anything (no ServerHello)"
        }
        guard bytes.count >= 5 else {
            return "TV closed after \(bytes.count) byte\(bytes.count == 1 ? "" : "s") (no complete TLS record)"
        }
        let type = bytes[bytes.startIndex]
        let length = (Int(bytes[bytes.startIndex + 3]) << 8)
            | Int(bytes[bytes.startIndex + 4])
        if type == 22, bytes.count >= 5 + length {
            let payload = bytes[(bytes.startIndex + 5)..<(bytes.startIndex + 5 + length)]
            var version: UInt16?
            var cipher: UInt16?
            _ = summarizeHandshake(payload, helloVersion: &version, helloCipher: &cipher)
            if let version, let cipher {
                return "TV closed after ServerHello \(tlsName(version)), cipher 0x\(hex(cipher)), no Certificate"
            }
        }
        return "TV closed after \(bytes.count) bytes (first record type \(type), len \(length))"
    }

    static func tlsName(_ version: UInt16?) -> String {
        switch version {
        case 0x0304: return "TLS 1.3"
        case 0x0303: return "TLS 1.2"
        case nil: return "TLS ?"
        default: return "TLS 0x\(String(format: "%04X", version!))"
        }
    }

    static func hex(_ value: UInt16?) -> String {
        guard let value else { return "?" }
        return String(format: "%04X", value)
    }

    static func alertName(_ description: UInt8) -> String {
        switch description {
        case 0: return "close_notify"
        case 10: return "unexpected_message"
        case 20: return "bad_record_mac"
        case 40: return "handshake_failure"
        case 42: return "bad_certificate"
        case 43: return "unsupported_certificate"
        case 44: return "certificate_revoked"
        case 45: return "certificate_expired"
        case 46: return "certificate_unknown"
        case 47: return "illegal_parameter"
        case 48: return "unknown_ca"
        case 49: return "access_denied"
        case 50: return "decode_error"
        case 51: return "decrypt_error"
        case 70: return "protocol_version"
        case 71: return "insufficient_security"
        case 80: return "internal_error"
        case 90: return "user_canceled"
        case 100: return "no_renegotiation"
        case 109: return "missing_extension"
        case 112: return "unrecognized_name"
        default: return "unknown"
        }
    }

    private static func describeError(_ error: Error) -> String {
        guard let nw = error as? NWError else { return error.localizedDescription }
        switch nw {
        case .posix(let code):
            return "POSIX \(code.rawValue) (\(POSIXError(code).localizedDescription))"
        case .dns(let code):
            return "DNS error \(code)"
        case .tls(let status):
            return "TLS error \(status)"
        @unknown default:
            return String(describing: nw)
        }
    }

    // MARK: - ClientHello

    /// A minimal TLS ClientHello offering TLS 1.2 and 1.3, with no SNI
    /// (the TV is addressed by IP). Kept deliberately small and
    /// standard: the point is to see what the TV sends back, not to
    /// replicate SecureTransport's exact hello.
    static func clientHello() -> Data {
        var body = Data()
        body.append(contentsOf: [0x03, 0x03]) // legacy_version: TLS 1.2
        var random = [UInt8](repeating: 0, count: 32)
        for i in random.indices { random[i] = UInt8.random(in: 0...255) }
        body.append(contentsOf: random)
        body.append(0) // session_id length
        let suites: [UInt16] = [0x1301, 0x1302, 0x1303,
                                0xC02F, 0xC030, 0xC02B, 0xC02C,
                                0xCCA8, 0xCCA9,
                                0x003C, 0x003D, 0x002F, 0x0035]
        body.append(u16(UInt16(suites.count * 2)))
        for suite in suites { body.append(u16(suite)) }
        body.append(1) // compression_methods length
        body.append(0) // null compression
        var extensions = Data()
        // supported_versions: TLS 1.3, TLS 1.2
        extensions.append(extensionBlock(0x002B, body: Data([0x04, 0x03, 0x04, 0x03, 0x03])))
        // key_share (x25519, group 0x001D): without it, BoringSSL /
        // Conscrypt stacks reject a TLS 1.3 hello with fatal alert 109
        // (missing_extension) — exactly what the QM7 sent back.
        // Ephemeral key pair, generated fresh per hello.
        let x25519 = Curve25519.KeyAgreement.PrivateKey()
        let publicKey = x25519.publicKey.rawRepresentation // 32 bytes
        var keyShare = Data()
        keyShare.append(u16(36)) // client_shares length: 2 (group) + 2 (len) + 32 (key)
        keyShare.append(u16(0x001D)) // x25519
        keyShare.append(u16(UInt16(publicKey.count)))
        keyShare.append(publicKey)
        extensions.append(extensionBlock(0x0033, body: keyShare))
        var groups = Data()
        groups.append(u16(6))
        for group in [UInt16(0x001D), 0x0017, 0x0018] { groups.append(u16(group)) }
        extensions.append(extensionBlock(0x000A, body: groups)) // supported_groups
        var sigAlgs = Data()
        sigAlgs.append(u16(10))
        for alg in [UInt16(0x0401), 0x0804, 0x0403, 0x0501, 0x0601] { sigAlgs.append(u16(alg)) }
        extensions.append(extensionBlock(0x000D, body: sigAlgs)) // signature_algorithms
        extensions.append(extensionBlock(0x000B, body: Data([0x01, 0x00]))) // ec_point_formats: uncompressed
        body.append(u16(UInt16(extensions.count)))
        body.append(extensions)

        var handshake = Data()
        handshake.append(0x01) // ClientHello
        handshake.append(u24(body.count))
        handshake.append(body)

        var record = Data()
        record.append(0x16) // handshake
        record.append(contentsOf: [0x03, 0x01]) // legacy record version
        record.append(u16(UInt16(handshake.count)))
        record.append(handshake)
        return record
    }

    static func u16(_ value: UInt16) -> Data {
        Data([UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    static func u24(_ value: Int) -> Data {
        Data([UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }

    static func extensionBlock(_ type: UInt16, body: Data) -> Data {
        var block = Data()
        block.append(u16(type))
        block.append(u16(UInt16(body.count)))
        block.append(body)
        return block
    }
}
