// Superseded in v1.0.16: certificate pinning is gone with the fork port.
// The fork trusts any server certificate and binds trust to the pairing
// secret; this app did the same until v1.0.7 added pinning, and the pin
// check was one more divergence from the working reference in the pairing
// path. Nothing reads or writes pins anymore. This file is kept only so
// the Xcode project reference stays valid.
