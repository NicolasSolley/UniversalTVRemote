import XCTest
import CryptoKit
import Security
@testable import UniversalTVRemote

/// Tests for the Android TV certificate handling, pairing secret, and
/// certificate pinning. Offline: no TV, no network. Key generation uses
/// SecKeyGeneratePair with non-permanent keys (nothing is stored in the
/// Keychain except the pin store's own round-trip test, which uses a
/// throwaway host name).
final class X509Tests: XCTestCase {

    /// Mint a fresh RSA keypair + self-signed certificate, as the app does.
    private func mintedCert(commonName: String = "UniversalTVRemote") throws -> (der: Data, publicKeyDER: Data) {
        var publicKey: SecKey?
        var privateKey: SecKey?
        let parameters: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
        ]
        let status = SecKeyGeneratePair(parameters as CFDictionary, &publicKey, &privateKey)
        XCTAssertEqual(status, errSecSuccess)
        let publicKey = try XCTUnwrap(publicKey)
        let privateKey = try XCTUnwrap(privateKey)
        let publicKeyDER = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?
        let der = try X509.makeSelfSigned(
            commonName: commonName,
            keyPair: (publicKey: publicKey, privateKey: privateKey))
        return (der, try XCTUnwrap(publicKeyDER))
    }

    func testMintedCertificateHasExpectedShape() throws {
        let (der, _) = try mintedCert()

        // iOS itself can parse the minted certificate.
        let certificate = SecCertificateCreateWithData(nil, der as CFData)
        XCTAssertNotNil(certificate)

        // CN == SAN == the client name.
        XCTAssertEqual(X509.subjectCommonName(certificateDER: der), "UniversalTVRemote")

        // Serial 1000 (the reference implementation's serial).
        XCTAssertEqual(X509.serialNumber(certificateDER: der), 1000)

        // Extensions, in mint order: basicConstraints, keyUsage,
        // extendedKeyUsage, subjectAltName — all non-critical.
        let extensions = try XCTUnwrap(X509.extensions(certificateDER: der))
        XCTAssertEqual(extensions.count, 4)
        XCTAssertEqual(extensions.map { $0.oid },
                       [[2, 5, 29, 19], [2, 5, 29, 15], [2, 5, 29, 37], [2, 5, 29, 17]])

        // basicConstraints: CA:TRUE, pathlen 0, non-critical.
        let bc = try XCTUnwrap(extensions.first { $0.oid == [2, 5, 29, 19] })
        XCTAssertFalse(bc.critical)
        let bcTLV = try XCTUnwrap(X509.readTLV(bc.value, offset: 0))
        XCTAssertEqual(bcTLV.tag, 0x30)
        let bcParts = X509.children(of: bcTLV.content)
        XCTAssertEqual(bcParts.count, 2)
        XCTAssertEqual(bcParts[0].tag, 0x01) // BOOLEAN
        XCTAssertEqual(bcParts[0].content, Data([0xFF])) // TRUE
        XCTAssertEqual(bcParts[1].tag, 0x02) // INTEGER
        XCTAssertEqual(bcParts[1].content, Data([0x00])) // pathlen 0

        // keyUsage: digitalSignature + keyEncipherment, non-critical.
        // BIT STRING content: 5 unused bits, bits 0x80 + 0x20 = 0xA0.
        let ku = try XCTUnwrap(extensions.first { $0.oid == [2, 5, 29, 15] })
        XCTAssertFalse(ku.critical)
        let kuTLV = try XCTUnwrap(X509.readTLV(ku.value, offset: 0))
        XCTAssertEqual(kuTLV.tag, 0x03) // BIT STRING
        XCTAssertEqual(kuTLV.content, Data([0x05, 0xA0]))

        // extendedKeyUsage: clientAuth only, non-critical.
        let eku = try XCTUnwrap(extensions.first { $0.oid == [2, 5, 29, 37] })
        XCTAssertFalse(eku.critical)
        let ekuTLV = try XCTUnwrap(X509.readTLV(eku.value, offset: 0))
        XCTAssertEqual(ekuTLV.tag, 0x30)
        let ekuOIDs = X509.children(of: ekuTLV.content)
            .compactMap { X509.oidComponents($0.content) }
        XCTAssertEqual(ekuOIDs, [[1, 3, 6, 1, 5, 5, 7, 3, 2]])

        // subjectAltName: dNSName == CN, non-critical.
        let san = try XCTUnwrap(extensions.first { $0.oid == [2, 5, 29, 17] })
        XCTAssertFalse(san.critical)
        let sanTLV = try XCTUnwrap(X509.readTLV(san.value, offset: 0))
        XCTAssertEqual(sanTLV.tag, 0x30)
        let sanNames = X509.children(of: sanTLV.content)
        XCTAssertEqual(sanNames.count, 1)
        XCTAssertEqual(sanNames[0].tag, 0x82) // dNSName [2]
        XCTAssertEqual(String(data: sanNames[0].content, encoding: .utf8), "UniversalTVRemote")

        // Cross-check with the Security framework's own reading of the
        // certificate: keyUsage bitmask, EKU OIDs, and SAN names.
        let values = SecCertificateCopyValues(
            certificate!,
            [kSecOIDKeyUsage, kSecOIDExtendedKeyUsage, kSecOIDSubjectAltName] as CFArray,
            nil) as? [String: [String: Any]]
        let valuesUnwrapped = try XCTUnwrap(values)
        if let kuEntry = valuesUnwrapped["2.5.29.15"],
           let mask = kuEntry[kSecPropertyKeyValue as String] as? Int {
            XCTAssertEqual(mask & 0b101, 0b101) // digitalSignature + keyEncipherment
        } else {
            XCTFail("keyUsage value missing from SecCertificateCopyValues")
        }
        if let ekuEntry = valuesUnwrapped["2.5.29.37"],
           let oids = ekuEntry[kSecPropertyKeyValue as String] as? [String] {
            XCTAssertTrue(oids.contains("1.3.6.1.5.5.7.3.2"))
        } else {
            XCTFail("extendedKeyUsage value missing from SecCertificateCopyValues")
        }
        if let sanEntry = valuesUnwrapped["2.5.29.17"],
           let names = sanEntry[kSecPropertyKeyValue as String] as? [String] {
            XCTAssertTrue(names.contains("UniversalTVRemote"))
        } else {
            XCTFail("subjectAltName value missing from SecCertificateCopyValues")
        }

        // Unparseable input is rejected, not misread.
        XCTAssertNil(X509.extensions(certificateDER: Data([0x30, 0x03, 0x02, 0x01, 0x00])))
        XCTAssertNil(X509.serialNumber(certificateDER: Data()))
    }

    func testRSAModulusExponentRoundTrip() throws {
        let (der, publicKeyDER) = try mintedCert()
        let keys = try XCTUnwrap(X509.rsaModulusExponent(certificateDER: der))

        // The SPKI's public key is a PKCS#1 RSAPublicKey SEQ { modulus, exponent }.
        let pkcs1 = try XCTUnwrap(X509.readTLV(publicKeyDER, offset: 0))
        XCTAssertEqual(pkcs1.tag, 0x30)
        let ints = X509.children(of: pkcs1.content)
        XCTAssertEqual(ints.count, 2)
        XCTAssertEqual(keys.modulus, X509.minimalIntegerBytes(ints[0].content))
        XCTAssertEqual(keys.exponent, X509.minimalIntegerBytes(ints[1].content))

        // Exponent is the standard 65537; modulus is a 2048-bit number.
        XCTAssertEqual(keys.exponent, Data([0x01, 0x00, 0x01]))
        XCTAssertEqual(keys.modulus.count, 256)

        // Garbage is rejected.
        XCTAssertNil(X509.rsaModulusExponent(certificateDER: Data([0x30, 0x03, 0x02, 0x01, 0x00])))
        XCTAssertNil(X509.rsaModulusExponent(certificateDER: Data()))
    }
}

