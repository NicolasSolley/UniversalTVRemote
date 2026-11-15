import XCTest
import CryptoKit
import Security
@testable import UniversalTVRemote

/// Tests for the ported Android TV code (v1.0.15–v1.0.16): DER encoding, the
/// client identity, the pairing secret, and the voice message bytes.
/// Offline: no TV, no network. Key generation uses SecKeyCreateRandomKey
/// with non-permanent keys, except ClientIdentity's own mint/reset test
/// (which uses a throwaway slot). Both clean up after themselves.
final class DERAndIdentityTests: XCTestCase {

    /// Mint a self-signed certificate with the DER helpers, as
    /// ClientIdentity does — but with a non-permanent key, so nothing
    /// touches the Keychain. When a signing key is supplied, the cert is
    /// minted with that key (so a test can compare the certificate's
    /// components against the key it already holds); otherwise a fresh
    /// throwaway key is generated.
    private func makeTestCertDER(commonName: String, signingKey: SecKey? = nil) throws -> Data {
        let privateKey: SecKey
        if let signingKey {
            privateKey = signingKey
        } else {
            let attributes: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeySizeInBits as String: 2048,
            ]
            privateKey = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        }
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(privateKey))
        let publicDER = try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)

        let signatureAlgorithm = DER.sequence([DER.oid("1.2.840.113549.1.1.11"), DER.null])
        let name = DER.sequence([DER.set([DER.sequence([DER.oid("2.5.4.3"), DER.utf8(commonName)])])])
        let now = Date()
        let validity = DER.sequence([DER.time(now.addingTimeInterval(-86_400)),
                                     DER.time(now.addingTimeInterval(20 * 365 * 86_400))])
        let spki = DER.sequence([
            DER.sequence([DER.oid("1.2.840.113549.1.1.1"), DER.null]),
            DER.bitString(Array(publicDER)),
        ])
        let basicConstraints = DER.sequence([
            DER.oid("2.5.29.19"),
            DER.octetString(DER.sequence([DER.boolean(true), DER.integer(0)])),
        ])
        let subjectAltName = DER.sequence([
            DER.oid("2.5.29.17"),
            DER.octetString(DER.sequence([DER.tlv(0x82, Array(commonName.utf8))])),
        ])
        var serial = [UInt8](repeating: 0, count: 8)
        _ = SecRandomCopyBytes(kSecRandomDefault, serial.count, &serial)
        serial[0] &= 0x7F
        let tbs = DER.sequence([
            DER.explicit(0, DER.integer(2)),
            DER.integer(serial),
            signatureAlgorithm,
            name,
            validity,
            name,
            spki,
            DER.explicit(3, DER.sequence([basicConstraints, subjectAltName])),
        ])
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256,
                                                    Data(tbs) as CFData, &error) as Data? else {
            throw error!.takeRetainedValue() as Error
        }
        return Data(DER.sequence([tbs, signatureAlgorithm, DER.bitString(Array(signature))]))
    }

    func testDERIntegerEncoding() {
        XCTAssertEqual(DER.integer([0x01, 0x00, 0x01]), [0x02, 0x03, 0x01, 0x00, 0x01])
        // High bit set: a 0x00 pad is added.
        XCTAssertEqual(DER.integer([0x80]), [0x02, 0x02, 0x00, 0x80])
        // Leading zeros are stripped.
        XCTAssertEqual(DER.integer([0x00, 0x01]), [0x02, 0x01, 0x01])
        XCTAssertEqual(DER.integer([0x00]), [0x02, 0x01, 0x00])
        XCTAssertEqual(DER.integer(0), [0x02, 0x01, 0x00])
        XCTAssertEqual(DER.integer(2), [0x02, 0x01, 0x02])
        XCTAssertEqual(DER.integer(256), [0x02, 0x02, 0x01, 0x00])
    }

    func testDEROIDEncoding() {
        // sha256WithRSAEncryption (1.2.840.113549.1.1.11).
        XCTAssertEqual(DER.oid("1.2.840.113549.1.1.11"),
                       [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B])
        // rsaEncryption (1.2.840.113549.1.1.1).
        XCTAssertEqual(DER.oid("1.2.840.113549.1.1.1"),
                       [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01])
        // commonName (2.5.4.3).
        XCTAssertEqual(DER.oid("2.5.4.3"), [0x06, 0x03, 0x55, 0x04, 0x03])
    }

    func testDERTimeEncoding() {
        // 2026-01-01 00:00:00 UTC → UTCTime (tag 0x17, before 2050).
        let date = Date(timeIntervalSince1970: 1767225600)
        let encoded = DER.time(date)
        XCTAssertEqual(encoded[0], 0x17)
        XCTAssertEqual(encoded[1], 0x0D)
        XCTAssertEqual(String(bytes: encoded.dropFirst(2), encoding: .utf8), "260101000000Z")
    }

    func testMintedCertificateParses() throws {
        let der = try makeTestCertDER(commonName: "UniversalTVRemote TEST")
        // iOS itself can parse the minted certificate.
        let certificate = SecCertificateCreateWithData(nil, der as CFData)
        XCTAssertNotNil(certificate)
        // CN is the common name we minted with.
        let subject = SecCertificateCopySubjectSummary(certificate!) as String?
        XCTAssertEqual(subject, "UniversalTVRemote TEST")
    }

    func testRSAModulusExponentRoundTrip() throws {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
        ]
        let privateKey = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(privateKey))
        let publicKeyDER = try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)
        // Mint the certificate with this same key — the pre-rebuild
        // test compared the certificate against the key it was minted
        // with, and the rebuild accidentally compared two different
        // random keys (the helper generated its own), so the moduli
        // could never match.
        let der = try makeTestCertDER(commonName: "UniversalTVRemote", signingKey: privateKey)
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, der as CFData))
        let keys = try XCTUnwrap(ClientIdentity.rsaComponents(of: certificate))

        // The SPKI's public key is a PKCS#1 RSAPublicKey SEQ { modulus, exponent }.
        let parsed = try XCTUnwrap(DER.rsaPublicKeyComponents(Array(publicKeyDER)))
        XCTAssertEqual(keys.modulus, parsed.modulus)
        XCTAssertEqual(keys.exponent, parsed.exponent)

        // Exponent is the standard 65537; modulus is a 2048-bit number.
        XCTAssertEqual(keys.exponent, [0x01, 0x00, 0x01])
        XCTAssertEqual(keys.modulus.count, 256)

        // Garbage is rejected.
        XCTAssertNil(DER.rsaPublicKeyComponents([0x30, 0x03, 0x02, 0x01, 0x00]))
        XCTAssertNil(DER.rsaPublicKeyComponents([]))
    }

    func testClientIdentityMintAndReset() throws {
        // Throwaway slot, so the test never touches the app's real
        // identity; everything is removed again in defer.
        let slot = "TestIdentity\(UUID().uuidString.prefix(8))"
        let originalSlot = ClientIdentity.slot
        ClientIdentity.slot = slot
        defer {
            ClientIdentity.reset()
            ClientIdentity.slot = originalSlot
            ClientIdentity.reset()
        }
        ClientIdentity.reset()
        let first = try ClientIdentity.loadOrCreate()

        // iOS itself can parse the minted certificate.
        let der = SecCertificateCopyData(first.certificate) as Data
        XCTAssertNotNil(SecCertificateCreateWithData(nil, der as CFData))

        // CN is the slot plus 4 random bytes rendered as 8 hex chars
        // (ClientIdentity mints 4 bytes, as the fork does — the old
        // expectation of 4 chars was wrong).
        let subject = SecCertificateCopySubjectSummary(first.certificate) as String?
        XCTAssertNotNil(subject)
        XCTAssertTrue(subject!.hasPrefix(slot + " "))
        let suffix = subject!.dropFirst(slot.count + 1)
        XCTAssertEqual(suffix.count, 8)
        XCTAssertTrue(suffix.allSatisfy(\.isHexDigit))

        // shortID is 4 hex chars.
        let shortID = ClientIdentity.shortID(of: first.certificate)
        XCTAssertEqual(shortID.count, 4)
        XCTAssertTrue(shortID.allSatisfy(\.isHexDigit))

        // RSA components: 2048-bit modulus, exponent 65537.
        let components = try XCTUnwrap(ClientIdentity.rsaComponents(of: first.certificate))
        XCTAssertEqual(components.modulus.count, 256)
        XCTAssertEqual(components.exponent, [0x01, 0x00, 0x01])

        // Loading again returns the same identity (cached / Keychain).
        let again = try ClientIdentity.loadOrCreate()
        XCTAssertEqual(SecCertificateCopyData(again.certificate) as Data, der)

        // Reset mints a fresh identity (different certificate).
        ClientIdentity.reset()
        let second = try ClientIdentity.loadOrCreate()
        XCTAssertNotEqual(SecCertificateCopyData(second.certificate) as Data, der)
    }
}

