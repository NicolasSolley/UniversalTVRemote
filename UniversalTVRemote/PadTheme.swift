// PadTheme.swift — theme + surface helpers, split out of
// ContentView.swift in v1.0.53 (the file had grown past 2,400 lines).
// PadTheme / PadBorder / TrailStyle / AppAppearance / AppBackground,
// and remoteAccent. Internal, so ContentView, the pad, and the
// sheets all share them.

import SwiftUI

// MARK: - Settings (v1.0.46)

/// Pad color themes (v1.0.46, palette curated in v1.0.51): the pad
/// gradient and the app accent follow the chosen theme. Stored in
/// UserDefaults; views read it through PadTheme.current, or through
/// @AppStorage("padTheme") when they need to re-render live on a
/// change. The v1.0.51 set is modern, popular colors — not a rainbow.
/// Midnight is the default (the old blue, kept so existing installs
/// look the same); the rest are muted, premium tones. An old stored
/// value (blue/purple/green/orange/pink) falls back to Midnight.
/// Teal replaced clay in v1.0.54 (Nick: clay looked brown/orange).
enum PadTheme: String, CaseIterable {
    case midnight, sage, teal, graphite, lavender, blush

    var name: String {
        switch self {
        case .midnight: return "Midnight"
        case .sage: return "Sage"
        case .teal: return "Teal"
        case .graphite: return "Graphite"
        case .lavender: return "Lavender"
        case .blush: return "Blush"
        }
    }
    /// Gradient top / bottom for the pad.
    var top: Color {
        switch self {
        case .midnight: return Color(red: 0.10, green: 0.16, blue: 0.35)
        case .sage: return Color(red: 0.16, green: 0.24, blue: 0.20)
        case .teal: return Color(red: 0.05, green: 0.32, blue: 0.35)
        case .graphite: return Color(red: 0.20, green: 0.21, blue: 0.24)
        case .lavender: return Color(red: 0.24, green: 0.20, blue: 0.38)
        case .blush: return Color(red: 0.34, green: 0.16, blue: 0.22)
        }
    }
    var bottom: Color {
        switch self {
        case .midnight: return Color(red: 0.05, green: 0.07, blue: 0.18)
        case .sage: return Color(red: 0.08, green: 0.13, blue: 0.10)
        case .teal: return Color(red: 0.02, green: 0.18, blue: 0.20)
        case .graphite: return Color(red: 0.10, green: 0.10, blue: 0.12)
        case .lavender: return Color(red: 0.13, green: 0.10, blue: 0.22)
        case .blush: return Color(red: 0.19, green: 0.08, blue: 0.12)
        }
    }
    /// Light-mode pad gradient (v1.0.51): a pale tint of the theme,
    /// so the pad reads as a light surface instead of a dark slab
    /// floating on a white page.
    var lightTop: Color {
        switch self {
        case .midnight: return Color(red: 0.85, green: 0.90, blue: 0.99)
        case .sage: return Color(red: 0.87, green: 0.92, blue: 0.88)
        case .teal: return Color(red: 0.85, green: 0.95, blue: 0.94)
        case .graphite: return Color(red: 0.90, green: 0.91, blue: 0.93)
        case .lavender: return Color(red: 0.91, green: 0.88, blue: 0.99)
        case .blush: return Color(red: 0.99, green: 0.88, blue: 0.92)
        }
    }
    var lightBottom: Color {
        switch self {
        case .midnight: return Color(red: 0.74, green: 0.82, blue: 0.98)
        case .sage: return Color(red: 0.78, green: 0.88, blue: 0.80)
        case .teal: return Color(red: 0.72, green: 0.90, blue: 0.89)
        case .graphite: return Color(red: 0.82, green: 0.83, blue: 0.87)
        case .lavender: return Color(red: 0.84, green: 0.78, blue: 0.98)
        case .blush: return Color(red: 0.98, green: 0.78, blue: 0.85)
        }
    }
    /// Light-mode page background (v1.0.51, deepened in v1.0.52):
    /// a tint of the theme, so the page stops being flat white and
    /// ties to the pad. The first version was the palest tint and
    /// it washed everything out — gray text and pale cards
    /// disappeared into the bright page — so the tint is deeper
    /// now, enough for the white surfaces to stand against it.
    var pageBackground: Color {
        switch self {
        case .midnight: return Color(red: 0.89, green: 0.92, blue: 0.99)
        case .sage: return Color(red: 0.90, green: 0.93, blue: 0.91)
        case .teal: return Color(red: 0.88, green: 0.94, blue: 0.93)
        case .graphite: return Color(red: 0.91, green: 0.92, blue: 0.94)
        case .lavender: return Color(red: 0.92, green: 0.90, blue: 0.98)
        case .blush: return Color(red: 0.97, green: 0.91, blue: 0.93)
        }
    }
    /// The accent: pad border, TV icon, keyboard ring.
    var accent: Color {
        switch self {
        case .midnight: return Color(red: 0.15, green: 0.45, blue: 1.0)
        case .sage: return Color(red: 0.35, green: 0.65, blue: 0.45)
        case .teal: return Color(red: 0.05, green: 0.60, blue: 0.62)
        case .graphite: return Color(red: 0.60, green: 0.65, blue: 0.80)
        case .lavender: return Color(red: 0.65, green: 0.55, blue: 1.0)
        case .blush: return Color(red: 0.95, green: 0.45, blue: 0.60)
        }
    }
    static var current: PadTheme {
        PadTheme(rawValue: UserDefaults.standard.string(forKey: "padTheme") ?? "") ?? .midnight
    }

