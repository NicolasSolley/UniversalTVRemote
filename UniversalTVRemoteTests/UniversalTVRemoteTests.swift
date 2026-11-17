import XCTest
import CoreGraphics
import CryptoKit
import Security
import SwiftUI
import UIKit
@testable import UniversalTVRemote

/// Tests for the ported Android TV code (v1.0.15–v1.0.16): DER encoding, the
/// client identity, the pairing secret, and the voice message bytes.
/// Offline: no TV, no network. Key generation uses SecKeyCreateRandomKey
/// with non-permanent keys, except ClientIdentity's own mint/reset test
/// (which uses a throwaway slot). Both clean up after themselves.
/// Mint a self-signed certificate with the DER helpers, as
/// ClientIdentity does — but with a non-permanent key, so nothing
/// touches the Keychain. When a signing key is supplied, the cert is
/// minted with that key (so a test can compare the certificate's
/// components against the key it already holds); otherwise a fresh
/// throwaway key is generated. Shared by DERAndIdentityTests and
/// PairingSecretTests (v1.0.53) — one helper, not one copy per class.
func makeTestCertDER(commonName: String, signingKey: SecKey? = nil) throws -> Data {
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


final class DERAndIdentityTests: XCTestCase {

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

    func testPairingSecretKnownVector() throws {
        let clientDER = try makeTestCertDER(commonName: "UniversalTVRemote")
        let serverDER = try makeTestCertDER(commonName: "TestTV")
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

    func testVoiceFeaturesIncludeVoice() {
        // The VOICE bit (8) is what makes the TV answer KEYCODE_SEARCH
        // with RemoteVoiceBegin — without it no voice session can open.
        XCTAssertNotEqual(AndroidTVDriver.requestedFeatures & 8, 0)
        XCTAssertEqual(AndroidTVDriver.requestedFeatures, 623)
    }

    func testVoiceDrainChunks() {
        // Small yields stay buffered: nothing under 8 KB goes out.
        var buffer = Data()
        XCTAssertEqual(AndroidTVDriver.voiceDrainChunks(samples: Data(repeating: 0xAB, count: 1000), buffer: &buffer), [])
        XCTAssertEqual(buffer.count, 1000)
        // Crossing 8 KB drains one 8–20 KB chunk; the tail stays buffered.
        let chunks = AndroidTVDriver.voiceDrainChunks(samples: Data(repeating: 0xAB, count: 8000), buffer: &buffer)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].count, 9000)
        XCTAssertEqual(buffer.count, 0)
        // A big yield drains 20 KB at a time, keeping the rest buffered.
        var buffer2 = Data()
        let big = AndroidTVDriver.voiceDrainChunks(samples: Data(repeating: 0xAB, count: 25_000), buffer: &buffer2)
        XCTAssertEqual(big.count, 1)
        XCTAssertEqual(big[0].count, 20 * 1024)
        XCTAssertEqual(buffer2.count, 25_000 - 20 * 1024)
    }

    func testVoiceFlushChunksPadsTail() {
        var buffer = Data(repeating: 0xAB, count: 100)
        let chunks = AndroidTVDriver.voiceFlushChunks(buffer: &buffer)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].count, 8 * 1024)
        XCTAssertEqual(chunks[0].prefix(100), Data(repeating: 0xAB, count: 100))
        XCTAssertEqual(buffer.count, 0)
        // Empty buffer yields nothing.
        XCTAssertEqual(AndroidTVDriver.voiceFlushChunks(buffer: &buffer), [])
    }
}

/// Tests for the v1.0.18 pairing persistence (AndroidTVPersistence):
/// the client identity backed up to the app container and restored
/// when the Keychain loses it, the paired flag mirrored to a file, and
/// the migration guard that never discards an identity a TV knows.
/// Offline: no TV, no network. Keychain use is confined to a throwaway
/// slot; every test cleans up its own flags and files.
final class AndroidTVPersistenceTests: XCTestCase {

    private let host = "10.0.0.99"

    override func tearDown() {
        // Leave nothing behind for the next test (or the app): clear
        // the throwaway paired flag, the migration marker and the
        // backup file, and reset any identity this test minted.
        AndroidTVPersistence.removePaired(host: host)
        UserDefaults.standard.removeObject(forKey: "androidtv.identity.forkFresh")
        ClientIdentity.reset()
        super.tearDown()
    }

    func testPairedFlagMirroredToFile() {
        // Starts unpaired in both stores.
        XCTAssertFalse(AndroidTVPersistence.isPaired(host: host))
        XCTAssertFalse(AndroidTVPersistence.loadState().pairedHosts.contains(host))

        // Setting it writes both stores…
        AndroidTVPersistence.setPaired(host: host, paired: true)
        XCTAssertTrue(AndroidTVPersistence.isPaired(host: host))
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "androidtv.paired.\(host)"))
        XCTAssertTrue(AndroidTVPersistence.loadState().pairedHosts.contains(host))
        XCTAssertTrue(AndroidTVPersistence.hasAnyPairedHost)

        // …and clearing it clears both.
        AndroidTVPersistence.setPaired(host: host, paired: false)
        XCTAssertFalse(AndroidTVPersistence.isPaired(host: host))
        XCTAssertFalse(AndroidTVPersistence.loadState().pairedHosts.contains(host))

        // The file alone is enough: write a paired host straight to
        // the file (bypassing the UserDefaults mirror) and it still
        // reads paired — this is the LiveContainer case, where
        // UserDefaults does not survive a relaunch.
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AndroidTV", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var state = AndroidTVPersistence.loadState()
        state.pairedHosts.insert(host)
        try! JSONEncoder().encode(state).write(to: dir.appendingPathComponent("state.json"), options: [.atomic])
        XCTAssertFalse(UserDefaults.standard.bool(forKey: "androidtv.paired.\(host)"))
        XCTAssertTrue(AndroidTVPersistence.isPaired(host: host))
    }

    func testIdentityBackupRestore() throws {
        // Mint an identity under a throwaway slot (never the app's real
        // one), then lose the Keychain copy only — the way a
        // LiveContainer relaunch loses it — and load again: the exact
        // same certificate must come back from the container backup.
        let slot = "TestIdentity\(UUID().uuidString.prefix(8))"
        let originalSlot = ClientIdentity.slot
        ClientIdentity.slot = slot
        defer { ClientIdentity.slot = originalSlot }
        ClientIdentity.reset()
        let first = try ClientIdentity.loadOrCreate()
        let firstDER = SecCertificateCopyData(first.certificate) as Data
        // The backup file exists after minting; keep its bytes aside.
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AndroidTV", isDirectory: true)
        let backupURL = dir.appendingPathComponent("identity.json")
        let backupData = try XCTUnwrap(try? Data(contentsOf: backupURL))

        // reset() clears the cache, the Keychain items and the backup
        // file — then put the backup file back, so the only thing
        // missing is the Keychain copy (the LiveContainer case).
        ClientIdentity.reset()
        try backupData.write(to: backupURL, options: [.atomic])
        let again = try ClientIdentity.loadOrCreate()
        XCTAssertEqual(SecCertificateCopyData(again.certificate) as Data, firstDER)
    }

    func testIdentityBackupRoundTrip() throws {
        // The backup file itself round-trips: save a minted identity,
        // read it back, and the certificate and key bytes match.
        let slot = "TestIdentity\(UUID().uuidString.prefix(8))"
        let originalSlot = ClientIdentity.slot
        ClientIdentity.slot = slot
        defer { ClientIdentity.slot = originalSlot }
        ClientIdentity.reset()
        let first = try ClientIdentity.loadOrCreate()
        let backup = try XCTUnwrap(AndroidTVPersistence.loadIdentityBackup())
        XCTAssertEqual(backup.certificateDER, SecCertificateCopyData(first.certificate) as Data)
        // The backed-up key parses back as a 2048-bit RSA private key
        // and its public half matches the certificate's.
        let key = try XCTUnwrap(SecKeyCreateWithData(backup.privateKeyDER as CFData, [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 2048,
        ] as CFDictionary, nil))
        let publicDER = try XCTUnwrap(SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(key)!, nil) as Data?)
        let components = try XCTUnwrap(ClientIdentity.rsaComponents(of: first.certificate))
        let parsed = try XCTUnwrap(DER.rsaPublicKeyComponents(Array(publicDER)))
        XCTAssertEqual(components.modulus, parsed.modulus)
        XCTAssertEqual(components.exponent, parsed.exponent)
    }

    func testMigrationSkipsPairedIdentity() throws {
        // A paired host is proof the current identity is good: the
        // migration must not discard it, even when its marker is lost.
        let slot = "TestIdentity\(UUID().uuidString.prefix(8))"
        let originalSlot = ClientIdentity.slot
        ClientIdentity.slot = slot
        defer { ClientIdentity.slot = originalSlot }
        ClientIdentity.reset()
        let first = try ClientIdentity.loadOrCreate()
        let firstDER = SecCertificateCopyData(first.certificate) as Data

        // Pair the host, then lose the migration marker in both stores.
        AndroidTVPersistence.setPaired(host: host, paired: true)
        UserDefaults.standard.removeObject(forKey: "androidtv.identity.forkFresh")
        var state = AndroidTVPersistence.loadState()
        state.forkFreshMigrated = false
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AndroidTV", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try! JSONEncoder().encode(state).write(to: dir.appendingPathComponent("state.json"), options: [.atomic])
        XCTAssertFalse(AndroidTVPersistence.isForkFreshMigrated)

        // Migration runs — and must leave the identity alone. Check
        // the Keychain directly: loadOrCreate would return the
        // in-memory cache, which survives a reset and would hide a
        // wrong discard.
        ClientIdentity.migrateToFreshIdentityIfNeeded()
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let identities = try XCTUnwrap(result as? [SecIdentity])
        let ders = identities.compactMap { id -> Data? in
            var cert: SecCertificate?
            guard SecIdentityCopyCertificate(id, &cert) == errSecSuccess, let cert else { return nil }
            return SecCertificateCopyData(cert) as Data
        }
        XCTAssertTrue(ders.contains(firstDER))
        // …and it marks itself done, so it will not run again.
        XCTAssertTrue(AndroidTVPersistence.isForkFreshMigrated)
    }
}

