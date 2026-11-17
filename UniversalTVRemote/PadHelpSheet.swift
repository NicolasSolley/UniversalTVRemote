import SwiftUI

// PadHelpSheet.swift — the pad-controls help sheet, split out of
// ContentView.swift in v1.0.53, with the frosted-glass building blocks
// it shares with SettingsSheet (which stays in ContentView.swift):
// GlassCardBackground, GlassHeaderPill, GlassSection and
// GlassSegmentedControl. Internal, so both sheets share them.

struct PadHelpSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            GlassHeaderPill(title: "Pad controls") { dismiss() }
                .padding(.horizontal, 16)
                .padding(.top, 12)
            ScrollView {
                VStack(spacing: 12) {
                    helpCard(icon: "touchid", tint: .blue, title: "Tap", subtitle: "Select / OK")
                    helpCard(icon: "hand.raised.fill", tint: .yellow, title: "Tap + hold", subtitle: "Hold OK down")
                    helpCard(icon: "repeat", tint: .green, title: "Double-tap + hold", subtitle: "Repeat OK")
                    helpCard(icon: "arrow.up.and.down.and.arrow.left.and.right", tint: .cyan, title: "Swipe", subtitle: "Move that way")
                    helpCard(icon: "forward.fill", tint: .indigo, title: "Swipe + hold", subtitle: "Keep moving")
                    helpCard(icon: "speaker.slash.fill", tint: .red, title: "Double-tap right side", subtitle: "Mute audio")
                }
                .padding(16)
                .padding(.bottom, 24)
            }
        }
        // Same background as the home screen (v1.0.48): the
        // sheet was showing the system black/white while the
        // home screen uses the Chrome gray / soft gray.
        .background(GlassWashBackground())
    }

    /// One gesture card: colored icon tile, name + what it does.
    /// No chevron (v1.0.42): the rows aren't tappable, and the
    /// arrow made them look clickable.
    private func helpCard(icon: String, tint: Color, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 52, height: 52)
                .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(GlassCardBackground())
    }
}

/// Settings (v1.0.46): a customization menu opened from the gear
/// on the devices page — pad color, pad border effect, trail
/// style, and light/dark mode. Everything persists in UserDefaults
/// and applies at once; the pad keeps its own theme gradient in
/// both appearances.
/// Frosted-glass card fill (v1.0.50): ultraThinMaterial in a big
/// rounded rect, hairline stroke, soft shadow. The material
/// adapts to light and dark on its own, so the same card reads
/// as glass on both appearances.
struct GlassCardBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        RoundedRectangle(cornerRadius: 28)
            .fill(.ultraThinMaterial)
            .overlay(
                // Light mode only (v1.0.53): the same gray veil as
                // the glass surfaces, so the card reads gray glass
                // instead of flat white. Dark mode keeps the bare
                // material exactly as before.
                Group {
                    if colorScheme == .light {
                        RoundedRectangle(cornerRadius: 28)
                            .fill(Color.glassVeil)
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 28)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
    }
}

/// Floating glass header pill for the sheets (v1.0.50): title
/// centered, Done on the right, like Nick's screenshot.
struct GlassHeaderPill: View {
    let title: String
    var onDone: () -> Void

    /// Explicit init (v1.0.53): the synthesized memberwise init is
    /// private to this file because of the private @Environment
    /// property below, so PadHelpSheet and SettingsSheet in
    /// ContentView.swift need this to construct the pill.
    init(title: String, onDone: @escaping () -> Void) {
        self.title = title
        self.onDone = onDone
    }

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(
                    // Light mode only (v1.0.53): the gray veil, as
                    // on the cards — the pill read as flat white.
                    Group {
                        if colorScheme == .light {
                            Capsule().fill(Color.glassVeil)
                        }
                    }
                )
                .overlay(
                    Capsule()
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                )
            Text(title)
                .font(.headline)
            HStack {
                Spacer()
                Button("Done", action: onDone)
            }
            .padding(.horizontal, 20)
        }
        .frame(height: 52)
    }
}

/// A glass section (v1.0.50): title on its own — no icon next to
/// it, Nick's call — then a frosted card holding the controls.
struct GlassSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.bold())
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .padding(16)
            .background(GlassCardBackground())
        }
    }
}

/// A segmented control that looks like the one in Nick's
/// screenshot (v1.0.50): dark track, the selected segment a solid
/// blue pill. The stock .segmented picker reads as a plain form
/// control next to the glass cards.
struct GlassSegmentedControl: View {
    let options: [(value: String, name: String)]
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                Button {
                    withAnimation(.snappy) { selection = option.value }
                } label: {
                    Text(option.name)
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(selection == option.value ? Color.blue : Color.clear)
                        )
                        .foregroundStyle(selection == option.value ? .white : .primary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.primary.opacity(0.08))
        )
    }
}

/// Settings, glassmorphic (v1.0.50): Nick's screenshot — frosted
/// glass cards on the page background, floating pill header,
/// title-only section headers. Also adds the pad cover picker.
