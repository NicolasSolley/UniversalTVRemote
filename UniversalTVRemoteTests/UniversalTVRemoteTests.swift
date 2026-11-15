import XCTest
import CryptoKit
import Security
@testable import UniversalTVRemote

/// Tests for the Android TV certificate handling, pairing secret, and
/// certificate pinning. Offline: no TV, no network. Key generation uses
/// SecKeyCreateRandomKey with non-permanent keys (nothing is stored in the
/// Keychain except the pin store's own round-trip test, which uses a
/// throwaway host name).
final class X509Tests: XCTestCase {

    /// Mint a fresh RSA keypair + self-signed certificate, as the app does.
    private func mintedCert(commonName: String = "UniversalTVRemote") throws -> (der: Data, publicKeyDER: Data) {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
        ]
        let privateKey = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(privateKey))
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

        // Serial is random 8 bytes (the reference app's serial): it
        // parses, is non-zero, and differs between mints.
        let serialHex = try XCTUnwrap(X509.serialNumberHex(certificateDER: der))
        XCTAssertTrue(serialHex.hasPrefix("0x"), serialHex)
        XCTAssertGreaterThan(serialHex.count, 2)
        XCTAssertNotNil(X509.serialNumber(certificateDER: der))
        let (der2, _) = try mintedCert()
        XCTAssertNotEqual(X509.serialNumberHex(certificateDER: der),
                          X509.serialNumberHex(certificateDER: der2))

        // Extensions, in mint order: basicConstraints, subjectAltName —
        // all non-critical. No keyUsage, no extendedKeyUsage: the
        // reference app's certificate has neither.
        let extensions = try XCTUnwrap(X509.extensions(certificateDER: der))
        XCTAssertEqual(extensions.count, 2)
        XCTAssertEqual(extensions.map { $0.oid },
                       [[2, 5, 29, 19], [2, 5, 29, 17]])

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

        // subjectAltName: dNSName == CN, non-critical.
        let san = try XCTUnwrap(extensions.first { $0.oid == [2, 5, 29, 17] })
        XCTAssertFalse(san.critical)
        let sanTLV = try XCTUnwrap(X509.readTLV(san.value, offset: 0))
        XCTAssertEqual(sanTLV.tag, 0x30)
        let sanNames = X509.children(of: sanTLV.content)
        XCTAssertEqual(sanNames.count, 1)
        XCTAssertEqual(sanNames[0].tag, 0x82) // dNSName [2]
        XCTAssertEqual(String(data: sanNames[0].content, encoding: .utf8), "UniversalTVRemote")

        // No SecCertificateCopyValues cross-check: that API (and the
        // kSecOID*/kSecPropertyKeyValue constants) is macOS-only and does
        // not exist in the iOS Security framework — it fails CI with
        // "cannot find in scope". The DER-level assertions above verify
        // the same SAN names.

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
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
        ]
        let privateKey = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(privateKey))
        return try X509.makeSelfSigned(
            commonName: commonName,
            keyPair: (publicKey: publicKey, privateKey: privateKey))
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

final class TLSHandshakeRecorderTests: XCTestCase {

    private func tlsRecord(type: UInt8, payload: Data) -> Data {
        var data = Data([type, 0x03, 0x03])
        data.append(TLSHandshakeRecorder.u16(UInt16(payload.count)))
        data.append(payload)
        return data
    }

    private func handshakeMessage(type: UInt8, body: Data) -> Data {
        var message = Data([type])
        message.append(TLSHandshakeRecorder.u24(body.count))
        message.append(body)
        return message
    }

    /// Minimal ServerHello: version + cipher, no extensions.
    private func serverHello(version: UInt16, cipher: UInt16) -> Data {
        var body = Data()
        body.append(contentsOf: [UInt8(version >> 8), UInt8(version & 0xFF)])
        body.append(Data(repeating: 0, count: 32)) // random
        body.append(0) // session_id length
        body.append(contentsOf: [UInt8(cipher >> 8), UInt8(cipher & 0xFF)])
        body.append(0) // compression
        body.append(contentsOf: [0x00, 0x00]) // extensions length
        return handshakeMessage(type: 2, body: body)
    }