/// Tests for the v1.0.22 Android TV text-input fix. The reference
/// (androidtvremote2, tests/test_remote.py) is the spec — these mirror
/// its cases: counters come from remote_ime_key_inject, a show request
/// updates the field counter, a batch edit is only a fallback when the
/// key inject carried no counters, and send_text puts the cursor after
/// the text (start/end are its length). Offline: no TV, no network —
/// messages are built with ProtoWriter and parsed back with ProtoMessage.
final class ImeCounterTrackerTests: XCTestCase {

    /// A field-20 remote_ime_key_inject: app_info (counter + package)
    /// and text_field_status (counter_field). Counters are optional —
    /// omitting one mirrors a key inject that carries no counter.
    private func keyInjectMessage(appPackage: String, appCounter: Int?, fieldCounter: Int?) -> ProtoMessage {
        var w = ProtoWriter()
        w.message(20) { inject in
            inject.message(1) { app in
                if let appCounter { app.int(1, appCounter) }
                app.string(12, appPackage)
            }
            inject.message(2) { field in
                if let fieldCounter { field.int(1, fieldCounter) }
            }
        }
        return ProtoMessage(w.bytes)!
    }

    /// A field-22 remote_ime_show_request with the focused field's
    /// counter_field.
    private func showRequestMessage(fieldCounter: Int) -> ProtoMessage {
        var w = ProtoWriter()
        w.message(22) { show in
            show.message(2) { status in status.int(1, fieldCounter) }
        }
        return ProtoMessage(w.bytes)!
    }

    /// A field-21 remote_ime_batch_edit carrying only its counters.
    private func batchEditMessage(imeCounter: Int, fieldCounter: Int) -> ProtoMessage {
        var w = ProtoWriter()
        w.message(21) { b in
            b.int(1, imeCounter)
            b.int(2, fieldCounter)
        }
        return ProtoMessage(w.bytes)!
    }

    func testKeyInjectSetsCounters() {
        var tracker = ImeCounterTracker()
        tracker.learnFromKeyInject(keyInjectMessage(appPackage: "org.jellyfin.androidtv", appCounter: 5, fieldCounter: 141).message(20)!)
        XCTAssertEqual(tracker.imeCounter, 5)
        XCTAssertEqual(tracker.imeFieldCounter, 141)
    }

    func testBatchEditDoesNotOverwriteKeyInjectCounters() {
        var tracker = ImeCounterTracker()
        tracker.learnFromKeyInject(keyInjectMessage(appPackage: "org.jellyfin.androidtv", appCounter: 5, fieldCounter: 141).message(20)!)
        tracker.learnFromBatchEdit(batchEditMessage(imeCounter: 1, fieldCounter: 1).message(21)!)
        XCTAssertEqual(tracker.imeCounter, 5)
        XCTAssertEqual(tracker.imeFieldCounter, 141)
    }

    func testShowRequestUpdatesFieldCounter() {
        var tracker = ImeCounterTracker()
        tracker.learnFromShowRequest(showRequestMessage(fieldCounter: 7).message(22)!)
        XCTAssertEqual(tracker.imeFieldCounter, 7)
        XCTAssertEqual(tracker.imeCounter, 0)
    }

    func testBatchEditFallbackWhenKeyInjectHasNoCounters() {
        var tracker = ImeCounterTracker()
        tracker.learnFromKeyInject(keyInjectMessage(appPackage: "com.android.vending", appCounter: 3, fieldCounter: 38).message(20)!)
        XCTAssertEqual(tracker.imeCounter, 3)
        XCTAssertEqual(tracker.imeFieldCounter, 38)

        // Switching to an app that reports 0 counters clears the
        // previous app's counters.
        tracker.learnFromKeyInject(keyInjectMessage(appPackage: "com.google.android.youtube.tv", appCounter: nil, fieldCounter: nil).message(20)!)
        XCTAssertEqual(tracker.imeCounter, 0)
        XCTAssertEqual(tracker.imeFieldCounter, 0)

        // A subsequent batch_edit populates the counters as fallback.
        tracker.learnFromBatchEdit(batchEditMessage(imeCounter: 9, fieldCounter: 4).message(21)!)
        XCTAssertEqual(tracker.imeCounter, 9)
        XCTAssertEqual(tracker.imeFieldCounter, 4)
    }

    func testBatchEditMessageCursorIsTextLength() {
        // send_text("abcd") with counters 5/141: field 21, then
        // ime_counter 5, field_counter 141 (varint 0x8D 0x01), one
        // edit_info (insert 1) whose object has start = end = 4 —
        // the text's length, not length - 1.
        let writer = AndroidTVDriver.imeBatchEditMessage(text: "abcd", imeCounter: 5, imeFieldCounter: 141)
        XCTAssertEqual(Data(writer.bytes), Data([
            0xAA, 0x01, 0x15,
            0x08, 0x05,
            0x10, 0x8D, 0x01,
            0x1A, 0x0E,
            0x08, 0x01,
            0x12, 0x0A,
            0x08, 0x04, 0x10, 0x04, 0x1A, 0x04, 0x61, 0x62, 0x63, 0x64,
        ]))
        // And parsed back, the same shape the reference asserts.
        let msg = ProtoMessage(writer.bytes)!
        let edit = msg.message(21)!
        XCTAssertEqual(edit.int(1), 5)
        XCTAssertEqual(edit.int(2), 141)
        let info = edit.message(3)!
        XCTAssertEqual(info.int(1), 1)
        let object = info.message(2)!
        XCTAssertEqual(object.int(1), 4)
        XCTAssertEqual(object.int(2), 4)
        XCTAssertEqual(object.string(3), "abcd")
    }
}

/// Hardware volume buttons (v1.0.23): the pure direction test behind
/// the outputVolume KVO — nil means "not a step", so the anchor
/// reset's own echo (exactly zero delta) never fires a step.
final class HardwareVolumeDirectionTests: XCTestCase {
    func testStepUp() {
        XCTAssertEqual(HardwareVolumeController.direction(from: 0.5, to: 0.5625), Optional(true))
    }

    func testStepDown() {
        XCTAssertEqual(HardwareVolumeController.direction(from: 0.5, to: 0.4375), Optional(false))
    }

    func testNoStepForZeroDelta() {
        XCTAssertNil(HardwareVolumeController.direction(from: 0.5, to: 0.5))
    }

    func testNoStepForTinyNoise() {
        XCTAssertNil(HardwareVolumeController.direction(from: 0.5, to: 0.505))
    }

    func testLargeDeltaStillOneStep() {
        // A jump from the anchor (e.g. the first press after a
        // failed anchor) is still just one direction, not many.
        XCTAssertEqual(HardwareVolumeController.direction(from: 0.5, to: 0.9625), Optional(true))
    }
}

