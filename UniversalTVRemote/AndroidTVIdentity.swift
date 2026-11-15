// SUPERSEDED in v1.0.15 — do not add code here.
//
// The Android TV client identity (RSA keypair + self-signed certificate
// in the Keychain) is now ClientIdentity.swift, ported from open-tv-remote
// (MIT, Copyright (c) 2026 Nathan Butler). It reuses the keychain item
// this file used to manage (same label and key tag, same "UniversalTVRemote
// XXXX" certificate subject), so existing identities carry over and no
// re-pairing is forced by the switch.
//
// This file is kept as a comment-only stub because the push path cannot
// delete files; it is still listed in the Xcode project but defines
// nothing.