    private func certificateMessage(certDER: Data) -> Data {
        var list = Data()
        list.append(TLSHandshakeRecorder.u24(certDER.count))
        list.append(certDER)
        var body = Data()
        body.append(TLSHandshakeRecorder.u24(list.count))
        body.append(list)
        return handshakeMessage(type: 11, body: body)
    }

    private func mintedCert() throws -> Data {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
        ]
        let privateKey = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(privateKey))
        return try X509.makeSelfSigned(
            commonName: "UniversalTVRemote",
            keyPair: (publicKey: publicKey, privateKey: privateKey))
    }

    func testClientHelloStructure() {
        let hello = TLSHandshakeRecorder.clientHello()
        // TLS record: handshake (0x16), legacy version 0x0301, length.
        XCTAssertEqual(hello[hello.startIndex], 0x16)
        XCTAssertEqual(hello[hello.startIndex + 1], 0x03)
        XCTAssertEqual(hello[hello.startIndex + 2], 0x01)
        XCTAssertEqual(hello.count - 5, Int(hello[hello.startIndex + 3]) << 8
                       | Int(hello[hello.startIndex + 4]))
        // Handshake: ClientHello (0x01), legacy_version TLS 1.2.
        XCTAssertEqual(hello[hello.startIndex + 5], 0x01)
        XCTAssertEqual(hello[hello.startIndex + 9], 0x03)
        XCTAssertEqual(hello[hello.startIndex + 10], 0x03)
        // Offers supported_versions (extension 0x002B: TLS 1.3 + 1.2).
        // Data has no contains(Data) — subdata search is range(of:).
        XCTAssertNotNil(hello.range(of: Data([0x00, 0x2B])))
        // Offers key_share (extension 0x0033) with an x25519 share
        // (group 0x001D) — without it, BoringSSL answers alert 109.
        XCTAssertNotNil(hello.range(of: Data([0x00, 0x33])))
        XCTAssertNotNil(hello.range(of: Data([0x00, 0x1D])))
    }

    func testSummarizeServerHelloAndCertificate() throws {
        let der = try mintedCert()
        let bytes = tlsRecord(type: 0x16, payload: serverHello(version: 0x0303, cipher: 0xC02F))
            + tlsRecord(type: 0x16, payload: certificateMessage(certDER: der))
        let summary = try XCTUnwrap(TLSHandshakeRecorder.summarize(bytes))
        XCTAssertTrue(summary.contains("TLS 1.2"), summary)
        XCTAssertTrue(summary.contains("0xC02F"), summary)
        XCTAssertTrue(summary.contains("1 cert"), summary)
        XCTAssertTrue(summary.contains("CN=UniversalTVRemote"), summary)
        let serialHex = try XCTUnwrap(X509.serialNumberHex(certificateDER: der))
        XCTAssertTrue(summary.contains("serial=\(serialHex)"), summary)
        XCTAssertTrue(summary.contains("sig=sha256WithRSAEncryption"), summary)
    }

    func testSummarizeServerHelloAndCertificateInOneRecord() throws {
        let der = try mintedCert()
        let bytes = tlsRecord(type: 0x16, payload: serverHello(version: 0x0303, cipher: 0xC02F)
            + certificateMessage(certDER: der))
        let summary = try XCTUnwrap(TLSHandshakeRecorder.summarize(bytes))
        XCTAssertTrue(summary.contains("TLS 1.2"), summary)
        XCTAssertTrue(summary.contains("CN=UniversalTVRemote"), summary)
    }

    func testSummarizeAlert() {
        let bytes = tlsRecord(type: 21, payload: Data([2, 70]))
        let summary = TLSHandshakeRecorder.summarize(bytes)
        XCTAssertEqual(summary, "alert fatal 70 (protocol_version)")
    }

    func testSummarizeNeedsMoreData() {
        XCTAssertNil(TLSHandshakeRecorder.summarize(Data()))
        XCTAssertNil(TLSHandshakeRecorder.summarize(Data([0x16, 0x03])))
        // A lone ServerHello settles nothing yet — the Certificate may follow.
        XCTAssertNil(TLSHandshakeRecorder.summarize(
            tlsRecord(type: 0x16, payload: serverHello(version: 0x0303, cipher: 0xC02F))))
    }

    func testSummarizeServerHelloDoneWithoutCertificate() throws {
        let bytes = tlsRecord(type: 0x16, payload: serverHello(version: 0x0303, cipher: 0xC02F)
            + handshakeMessage(type: 14, body: Data()))
        let summary = try XCTUnwrap(TLSHandshakeRecorder.summarize(bytes))
        XCTAssertTrue(summary.contains("no Certificate message"), summary)
    }

    func testSummarizeTLS13Encrypted() throws {
        let bytes = tlsRecord(type: 0x16, payload: serverHello(version: 0x0304, cipher: 0x1301))
            + tlsRecord(type: 0x17, payload: Data([1, 2, 3]))
        let summary = try XCTUnwrap(TLSHandshakeRecorder.summarize(bytes))
        XCTAssertTrue(summary.contains("TLS 1.3"), summary)
        XCTAssertTrue(summary.contains("encrypted"), summary)
    }

    func testDescribeIncomplete() {
        XCTAssertTrue(TLSHandshakeRecorder.describeIncomplete(Data())
            .contains("without sending anything"))
        let closed = TLSHandshakeRecorder.describeIncomplete(
            tlsRecord(type: 0x16, payload: serverHello(version: 0x0303, cipher: 0xC02F)))
        XCTAssertTrue(closed.contains("ServerHello TLS 1.2"), closed)
        XCTAssertTrue(closed.contains("no Certificate"), closed)
    }

    func testX509SignatureAlgorithmAndSerialHex() throws {
        let der = try mintedCert()
        XCTAssertEqual(X509.signatureAlgorithm(certificateDER: der), "sha256WithRSAEncryption")
        // Random 8-byte serial: parses as minimal hex, never the old fixed 1000.
        let serialHex = try XCTUnwrap(X509.serialNumberHex(certificateDER: der))
        XCTAssertTrue(serialHex.hasPrefix("0x"), serialHex)
        XCTAssertNotEqual(serialHex, "0x3E8")
        XCTAssertNil(X509.signatureAlgorithm(certificateDER: Data()))
        XCTAssertNil(X509.serialNumberHex(certificateDER: Data()))
    }
}