/// Volume step tracking (v1.0.26): the pure tracker behind the
/// outputVolume KVO — lastVolume always holds the phone's real
/// volume, and the anchor reset only re-bases it when the reset
/// actually moved the slider.
final class VolumeStepTrackerTests: XCTestCase {
    func testFirstPressAfterFailedAnchorReadsRealDirection() {
        // The v1.0.23 bug: the phone is at max (1.0) and the anchor
        // never landed — pressing down must read DOWN, not up (the
        // old code measured against a phantom 0.5 anchor).
        var tracker = VolumeStepTracker(startingVolume: 1.0)
        XCTAssertEqual(tracker.step(to: 0.9375, resetSucceeded: false), Optional(false))
        XCTAssertEqual(tracker.lastVolume, 0.9375)
    }

    func testStepUpFromRealVolume() {
        var tracker = VolumeStepTracker(startingVolume: 0.25)
        XCTAssertEqual(tracker.step(to: 0.3125, resetSucceeded: false), Optional(true))
        XCTAssertEqual(tracker.lastVolume, 0.3125)
    }

    func testSuccessfulResetRebasesToAnchor() {
        var tracker = VolumeStepTracker(startingVolume: 0.25)
        XCTAssertEqual(tracker.step(to: 0.3125, resetSucceeded: true), Optional(true))
        XCTAssertEqual(tracker.lastVolume, 0.5)
        // The next press is measured from the anchor.
        XCTAssertEqual(tracker.step(to: 0.4375, resetSucceeded: true), Optional(false))
    }

    func testFailedResetKeepsRealVolume() {
        var tracker = VolumeStepTracker(startingVolume: 0.25)
        XCTAssertEqual(tracker.step(to: 0.3125, resetSucceeded: false), Optional(true))
        XCTAssertEqual(tracker.lastVolume, 0.3125)
        XCTAssertEqual(tracker.step(to: 0.25, resetSucceeded: false), Optional(false))
    }

    func testResetEchoIsIgnored() {
        var tracker = VolumeStepTracker(startingVolume: 0.5)
        tracker.noteAnchorApplied()
        XCTAssertNil(tracker.step(to: 0.5, resetSucceeded: true))
    }

    func testAnchorAppliedRebasesTracker() {
        var tracker = VolumeStepTracker(startingVolume: 0.9)
        tracker.noteAnchorApplied()
        XCTAssertEqual(tracker.lastVolume, 0.5)
    }
}

/// Swipe pad gesture decisions (v1.0.25, swipe-and-hold repeat
/// v1.0.27): the pure state machine behind SwipePadView — tap,
/// single-tap-hold, double-tap-hold spam, the double-tap window,
/// a swipe cancelling a hold, and a held swipe repeating.
final class SwipePadGestureTests: XCTestCase {
    private let slop: CGFloat = 14
    private let still = CGSize(width: 0, height: 0)
    private let swipeRight = CGSize(width: 40, height: 2)

    func testTapSendsExactlyOneEnter() {
        var g = SwipePadGesture()
        XCTAssertTrue(g.touchDown())
        XCTAssertEqual(g.touchUp(translation: still, slop: slop), [.enter(haptic: true)])
        XCTAssertTrue(g.isAwaitingSecondTap)
    }

    func testTapHeldSendsDownAtOnsetAndUpOnLiftWithNoEnterOnLift() {
        var g = SwipePadGesture()
        XCTAssertTrue(g.touchDown())
        XCTAssertEqual(g.onsetTimerFired(), [.enterDown])
        XCTAssertTrue(g.isKeyHeldDown)
        XCTAssertEqual(g.touchUp(translation: still, slop: slop), [.enterUp])
        XCTAssertFalse(g.isKeyHeldDown)
        // A hold-lift is not a tap: it never opens a double-tap window.
        XCTAssertFalse(g.isAwaitingSecondTap)
    }

    func testDoubleTapHeldSpams() {
        var g = SwipePadGesture()
        XCTAssertTrue(g.touchDown())
        XCTAssertEqual(g.touchUp(translation: still, slop: slop), [.enter(haptic: true)])
        XCTAssertTrue(g.touchDown()) // second tap inside the window
        // First repeat buzzes once…
        XCTAssertEqual(g.onsetTimerFired(), [.enter(haptic: true)])
        XCTAssertTrue(g.isSpamming)
        // …later repeats are silent.
        XCTAssertEqual(g.spamTick(), [.enter(haptic: false)])
        XCTAssertEqual(g.spamTick(), [.enter(haptic: false)])
        // Lift stops the spam; no key was held down, so no key-up.
        XCTAssertEqual(g.touchUp(translation: still, slop: slop), [])
        XCTAssertFalse(g.isSpamming)
    }

    func testDoubleTapQuickSendsTwoEnters() {
        var g = SwipePadGesture()
        XCTAssertTrue(g.touchDown())
        XCTAssertEqual(g.touchUp(translation: still, slop: slop), [.enter(haptic: true)])
        XCTAssertTrue(g.touchDown())
        XCTAssertEqual(g.touchUp(translation: still, slop: slop), [.enter(haptic: true)])
        XCTAssertFalse(g.isAwaitingSecondTap)
    }

    func testDoubleTapWindowExpiryMakesTwoSeparateTaps() {
        var g = SwipePadGesture()
        XCTAssertTrue(g.touchDown())
        XCTAssertEqual(g.touchUp(translation: still, slop: slop), [.enter(haptic: true)])
        g.secondTapWindowExpired()
        XCTAssertFalse(g.isAwaitingSecondTap)
        // The next tap is a fresh single: it opens a new window.
        XCTAssertTrue(g.touchDown())
        XCTAssertEqual(g.touchUp(translation: still, slop: slop), [.enter(haptic: true)])
        XCTAssertTrue(g.isAwaitingSecondTap)
    }

    func testSwipeCancelsHoldAndReleasesKeyFirst() {
        var g = SwipePadGesture()
        XCTAssertTrue(g.touchDown())
        XCTAssertEqual(g.onsetTimerFired(), [.enterDown])
        // Key released first, then the first press fires at once.
        XCTAssertEqual(g.moved(translation: swipeRight, slop: slop), [.enterUp, .right(haptic: true)])
        XCTAssertFalse(g.isKeyHeldDown)
        XCTAssertTrue(g.isSwiping)
        // Lift sends nothing more — the press already fired.
        XCTAssertEqual(g.touchUp(translation: swipeRight, slop: slop), [])
        XCTAssertFalse(g.isSwiping)
    }

    func testSwipeBeforeOnsetSendsDirectionAndNoEnter() {
        var g = SwipePadGesture()
        XCTAssertTrue(g.touchDown())
        // The first press fires at swipe recognition…
        XCTAssertEqual(g.moved(translation: swipeRight, slop: slop), [.right(haptic: true)])
        XCTAssertTrue(g.isSwiping)
        // …and lift sends nothing more.
        XCTAssertEqual(g.touchUp(translation: swipeRight, slop: slop), [])
        XCTAssertFalse(g.isSwiping)
    }

    func testSwipeHeldRepeatsAfterOnset() {
        var g = SwipePadGesture()
        XCTAssertTrue(g.touchDown())
        XCTAssertEqual(g.moved(translation: swipeRight, slop: slop), [.right(haptic: true)])
        // First repeat buzzes once…
        XCTAssertEqual(g.onsetTimerFired(), [.right(haptic: true)])
        // …later repeats are silent.
        XCTAssertEqual(g.swipeTick(), [.right(haptic: false)])
        XCTAssertEqual(g.swipeTick(), [.right(haptic: false)])
        // Release stops the repeats and sends no extra press.
        XCTAssertEqual(g.touchUp(translation: swipeRight, slop: slop), [])
        XCTAssertFalse(g.isSwiping)
        XCTAssertEqual(g.swipeTick(), [])
    }

    func testSwipeHeldAfterHoldRepeats() {
        var g = SwipePadGesture()
        XCTAssertTrue(g.touchDown())
        XCTAssertEqual(g.onsetTimerFired(), [.enterDown])
        // Swiping out of a hold releases the key, then fires the press.
        XCTAssertEqual(g.moved(translation: swipeRight, slop: slop), [.enterUp, .right(haptic: true)])
        // First repeat buzzes once…
        XCTAssertEqual(g.swipeTick(), [.right(haptic: true)])
        // …later repeats are silent.
        XCTAssertEqual(g.swipeTick(), [.right(haptic: false)])
        XCTAssertEqual(g.touchUp(translation: swipeRight, slop: slop), [])
        XCTAssertFalse(g.isSwiping)
    }

    func testSwipeLocksDirectionForTheTouch() {
        var g = SwipePadGesture()
        XCTAssertTrue(g.touchDown())
        XCTAssertEqual(g.moved(translation: swipeRight, slop: slop), [.right(haptic: true)])
        // Wandering up mid-swipe changes nothing.
        XCTAssertEqual(g.moved(translation: CGSize(width: 2, height: -40), slop: slop), [])
        XCTAssertEqual(g.swipeTick(), [.right(haptic: true)])
        XCTAssertEqual(g.touchUp(translation: CGSize(width: 2, height: -40), slop: slop), [])
    }

