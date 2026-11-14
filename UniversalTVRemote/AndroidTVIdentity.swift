import Foundation
import Security

/// The Android TV client identity: an RSA keypair + self-signed certificate
/// kept in the Keychain. The TV binds this certificate during pairing and
/// trusts it on later connections, so it must survive app restarts.
enum AndroidTVIdentity {
    private static let keyTag = "com.nicolassolley.universaltvremote.androidtv.key"
    private static let certLabel = "UniversalTVRemote AndroidTV"

    /// The certificate's common name. It must equal the PairingRequest
    /// client_name: the reference implementation mints its certificate
    /// with CN == SAN == client_name. (An earlier build used a per-install
    /// UUID CN; identities minted that way are dropped by load(), below.)
    private static func clientCommonName() -> String {
        AndroidTVRemote.clientName
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
        // Drop identities minted under the old scheme (per-install UUID
        // CN, critical CA:TRUE cert) — they can never pair. A nil CN
        // lookup is treated as "unknown, keep it", so a lookup quirk can
        // never force a fresh identity on every launch (which would break
        // re-pairing with an already-paired TV).
        if let cn = X509.subjectCommonName(certificateDER: certDER),
           cn != AndroidTVRemote.clientName {
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
        ]
        let parameters: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: privateAttrs,
        ]
        var publicKey: SecKey?
        var privateKey: SecKey?
        let status = SecKeyGeneratePair(parameters as CFDictionary, &publicKey, &privateKey)
        guard status == errSecSuccess, let publicKey, let privateKey else {
            throw NSError(domain: "AndroidTVIdentity", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not generate keypair"])
        }

        let certDER = try X509.makeSelfSigned(
            commonName: clientCommonName(),
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
