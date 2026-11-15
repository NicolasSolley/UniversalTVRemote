// SUPERSEDED in v1.0.15 — do not add code here.
//
// The raw-TLS handshake recorder (diagnostic only: hand-built ClientHello
// over plain TCP, reporting what the TV sends back) is removed with the
// rest of the v1.0.7–v1.0.14 diagnostic probes. The fork's implementation
// never probes — it goes straight to the connection — and the probes were
// three extra failed handshakes before the real attempt. A failure now
// reports the driver's plain-language reason as the status text instead
// of probe notes. Its tests are removed with it.
//
// This file is kept as a comment-only stub because the push path cannot
// delete files; it is still listed in the Xcode project but defines
// nothing.