final class PairingSecretTests: XCTestCase {

    private func mintedCert(commonName: String) throws -> Data {
        var publicKey: SecKey?
        var privateKey: SecKey?
        let parameters: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
        ]
        XCTAssertEqual(SecKeyGeneratePair(parameters as CFDictionary, &publicKey, &privateKey),
                       errSecSuccess)
        return try X509.makeSelfSigned(
            commonName: commonName,
            keyPair: (publicKey: try XCTUnwrap(publicKey), privateKey: try XCTUnwrap(privateKey)))
    }

    func testPairingSecretKnownVector() throws {
        let clientDER = try mintedCert(commonName: "UniversalTVRemote")
        let serverDER = try mintedCert(commonName: "TestTV")
        let clientKeys = try XCTUnwrap(X509.rsaModulusExponent(certificateDER: clientDER))
        let serverKeys = try XCTUnwrap(X509.rsaModulusExponent(certificateDER: serverDER))

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
            AndroidTVRemote.pairingSecret(code: code, clientCertificateDER: clientDER,
                                          serverCertificateDER: serverDER),
            digest)

        // A code whose first byte does not match the digest is rejected.
        let wrongCode = String(format: "%02x", firstByte ^ 0xFF) + "3456"
        XCTAssertNil(
            AndroidTVRemote.pairingSecret(code: wrongCode, clientCertificateDER: clientDER,
                                          serverCertificateDER: serverDER))

        // Garbage certificates are rejected.
        XCTAssertNil(
            AndroidTVRemote.pairingSecret(code: code, clientCertificateDER: Data(),
                                          serverCertificateDER: serverDER))
        XCTAssertNil(
            AndroidTVRemote.pairingSecret(code: code, clientCertificateDER: clientDER,
                                          serverCertificateDER: Data()))
    }
}

