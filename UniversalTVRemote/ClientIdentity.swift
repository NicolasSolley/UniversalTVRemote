// Ported from open-tv-remote (https://github.com/iamnbutler/open-tv-remote),
// MIT License, Copyright (c) 2026 Nathan Butler. Adapted for UniversalTVRemote:
// the keychain slot is "UniversalTVRemote" (so the certificate subject is
// "UniversalTVRemote XXXX"), and the label / key tag match the identity this
// app minted in v1.0.10–v1.0.14. v1.0.16: any identity minted by the pre-fork
// code is discarded once (migrateToFreshIdentityIfNeeded) and a fresh one
// is minted with the fork's exact code — the old identity never paired
// with any TV, so nothing is lost, and the TV then sees the same
// certificate shape the working reference app presents.

import CryptoKit
import Foundation
import Security

/// The RSA key + self-signed certificate this app presents to Android TVs.
/// Generated once and kept in the keychain; the TV remembers it after pairing.
enum ClientIdentity {
    struct Material {
        let identity: SecIdentity
        let certificate: SecCertificate
    }

    enum IdentityError: LocalizedError {
        case keychain(String)
        var errorDescription: String? {
            switch self { case .keychain(let m): "Couldn't set up this device's pairing key (\(m))." }
        }
    }

    /// Which keychain slot holds the identity. Overridable so dev tools keep their own key instead
    /// of sharing (and prompting for) the app's.
    static var slot = "UniversalTVRemote"
    /// The label the v1.0.10–v1.0.14 identity was stored under; kept so
    /// find() reuses it and reset() removes it.
    private static var label: String { "UniversalTVRemote AndroidTV" }
    /// The application tag the v1.0.10–v1.0.14 key was stored under; kept
    /// for the same reason.
    private static var keyTag: Data { Data("com.nicolassolley.universaltvremote.androidtv.key".utf8) }

    /// Android TVs keep one pairing per certificate subject, so every install needs its own: a
    /// shared name let each new pairing replace the last. Identities from before this have the
    /// bare slot name and are replaced, which means pairing once more.
    private static func isOurs(_ subject: String) -> Bool { subject.hasPrefix("\(slot) ") }

    private static var cached: Material?

    static func loadOrCreate() throws -> Material {
        if let cached { return cached }
        if let found = find() {
            cached = found
            return found
        }
        // The Keychain lost the identity (LiveContainer's guest Keychain
        // does not reliably persist across relaunches) — restore the
        // exact same certificate from the container backup, so the TV
        // still recognizes us and no re-pairing is needed.
        if restoreFromBackup(), let found = find() {
            cached = found
            return found
        }
        try create()
        guard let found = find() else { throw IdentityError.keychain("identity not found after creation") }
        cached = found
        return found
    }

    /// Re-imports the backed-up identity (certificate + private key)
    /// into the Keychain. Returns true when both items are in place.
    private static func restoreFromBackup() -> Bool {
        guard let backup = AndroidTVPersistence.loadIdentityBackup() else { return false }
        guard let privateKey = SecKeyCreateWithData(backup.privateKeyDER as CFData, [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 2048,
        ] as CFDictionary, nil) else { return false }
        let keyStatus = SecItemAdd(scoped([
            kSecClass as String: kSecClassKey,
            kSecValueRef as String: privateKey,
            kSecAttrApplicationTag as String: keyTag,
            kSecAttrLabel as String: label,
            kSecAttrIsPermanent as String: true,
        ]) as CFDictionary, nil)
        guard keyStatus == errSecSuccess || keyStatus == errSecDuplicateItem else { return false }
        guard let certificate = SecCertificateCreateWithData(nil, backup.certificateDER as CFData) else { return false }
        let certStatus = SecItemAdd(scoped([
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrLabel as String: label,
        ]) as CFDictionary, nil)
        return certStatus == errSecSuccess || certStatus == errSecDuplicateItem
    }

    /// One-time migration (v1.0.16): discard any client identity minted by
    /// the pre-fork code and mint fresh with the fork's exact code on the
    /// next loadOrCreate, so the TV sees the same certificate shape the
    /// working reference app presents. The old identity never paired with
    /// any TV (the QM7 never paired; Samsung uses its own pairing), so
    /// nothing is lost. Runs once, guarded by a marker in both stores.
    ///
    /// Guard: never discard an identity that has a paired TV. The marker
    /// can be lost when the stores don't persist, and re-running the
    /// migration then would throw away the very certificate the TV knows
    /// — the exact re-pairing bug this version fixes. A paired host is
    /// proof the current identity is good, so the migration is skipped
    /// (and marked done) instead.
    static func migrateToFreshIdentityIfNeeded() {
        guard !AndroidTVPersistence.isForkFreshMigrated else { return }
        if AndroidTVPersistence.hasAnyPairedHost {
            AndroidTVPersistence.setForkFreshMigrated()
            return
        }
        reset()
        AndroidTVPersistence.setForkFreshMigrated()
    }