    func testSwipeLiftWithoutMovedSendsOnePress() {
        // A flick too fast for moved() to see still sends one press, on lift.
        var g = SwipePadGesture()
        XCTAssertTrue(g.touchDown())
        XCTAssertEqual(g.touchUp(translation: swipeRight, slop: slop), [.right(haptic: true)])
        XCTAssertFalse(g.isSwiping)
    }

    func testHoldLiftResetsDoubleTapWindow() {
        var g = SwipePadGesture()
        XCTAssertTrue(g.touchDown())
        XCTAssertEqual(g.onsetTimerFired(), [.enterDown])
        XCTAssertEqual(g.touchUp(translation: still, slop: slop), [.enterUp])
        // The next tap is a fresh single, not a double-tap: holding
        // it engages a hold again instead of spamming.
        XCTAssertTrue(g.touchDown())
        XCTAssertEqual(g.onsetTimerFired(), [.enterDown])
    }

    func testSmallMovementWithinSlopIsStillATap() {
        var g = SwipePadGesture()
        XCTAssertTrue(g.touchDown())
        XCTAssertEqual(g.moved(translation: CGSize(width: 5, height: -5), slop: slop), [])
        XCTAssertEqual(g.touchUp(translation: CGSize(width: 5, height: -5), slop: slop), [.enter(haptic: true)])
    }

    // MARK: Mute zone (v1.0.34)

    func testZoneTapHeldBackUntilWindowExpires() {
        var g = SwipePadGesture()
        // A zone tap starts no hold timer and sends nothing yet.
        let down = g.touchDown(inMuteZone: true)
        XCTAssertEqual(down.outputs, [])
        XCTAssertFalse(down.startHold)
        XCTAssertEqual(g.touchUp(translation: still, slop: slop), [])
        XCTAssertTrue(g.isAwaitingSecondTapZone)
        // No second tap: the held-back enter stands alone.
        XCTAssertEqual(g.secondTapWindowExpired(), [.enter(haptic: true)])
        XCTAssertFalse(g.isAwaitingSecondTapZone)
    }

    func testZoneDoubleTapMutesAndSendsNoEnter() {
        var g = SwipePadGesture()
        let first = g.touchDown(inMuteZone: true)
        XCTAssertEqual(first.outputs, [])
        XCTAssertEqual(g.touchUp(translation: still, slop: slop), [])
        XCTAssertTrue(g.isAwaitingSecondTapZone)
        let second = g.touchDown(inMuteZone: true)
        XCTAssertEqual(second.outputs, [])
        XCTAssertFalse(second.startHold)
        XCTAssertEqual(g.touchUp(translation: still, slop: slop), [.mute(haptic: true)])
        XCTAssertFalse(g.isAwaitingSecondTapZone)
    }

    func testZoneTapThenMiddleTapSendsTwoEnters() {
        var g = SwipePadGesture()
        XCTAssertEqual(g.touchDown(inMuteZone: true).outputs, [])
        XCTAssertEqual(g.touchUp(translation: still, slop: slop), [])
        // Second tap outside the zone: not a mute — the held-back
        // enter stands, and this tap is a fresh single.
        let second = g.touchDown(inMuteZone: false)
        XCTAssertEqual(second.outputs, [.enter(haptic: true)])
        XCTAssertTrue(second.startHold)
        XCTAssertEqual(g.touchUp(translation: still, slop: slop), [.enter(haptic: true)])
    }

    func testMiddleTapThenZoneTapIsNormalDoubleTap() {
        var g = SwipePadGesture()
        XCTAssertTrue(g.touchDown())
        XCTAssertEqual(g.touchUp(translation: still, slop: slop), [.enter(haptic: true)])
        // First tap was in the middle: a zone tap now is just the
        // second tap of a normal double-tap. Muting needs both
        // taps in the zone.
        let second = g.touchDown(inMuteZone: true)
        XCTAssertEqual(second.outputs, [])
        XCTAssertTrue(second.startHold)
        XCTAssertEqual(g.touchUp(translation: still, slop: slop), [.enter(haptic: true)])
        XCTAssertFalse(g.isAwaitingSecondTapZone)
    }

    func testZoneTapHeldStartsNoHold() {
        var g = SwipePadGesture()
        let down = g.touchDown(inMuteZone: true)
        XCTAssertFalse(down.startHold)
        // Even at onset, a zone tap never holds the key down.
        XCTAssertEqual(g.onsetTimerFired(), [])
        XCTAssertFalse(g.isKeyHeldDown)
        XCTAssertEqual(g.touchUp(translation: still, slop: slop), [])
        XCTAssertTrue(g.isAwaitingSecondTapZone)
    }

    func testSwipeFromZoneStillSwipes() {
        var g = SwipePadGesture()
        XCTAssertEqual(g.touchDown(inMuteZone: true).outputs, [])
        // A swipe starting in the zone is still a swipe.
        XCTAssertEqual(g.moved(translation: swipeRight, slop: slop), [.right(haptic: true)])
        XCTAssertTrue(g.isSwiping)
        XCTAssertEqual(g.touchUp(translation: swipeRight, slop: slop), [])
    }

    func testZoneDoubleTapHeldStillMutesOnLift() {
        var g = SwipePadGesture()
        XCTAssertEqual(g.touchDown(inMuteZone: true).outputs, [])
        XCTAssertEqual(g.touchUp(translation: still, slop: slop), [])
        let second = g.touchDown(inMuteZone: true)
        XCTAssertFalse(second.startHold)
        XCTAssertEqual(g.onsetTimerFired(), [])
        XCTAssertEqual(g.touchUp(translation: still, slop: slop), [.mute(haptic: true)])
    }

    // MARK: Bottom zones (v1.0.55)

    func testBottomZoneDoubleTapFiresZoneAction() {
        let cases: [(PadZone, SwipePadGesture.Output)] = [
            (.back, .back(haptic: true)),
            (.home, .home(haptic: true)),
            (.exit, .exit(haptic: true)),
        ]
        for (zone, expected) in cases {
            var g = SwipePadGesture()
            XCTAssertEqual(g.touchDown(inZone: zone).outputs, [])
            XCTAssertEqual(g.touchUp(translation: still, slop: slop), [])
            XCTAssertTrue(g.isAwaitingSecondTapZone)
            XCTAssertEqual(g.touchDown(inZone: zone).outputs, [])
            XCTAssertEqual(g.touchUp(translation: still, slop: slop), [expected])
            XCTAssertFalse(g.isAwaitingSecondTapZone)
        }
    }

    func testSingleTapInBottomZoneStillSendsOK() {
        // A single tap in a bottom zone is still an OK — the zone
        // only changes what a double-tap does.
        for zone in [PadZone.back, .home, .exit, .mute] {
            var g = SwipePadGesture()
            XCTAssertEqual(g.touchDown(inZone: zone).outputs, [])
            XCTAssertEqual(g.touchUp(translation: still, slop: slop), [])
            XCTAssertEqual(g.secondTapWindowExpired(), [.enter(haptic: true)])
        }
    }

    func testSecondTapInDifferentZoneIsNotAnAction() {
        var g = SwipePadGesture()
        XCTAssertEqual(g.touchDown(inZone: .back).outputs, [])
        XCTAssertEqual(g.touchUp(translation: still, slop: slop), [])
        // Second tap in a different zone: no action fires — the
        // held-back enter stands and this tap is a fresh single.
        let second = g.touchDown(inZone: .exit)
        XCTAssertEqual(second.outputs, [.enter(haptic: true)])
        XCTAssertTrue(second.startHold)
        XCTAssertEqual(g.touchUp(translation: still, slop: slop), [.enter(haptic: true)])
    }

    func testSwipeFromBottomZoneStillSwipes() {
        var g = SwipePadGesture()
        XCTAssertEqual(g.touchDown(inZone: .back).outputs, [])
        XCTAssertEqual(g.moved(translation: swipeRight, slop: slop), [.right(haptic: true)])
        XCTAssertTrue(g.isSwiping)
        XCTAssertEqual(g.touchUp(translation: swipeRight, slop: slop), [])
    }
}

