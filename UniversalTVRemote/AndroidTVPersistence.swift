import Foundation
import Security

/// File-backed pairing state for Android TV.
///
/// Why this exists: the pairing needs two things to survive a relaunch —
/// the client identity (the TV only recognizes the exact certificate it
/// paired) and the paired flag (so the app goes straight to the 6466
/// control channel instead of pairing again). Both lived in stores that
/// LiveContainer's guest sandbox does not reliably persist across
/// relaunches: the identity in the Keychain, the paired flag and the
/// v1.0.16 migration marker in UserDefaults. When either was lost, the
/// next launch re-paired from scratch and the TV asked to allow it again.
///
/// The fix mirrors both into files in the app container (Application
/// Support), which LiveContainer does persist per guest app, and reads
/// either store:
///
/// - Identity: after minting, the certificate + private key are backed up
///   to `identity.json`. If the Keychain has no identity on a later
///   launch, the exact same certificate is re-imported from the backup,
///   so the TV still knows us. The Keychain stays the primary store and
///   the runtime store — the file is only a backup, read when the
///   Keychain comes up empty.
/// - Paired flag / migration marker: written to `state.json` as well as
///   UserDefaults; a read takes either store saying yes.
///
/// Tradeoff, stated plainly: the backup file holds the TV-remote private
/// key outside the Keychain, in the app's own container (sandboxed to
/// this app, written with complete file protection — unreadable while
/// the phone is locked). The Keychain protects it better (hardware
/// encryption, access controls), but a key the TV forgets every launch
/// is useless; the file is what makes the pairing stick in LiveContainer.
/// The key only authenticates this phone to the TV — the worst case if
/// it leaked is someone else driving the TV.
enum AndroidTVPersistence {

    // MARK: - Files

    /// Application Support/AndroidTV — created on first write.
    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AndroidTV", isDirectory: true)
    }

    private static var identityURL: URL { directory.appendingPathComponent("identity.json") }
    private static var stateURL: URL { directory.appendingPathComponent("state.json") }

    /// The client identity, as backed up to the container: the
    /// self-signed certificate and its RSA private key, both DER.
    /// Codable Data encodes as base64.
    struct IdentityBackup: Codable {
        var certificateDER: Data
        var privateKeyDER: Data
    }

    /// Pairing state mirrored from UserDefaults: which hosts are paired,
    /// and whether the v1.0.16 one-time identity migration already ran.
    struct PairingState: Codable {
        var pairedHosts: Set<String> = []
        var forkFreshMigrated: Bool = false
    }

    // MARK: - Identity backup

    /// Backs up the identity to the container. Best-effort: a failed
    /// write must not break pairing — the Keychain is still primary.
    static func saveIdentityBackup(certificate: SecCertificate, privateKey: SecKey) {
        guard let keyDER = SecKeyCopyExternalRepresentation(privateKey, nil) as Data? else { return }
        let certDER = SecCertificateCopyData(certificate) as Data
        let backup = IdentityBackup(certificateDER: certDER, privateKeyDER: keyDER)
        guard let data = try? JSONEncoder().encode(backup) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: identityURL, options: [.atomic, .completeFileProtection])
    }

    static func loadIdentityBackup() -> IdentityBackup? {
        guard let data = try? Data(contentsOf: identityURL) else { return nil }
        return try? JSONDecoder().decode(IdentityBackup.self, from: data)
    }

    /// Throws the backup away — used when the identity itself is
    /// discarded (ClientIdentity.reset), so a stale backup can never
    /// resurrect a discarded key.
    static func deleteIdentityBackup() {
        try? FileManager.default.removeItem(at: identityURL)
    }

    // MARK: - Paired hosts

    /// True when either store says this host is paired. The file is the
    /// one that survives a LiveContainer relaunch; UserDefaults is kept
    /// for the flags older builds already wrote.
    static func isPaired(host: String) -> Bool {
        if UserDefaults.standard.bool(forKey: pairedKey(host)) { return true }
        return loadState().pairedHosts.contains(host)
    }

    /// Records the paired flag in both stores.
    static func setPaired(host: String, paired: Bool) {
        UserDefaults.standard.set(paired, forKey: pairedKey(host))
        var state = loadState()
        if paired { state.pairedHosts.insert(host) } else { state.pairedHosts.remove(host) }
        saveState(state)
    }

    /// Clears the paired flag from both stores ("Forget this TV").
    static func removePaired(host: String) {
        UserDefaults.standard.removeObject(forKey: pairedKey(host))
        var state = loadState()
        state.pairedHosts.remove(host)
        saveState(state)
    }

    /// True when any host is paired in either store — used by the
    /// migration guard, which must never discard an identity a TV knows.
    /// (UserDefaults flags from older builds are included: a key present
    /// with value true counts.)
    static var hasAnyPairedHost: Bool {
        let udPaired = UserDefaults.standard.dictionaryRepresentation().contains { key, value in
            key.hasPrefix("androidtv.paired.") && (value as? Bool == true)
        }
        return udPaired || !loadState().pairedHosts.isEmpty
    }

    // MARK: - Migration marker

    /// True when either store says the v1.0.16 migration already ran.
    static var isForkFreshMigrated: Bool {
        UserDefaults.standard.bool(forKey: "androidtv.identity.forkFresh")
            || loadState().forkFreshMigrated
    }

    /// Records the migration as done in both stores.
    static func setForkFreshMigrated() {
        UserDefaults.standard.set(true, forKey: "androidtv.identity.forkFresh")
        var state = loadState()
        state.forkFreshMigrated = true
        saveState(state)
    }

    // MARK: - Internals

    private static func pairedKey(_ host: String) -> String { "androidtv.paired.\(host)" }

    /// Visible for tests (state file round-trip, paired-flag mirror).
    static func loadState() -> PairingState {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(PairingState.self, from: data) else { return PairingState() }
        return state
    }

    private static func saveState(_ state: PairingState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: stateURL, options: [.atomic, .completeFileProtection])
    }
}