    /// Throws away the key so the next pairing starts fresh — from the
    /// Keychain and from the container backup, so a stale backup can
    /// never resurrect a discarded key.
    static func reset() {
        cached = nil
        AndroidTVPersistence.deleteIdentityBackup()
        SecItemDelete(scoped([kSecClass as String: kSecClassCertificate, kSecAttrLabel as String: label]) as CFDictionary)
        SecItemDelete(scoped([kSecClass as String: kSecClassKey, kSecAttrApplicationTag as String: keyTag]) as CFDictionary)
    }

    // MARK: - Keychain plumbing

    /// On macOS, prefer the modern data-protection keychain when the build is signed for it,
    /// falling back to the login keychain for unsigned/dev builds.
    static let useDataProtectionKeychain: Bool = {
        #if os(macOS)
        let probe: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "freeremote.probe",
            kSecAttrAccount as String: "probe",
            kSecValueData as String: Data([1]),
            kSecUseDataProtectionKeychain as String: true,
        ]
        let status = SecItemAdd(probe as CFDictionary, nil)
        SecItemDelete(probe as CFDictionary)
        return status == errSecSuccess || status == errSecDuplicateItem
        #else
        return false
        #endif
    }()

    /// Adds the data-protection keychain flag where it applies.
    static func scoped(_ q: [String: Any]) -> [String: Any] {
        var q = q
        #if os(macOS)
        if useDataProtectionKeychain { q[kSecUseDataProtectionKeychain as String] = true }
        #endif
        return q
    }

    private static func find() -> Material? {
        let query = scoped([
            kSecClass as String: kSecClassIdentity,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ])
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let identities = result as? [SecIdentity] else { return nil }
        for identity in identities {
            var cert: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &cert) == errSecSuccess, let cert else { continue }
            if let subject = SecCertificateCopySubjectSummary(cert) as String?, isOurs(subject) {
                return Material(identity: identity, certificate: cert)
            }
        }
        return nil
    }

    private static func create() throws {
        reset()
        var error: Unmanaged<CFError>?
        let attrs = scoped([
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: keyTag,
                kSecAttrLabel as String: label,
            ],
        ])
        guard let privateKey = SecKeyCreateRandomKey(attrs as CFDictionary, &error),
              let publicKey = SecKeyCopyPublicKey(privateKey),
              let publicDER = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw IdentityError.keychain(error?.takeRetainedValue().localizedDescription ?? "key generation failed")
        }

        var suffix = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, suffix.count, &suffix)
        let commonName = "\(slot) " + suffix.map { String(format: "%02X", $0) }.joined()

        let signatureAlgorithm = DER.sequence([DER.oid("1.2.840.113549.1.1.11"), DER.null]) // sha256WithRSAEncryption
        let name = DER.sequence([DER.set([DER.sequence([DER.oid("2.5.4.3"), DER.utf8(commonName)])])])
        let now = Date()
        let validity = DER.sequence([DER.time(now.addingTimeInterval(-86_400)), DER.time(now.addingTimeInterval(20 * 365 * 86_400))])
        let spki = DER.sequence([
            DER.sequence([DER.oid("1.2.840.113549.1.1.1"), DER.null]), // rsaEncryption
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
            DER.explicit(0, DER.integer(2)), // v3
            DER.integer(serial),
            signatureAlgorithm,
            name,
            validity,
            name,
            spki,
            DER.explicit(3, DER.sequence([basicConstraints, subjectAltName])),
        ])

        guard let signature = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, Data(tbs) as CFData, &error) as Data? else {
            throw IdentityError.keychain(error?.takeRetainedValue().localizedDescription ?? "signing failed")
        }
        let certDER = DER.sequence([tbs, signatureAlgorithm, DER.bitString(Array(signature))])
        guard let certificate = SecCertificateCreateWithData(nil, Data(certDER) as CFData) else {
            throw IdentityError.keychain("certificate encoding rejected")
        }
        let status = SecItemAdd(scoped([
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrLabel as String: label,
        ]) as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw IdentityError.keychain("OSStatus \(status)")
        }
        // Back the identity up to the container (see
        // AndroidTVPersistence): the Keychain alone does not reliably
        // survive a LiveContainer relaunch, and without this exact
        // certificate the TV asks to pair again on every reopen.
        AndroidTVPersistence.saveIdentityBackup(certificate: certificate, privateKey: privateKey)
    }

    /// RSA modulus and exponent of a certificate's public key, used in the pairing secret.
    /// First four hex digits of the certificate's SHA-256, stable for as long as the identity is.
    static func shortID(of certificate: SecCertificate) -> String {
        let digest = SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
        return digest.prefix(2).map { String(format: "%02X", $0) }.joined()
    }

    static func rsaComponents(of certificate: SecCertificate) -> (modulus: [UInt8], exponent: [UInt8])? {
        guard let key = SecCertificateCopyKey(certificate),
              let der = SecKeyCopyExternalRepresentation(key, nil) as Data? else { return nil }
        return DER.rsaPublicKeyComponents(Array(der))
    }
}