/// The coalescing volume pump (v1.0.28): rapid steps collapse into
/// one pending slot plus one in-flight send, so a hold stops the
/// instant the finger lifts and never blocks other keys.
@MainActor
final class VolumePumpTests: XCTestCase {
    /// Polls until `condition` is true or the timeout elapses.
    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 2.0) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testSingleStepSendsOnce() async {
        let pump = CoalescingPump<Bool>()
        var sent: [Bool] = []
        pump.send = { up in sent.append(up) }
        pump.enqueue(true)
        await waitUntil { sent.count == 1 }
        XCTAssertEqual(sent, [true])
        XCTAssertFalse(pump.isPumping)
    }

    func testRapidStepsCoalesceToOnePending() async {
        let pump = CoalescingPump<Bool>()
        var sent: [Bool] = []
        // The first send is slow (throttle): three more steps land
        // while it is in flight and must collapse into ONE pending
        // step — not three queued sends.
        pump.send = { up in
            try? await Task.sleep(nanoseconds: 150_000_000)
            sent.append(up)
        }
        pump.enqueue(true)
        // Let the first send start before piling on, so the later
        // steps genuinely arrive mid-send (a synchronous burst
        // would coalesce into the first send's own slot).
        try? await Task.sleep(nanoseconds: 50_000_000)
        pump.enqueue(true)
        pump.enqueue(true)
        pump.enqueue(true)
        await waitUntil { sent.count == 2 }
        XCTAssertEqual(sent, [true, true])
        XCTAssertFalse(pump.isPumping)
    }

    func testLatestDirectionWins() async {
        let pump = CoalescingPump<Bool>()
        var sent: [Bool] = []
        pump.send = { up in
            try? await Task.sleep(nanoseconds: 150_000_000)
            sent.append(up)
        }
        pump.enqueue(true)
        // A down step arrives while the up send is in flight: the
        // pending slot flips to down.
        try? await Task.sleep(nanoseconds: 50_000_000)
        pump.enqueue(false)
        await waitUntil { sent.count == 2 }
        XCTAssertEqual(sent, [true, false])
    }

    func testNoSendsAfterPumpDrains() async {
        // The v1.0.28 bug, as a test: hold, release, and the pump
        // must go quiet — nothing fires after the drain.
        let pump = CoalescingPump<Bool>()
        var sent: [Bool] = []
        pump.send = { up in
            try? await Task.sleep(nanoseconds: 100_000_000)
            sent.append(up)
        }
        pump.enqueue(true)
        try? await Task.sleep(nanoseconds: 50_000_000)
        pump.enqueue(true)
        pump.enqueue(true)
        await waitUntil { sent.count == 2 }
        // Released: wait well past another send cycle and assert
        // nothing more went out.
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(sent, [true, true])
        XCTAssertFalse(pump.isPumping)
    }

    func testCancelDropsPendingStep() async {
        let pump = CoalescingPump<Bool>()
        var sent: [Bool] = []
        pump.send = { up in
            try? await Task.sleep(nanoseconds: 150_000_000)
            sent.append(up)
        }
        pump.enqueue(true)
        try? await Task.sleep(nanoseconds: 50_000_000)
        pump.enqueue(true) // pending, waiting on the first send
        pump.cancel() // disconnect mid-send: the pending step dies
        await waitUntil { sent.count == 1 }
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(sent, [true])
        XCTAssertFalse(pump.isPumping)
    }

    func testSequentialStepsEachSend() async {
        let pump = CoalescingPump<Bool>()
        var sent: [Bool] = []
        pump.send = { up in sent.append(up) }
        pump.enqueue(true)
        await waitUntil { sent.count == 1 }
        pump.enqueue(false)
        await waitUntil { sent.count == 2 }
        XCTAssertEqual(sent, [true, false])
    }
}

/// The coalescing repeat pump (v1.0.34): rapid repeat presses
/// collapse into one pending slot plus one in-flight send, so a
/// hold stops dead the instant the finger lifts.
@MainActor
final class RepeatPumpTests: XCTestCase {
    /// Polls until `condition` is true or the timeout elapses.
    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 2.0) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testSingleRepeatSendsOnce() async {
        let pump = CoalescingPump<RemoteCommand>()
        var sent: [RemoteCommand] = []
        pump.send = { command in sent.append(command) }
        pump.enqueue(.enter)
        await waitUntil { sent.count == 1 }
        XCTAssertEqual(sent, [.enter])
        XCTAssertFalse(pump.isPumping)
    }

    func testRapidRepeatsCoalesceToOnePending() async {
        let pump = CoalescingPump<RemoteCommand>()
        var sent: [RemoteCommand] = []
        // The first send is slow (throttle): three more repeats
        // land while it is in flight and must collapse into ONE
        // pending press — not three queued sends.
        pump.send = { command in
            try? await Task.sleep(nanoseconds: 150_000_000)
            sent.append(command)
        }
        pump.enqueue(.enter)
        try? await Task.sleep(nanoseconds: 50_000_000)
        pump.enqueue(.enter)
        pump.enqueue(.enter)
        pump.enqueue(.enter)
        await waitUntil { sent.count == 2 }
        XCTAssertEqual(sent, [.enter, .enter])
        XCTAssertFalse(pump.isPumping)
    }

    func testLatestCommandWins() async {
        let pump = CoalescingPump<RemoteCommand>()
        var sent: [RemoteCommand] = []
        pump.send = { command in
            try? await Task.sleep(nanoseconds: 150_000_000)
            sent.append(command)
        }
        pump.enqueue(.enter)
        // A direction arrives while the enter is in flight: the
        // pending slot flips to it.
        try? await Task.sleep(nanoseconds: 50_000_000)
        pump.enqueue(.up)
        await waitUntil { sent.count == 2 }
        XCTAssertEqual(sent, [.enter, .up])
    }

    func testCancelDropsPendingRepeat() async {
        let pump = CoalescingPump<RemoteCommand>()
        var sent: [RemoteCommand] = []
        pump.send = { command in
            try? await Task.sleep(nanoseconds: 150_000_000)
            sent.append(command)
        }
        pump.enqueue(.enter)
        try? await Task.sleep(nanoseconds: 50_000_000)
        pump.enqueue(.enter) // pending, waiting on the first send
        pump.cancel() // finger lifted mid-send: the pending dies
        await waitUntil { sent.count == 1 }
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(sent, [.enter])
        XCTAssertFalse(pump.isPumping)
    }

    func testNoRepeatsAfterPumpDrains() async {
        // The v1.0.34 bug, as a test: hold, release, and the pump
        // must go quiet — nothing fires after the drain.
        let pump = CoalescingPump<RemoteCommand>()
        var sent: [RemoteCommand] = []
        pump.send = { command in
            try? await Task.sleep(nanoseconds: 100_000_000)
            sent.append(command)
        }
        pump.enqueue(.enter)
        try? await Task.sleep(nanoseconds: 50_000_000)
        pump.enqueue(.enter)
        pump.enqueue(.enter)
        pump.enqueue(.enter)
        await waitUntil { sent.count == 2 }
        // Released: wait well past another send cycle and assert
        // nothing more went out.
        try? await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertEqual(sent, [.enter, .enter])
        XCTAssertFalse(pump.isPumping)
    }
}


// MARK: - v1.0.53 cleanup tests

/// Held-key tracking (B1): a Samsung key held down stays stuck if
/// Wi-Fi drops mid-hold, so the tracker remembers it until a Release
/// goes out or a disconnect best-effort Releases it.
final class HeldKeyTrackerTests: XCTestCase {
    func testPressTracksKey() {
        var tracker = HeldKeyTracker()
        XCTAssertNil(tracker.heldKey)
        tracker.pressSucceeded(.enter)
        XCTAssertEqual(tracker.heldKey, .enter)
    }

    func testReleaseClearsMatchingKey() {
        var tracker = HeldKeyTracker()
        tracker.pressSucceeded(.enter)
        tracker.releaseSucceeded(.enter)
        XCTAssertNil(tracker.heldKey)
    }

    func testReleaseIgnoresDifferentKey() {
        var tracker = HeldKeyTracker()
        tracker.pressSucceeded(.enter)
        tracker.releaseSucceeded(.back)
        XCTAssertEqual(tracker.heldKey, .enter)
    }

    func testReleaseFailedReturnsStuckKeyAndKeepsItTracked() {
        var tracker = HeldKeyTracker()
        tracker.pressSucceeded(.volumeUp)
        XCTAssertEqual(tracker.releaseFailed(.volumeUp), .volumeUp)
        // Still tracked: a later disconnect can still free it.
        XCTAssertEqual(tracker.heldKey, .volumeUp)
        XCTAssertNil(tracker.releaseFailed(.enter))
    }

    func testTakeForDisconnectConsumesKey() {
        var tracker = HeldKeyTracker()
        XCTAssertNil(tracker.takeForDisconnect())
        tracker.pressSucceeded(.power)
        XCTAssertEqual(tracker.takeForDisconnect(), .power)
        XCTAssertNil(tracker.heldKey)
        XCTAssertNil(tracker.takeForDisconnect())
    }