final class PairingSecretTests: XCTestCase {

    private func mintedCertDER(commonName: String) throws -> Data {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
        ]
        let privateKey = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(privateKey))
        let publicDER = try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, nil) as Data?)
        let signatureAlgorithm = DER.sequence([DER.oid("1.2.840.113549.1.1.11"), DER.null])
        let name = DER.sequence([DER.set([DER.sequence([DER.oid("2.5.4.3"), DER.utf8(commonName)])])])
        let now = Date()
        let validity = DER.sequence([DER.time(now.addingTimeInterval(-86_400)),
                                     DER.time(now.addingTimeInterval(20 * 365 * 86_400))])
        let spki = DER.sequence([
            DER.sequence([DER.oid("1.2.840.113549.1.1.1"), DER.null]),
            DER.bitString(Array(publicDER)),
        ])
        let basicConstraints = DER.sequence([
            DER.oid("2.5.29.19"),
            DER.octetString(DER.sequence([DER.boolean(true), DER.integer(0)])),
        ])
        let subjectAltName = DER.sequence([
            DER.oid("2.5.29.17"),
            DER.octetString(DER.sequence([DER.tlv(0x82, Array(commonName.utf8))])),
        ])
        var serial = [UInt8](repeating: 0, count: 8)
        _ = SecRandomCopyBytes(kSecRandomDefault, serial.count, &serial)
        serial[0] &= 0x7F
        let tbs = DER.sequence([
            DER.explicit(0, DER.integer(2)),
            DER.integer(serial),
            signatureAlgorithm,
            name,
            validity,
            name,
            spki,
            DER.explicit(3, DER.sequence([basicConstraints, subjectAltName])),
        ])
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256,
                                                    Data(tbs) as CFData, &error) as Data? else {
            throw error!.takeRetainedValue() as Error
        }
        return Data(DER.sequence([tbs, signatureAlgorithm, DER.bitString(Array(signature))]))
    }

    func testPairingSecretKnownVector() throws {
        let clientDER = try mintedCertDER(commonName: "UniversalTVRemote")
        let serverDER = try mintedCertDER(commonName: "TestTV")
        let clientCert = try XCTUnwrap(SecCertificateCreateWithData(nil, clientDER as CFData))
        let serverCert = try XCTUnwrap(SecCertificateCreateWithData(nil, serverDER as CFData))
        let clientKeys = try XCTUnwrap(ClientIdentity.rsaComponents(of: clientCert))
        let serverKeys = try XCTUnwrap(ClientIdentity.rsaComponents(of: serverCert))

        // The secret is SHA-256 over client modulus, client exponent,
        // server modulus, server exponent, then the last 4 hex chars of
        // the code as bytes. Build the expected digest independently
        // (CryptoKit, not the function under test), then derive a code
        // whose first byte matches the digest's first byte — the
        // property the TV checks.
        let suffix = Data([0x34, 0x56])
        var hasher = SHA256()
        hasher.update(data: clientKeys.modulus)
        hasher.update(data: clientKeys.exponent)
        hasher.update(data: serverKeys.modulus)
        hasher.update(data: serverKeys.exponent)
        hasher.update(data: suffix)
        let digest = Data(hasher.finalize())
        let firstByte = try XCTUnwrap(digest.first)

        let code = String(format: "%02x", firstByte) + "3456"
        XCTAssertEqual(
            AndroidTVDriver.pairingSecret(code: code, clientCertificate: clientCert,
                                          serverCertificate: serverCert),
            digest)

        // The digest depends only on the code's last 4 hex chars (the
        // suffix), so a wrong first byte yields the SAME digest — and
        // the checksum in submitPairingCode (first byte of the digest
        // must equal the code's first byte, as the TV checks) rejects
        // it. The driver's pairingSecret itself returns the digest for
        // any 6-hex code, as in the fork; the check lives in the caller.
        let wrongCode = String(format: "%02x", firstByte ^ 0xFF) + "3456"
        XCTAssertEqual(
            AndroidTVDriver.pairingSecret(code: wrongCode, clientCertificate: clientCert,
                                          serverCertificate: serverCert),
            digest)
        let wrongFirstByte = try XCTUnwrap(UInt8(wrongCode.prefix(2), radix: 16))
        XCTAssertNotEqual(digest.first, wrongFirstByte)

        // A code that isn't 6 hex characters is rejected.
        XCTAssertNil(
            AndroidTVDriver.pairingSecret(code: "XYZ", clientCertificate: clientCert,
                                          serverCertificate: serverCert))
        XCTAssertNil(
            AndroidTVDriver.pairingSecret(code: "12345", clientCertificate: clientCert,
                                          serverCertificate: serverCert))
    }
}

