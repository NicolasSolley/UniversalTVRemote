import Foundation
import Security

/// Trust-on-first-use pin store for Android TV server certificates.
///
/// After a TV is paired, its self-signed certificate's DER is stored
/// here (one Keychain generic-password item per host) and enforced on
/// every later remote session: the TLS verify block only accepts the
/// exact pinned certificate. This is what stops the app from blindly
/// trusting any self-signed certificate on every connection — the
/// first-trust acceptance happens once, at pairing, and is pinned from
/// then on. A pin is set when pairing succeeds (secret_ack) and when a
/// first connection succeeds; it is cleared only when the user forgets
/// the TV.
///
/// The pin is a public certificate (not a secret), but it lives in the
/// Keychain alongside the client identity rather than in UserDefaults,
/// so it survives app restarts and is not readable as plaintext prefs.
enum AndroidTVPinStore {
    private static let service = "com.nicolassolley.universaltvremote.androidtv.servercert"

    /// The pinned server-certificate DER for `host`, if one was stored.
    static func pinnedCertificateDER(for host: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    /// Store (or replace) the pinned server-certificate DER for `host`.
    static func set(_ der: Data, for host: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: der,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let addQuery = query.merging(attributes) { _, new in new }
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status == errSecDuplicateItem {
            SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        }
    }

    /// Remove the pin for `host` (forgetting the TV).
    static func clear(for host: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
