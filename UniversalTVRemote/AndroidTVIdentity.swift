import Foundation
import Security

/// The Android TV client identity: an RSA keypair + self-signed certificate
/// kept in the Keychain. The TV binds this certificate during pairing and
/// trusts it on later connections, so it must survive app restarts.
enum AndroidTVIdentity {
    private static let keyTag = "com.nicolassolley.universaltvremote.androidtv.key"
    private static let certLabel = "UniversalTVRemote AndroidTV"

    /// The certificate's common name: per-install unique, mirroring the
    /// working reference app ("FreeRemote XXXX"). Android TVs keep one
    /// pairing per certificate subject, so a shared name lets each new
    /// pairing replace the last. Minted fresh at create() time; load()
    /// reads it back off the stored certificate.
    private static func newClientCommonName() -> String {
        var suffix = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, suffix.count, &suffix)
        return "UniversalTVRemote " + suffix.map { String(format: "%02X", $0) }.joined()
    }

    struct Loaded {
        let identity: SecIdentity
        /// DER bytes of our certificate (needed for the pairing secret hash).
        let certificateDER: Data
    }

    /// Load the stored identity, creating a fresh keypair + certificate on
    /// first use.
    static func loadOrCreate() throws -> Loaded {
        if let loaded = try load() { return loaded }
        return try create()
    }

    private static func load() throws -> Loaded? {
        guard let identity = loadIdentity(),
              let certificate = loadCertificate() else { return nil }
        let certDER = SecCertificateCopyData(certificate) as Data
        // Only identities minted under the per-install scheme pair: the
        // CN must start with "UniversalTVRemote " (a fixed CN, a UUID
        // CN, or any other shape is an old identity that never paired
        // with a TV, so dropping it breaks no working pairing). A nil
        // CN lookup is treated as "unknown, keep it", so a lookup quirk
        // can never force a fresh identity on every launch (which would
        // break re-pairing with an already-paired TV).
        if let cn = X509.subjectCommonName(certificateDER: certDER),
           !cn.hasPrefix("UniversalTVRemote ") {
            return nil
        }
        return Loaded(identity: identity, certificateDER: certDER)
    }

    private static func create() throws -> Loaded {
        deleteAll() // clean slate if a half-created identity lingers

        let tagData = Data(keyTag.utf8)
        let privateAttrs: [String: Any] = [
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: tagData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrLabel as String: certLabel,
        ]
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: privateAttrs,
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
              let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw NSError(domain: "AndroidTVIdentity", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Could not generate keypair (\(error?.takeRetainedValue().localizedDescription ?? "unknown error"))"])
        }

        let certDER = try X509.makeSelfSigned(
            commonName: newClientCommonName(),
            keyPair: (publicKey: publicKey, privateKey: privateKey))
        guard let certificate = SecCertificateCreateWithData(nil, certDER as CFData) else {
            throw NSError(domain: "AndroidTVIdentity", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create certificate"])
        }
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrLabel as String: certLabel,
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw NSError(domain: "AndroidTVIdentity", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Could not store certificate"])
        }
        guard let identity = loadIdentity() else {
            throw NSError(domain: "AndroidTVIdentity", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Could not load identity"])
        }
        return Loaded(identity: identity, certificateDER: certDER)
    }

    /// Fetch the identity from the Keychain. On iOS there is no API to
    /// build a SecIdentity from a certificate + key directly
    /// (SecIdentityCreateWithCertificate is macOS-only); instead the
    /// Keychain vends the identity once the certificate and its private
    /// key are both stored, matched by the certificate's label.
    private static func loadIdentity() -> SecIdentity? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: certLabel,
            kSecReturnRef as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return (item as! SecIdentity)
    }

    private static func loadCertificate() -> SecCertificate? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: certLabel,
            kSecReturnRef as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return (item as! SecCertificate)
    }

    /// Delete the stored identity (used when pairing is reset).
    static func deleteAll() {
        let keyQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Data(keyTag.utf8),
        ]
        SecItemDelete(keyQuery as CFDictionary)
        let certQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: certLabel,
        ]
        SecItemDelete(certQuery as CFDictionary)
    }
}
