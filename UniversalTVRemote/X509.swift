import Foundation
import Security
import CommonCrypto

/// Minimal X.509 / DER helpers for the Android TV Remote protocol.
///
/// The TV's pairing flow needs two things no iOS API hands you directly:
/// 1. A self-signed RSA client certificate to present during mutual TLS.
///    iOS cannot mint one for you, so the TBSCertificate is DER-encoded
///    by hand here and signed with SecKey.
/// 2. The RSA modulus/exponent of both the client and the TV certificates,
///    for the pairing secret hash. A tiny DER parser extracts them.
enum X509 {

    // MARK: - DER encoding

    private static func lengthBytes(_ count: Int) -> Data {
        if count < 0x80 { return Data([UInt8(count)]) }
        var bytes: [UInt8] = []
        var n = count
        while n > 0 { bytes.insert(UInt8(n & 0xFF), at: 0); n >>= 8 }
        return Data([UInt8(0x80 | bytes.count)] + bytes)
    }

    private static func tlv(tag: UInt8, content: Data) -> Data {
        Data([tag]) + lengthBytes(content.count) + content
    }

    /// DER INTEGER, minimal big-endian, with a leading 0x00 when the top
    /// bit is set (so the value stays positive).
    static func integer(_ bytes: Data) -> Data {
        var value = bytes
        while value.count > 1, value.first == 0 { value.removeFirst() }
        if let first = value.first, first & 0x80 != 0 {
            value = Data([0x00]) + value
        }
        return tlv(tag: 0x02, content: value)
    }

    static func integer(_ value: Int) -> Data {
        var v = value
        var bytes = Data()
        repeat {
            bytes.insert(UInt8(v & 0xFF), at: 0)
            v >>= 8
        } while v > 0
        return integer(bytes)
    }

    static func oid(_ components: [Int]) -> Data {
        var bytes = Data([UInt8(components[0] * 40 + components[1])])
        for component in components.dropFirst(2) {
            var value = component
            var stack: [UInt8] = [UInt8(value & 0x7F)]
            value >>= 7
            while value > 0 {
                stack.insert(UInt8((value & 0x7F) | 0x80), at: 0)
                value >>= 7
            }
            bytes.append(contentsOf: stack)
        }
        return tlv(tag: 0x06, content: bytes)
    }

    static func null() -> Data { Data([0x05, 0x00]) }

    static func utf8String(_ string: String) -> Data {
        tlv(tag: 0x0C, content: Data(string.utf8))
    }

    static func utcTime(_ date: Date) -> Data {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return tlv(tag: 0x17, content: Data(formatter.string(from: date).utf8))
    }

    static func bitString(_ content: Data) -> Data {
        tlv(tag: 0x03, content: Data([0x00]) + content)
    }

    static func boolean(_ value: Bool) -> Data {
        tlv(tag: 0x01, content: Data([value ? 0xFF : 0x00]))
    }

    static func octetString(_ content: Data) -> Data {
        tlv(tag: 0x04, content: content)
    }

    /// One X.509 extension: SEQUENCE { OID, [BOOLEAN critical], OCTET STRING value }.
    static func extensionItem(oidComponents: [Int], critical: Bool, value: Data) -> Data {
        var content = oid(oidComponents)
        if critical { content += boolean(true) }
        content += octetString(value)
        return sequence(content)
    }

    static func sequence(_ content: Data) -> Data {
        tlv(tag: 0x30, content: content)
    }

    static func set(_ content: Data) -> Data {
        tlv(tag: 0x31, content: content)
    }

    static func explicit(_ tagNumber: UInt8, _ content: Data) -> Data {
        tlv(tag: 0xA0 + tagNumber, content: content)
    }

    private static let rsaEncryptionOID = [1, 2, 840, 113549, 1, 1, 1]
    private static let sha256WithRSAOID = [1, 2, 840, 113549, 1, 1, 11]
    private static let commonNameOID = [2, 5, 4, 3]
    private static let basicConstraintsOID = [2, 5, 29, 19]
    private static let subjectAltNameOID = [2, 5, 29, 17]

    // MARK: - Self-signed certificate

    struct ClientIdentity {
        let certificate: SecCertificate
        let privateKey: SecKey
        let certificateDER: Data
    }

