// Driver protocol for the fork's TV drivers.
//
// Ported from open-tv-remote (https://github.com/iamnbutler/open-tv-remote),
// MIT License, Copyright (c) 2026 Nathan Butler. The protocol, the state
// enums, TVApp and TVBrand are the fork's code verbatim. ONE mechanical
// rename: the fork's `TVDevice` struct is `AndroidTVDevice` here, because
// this app already has a discovery model called `TVDevice`
// (TVDevice.swift); the fields are unchanged. `RemoteInputRequest` is the
// fork's class from Sources/Core/JoystickInput.swift, included here
// because the TVDriver protocol references it.
//
// v1.0.16: the Android TV section now uses the fork's driver through this
// protocol, instead of the v1.0.15 adapter (which wrapped the same driver
// in closures, added a 30-second connect timeout, and checked a
// certificate pin the fork never had). The driver reports state through
// the delegate; RemoteSession is the delegate.

import Foundation

enum PairingPrompt: Equatable, Sendable {
    /// The TV is showing a code the user must type in.
    case enterCode(length: Int, error: String?)
    /// The TV is showing an Allow / Deny dialog.
    case acceptOnTV
    /// We've sent the code and are waiting for the TV to confirm it.
    case verifying
}

enum ConnectionState: Equatable, Sendable {
    case idle
    case connecting
    /// We have no credentials yet. Pairing only starts when the user asks,
    /// so nothing pops up on a TV someone else is watching.
    case unpaired
    case pairing(PairingPrompt)
    case connected
    case failed(String)

    var isConnected: Bool { self == .connected }
}

/// Something the TV can open: either an installed app reported by the TV, or a catalog entry.
struct TVApp: Identifiable, Hashable, Sendable {
    var id: String { launchID }
    let name: String
    /// Driver-specific: Roku channel ID, Samsung/LG app ID, or Android TV app link.
    let launchID: String
    var iconURL: URL?
    /// Samsung needs to know whether an app launches as a deep link or native app.
    var extra: String?
}

@MainActor
protocol TVDriverDelegate: AnyObject {
    func driver(_ driver: TVDriver, didChangeState state: ConnectionState)
    /// Called when the driver learns something worth persisting (tokens, names, pairing).
    func driver(_ driver: TVDriver, didUpdateDevice device: AndroidTVDevice)
    /// Called when the TV announces a text field gaining or losing
    /// focus (v1.0.34) — Android TV's field-22 show request /
    /// field-20 counter clear. The session surfaces it so the
    /// keyboard can pop up on its own.
    func driver(_ driver: TVDriver, didChangeTextFieldFocus focused: Bool)
}

extension TVDriverDelegate {
    /// Default: ignore focus changes. RemoteSession overrides it.
    func driver(_ driver: TVDriver, didChangeTextFieldFocus focused: Bool) {}
}

@MainActor
protocol TVDriver: AnyObject {
    var device: AndroidTVDevice { get }
    var delegate: TVDriverDelegate? { get set }
    var state: ConnectionState { get }

    /// Connect with stored credentials. Must never cause anything to appear on the TV.
    func connect()
    /// Start pairing. This *will* show a code or prompt on the TV.
    func pair()
    func submitPairingCode(_ code: String)
    func disconnect()

    func supports(_ key: RemoteKey) -> Bool
    func send(_ key: RemoteKey)
    /// Await transport completion; discard invalidated input instead of replaying it.
    func sendInteractive(_ key: RemoteKey, request: RemoteInputRequest) async
    func sendText(_ text: String)
    /// Whether text sent a piece at a time is appended on the TV, so the keyboard pad can type live.
    var typesLive: Bool { get }
    func launch(_ app: TVApp)
    /// Apps installed on the TV, or nil if the protocol can't list them.
    func installedApps() async -> [TVApp]?
}

extension TVDriver {
    var typesLive: Bool { true }
    func sendInteractive(_ key: RemoteKey, request: RemoteInputRequest) async {
        guard !request.isCancelled, !Task.isCancelled else { return }
        send(key)
    }
}

/// Cancellation belongs to the input, not the connection. A driver waiting for
/// its turn can discard stale input without cancelling a shared WebSocket.
/// (The fork's class from Sources/Core/JoystickInput.swift.)
@MainActor
final class RemoteInputRequest {
    enum Feedback { case firm, soft, none }
    let isRepeat: Bool
    let feedback: Feedback
    private(set) var isCancelled = false

    init(isRepeat: Bool = false, feedback: Feedback = .firm) {
        self.isRepeat = isRepeat
        self.feedback = feedback
    }
    func cancel() { isCancelled = true }
}

enum TVBrand: String, Codable, CaseIterable, Identifiable, Sendable {
    case androidTV
    case roku
    case samsung
    case lg

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .androidTV: "Google TV / Android TV"
        case .roku: "Roku"
        case .samsung: "Samsung"
        case .lg: "LG webOS"
        }
    }

    var shortName: String {
        switch self {
        case .androidTV: "Google TV"
        case .roku: "Roku"
        case .samsung: "Samsung"
        case .lg: "LG"
        }
    }

    /// Shown before pairing so people know what's about to appear on their TV.
    var pairingExplanation: String {
        switch self {
        case .androidTV: "Your TV will show a 6-character code. Type it here to finish pairing."
        case .roku: "Roku TVs don't need pairing."
        case .samsung: "Your TV will ask whether to allow Open Remote. Choose Allow with your regular remote."
        case .lg: "Your TV will ask whether to accept the connection. Choose Accept with your regular remote."
        }
    }

    var examples: String {
        switch self {
        case .androidTV: "Sony, TCL, Hisense, Philips, Sharp, Chromecast with Google TV, Nvidia Shield"
        case .roku: "Roku TVs, Roku sticks and boxes"
        case .samsung: "Samsung Tizen smart TVs (2016+)"
        case .lg: "LG smart TVs running webOS"
        }
    }
}

/// The fork's TVDevice struct, renamed: this app already has a discovery
/// model called `TVDevice` (TVDevice.swift), so the driver's device type
/// is `AndroidTVDevice`. Fields unchanged from the fork.
struct AndroidTVDevice: Codable, Identifiable, Hashable, Sendable {
    var id: String { "\(brand.rawValue)@\(host)" }
    var name: String
    var brand: TVBrand
    var host: String
    var model: String?
    /// Samsung access token or LG client key, issued by the TV when the user allows us.
    var token: String?
    /// Android TV: the TV has accepted our client certificate.
    var isPaired: Bool = false
    /// Samsung: Wi-Fi/Ethernet MAC, so we can wake the TV with a Wake-on-LAN packet.
    var macAddress: String?

    /// What another device may know about this TV: pairing is between one device and the TV.
    var withoutCredentials: AndroidTVDevice {
        var shared = self
        shared.token = nil
        shared.isPaired = false
        return shared
    }

    var hasCredentials: Bool {
        switch brand {
        case .roku: true
        case .androidTV: isPaired
        case .samsung, .lg: token != nil
        }
    }
}
