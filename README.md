# UniversalTVRemote

A native SwiftUI iPhone app that finds the TVs on your Wi-Fi and controls
them — like the App Store app "TV Remote - Universal Control" by
EVOLLY.APP, but built as a single open project with no accounts, no
paywall, and no tracking.

It is installed through [LiveContainer](https://github.com/khanhduytran0/LiveContainer)
as an unsigned IPA (see *Install* below). No Apple Developer account,
provisioning profile, or signing step is needed.

> **Testing status:** this build is compile-verified only (GitHub Actions).
> No TV control in it has been tested against a live TV yet. If a button
> does not work on your TV, please open an issue with the brand and model.

## How it finds TVs

Scan-only — there is no way to type in an IP address, by design. If a TV
doesn't answer the scan, it simply doesn't appear.

1. **Subnet sweep (primary).** The app reads the phone's Wi-Fi address
   and probes every host on that subnet directly (unicast HTTP/TCP):
   Roku on :8060, Samsung on :8001, DIAL on :8008, Android TV Remote
   on :6466/:6467, LG webOS on :3001. This is the path that works in
   LiveContainer — SSDP multicast and Bonjour are both dead there (see
   below), so the sweep is what actually finds TVs under LiveContainer.
   A plain Chromecast dongle is listed as discovery-only, never as a
   controllable Android TV: it serves DIAL but has no remote service.
2. **SSDP (secondary).** The app sends M-SEARCH requests to the multicast
   address 239.255.255.250:1900, several rounds, and reads each reply's
   device description to identify the brand and model. This works on a
   normally installed app, but **not in LiveContainer**: multicast needs
   Apple's `com.apple.developer.networking.multicast` entitlement, which
   the sideloaded LiveContainer host does not have, so the packets never
   go out (v1.0.2 found zero TVs in the field for exactly this reason).
3. **Bonjour (secondary).** NetService browsing for Roku, Samsung, LG,
   Android TV, AirPlay, and Chromecast service types. In LiveContainer
   the guest app's Bonjour service list is ignored by iOS (the host app
   gates it), so Bonjour discovery silently finds nothing there. On a
   normally installed app all three paths work.

Only real responses are shown. Nothing is invented or guessed.

## Supported TVs

| TV | Control | Notes |
| --- | --- | --- |
| Roku (TVs and sticks) | Yes | Power, volume, mute, channels, D-pad, home, back, info, search, playback, text input, app launching |
| Samsung Smart TV (Tizen, 2016+) | Yes | Power (Wake-on-LAN fallback if the MAC is known), volume, mute, channels, D-pad, digits, home, back, info, menu, playback, text input in native Tizen fields. First connect shows an Allow prompt on the TV; the token is stored and reused |
| LG webOS | Yes | Power off only, volume, mute, channels, D-pad, digits, home, back, info, menu, playback, text input. First connect shows a pairing prompt on the TV; the client-key is stored and reused. The TV's certificate is pinned after first pairing — if it changes, forget the TV and pair again |
| Android TV / Google TV | Yes | Power, volume, mute, channels, D-pad, digits, home, back, info, menu, playback. First connect shows a 6-character code on the TV that you type into the app (Android TV Remote protocol v2, mutual TLS). Connection, pairing and control are the fork's code verbatim — [open-tv-remote](https://github.com/iamnbutler/open-tv-remote) (MIT License, Copyright (c) 2026 Nathan Butler) driver, protocol and delegate, with only this app's UI on top (v1.0.16; v1.0.15 had ported the same code but wrapped it in an adapter with its own timeout and certificate pinning, and pairing still failed). The pairing is remembered across relaunches: the client identity is backed up to the app container and the paired flag is mirrored there too, because LiveContainer's guest Keychain/UserDefaults do not reliably persist (v1.0.18). Text input is implemented in the driver but the keyboard stays hidden until it is verified on a real TV |
| AirPlay-compatible devices | Discovery only | There is no public remote-control API for arbitrary AirPlay devices, so these are listed but cannot be controlled |

A button that cannot work on a platform is absent, never shown dead.
Pairing credentials (Samsung token, LG client-key and certificate pin,
Android TV identity) stay on the device — Samsung/LG in UserDefaults,
the Android TV keypair in the Keychain, backed up to the app container
along with the paired flag so the pairing survives a relaunch
(LiveContainer's guest Keychain/UserDefaults do not reliably persist).

## The remote

- **Swipe pad** (drag to move, tap to select) — the one navigation
  control. No D-pad, no toggle.
- Big volume rocker (hold to repeat) and mute, back, home, menu.
  No playback row — left/right swipes already seek.
- Number pad (Samsung, LG, Android TV).
- Keyboard for text input where the platform supports it (Roku, Samsung,
  LG). Samsung text works only in native Tizen fields, not inside
  streaming apps' own search screens.
- Every failure is plain language: unreachable TV, pairing rejected,
  pairing timed out, certificate changed.

## Install (LiveContainer)

1. On your iPhone, open the
   [latest release](https://github.com/NicolasSolley/UniversalTVRemote/releases)
   and download `UniversalTVRemote-unsigned.ipa`.
2. Open LiveContainer, tap **+**, and import the IPA.
3. Launch the app, tap **Scan**, and wait a few seconds. Your TVs appear
   as they answer the scan — make sure the TV is on and on the same
   Wi-Fi network as the phone.
4. Tap a TV. If it asks you to accept a prompt (Samsung, LG) or shows a
   code (Android TV), follow the on-screen instructions.

## Build from source

Requires Xcode 16.4+ on macOS. The project has no package dependencies
(Foundation, Network, and CryptoKit only) and one app target, no
extensions, no entitlements file, deployment target iOS 15.0.

```sh
xcodebuild build \
  -project UniversalTVRemote.xcodeproj \
  -scheme UniversalTVRemote \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO
```

GitHub Actions does exactly this on every push to `main`. Pushing a
`v*` tag also attaches `UniversalTVRemote-unsigned.ipa` to a GitHub
Release.

## Limitations

- Compile-verified only — no live-TV testing yet (see above).
- LiveContainer gates Bonjour and blocks SSDP multicast, so discovery
  there is sweep-only (unicast probing of the Wi-Fi subnet).
- LG power button turns the TV off only; turn it back on with the TV's
  own remote.
- Android TV text input is implemented in the driver but the keyboard is hidden until it is verified on a real TV.
- Samsung text input works only in native Tizen fields.
- Samsung power-on over the network is unreliable when the TV is fully
  off; Wake-on-LAN is sent when the TV's MAC is known, and it may still
  not wake the TV.