    /// Mint a minimal self-signed RSA certificate for `commonName`.
    /// Valid 10 years from now. The TV does not validate the chain — it
    /// binds this certificate during pairing — but the reference
    /// implementations mint it with `basicConstraints CA:TRUE` and a
    /// subjectAltName, and at least one TV has been seen rejecting a cert
    /// without them, so both extensions are included.
    static func makeSelfSigned(commonName: String, keyPair: (publicKey: SecKey, privateKey: SecKey)) throws -> Data {
        guard let publicKeyDER = SecKeyCopyExternalRepresentation(keyPair.publicKey, nil) as Data? else {
            throw NSError(domain: "X509", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not export public key"])
        }

        let algorithm = sequence(oid(sha256WithRSAOID) + null())
        let name = sequence(set(sequence(oid(commonNameOID) + utf8String(commonName))))
        let now = Date()
        let validity = sequence(utcTime(now) + utcTime(now.addingTimeInterval(10 * 365 * 24 * 3600)))
        let spki = sequence(sequence(oid(rsaEncryptionOID) + null()) + bitString(publicKeyDER))
        // Extensions [3]: basicConstraints CA:TRUE (critical) + SAN dNSName.
        // The dNSName GeneralName is context-specific primitive tag [2] (0x82).
        let extensions = explicit(3, sequence(
            extensionItem(oidComponents: basicConstraintsOID, critical: true,
                          value: sequence(boolean(true)))
            + extensionItem(oidComponents: subjectAltNameOID, critical: false,
                            value: sequence(tlv(tag: 0x82, content: Data(commonName.utf8))))
        ))

        let tbs = sequence(
            explicit(0, integer(2)) +
            integer(1) +
            algorithm +
            name +
            validity +
            name +
            spki +
            extensions
        )

        guard let signature = SecKeyCreateSignature(
            keyPair.privateKey, .rsaSignatureMessagePKCS1v15SHA256, tbs as CFData, nil) as Data? else {
            throw NSError(domain: "X509", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Could not sign certificate"])
        }

        let certificate = sequence(tbs + algorithm + bitString(signature))
        return certificate
    }

    // MARK: - DER parsing (RSA modulus / exponent)

    /// One TLV element.
    struct TLV {
        let tag: UInt8
        let content: Data
        let totalLength: Int
    }

    /// Parse the first TLV at `offset` in `data`.
    static func readTLV(_ data: Data, offset: Int) -> TLV? {
        guard offset + 2 <= data.count else { return nil }
        let tag = data[offset]
        var index = offset + 1
        var length = Int(data[index])
        index += 1
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count > 0, count <= 4, index + count <= data.count else { return nil }
            length = 0
            for _ in 0..<count {
                length = (length << 8) | Int(data[index])
                index += 1
            }
        }
        guard index + length <= data.count else { return nil }
        return TLV(tag: tag, content: data[index..<(index + length)],
                   totalLength: (index - offset) + length)
    }

    /// All top-level TLVs inside a constructed value's content.
    static func children(of content: Data) -> [TLV] {
        var result: [TLV] = []
        var offset = 0
        while let tlv = readTLV(content, offset: offset) {
            result.append(tlv)
            offset += tlv.totalLength
        }
        return result
    }

    /// Minimal big-endian bytes of a DER INTEGER (leading 0x00 sign byte stripped).
    static func minimalIntegerBytes(_ content: Data) -> Data {
        var value = content
        while value.count > 1, value.first == 0 { value.removeFirst() }
        return value
    }

    /// Extract (modulus, exponent) from an X.509 certificate's DER bytes.
    static func rsaModulusExponent(certificateDER: Data) -> (modulus: Data, exponent: Data)? {
        guard let cert = readTLV(certificateDER, offset: 0), cert.tag == 0x30 else { return nil }
        // Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signatureValue }
        let certFields = children(of: cert.content)
        guard certFields.count == 3 else { return nil }
        // TBSCertificate (v3) fields: version, serial, signature, issuer,
        // validity, subject, subjectPublicKeyInfo, [extensions]. The SPKI is
        // element 6.
        let tbsFields = children(of: certFields[0].content)
        guard tbsFields.count >= 7 else { return nil }
        let spki = children(of: tbsFields[6].content)
        guard spki.count == 2 else { return nil }
        // BIT STRING content starts with 0x00 (unused-bits byte).
        let bitString = spki[1].content
        guard bitString.count > 1 else { return nil }
        let publicKeyDER = bitString.dropFirst()
        guard let rsaKey = readTLV(publicKeyDER, offset: 0), rsaKey.tag == 0x30 else { return nil }
        let ints = children(of: rsaKey.content)
        guard ints.count == 2, ints[0].tag == 0x02, ints[1].tag == 0x02 else { return nil }
        return (minimalIntegerBytes(ints[0].content), minimalIntegerBytes(ints[1].content))
    }

    /// SHA-256 fingerprint of a certificate's DER bytes (for LG cert pinning).
    static func sha256Fingerprint(certificateDER: Data) -> Data {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        certificateDER.withUnsafeBytes { ptr in
            _ = CC_SHA256(ptr.baseAddress, CC_LONG(certificateDER.count), &digest)
        }
        return Data(digest)
    }
}