final class VoiceMessageTests: XCTestCase {

    func testVoiceBeginMessageBytes() {
        // RemoteMessage field 30 (tag 0xF2 0x01) + len 2 + RemoteVoiceBegin { session_id = 1 }.
        XCTAssertEqual(AndroidTVDriver.voiceBeginMessage(sessionId: 1),
                       Data([0xF2, 0x01, 0x02, 0x08, 0x01]))
    }

    func testVoicePayloadMessageBytes() {
        // Field 31 (tag 0xFA 0x01): { session_id = 1, samples = [0x00, 0x01] }.
        XCTAssertEqual(AndroidTVDriver.voicePayloadMessage(sessionId: 1, samples: Data([0x00, 0x01])),
                       Data([0xFA, 0x01, 0x06, 0x08, 0x01, 0x12, 0x02, 0x00, 0x01]))
    }

    func testVoiceEndMessageBytes() {
        // Field 32 (tag 0x82 0x02) + len 2 + { session_id = 1 }.
        XCTAssertEqual(AndroidTVDriver.voiceEndMessage(sessionId: 1),
                       Data([0x82, 0x02, 0x02, 0x08, 0x01]))
    }

    func testVoicePayloadChunking() {
        XCTAssertEqual(AndroidTVDriver.voicePayloadChunks(samples: Data()), [])
        let samples = Data(repeating: 0xAB, count: 25_000)
        let chunks = AndroidTVDriver.voicePayloadChunks(samples: samples)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].count, 20 * 1024)
        XCTAssertEqual(chunks[1].count, 25_000 - 20 * 1024)
        XCTAssertEqual(Data(chunks.flatMap { $0 }), samples)
        // Exactly one full chunk stays one chunk.
        XCTAssertEqual(AndroidTVDriver.voicePayloadChunks(samples: Data(repeating: 0, count: 20 * 1024)).count, 1)
    }
}
