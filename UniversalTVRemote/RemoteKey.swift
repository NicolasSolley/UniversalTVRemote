// A brand-agnostic remote button. Each driver maps these onto whatever its TV speaks.
//
// Ported from open-tv-remote (https://github.com/iamnbutler/open-tv-remote),
// MIT License, Copyright (c) 2026 Nathan Butler. Verbatim except the three
// extra cases marked ours: this app's RemoteCommand has distinct play /
// pause / stop buttons, and the old adapter sent Android key codes 126 /
// 127 / 86 for them; the fork only has playPause (85).

import Foundation

/// A brand-agnostic remote button. Each driver maps these onto whatever its TV speaks.
enum RemoteKey: Hashable, Sendable {
    case power
    /// A full power-off, for TVs where the power key only toggles a standby or art mode.
    case powerOff
    case up, down, left, right, select
    case back, home, menu, info, input, search
    case volumeUp, volumeDown, mute
    case channelUp, channelDown
    case playPause, rewind, fastForward
    case backspace, enter, exit
    case digit(Int)
    // Ours: distinct play / pause / stop (RemoteCommand has them too).
    case play, pause, stop

    var accessibilityName: String {
        switch self {
        case .power: "Power"
        case .powerOff: "Turn off"
        case .up: "Up"
        case .down: "Down"
        case .left: "Left"
        case .right: "Right"
        case .select: "OK"
        case .back: "Back"
        case .home: "Home"
        case .menu: "Menu"
        case .info: "Info"
        case .input: "Input"
        case .search: "Search"
        case .volumeUp: "Volume up"
        case .volumeDown: "Volume down"
        case .mute: "Mute"
        case .channelUp: "Channel up"
        case .channelDown: "Channel down"
        case .playPause: "Play or pause"
        case .rewind: "Rewind"
        case .fastForward: "Fast forward"
        case .backspace: "Delete"
        case .enter: "Enter"
        case .exit: "Exit"
        case .digit(let n): "\(n)"
        case .play: "Play"
        case .pause: "Pause"
        case .stop: "Stop"
        }
    }
}