    func testPressReplacesHeldKey() {
        var tracker = HeldKeyTracker()
        tracker.pressSucceeded(.enter)
        tracker.pressSucceeded(.back)
        XCTAssertEqual(tracker.heldKey, .back)
    }
}

/// Samsung queue drain (S9): keys queued while the TV was
/// unreachable go stale — drop them after ~5 s instead of firing a
/// key the user forgot about minutes later.
final class SamsungQueueTests: XCTestCase {
    func testFreshPendingKeysDropsStaleEntries() {
        let now = Date()
        let queued: [(key: SamsungRemote.Key, enqueuedAt: Date)] = [
            (.enter, now.addingTimeInterval(-10)),
            (.back, now.addingTimeInterval(-6)),
            (.up, now.addingTimeInterval(-1)),
        ]
        XCTAssertEqual(SamsungRemote.freshPendingKeys(queued, now: now), [.up])
    }

    func testFreshPendingKeysKeepsBoundaryEntry() {
        let now = Date()
        let queued: [(key: SamsungRemote.Key, enqueuedAt: Date)] = [
            (.enter, now.addingTimeInterval(-4.9)),
            (.back, now.addingTimeInterval(-5)),
            (.up, now.addingTimeInterval(-5.1)),
        ]
        XCTAssertEqual(SamsungRemote.freshPendingKeys(queued, now: now), [.enter, .back])
    }

    func testFreshPendingKeysEmptyInEmptyOut() {
        XCTAssertEqual(SamsungRemote.freshPendingKeys([], now: Date()), [])
    }
}

/// Error mapping (S1): only connection-level errors drop
/// `isConnected` — a TV that answered (bad reply, refused pairing)
/// is still there.
final class ErrorConnectionLevelTests: XCTestCase {
    func testSamsungErrors() {
        XCTAssertTrue(SamsungRemote.SamsungError.notConnected.isConnectionLevel)
        XCTAssertTrue(SamsungRemote.SamsungError.timeout.isConnectionLevel)
        XCTAssertTrue(SamsungRemote.SamsungError.denied.isConnectionLevel)
        XCTAssertFalse(SamsungRemote.SamsungError.invalidResponse.isConnectionLevel)
    }

    func testLGErrors() {
        XCTAssertTrue(LGError.notConnected.isConnectionLevel)
        XCTAssertTrue(LGError.timeout.isConnectionLevel)
        XCTAssertFalse(LGError.pairingDenied.isConnectionLevel)
        XCTAssertFalse(LGError.pairingTimeout.isConnectionLevel)
        XCTAssertFalse(LGError.certificateChanged.isConnectionLevel)
        XCTAssertFalse(LGError.invalidResponse.isConnectionLevel)
        XCTAssertFalse(LGError.remoteError("x").isConnectionLevel)
        XCTAssertFalse(LGError.blacklistOrSignature.isConnectionLevel)
    }

    func testRokuErrors() {
        XCTAssertFalse(RokuRemote.RokuError.blocked.isConnectionLevel)
        XCTAssertFalse(RokuRemote.RokuError.badResponse.isConnectionLevel)
    }
}

/// Double-connect guard (S2): a second connect while one is in
/// flight is a no-op — it must not race the socket or the busy state.
/// Driven by setting `isBusy` directly so no network is involved.
@MainActor
final class RemoteSessionDoubleConnectTests: XCTestCase {
    private func samsungDevice() -> TVDevice {
        TVDevice(id: "test:samsung", name: "Test Samsung", brand: .samsung,
                 host: "192.0.2.1", port: 8002, source: .sweep)
    }

    func testSecondConnectWhileBusyIsANoOp() async {
        let session = RemoteSession(device: samsungDevice())
        XCTAssertFalse(session.isBusy)
        session.isBusy = true
        let before = session.status
        await session.connect()
        XCTAssertTrue(session.isBusy)
        XCTAssertEqual(session.status, before)
    }

    func testConnectWithoutControlReturnsEarly() async {
        let device = TVDevice(id: "test:other", name: "Test Other", brand: .other,
                              host: "192.0.2.1", source: .sweep)
        let session = RemoteSession(device: device)
        await session.connect()
        XCTAssertFalse(session.isBusy)
        XCTAssertEqual(session.status, "This device was found, but there's no public way to control it from an app.")
    }
}

/// Discovery merge rules (S7): the SSDP port is the description
/// URL's port, not a control port — the sweep's probed port stays;
/// a merge never downgrades a controllable brand; in-place updates
/// re-sort.
@MainActor
final class DiscoveryMergeTests: XCTestCase {
    private func ssdp(host: String, name: String, brand: TVDevice.Brand, port: Int) -> SSDPDevice {
        SSDPDevice(usn: "uuid:\(host)", location: "http://\(host):\(port)/desc.xml",
                   name: name, brand: brand, host: host, port: port, model: nil, manufacturer: nil)
    }

    private func sweep(host: String, name: String, brand: TVDevice.Brand, port: Int) -> SweptDevice {
        SweptDevice(name: name, brand: brand, host: host, port: port, model: nil, manufacturer: nil)
    }

    func testMergeSSDPKeepsSweepControlPort() {
        let manager = DiscoveryManager()
        manager.mergeSweep(sweep(host: "192.168.1.50", name: "Samsung TV", brand: .samsung, port: 8002))
        manager.mergeSSDP(ssdp(host: "192.168.1.50", name: "Samsung TV", brand: .samsung, port: 80))
        XCTAssertEqual(manager.devices.count, 1)
        XCTAssertEqual(manager.devices[0].port, 8002)
    }

    func testMergeSSDPResortsAfterInPlaceRename() {
        let manager = DiscoveryManager()
        manager.mergeSweep(sweep(host: "192.168.1.2", name: "Zebra", brand: .samsung, port: 8002))
        manager.mergeSweep(sweep(host: "192.168.1.3", name: "Alpha", brand: .samsung, port: 8002))
        XCTAssertEqual(manager.devices.map(\.name), ["Alpha", "Zebra"])
        manager.mergeSSDP(ssdp(host: "192.168.1.3", name: "Zulu", brand: .samsung, port: 80))
        XCTAssertEqual(manager.devices.map(\.name), ["Zebra", "Zulu"])
    }

    func testMergeSweepDoesNotDowngradeControllableBrand() {
        let manager = DiscoveryManager()
        manager.mergeSweep(sweep(host: "192.168.1.50", name: "TV", brand: .samsung, port: 8002))
        manager.mergeSweep(sweep(host: "192.168.1.50", name: "TV", brand: .other, port: 8000))
        XCTAssertEqual(manager.devices[0].brand, .samsung)
        XCTAssertEqual(manager.devices[0].port, 8002)
    }

    func testMergeSweepUpgradesNonControllableBrand() {
        let manager = DiscoveryManager()
        manager.mergeSweep(sweep(host: "192.168.1.50", name: "TV", brand: .other, port: 8000))
        manager.mergeSweep(sweep(host: "192.168.1.50", name: "TV", brand: .samsung, port: 8002))
        XCTAssertEqual(manager.devices[0].brand, .samsung)
        XCTAssertEqual(manager.devices[0].port, 8002)
    }

    func testMergeSSDPDoesNotEraseControllableBrand() {
        let manager = DiscoveryManager()
        manager.mergeSweep(sweep(host: "192.168.1.50", name: "TV", brand: .samsung, port: 8002))
        manager.mergeSSDP(ssdp(host: "192.168.1.50", name: "TV", brand: .other, port: 80))
        XCTAssertEqual(manager.devices[0].brand, .samsung)
    }

    func testMergeSSDPControllableBrandReplaces() {
        let manager = DiscoveryManager()
        manager.mergeSweep(sweep(host: "192.168.1.50", name: "TV", brand: .other, port: 8000))
        manager.mergeSSDP(ssdp(host: "192.168.1.50", name: "TV", brand: .lg, port: 80))
        XCTAssertEqual(manager.devices[0].brand, .lg)
    }
}

/// Protobuf framer edges (S6): a corrupt length prefix and an
/// unbounded buffer both drop the buffer instead of trapping or
/// growing forever, and framing resyncs on the next message.
final class ProtoFramerTests: XCTestCase {
    private func frame(_ payload: [UInt8]) -> Data {
        Data(ProtoWriter.varint(UInt64(payload.count)) + payload)
    }

    func testValidFrameRoundTrips() {
        var framer = ProtoFramer()
        framer.append(frame([1, 2, 3]))
        XCTAssertEqual(framer.next(), [1, 2, 3])
        XCTAssertNil(framer.next())
    }