    /// One-time migration (v1.0.54): clay was removed and replaced
    /// by teal — move anyone still on clay to teal, and write it
    /// back so Settings shows Teal selected and the pad renders
    /// teal. Called once at launch; a no-op for everyone else, and
    /// idempotent if it ever runs twice.
    static func migrateIfNeeded() {
        if UserDefaults.standard.string(forKey: "padTheme") == "clay" {
            UserDefaults.standard.set("teal", forKey: "padTheme")
        }
    }
}

/// Pad border effect (v1.0.46): off is the plain static border;
/// glow puts a soft halo around the pad; flow runs a light around
/// the border, LED-keyboard style.
enum PadBorder: String, CaseIterable {
    case off, glow, flow
    var name: String {
        switch self {
        case .off: return "Off"
        case .glow: return "Glow"
        case .flow: return "Flow"
        }
    }
    static var current: PadBorder {
        PadBorder(rawValue: UserDefaults.standard.string(forKey: "padBorder") ?? "") ?? .off
    }
}

/// Finger trail style (v1.0.46; Glow renamed to Line in v1.0.58 —
/// Nick: "just call this one Line not glow for trails"): how the
/// swipe trail looks. Line is the thin smooth continuous line;
/// Dots is a row of circles; Off draws nothing.
enum TrailStyle: String, CaseIterable {
    case off, line, dots
    var name: String {
        switch self {
        case .off: return "Off"
        case .line: return "Line"
        case .dots: return "Dots"
        }
    }
    static var current: TrailStyle {
        let raw = UserDefaults.standard.string(forKey: "trailStyle") ?? ""
        if raw == "glow" { return .line } // renamed in v1.0.58
        return TrailStyle(rawValue: raw) ?? .line
    }

    /// One-time migration (v1.0.58): Glow was renamed to Line —
    /// move anyone still on "glow" to "line", and write it back
    /// so Settings shows Line selected and the pad renders Line.
    /// Called once at launch; a no-op for everyone else, and
    /// idempotent if it ever runs twice.
    static func migrateIfNeeded() {
        if UserDefaults.standard.string(forKey: "trailStyle") == "glow" {
            UserDefaults.standard.set("line", forKey: "trailStyle")
        }
    }
}

/// App appearance (v1.0.46, default System in v1.0.51 — Nick: the
/// app follows the phone unless the user picks Dark or Light, and
/// then it remembers that choice): system follows the phone, dark
/// and light pin it. The pad keeps its own theme gradient in both
/// modes.
enum AppAppearance: String, CaseIterable {
    case system, dark, light
    var name: String {
        switch self {
        case .system: return "System"
        case .dark: return "Dark"
        case .light: return "Light"
        }
    }
    /// The phone's real system appearance, straight off the
    /// screen's trait collection (v1.0.56): UIScreen's traits
    /// are NOT affected by any preferredColorScheme override
    /// SwiftUI has applied, so this reads the device's actual
    /// appearance even while the app is forcing one.
    static var deviceScheme: ColorScheme {
        UIScreen.main.traitCollection.userInterfaceStyle == .dark ? .dark : .light
    }
    /// The scheme to force. System resolves to the device's
    /// live scheme explicitly (v1.0.56) — the old mapping
    /// returned nil for System, and preferredColorScheme(nil)
    /// does NOT revert a previously forced scheme: once Light
    /// (or Dark) had been forced, picking System left the app
    /// stuck on it instead of following the phone. Dark and
    /// Light always worked (non-nil to non-nil propagates);
    /// only the System flip was broken.
    var scheme: ColorScheme {
        switch self {
        case .system: return Self.deviceScheme
        case .dark: return .dark
        case .light: return .light
        }
    }
    static var current: AppAppearance {
        AppAppearance(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .system
    }
}

/// Page background (v1.0.48, retuned in v1.0.51): not the system
/// extremes. Dark is Chrome's dark gray (#202124), not solid black;
/// light is the palest tint of the pad theme — not flat white, so
/// the page ties to the pad. Resolved from the environment color
/// scheme, so System follows the phone.
enum AppBackground {
    static func color(for scheme: ColorScheme) -> Color {
        switch scheme {
        case .dark: return Color(red: 0.125, green: 0.129, blue: 0.141)
        case .light: return PadTheme.current.pageBackground
        @unknown default: return Color(.systemBackground)
        }
    }
}

/// Accent for the redesigned remote (v1.0.12): the Devices pill
/// icon, the keyboard ring, the power-adjacent highlights. One
/// accent, used sparingly — the rest stays dark and neutral. Since
/// v1.0.46 it follows the pad color theme in Settings.
var remoteAccent: Color { PadTheme.current.accent }
