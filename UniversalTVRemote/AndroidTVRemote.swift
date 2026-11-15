// Superseded in v1.0.16: the AndroidTVRemote adapter (which wrapped the
// fork's driver in closures, added a 30-second connect timeout, and
// checked a certificate pin the fork never had) and the v1.0.15 copy of
// the fork's driver are gone. The Android TV section is now the fork's
// driver verbatim — see AndroidTVDriver.swift (driver) and TVDriver.swift
// (protocol/delegate) — with RemoteSession as the delegate. This file is
// kept only so the Xcode project reference stays valid.
