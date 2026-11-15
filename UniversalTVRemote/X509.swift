// SUPERSEDED in v1.0.15, except for one function — see below.
//
// The X.509 / DER helpers (self-signed certificate minting, RSA
// modulus/exponent extraction, serial/subject parsing) moved to DER.swift
// + ClientIdentity.swift, ported from open-tv-remote (MIT, Copyright
// (c) 2026 Nathan Butler). The old X509 enum is gone; its tests moved to
// the DER / ClientIdentity tests in UniversalTVRemoteTests.swift.
//
// One function stays: sha256Fingerprint, used by LGRemote.swift for LG
// certificate pinning (it has nothing to do with Android TV — it just
// lived here). Reimplemented with CryptoKit instead of CommonCrypto;
// same output (the SHA-256 digest of the DER bytes), so pins stored by
// earlier builds still match.

import CryptoKit
import Foundation

enum X509 {
    /// SHA-256 fingerprint of a certificate's DER bytes (for LG cert pinning).
    static func sha256Fingerprint(certificateDER: Data) -> Data {
        Data(SHA256.hash(data: certificateDER))
    }
}