    func testPartialFrameCompletes() {
        var framer = ProtoFramer()
        framer.append(Data(ProtoWriter.varint(5) + [1, 2]))
        XCTAssertNil(framer.next())
        framer.append(Data([3, 4, 5]))
        XCTAssertEqual(framer.next(), [1, 2, 3, 4, 5])
    }

    func testOversizedLengthPrefixReturnsNilAndClearsBuffer() {
        var framer = ProtoFramer()
        framer.append(Data(ProtoWriter.varint(ProtoFramer.maxFrameLength + 1)))
        XCTAssertNil(framer.next())
        // The buffer was dropped: a valid frame after it still parses.
        framer.append(frame([9, 9]))
        XCTAssertEqual(framer.next(), [9, 9])
    }

    func testHugeAppendIsCapped() {
        var framer = ProtoFramer()
        framer.append(Data(repeating: 0, count: ProtoFramer.maxBufferLength + 1))
        XCTAssertNil(framer.next())
        framer.append(frame([7]))
        XCTAssertEqual(framer.next(), [7])
    }

    func testWireTypeTwoLengthBeyondBufferIsNil() {
        // Field 1, wire type 2, declared length 10, only 2 bytes present.
        XCTAssertNil(ProtoMessage([0x0A, 0x0A, 0x01, 0x02]))
    }

    func testWireTypeTwoValidBytesFieldParses() {
        var w = ProtoWriter()
        w.data(1, [0xAA, 0xBB])
        guard let message = ProtoMessage(w.bytes) else {
            return XCTFail("valid bytes field should parse")
        }
        guard case .bytes(let bytes)? = message.fields[1]?.first else {
            return XCTFail("expected a bytes value for field 1")
        }
        XCTAssertEqual(bytes, [0xAA, 0xBB])
    }
}

/// Wake-on-LAN packet shape (N7): six 0xFF bytes, then the MAC
/// repeated 16 times — 102 bytes total.
final class WakeOnLANTests: XCTestCase {
    func testMagicPacketShape() {
        guard let packet = WakeOnLAN.magicPacket(mac: "aa:bb:cc:dd:ee:ff") else {
            return XCTFail("valid MAC should build a packet")
        }
        XCTAssertEqual(packet.count, 102)
        XCTAssertEqual(Array(packet[0..<6]), [UInt8](repeating: 0xFF, count: 6))
        let mac: [UInt8] = [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]
        for i in 0..<16 {
            XCTAssertEqual(Array(packet[6 + i * 6..<12 + i * 6]), mac)
        }
    }

    func testMagicPacketAcceptsDashes() {
        XCTAssertEqual(WakeOnLAN.magicPacket(mac: "aa-bb-cc-dd-ee-ff")?.count, 102)
    }

    func testMagicPacketRejectsBadMAC() {
        XCTAssertNil(WakeOnLAN.magicPacket(mac: "not-a-mac"))
        XCTAssertNil(WakeOnLAN.magicPacket(mac: "aa:bb:cc:dd:ee"))
        XCTAssertNil(WakeOnLAN.magicPacket(mac: "gg:bb:cc:dd:ee:ff"))
    }

    func testWifiBroadcastAddressIsNilOrDottedQuad() {
        guard let broadcast = SubnetSweep.wifiBroadcastAddress() else { return }
        let parts = broadcast.split(separator: ".")
        XCTAssertEqual(parts.count, 4)
        XCTAssertTrue(parts.allSatisfy { UInt8($0) != nil })
    }
}

/// Pad geometry (v1.0.54): max tilt 6° (back from 8°, still
/// slightly too strong in the v1.0.53 field test), mute zone
/// middle-right, tilt axis toward the finger.
final class PadGeometryTests: XCTestCase {
    private let pad = PadGeometry(size: CGSize(width: 360, height: 220))

    func testCenterPressDoesNotTilt() {
        XCTAssertEqual(pad.tiltAngle(isPressed: true, pressLocation: CGPoint(x: 180, y: 110)), 0, accuracy: 0.0001)
    }

    func testCornerPressTiltsAtMax() {
        XCTAssertEqual(pad.tiltAngle(isPressed: true, pressLocation: CGPoint(x: 360, y: 220)), 6, accuracy: 0.0001)
    }

    func testQuarterPressTiltsProportionally() {
        // dx 0.25, dy 0 → sqrt(0.0625) * 2.5 = 0.625 of max (3.75° at a 6° max).
        XCTAssertEqual(pad.tiltAngle(isPressed: true, pressLocation: CGPoint(x: 270, y: 110)), 3.75, accuracy: 0.0001)
    }

    func testNoPressDoesNotTilt() {
        XCTAssertEqual(pad.tiltAngle(isPressed: false, pressLocation: CGPoint(x: 360, y: 220)), 0)
    }

    func testUnknownSizeDoesNotTilt() {
        XCTAssertEqual(PadGeometry(size: .zero).tiltAngle(isPressed: true, pressLocation: CGPoint(x: 10, y: 10)), 0)
    }

    func testMuteZone() {
        XCTAssertTrue(pad.isMuteZone(CGPoint(x: 300, y: 110)))
        XCTAssertTrue(pad.isMuteZone(CGPoint(x: 241.2, y: 55)))
        XCTAssertTrue(pad.isMuteZone(CGPoint(x: 360, y: 165)))
        XCTAssertFalse(pad.isMuteZone(CGPoint(x: 180, y: 110)))
        XCTAssertFalse(pad.isMuteZone(CGPoint(x: 300, y: 10)))
        XCTAssertFalse(pad.isMuteZone(CGPoint(x: 300, y: 200)))
        XCTAssertFalse(PadGeometry(size: .zero).isMuteZone(CGPoint(x: 10, y: 10)))
    }

    func testBottomZones() {
        // Bottom strip (y >= 0.75) split into thirds on a 360x220 pad.
        XCTAssertTrue(pad.isBackZone(CGPoint(x: 30, y: 200)))
        XCTAssertTrue(pad.isBackZone(CGPoint(x: 0, y: 220)))
        XCTAssertTrue(pad.isHomeZone(CGPoint(x: 180, y: 200)))
        XCTAssertTrue(pad.isHomeZone(CGPoint(x: 180, y: 220)))
        XCTAssertTrue(pad.isExitZone(CGPoint(x: 330, y: 200)))
        XCTAssertTrue(pad.isExitZone(CGPoint(x: 360, y: 220)))
        // Above the strip is not a bottom zone.
        XCTAssertFalse(pad.isBackZone(CGPoint(x: 30, y: 150)))
        XCTAssertFalse(pad.isHomeZone(CGPoint(x: 180, y: 150)))
        XCTAssertFalse(pad.isExitZone(CGPoint(x: 330, y: 150)))
        // Thirds: the left third is back, not home or exit.
        XCTAssertFalse(pad.isHomeZone(CGPoint(x: 30, y: 200)))
        XCTAssertFalse(pad.isExitZone(CGPoint(x: 30, y: 200)))
        XCTAssertFalse(pad.isBackZone(CGPoint(x: 330, y: 200)))
        // Boundaries: x = 1/3 belongs to back (checked first),
        // x = 2/3 belongs to home; y = 0.75 still belongs to mute.
        XCTAssertTrue(pad.isBackZone(CGPoint(x: 120, y: 200)))
        XCTAssertTrue(pad.isHomeZone(CGPoint(x: 240, y: 200)))
        XCTAssertTrue(pad.isMuteZone(CGPoint(x: 300, y: 165)))
        XCTAssertFalse(pad.isExitZone(CGPoint(x: 300, y: 165)))
        XCTAssertFalse(PadGeometry(size: .zero).isBackZone(CGPoint(x: 10, y: 10)))
    }

    func testZoneAt() {
        XCTAssertEqual(pad.zone(at: CGPoint(x: 300, y: 110)), .mute)
        XCTAssertEqual(pad.zone(at: CGPoint(x: 30, y: 200)), .back)
        XCTAssertEqual(pad.zone(at: CGPoint(x: 180, y: 200)), .home)
        XCTAssertEqual(pad.zone(at: CGPoint(x: 330, y: 200)), .exit)
        XCTAssertNil(pad.zone(at: CGPoint(x: 180, y: 110)))
        XCTAssertNil(pad.zone(at: CGPoint(x: 30, y: 100)))
        XCTAssertNil(PadGeometry(size: .zero).zone(at: CGPoint(x: 10, y: 10)))
    }