final class VoiceMessageTests: XCTestCase {

    func testVoiceBeginMessageBytes() {
        // RemoteMessage field 30 (tag 0xF2 0x01) + len 2 + RemoteVoiceBegin { session_id = 1 }.
        XCTAssertEqual(AndroidTVRemote.voiceBeginMessage(sessionId: 1),
                       Data([0xF2, 0x01, 0x02, 0x08, 0x01]))
    }

    func testVoicePayloadMessageBytes() {
        // Field 31 (tag 0xFA 0x01): { session_id = 1, samples = [0x00, 0x01] }.
        XCTAssertEqual(AndroidTVRemote.voicePayloadMessage(sessionId: 1, samples: Data([0x00, 0x01])),
                       Data([0xFA, 0x01, 0x06, 0x08, 0x01, 0x12, 0x02, 0x00, 0x01]))
    }

    func testVoiceEndMessageBytes() {
        // Field 32 (tag 0x82 0x02) + len 2 + { session_id = 1 }.
        XCTAssertEqual(AndroidTVRemote.voiceEndMessage(sessionId: 1),
                       Data([0x82, 0x02, 0x02, 0x08, 0x01]))
    }

    func testVoicePayloadChunking() {
        XCTAssertEqual(AndroidTVRemote.voicePayloadChunks(samples: Data()), [])
        let samples = Data(repeating: 0xAB, count: 25_000)
        let chunks = AndroidTVRemote.voicePayloadChunks(samples: samples)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].count, 20 * 1024)
        XCTAssertEqual(chunks[1].count, 25_000 - 20 * 1024)
        XCTAssertEqual(Data(chunks.flatMap { $0 }), samples)
        // Exactly one full chunk stays one chunk.
        XCTAssertEqual(AndroidTVRemote.voicePayloadChunks(samples: Data(repeating: 0, count: 20 * 1024)).count, 1)
    }
}