final class PinningTests: XCTestCase {

    func testVerifyAcceptsAnythingWithoutPin() {
        // Trust on first use: no pin stored, any certificate is accepted.
        XCTAssertTrue(TLSConnection.certificateMatchesPin(
            presentedDER: Data([1, 2, 3]), expectedDER: nil))
        XCTAssertTrue(TLSConnection.certificateMatchesPin(
            presentedDER: Data(), expectedDER: nil))
    }

    func testVerifyAcceptsMatchingPin() {
        let der = Data([0x30, 0x03, 0x02, 0x01, 0x05])
        XCTAssertTrue(TLSConnection.certificateMatchesPin(
            presentedDER: der, expectedDER: der))
    }

    func testVerifyRejectsNonMatchingPin() {
        XCTAssertFalse(TLSConnection.certificateMatchesPin(
            presentedDER: Data([1]), expectedDER: Data([2])))
        XCTAssertFalse(TLSConnection.certificateMatchesPin(
            presentedDER: Data(), expectedDER: Data([1])))
    }

    func testPinStoreRoundTrip() {
        let host = "test-pin-\(UUID().uuidString)"
        let der = Data([0x30, 0x82, 0x01, 0x00, 0x02, 0x01, 0x05])
        XCTAssertNil(AndroidTVPinStore.pinnedCertificateDER(for: host))
        AndroidTVPinStore.set(der, for: host)
        XCTAssertEqual(AndroidTVPinStore.pinnedCertificateDER(for: host), der)
        // Storing again replaces the pin.
        let der2 = Data([0x30, 0x03, 0x02, 0x01, 0x07])
        AndroidTVPinStore.set(der2, for: host)
        XCTAssertEqual(AndroidTVPinStore.pinnedCertificateDER(for: host), der2)
        // Clearing removes it.
        AndroidTVPinStore.clear(for: host)
        XCTAssertNil(AndroidTVPinStore.pinnedCertificateDER(for: host))
        // Clearing a host that was never pinned is a no-op.
        AndroidTVPinStore.clear(for: host)
        XCTAssertNil(AndroidTVPinStore.pinnedCertificateDER(for: host))
    }

    func testCertificateChangedErrorMessage() {
        XCTAssertEqual(
            AndroidTVRemote.AndroidTVError.certificateChanged.localizedDescription,
            "This TV's certificate changed since you paired it. Forget the TV and pair again.")
    }
}