    func testZoneCenters() {
        // Zone overlay (v1.0.56): on a 360x220 pad the mute icon
        // sits at (0.835, 0.5) and the bottom icons at y 0.875,
        // x 1/6, 1/2, 5/6.
        XCTAssertEqual(pad.center(of: .mute)?.x ?? -1, 300.6, accuracy: 0.001)
        XCTAssertEqual(pad.center(of: .mute)?.y ?? -1, 110, accuracy: 0.001)
        XCTAssertEqual(pad.center(of: .back)?.x ?? -1, 60, accuracy: 0.001)
        XCTAssertEqual(pad.center(of: .back)?.y ?? -1, 192.5, accuracy: 0.001)
        XCTAssertEqual(pad.center(of: .home)?.x ?? -1, 180, accuracy: 0.001)
        XCTAssertEqual(pad.center(of: .home)?.y ?? -1, 192.5, accuracy: 0.001)
        XCTAssertEqual(pad.center(of: .exit)?.x ?? -1, 300, accuracy: 0.001)
        XCTAssertEqual(pad.center(of: .exit)?.y ?? -1, 192.5, accuracy: 0.001)
        XCTAssertNil(PadGeometry(size: .zero).center(of: .mute))
    }

    func testZoneCentersFallInTheirZones() {
        // The overlay icons must sit inside the zones they label.
        for zone in [PadZone.mute, .back, .home, .exit] {
            guard let center = pad.center(of: zone) else {
                return XCTFail("center should exist for \(zone)")
            }
            XCTAssertEqual(pad.zone(at: center), zone)
        }
    }

    func testTiltAxis() {
        let idle = pad.tiltAxis(pressLocation: nil)
        XCTAssertEqual(idle.x, 0, accuracy: 0.0001)
        XCTAssertEqual(idle.y, 1, accuracy: 0.0001)
        XCTAssertEqual(idle.z, 0, accuracy: 0.0001)
        let corner = pad.tiltAxis(pressLocation: CGPoint(x: 360, y: 220))
        XCTAssertEqual(corner.x, -0.5, accuracy: 0.0001)
        XCTAssertEqual(corner.y, 0.5, accuracy: 0.0001)
        XCTAssertEqual(corner.z, 0, accuracy: 0.0001)
    }
}

/// QuickPath smoothing (v1.0.55): the resampled curve passes
/// through the endpoints, rounds the corners, and never connects
/// separate strokes (strokes stay separate by construction — the
/// smoother only ever sees one stroke at a time).
final class TrailSmoothingTests: XCTestCase {
    func testStraightLinePassesThroughEndpoints() {
        let now = Date()
        let stroke = [TrailPoint(point: CGPoint(x: 0, y: 0), time: now),
                      TrailPoint(point: CGPoint(x: 60, y: 0), time: now.addingTimeInterval(0.1)),
                      TrailPoint(point: CGPoint(x: 120, y: 0), time: now.addingTimeInterval(0.2))]
        let smoothed = TrailSmoothing.smoothStroke(stroke)
        XCTAssertEqual(smoothed.first?.point.x ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(smoothed.first?.point.y ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(smoothed.last?.point.x ?? -1, 120, accuracy: 0.001)
        XCTAssertEqual(smoothed.last?.point.y ?? -1, 0, accuracy: 0.001)
        // A straight line stays straight.
        XCTAssertTrue(smoothed.allSatisfy { abs($0.point.y) < 0.001 })
        // Resampling adds points between the samples.
        XCTAssertGreaterThan(smoothed.count, stroke.count)
    }

    func testCurveBulgesAroundACorner() {
        // An L-shaped stroke: the smooth curve rounds the corner
        // instead of kinking through it — a point between the
        // corner and the end sits off the straight segment.
        let now = Date()
        let stroke = [TrailPoint(point: CGPoint(x: 0, y: 0), time: now),
                      TrailPoint(point: CGPoint(x: 60, y: 0), time: now.addingTimeInterval(0.1)),
                      TrailPoint(point: CGPoint(x: 60, y: 60), time: now.addingTimeInterval(0.2))]
        let smoothed = TrailSmoothing.smoothStroke(stroke)
        XCTAssertTrue(smoothed.contains { $0.point.x > 60.5 && $0.point.y > 0 && $0.point.y < 60 })
        XCTAssertEqual(smoothed.last?.point, CGPoint(x: 60, y: 60))
    }

    func testSinglePointStaysSingle() {
        let now = Date()
        let stroke = [TrailPoint(point: CGPoint(x: 10, y: 10), time: now)]
        let smoothed = TrailSmoothing.smoothStroke(stroke)
        XCTAssertEqual(smoothed.count, 1)
        XCTAssertEqual(smoothed.first?.point, CGPoint(x: 10, y: 10))
    }

    func testTimesIncreaseAlongTheCurve() {
        let now = Date()
        let stroke = (0..<5).map { TrailPoint(point: CGPoint(x: CGFloat($0) * 30, y: 0), time: now.addingTimeInterval(Double($0) * 0.1)) }
        let smoothed = TrailSmoothing.smoothStroke(stroke)
        for i in 1..<smoothed.count {
            XCTAssertGreaterThanOrEqual(smoothed[i].time, smoothed[i - 1].time)
        }
    }
}

/// DER guards (N5): an invalid OID or a negative integer must not
/// crash or produce garbage bytes — encode an empty OID / zero.
final class DERGuardTests: XCTestCase {
    func testOIDGuardsReturnEmptyOID() {
        let empty: [UInt8] = [0x06, 0x00]
        XCTAssertEqual(DER.oid(""), empty)
        XCTAssertEqual(DER.oid("1"), empty)
        XCTAssertEqual(DER.oid("9.1"), empty)
        XCTAssertEqual(DER.oid("3.1"), empty)
        XCTAssertEqual(DER.oid("1.300"), empty)
    }

    func testIntegerNegativeEncodesZero() {
        XCTAssertEqual(DER.integer(-1), [0x02, 0x01, 0x00])
        XCTAssertEqual(DER.integer(0), [0x02, 0x01, 0x00])
    }
}

/// Appearance mapping (v1.0.56): Dark and Light pin the scheme;
/// System resolves to the device's live scheme explicitly —
/// preferredColorScheme(nil) never reverted a forced scheme,
/// so picking System left the app stuck on Light/Dark.
final class AppAppearanceTests: XCTestCase {
    func testDarkMapsToDark() {
        XCTAssertEqual(AppAppearance.dark.scheme, .dark)
    }

    func testLightMapsToLight() {
        XCTAssertEqual(AppAppearance.light.scheme, .light)
    }

    func testSystemMapsToDeviceScheme() {
        let device: ColorScheme = UIScreen.main.traitCollection.userInterfaceStyle == .dark ? .dark : .light
        XCTAssertEqual(AppAppearance.system.scheme, device)
        XCTAssertEqual(AppAppearance.deviceScheme, device)
    }
}

/// Crop geometry (v1.0.56): the crop must come out at the
/// frame's aspect — what you see is what the pad shows. A
/// letterboxed crop (wrong aspect) is the bug: the saved cover
/// would carry black bars onto the pad.
final class PadCoverCropTests: XCTestCase {
    private let frame = CGSize(width: 360, height: 500)

    private func solidImage(width: CGFloat, height: CGFloat) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: width, height: height)).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(origin: .zero, size: CGSize(width: width, height: height)))
        }
    }

    private func aspect(_ size: CGSize) -> CGFloat { size.width / size.height }

    func testSquareImageCropsToFrameAspect() {
        let cropped = PadCoverCropView.crop(image: solidImage(width: 1000, height: 1000), scale: 1, offset: .zero, frameSize: frame)
        XCTAssertEqual(aspect(cropped.size), aspect(frame), accuracy: 0.01)
        XCTAssertEqual(cropped.size.width, 720, accuracy: 1)
        XCTAssertEqual(cropped.size.height, 1000, accuracy: 1)
    }

    func testPortraitImageCropsTopAndBottom() {
        let cropped = PadCoverCropView.crop(image: solidImage(width: 1000, height: 1500), scale: 1, offset: .zero, frameSize: frame)
        XCTAssertEqual(aspect(cropped.size), aspect(frame), accuracy: 0.01)
        XCTAssertLessThan(cropped.size.height, 1500)
    }

    func testLandscapeImageCropsSides() {
        let cropped = PadCoverCropView.crop(image: solidImage(width: 1500, height: 1000), scale: 1, offset: .zero, frameSize: frame)
        XCTAssertEqual(aspect(cropped.size), aspect(frame), accuracy: 0.01)
        XCTAssertEqual(cropped.size.width, 720, accuracy: 1)
    }

    func testOffsetKeepsFrameAspect() {
        let cropped = PadCoverCropView.crop(image: solidImage(width: 1000, height: 1000), scale: 1, offset: CGSize(width: 100, height: 0), frameSize: frame)
        XCTAssertEqual(aspect(cropped.size), aspect(frame), accuracy: 0.01)
    }
}
