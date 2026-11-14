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

1. **SSDP (primary).** The app sends M-SEARCH requests to the multicast
   address 239.255.255.250:1900, several rounds, and reads each reply's
   device description to identify the brand and model. This works in
   LiveContainer.
2. **Bonjour (secondary).** NetService browsing for Roku, Samsung, LG,
   Android TV, AirPlay, and Chromecast service types. In LiveContainer
   the guest app's Bonjour service list is ignored by iOS (the host app
   gates it), so Bonjour discovery silently finds nothing there — SSDP
   is what actually discovers TVs under LiveContainer. On a normally
   installed app both paths work.

Only real responses are shown. Nothing is invented or guessed.

## Supported TVs

| TV | Control | Notes |
| --- | --- | --- |
| Roku (TVs and sticks) | Yes | Power, volume, mute, channels, D-pad, home, back, info, search, playback, text input, app launching |
| Samsung Smart TV (Tizen, 2016+) | Yes | Power (Wake-on-LAN fallback if the MAC is known), volume, mute, channels, D-pad, digits, home, back, info, menu, playback, text input in native Tizen fields. First connect shows an Allow prompt on the TV; the token is stored and reused |
| LG webOS | Yes | Power off only, volume, mute, channels, D-pad, digits, home, back, info, menu, playback, text input. First connect shows a pairing prompt on the TV; the client-key is stored and reused. The TV's certificate is pinned after first pairing — if it changes, forget the TV and pair again |
| Android TV / Google TV | Yes | Power, volume, mute, channels, D-pad, digits, home, back, info, menu, playback. First connect shows a 6-character code on the TV that you type into the app (Android TV Remote protocol v2, mutual TLS). **No text input** — the keyboard is hidden for Android TV |
| AirPlay-compatible devices | Discovery only | There is no public remote-control API for arbitrary AirPlay devices, so these are listed but cannot be controlled |

A button that cannot work on a platform is absent, never shown dead.
Pairing credentials (Samsung token, LG client-key and certificate pin,
Android TV identity) stay on the device — Samsung/LG in UserDefaults,
the Android TV keypair in the Keychain.

## The remote

- **Touchpad** (drag to move, tap to select) or **D-pad** — switch with
  the segmented control, like the EVOLLY app.
- Volume and channel rockers, mute, back, home, menu, playback controls.
- Number pad (Samsung, LG, Android TV).
- Keyboard for text input where the platform supports it (Roku, Samsung,
  LG). Samsung text works only in native Tizen fields, not inside
  streaming apps' own search screens.
- Roku: installed apps are listed and can be launched directly.
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
- LiveContainer gates Bonjour, so discovery there is SSDP-only.
- LG power button turns the TV off only; turn it back on with the TV's
  own remote.
- Android TV has no text input in this build.
- Samsung text input works only in native Tizen fields.
- Samsung power-on over the network is unreliable when the TV is fully
  off; Wake-on-LAN is sent when the TV's MAC is known, and it may still
  not wake the TV.
