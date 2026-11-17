import SwiftUI

// SwipePad.swift — the swipe pad, split out of ContentView.swift in
// v1.0.53: the pure gesture decision logic (SwipePadGesture), the
// pure pad geometry (PadGeometry), the finger trail, and the pad
// view itself. Internal, so RemoteView can use the pad and tests can
// drive the pure types directly.

// MARK: - Swipe pad

/// Pure gesture decision logic for the swipe pad (v1.0.25) — no
/// timers, no SwiftUI, so unit tests can drive it directly. The view
/// owns the two timers (hold onset, double-tap window) and feeds this
/// type touch events; it returns the commands to send.
///
/// Modes:
/// - Quick tap (lift before the 0.3s onset): exactly one enter, on
///   lift. A second tap within the window is a second enter; held
///   past onset it spams enters instead (double-tap-hold).
/// - Single tap held past onset: the OK key goes DOWN at onset and
///   UP on lift — no enter on lift. A hold-lift is not a tap, so it
///   never opens a double-tap window.
/// - Swipe (≥ slop): a held key is released first, then the first
///   directional press fires at once, with the direction locked in
///   for the touch. Hold past the 0.3s onset and that direction
///   repeats every 0.12s until lift; a quick swipe-and-lift is still
///   exactly one press. A key is never left down.
struct SwipePadGesture {
    enum Output: Equatable {
        case enter(haptic: Bool)
        case enterDown
        case enterUp
        case mute(haptic: Bool)
        case up(haptic: Bool), down(haptic: Bool), left(haptic: Bool), right(haptic: Bool)
    }

    private enum State {
        case idle
        case awaitingSecondTap
        case singleDown
        case singleHeld
        case doubleDown
        case doubleSpam
        case swiping
        /// First tap down inside the mute zone (v1.0.34): no hold
        /// timer, no enter yet — the window decides.
        case muteZoneDown
        /// First tap in the mute zone lifted, waiting to see if a
        /// second zone tap mutes or the window expires (one enter).
        case awaitingSecondTapZone
        /// Second tap down inside the mute zone: lift mutes.
        case muteZoneDoubleDown
    }

    private var state: State = .idle

    /// The direction locked in when the current swipe was
    /// recognized; nil when not swiping.
    private var swipeDirection: Output?
    /// True once a repeat of the held swipe has fired, so only the
    /// first repeat buzzes and later ones stay silent.
    private var swipeRepeatFired = false

    /// True while a key-down has been sent and not yet released.
    var isKeyHeldDown: Bool { state == .singleHeld }
    /// True while double-tap-hold spam is active.
    var isSpamming: Bool { state == .doubleSpam }
    /// True after a quick tap lifted, while a second tap still
    /// counts as a double-tap.
    var isAwaitingSecondTap: Bool { state == .awaitingSecondTap }
    /// True after a quick tap in the mute zone lifted, while a
    /// second tap in the zone still counts as a mute.
    var isAwaitingSecondTapZone: Bool { state == .awaitingSecondTapZone }
    /// True while a swipe is being held down (repeats active).
    var isSwiping: Bool { state == .swiping }

    /// Finger down. Returns true when the view should start the hold
    /// onset timer (a fresh single or double tap); false when this
    /// touch is already a swipe that wandered back inside the slop.
    mutating func touchDown() -> Bool {
        touchDown(inMuteZone: false).startHold
    }

    /// Finger down, with the mute-zone flag (v1.0.34). Returns the
    /// outputs to emit now and whether the view should start the
    /// hold onset timer. A tap inside the mute zone never starts
    /// the hold timer — a hold in the zone is not a key hold — and
    /// its enter is held back until the double-tap window decides:
    /// a second zone tap mutes, the window expiring leaves one
    /// enter, and a second tap outside the zone turns the held-back
    /// enter into half of a normal double-tap. Muting needs both
    /// taps in the zone: a zone tap after a middle tap is just the
    /// second tap of a normal double-tap.
    mutating func touchDown(inMuteZone: Bool) -> (outputs: [Output], startHold: Bool) {
        if inMuteZone {
            switch state {
            case .idle:
                state = .muteZoneDown
                return ([], false)
            case .awaitingSecondTapZone:
                state = .muteZoneDoubleDown
                return ([], false)
            case .awaitingSecondTap:
                state = .doubleDown
                return ([], true)
            default:
                return ([], false)
            }
        }
        switch state {
        case .idle:
            state = .singleDown
            return ([], true)
        case .awaitingSecondTap:
            state = .doubleDown
            return ([], true)
        case .awaitingSecondTapZone:
            state = .singleDown
            return ([.enter(haptic: true)], true)
        default:
            return ([], false)
        }
    }

    /// The 0.3s hold onset fired: a single tap engages the hold
    /// (key down), a double-tap starts spamming enters, and a held
    /// swipe fires its first directional repeat.
    mutating func onsetTimerFired() -> [Output] {
        switch state {
        case .singleDown:
            state = .singleHeld
            return [.enterDown]
        case .doubleDown:
            state = .doubleSpam
            return [.enter(haptic: true)]
        case .swiping:
            // First repeat of a held swipe — buzzes once, like the
            // first repeat of a double-tap-hold.
            return nextSwipeRepeat()
        default:
            return []
        }
    }

    /// One spam interval (0.12s) while double-tap-hold is active.
    /// Later repeats are silent; the first repeat (from
    /// onsetTimerFired) buzzed once.
    mutating func spamTick() -> [Output] {
        state == .doubleSpam ? [.enter(haptic: false)] : []
    }

    /// One repeat interval (0.12s) while a swipe is held down.
    /// The first repeat buzzes once; later repeats are silent.
    mutating func swipeTick() -> [Output] {
        state == .swiping ? nextSwipeRepeat() : []
    }

    /// The next repeat of the held swipe: the first one buzzes,
    /// later ones are silent.
    private mutating func nextSwipeRepeat() -> [Output] {
        guard let direction = swipeDirection else { return [] }
        if swipeRepeatFired { return [silent(direction)] }
        swipeRepeatFired = true
        return [direction]
    }

    /// The same direction with its haptic silenced.
    private func silent(_ output: Output) -> Output {
        switch output {
        case .up(_): return .up(haptic: false)
        case .down(_): return .down(haptic: false)
        case .left(_): return .left(haptic: false)
        case .right(_): return .right(haptic: false)
        default: return output
        }
    }

    /// Finger moved. Beyond the slop the gesture becomes a swipe: a
    /// held key is released first, then the first directional press
    /// fires at once and the direction locks in for the touch —
    /// further movement never changes it. Holding past the onset
    /// repeats that direction (see onsetTimerFired / swipeTick).
    mutating func moved(translation: CGSize, slop: CGFloat) -> [Output] {
        guard abs(translation.width) >= slop || abs(translation.height) >= slop else { return [] }
        switch state {
        case .singleHeld:
            state = .swiping
            let direction = direction(of: translation)
            swipeDirection = direction
            return [.enterUp, direction]
        case .singleDown, .doubleDown, .doubleSpam, .muteZoneDown, .muteZoneDoubleDown:
            // A swipe starting in the mute zone is still a swipe:
            // the zone only changes what a tap does, and no key
            // was held down, so there is nothing to release first.
            state = .swiping
            let direction = direction(of: translation)
            swipeDirection = direction
            return [direction]
        case .swiping:
            return []
        default:
            return []
        }
    }

    /// Finger lifted. A swipe whose press never fired (a flick too
    /// fast for moved() to see) sends its direction; a swipe already
    /// recognized sends nothing more — its press fired in moved()
    /// and its repeats stop. A quick tap sends one enter (and opens
    /// the double-tap window for a first tap only); a hold releases
    /// the key with no enter on lift; spam just stops.
    mutating func touchUp(translation: CGSize, slop: CGFloat) -> [Output] {
        let isSwipe = abs(translation.width) >= slop || abs(translation.height) >= slop
        switch state {
        case .singleDown:
            if isSwipe {
                state = .idle
                return [direction(of: translation)]
            }
            state = .awaitingSecondTap
            return [.enter(haptic: true)]
        case .singleHeld:
            state = .idle
            return isSwipe ? [.enterUp, direction(of: translation)] : [.enterUp]
        case .doubleDown:
            if isSwipe {
                state = .idle
                return [direction(of: translation)]
            }
            state = .idle
            return [.enter(haptic: true)]
        case .doubleSpam:
            state = .idle
            return isSwipe ? [direction(of: translation)] : []
        case .muteZoneDown:
            // First tap in the zone lifted: hold its enter until
            // the window decides — a second zone tap mutes, the
            // window expiring leaves one enter.
            state = .awaitingSecondTapZone
            return []
        case .muteZoneDoubleDown:
            if isSwipe {
                state = .idle
                return [direction(of: translation)]
            }
            state = .idle
            return [.mute(haptic: true)]
        case .swiping:
            state = .idle
            swipeDirection = nil
            swipeRepeatFired = false
            return []
        case .awaitingSecondTap, .awaitingSecondTapZone, .idle:
            return []
        }
    }

    /// The double-tap window expired with no second tap. Returns
    /// the outputs to emit: a zone-first tap's held-back enter
    /// stands alone; a normal first tap already sent its enter.
    /// The next tap is a fresh single either way.
    mutating func secondTapWindowExpired() -> [Output] {
        switch state {
        case .awaitingSecondTapZone:
            state = .idle
            return [.enter(haptic: true)]
        case .awaitingSecondTap:
            state = .idle
            return []
        default:
            return []
        }
    }

    mutating func reset() {
        state = .idle
        swipeDirection = nil
        swipeRepeatFired = false
    }

    private func direction(of translation: CGSize, haptic: Bool = true) -> Output {
        if abs(translation.width) > abs(translation.height) {
            return translation.width > 0 ? .right(haptic: haptic) : .left(haptic: haptic)
        }
        return translation.height > 0 ? .down(haptic: haptic) : .up(haptic: haptic)
    }
}

/// Pad controls reminder: each gesture is its own card — a colored
/// icon tile, the gesture name, what it does — matching the mockup
/// Nick sent. No picture of the remote (v1.0.39).
/// Pad controls help, glassmorphic (v1.0.50): Nick's screenshot —
/// frosted glass cards on the page background, floating pill
/// header, same six gesture cards.

/// Pure pad geometry (v1.0.53): the tilt and mute-zone math as
/// functions of the pad size and the press location — no SwiftUI, so
/// unit tests can drive it directly. Extracted from SwipePadView
/// when the pad moved into its own file.
struct PadGeometry {
    /// Max tilt: 8° (v1.0.53) — back from 14° in v1.0.51, whose field
    /// test found 14° over-rotated; the v1.0.47 value, which nobody
    /// complained about.
    static let maxTiltDegrees: Double = 8
    /// Mute zone (v1.0.34): the middle-right of the pad — the right
    /// third horizontally, the middle half vertically. A double-tap
    /// with both taps here mutes; the middle stays for taps/holds.
    static let muteZoneMinX: CGFloat = 0.67
    static let muteZoneMinY: CGFloat = 0.25
    static let muteZoneMaxY: CGFloat = 0.75

    let size: CGSize

    /// True when a tap location (in the pad's own coordinates)
    /// falls inside the mute zone. False until the size is known.
    func isMuteZone(_ location: CGPoint) -> Bool {
        guard size.width > 0, size.height > 0 else { return false }
        let x = location.x / size.width
        let y = location.y / size.height
        return x >= Self.muteZoneMinX && y >= Self.muteZoneMinY && y <= Self.muteZoneMaxY
    }

    /// Tilt toward the finger while pressed (v1.0.34, stronger in
    /// v1.0.44, stronger again in v1.0.47, and again in v1.0.51,
    /// simplified in v1.0.52): at most maxTiltDegrees, around the
    /// axis perpendicular to the offset from center, so the pad
    /// feels like a platform tipping toward the thumb — strongest
    /// at the corners. A dead-center press doesn't tilt at all — it
    /// only scales (barely, now). The axis sign is toward the finger.
    /// Returns 0 when not pressed or the size is unknown.
    func tiltAngle(isPressed: Bool, pressLocation: CGPoint?) -> Double {
        guard isPressed, let loc = pressLocation,
              size.width > 0, size.height > 0 else { return 0 }
        let dx = loc.x / size.width - 0.5
        let dy = loc.y / size.height - 0.5
        return min(1, sqrt(dx * dx + dy * dy) * 2.5) * Self.maxTiltDegrees
    }

    /// The tilt axis for a press location: perpendicular to the
    /// offset from center, toward the finger. The default (no press
    /// or unknown size) is a no-op tilt around the vertical axis.
    func tiltAxis(pressLocation: CGPoint?) -> (x: CGFloat, y: CGFloat, z: CGFloat) {
        guard let loc = pressLocation,
              size.width > 0, size.height > 0 else { return (x: 0, y: 1, z: 0) }
        let dx = loc.x / size.width - 0.5
        let dy = loc.y / size.height - 0.5
        return (x: -dy, y: dx, z: 0)
    }
}

struct TrailPoint {
    var point: CGPoint
    var time: Date
}

/// The finger trail (v1.0.44, styles in v1.0.46), drawn in the
/// pad's own coordinates. Each touch is its own stroke (v1.0.47):
/// lifting and touching elsewhere starts a new streak instead of
/// drawing a connector line across the pad. Glow is a soft wide
/// line with a faint core, plus a soft dot under the finger. Dots
/// is a row of circles that shrink and fade with age. Off draws
/// nothing. Fades as a whole after lift (see trailOpacity).
/// Everything is very faint — just enough to know the touch registered.
struct PadTrailOverlay: View {
    var strokes: [[TrailPoint]]
    var opacity: Double
    var style: TrailStyle
    /// Trail color (v1.0.51): white on the dark pad, the theme
    /// accent on the light pad — a white trail is invisible on a
    /// light surface.
    var color: Color = .white

    var body: some View {
        ZStack {
            switch style {
            case .off:
                EmptyView()
            case .glow:
                ForEach(strokes.indices, id: \.self) { i in
                    if strokes[i].count > 1 {
                        trailPath(strokes[i])
                            .stroke(color.opacity(0.07), style: StrokeStyle(lineWidth: 12, lineCap: .round, lineJoin: .round))
                        trailPath(strokes[i])
                            .stroke(color.opacity(0.16), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    }
                }
                if let last = strokes.last?.last {
                    Circle()
                        .fill(color.opacity(0.3))
                        .frame(width: 12, height: 12)
                        .shadow(color: color.opacity(0.25), radius: 8)
                        .position(last.point)
                }
            case .dots:
                ForEach(strokes.indices, id: \.self) { i in
                    ForEach(strokes[i].indices, id: \.self) { j in
                        let point = strokes[i][j]
                        let age = Date().timeIntervalSince(point.time)
                        Circle()
                            .fill(color.opacity(max(0, 0.35 - age)))
                            .frame(width: dotSize(age), height: dotSize(age))
                            .position(point.point)
                    }
                }
            }
        }
        .opacity(opacity)
        .allowsHitTesting(false)
    }

    /// The path through one stroke's points.
    private func trailPath(_ stroke: [TrailPoint]) -> Path {
        var path = Path()
        if let first = stroke.first {
            path.move(to: first.point)
            for point in stroke.dropFirst() { path.addLine(to: point.point) }
        }
        return path
    }

    /// A dot's size by age: 12pt fresh, shrinking to 3pt.
    private func dotSize(_ age: TimeInterval) -> CGFloat {
        max(3, 12 - age * 10)
    }
}

struct SwipePadView: View {
    var height: CGFloat
    /// Second parameter: whether the command should buzz. A tap
    /// buzzes once, the hold onset buzzes once, and the first spam
    /// repeat of a double-tap-hold buzzes once; later repeats of a
    /// hold are silent — the same rule as the volume hold (v1.0.20),
    /// because buzzing at repeat rate is faster than the TV moves.
    /// A key release never buzzes.
    var onCommand: (RemoteCommand, Bool) -> Void
    /// Repeat presses (double-tap-hold spam, swipe-and-hold ticks)
    /// go through the session's coalescing pump (v1.0.34), not the
    /// direct send: the pump keeps one pending press and drops it
    /// on lift, so repeats stop dead the instant the finger lifts
    /// instead of draining a backlog. Discrete presses never use
    /// this path.
    var onRepeatCommand: (RemoteCommand, Bool) -> Void
    /// Called on finger lift (and when the pad goes away): drops
    /// the pump's pending repeat press, if any.
    var onCancelRepeats: () -> Void
    /// True while the iOS keyboard is up (v1.0.53): a touch that
    /// lands then is a keyboard dismiss, not a command — the pad
    /// swallows the whole touch and reports it through
    /// onDismissKeyboard instead.
    var isKeyboardOpen: Bool
    /// The keyboard-dismiss path (v1.0.53): the same dismiss the
    /// keyboard's own × button runs — clear the text, hide the row,
    /// unfocus. The pad calls this for a touch that landed while
    /// the keyboard was open; the touch itself sends nothing.
    var onDismissKeyboard: () -> Void
    /// A touch that landed while the keyboard was open (v1.0.53):
    /// the whole touch stays consumed as a dismiss even if the
    /// finger is still down when the keyboard finishes closing and
    /// isKeyboardOpen flips back to false mid-touch — otherwise the
    /// hold onset would fire a key press from the dismissing tap.
    @State private var dismissedTouch = false

    @State private var gesture = SwipePadGesture()
    @State private var holdTask: Task<Void, Never>?
    @State private var windowTask: Task<Void, Never>?
    /// The pad's rendered size, for the mute zone (v1.0.34): the
    /// zone is a fraction of the pad, so taps are located against
    /// this, not against fixed points.
    @State private var padSize: CGSize = .zero

    /// Records the pad's measured size (v1.0.52): read straight off
    /// the geometry in the background, no PreferenceKey in between.
    /// The key never delivered — the size stayed .zero, so the tilt
    /// never tilted and the mute zone never matched a tap. The size
    /// is also remembered for the cover cropper (v1.0.50).
    private func setPadSize(_ size: CGSize) {
        // Only write on change: onAppear fires on every appear and
        // the geometry fires on every layout pass, so an unconditional
        // write churned UserDefaults (and re-rendered the pad) for
        // the same size.
        guard size != padSize else { return }
        padSize = size
        UserDefaults.standard.set(size.width, forKey: "padMeasuredWidth")
        UserDefaults.standard.set(size.height, forKey: "padMeasuredHeight")
    }
    /// Press feedback (v1.0.34, retuned in v1.0.47 and v1.0.51,
    /// simplified in v1.0.52 — the tilt does the talking now: 8°
    /// toward the finger (v1.0.53: back from 14° — his field test
    /// found 14° over-rotated), scale barely 0.995 — so a tap reads
    /// as a tilt, not a press inward): while a finger is down the pad
    /// dips toward it and springs back on lift.
    @State private var isPressed = false
    @State private var pressLocation: CGPoint? = nil
    /// Finger trail (v1.0.44): a short faint line that follows the
    /// finger across the pad and fades shortly after lift, so the
    /// pad feels alive to touch. Points older than 0.8s drop off
    /// while dragging; on lift the whole trail fades out. One
    /// stroke per touch (v1.0.47): lifting and touching elsewhere
    /// starts a new streak — the strokes never connect.
    @State private var trail: [[TrailPoint]] = []
    @State private var trailStrokeOpen = false
    @State private var trailOpacity: Double = 1
    @State private var trailFadeTask: Task<Void, Never>?
    /// Settings (v1.0.46), read live so the pad re-renders when
    /// they change: color theme, border effect, trail style.
    @AppStorage("padTheme") private var padThemeRaw = "midnight"
    @AppStorage("padBorder") private var padBorderRaw = "off"
    @AppStorage("trailStyle") private var trailStyleRaw = "glow"
    /// Pad cover art (v1.0.50): bumped whenever the cover is
    /// set, re-cropped, or removed, so the pad re-renders.
    @AppStorage("padCoverVersion") private var coverVersion = 0
    private var theme: PadTheme { PadTheme(rawValue: padThemeRaw) ?? .midnight }
    private var borderEffect: PadBorder { PadBorder(rawValue: padBorderRaw) ?? .off }
    private var trailStyle: TrailStyle { TrailStyle(rawValue: trailStyleRaw) ?? .glow }
    /// Resolved color scheme (v1.0.51): the pad follows the page —
    /// a light pad in light mode, dark in dark mode.
    @Environment(\.colorScheme) private var colorScheme

    /// Same timing as the volume hold (v1.0.19/20): the hold engages
    /// 0.3s after touch down, then spam repeats one press every
    /// 0.12s (~8/s).
    private static let holdOnset: UInt64 = 300_000_000
    private static let holdInterval: UInt64 = 120_000_000
    /// A second tap within this long of the first tap's lift counts
    /// as a double-tap; after it, the next tap is a fresh single.
    /// 0.5s in v1.0.51 (was 0.3s): the tight window made a natural
    /// double-tap on the mute zone land as two separate selects
    /// instead of a mute — the second tap kept missing the window.
    private static let doubleTapWindow: UInt64 = 500_000_000
    /// Finger movement within this box counts as a tap/hold;
    /// beyond it, the gesture is a swipe.
    private static let tapSlop: CGFloat = 14
    /// Pad geometry (v1.0.53): the tilt + mute-zone math, as the
    /// pure PadGeometry type — see below.
    private var padGeometry: PadGeometry { PadGeometry(size: padSize) }

    /// The pad's border (v1.0.46, Flow fixed in v1.0.51, inset in
    /// v1.0.52): off is the plain static stroke; glow adds a soft
    /// halo in the theme color; flow runs a bright segment around
    /// the border, LED-keyboard style — a trimmed stroke whose
    /// trim window slides along the path, driven by a TimelineView
    /// so it stays smooth with no timer to manage. (The first
    /// version rotated the trimmed shape instead — on a rounded
    /// rectangle that swings the piece off the border.) All strokes
    /// are inset (strokeBorder): a centered stroke hangs half its
    /// width past the pad's edge, so against a cover photo it read
    /// as a line that didn't line up with the image — inset, the
    /// border's outer edge is exactly the photo's edge.
    @ViewBuilder
    private var padBorder: some View {
        switch borderEffect {
        case .off:
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(theme.accent.opacity(0.55), lineWidth: 1.5)
        case .glow:
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(theme.accent, lineWidth: 2)
                .shadow(color: theme.accent.opacity(0.8), radius: 14)
        case .flow:
            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .strokeBorder(theme.accent.opacity(0.25), lineWidth: 2)
                TimelineView(.animation) { timeline in
                    let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3) / 3
                    let end = phase + 0.15
                    // The segment is inset by half its width first:
                    // strokeBorder doesn't exist on a trimmed shape
                    // (trim drops the InsettableShape conformance,
                    // so the v1.0.52 build failed to compile), and
                    // a centered stroke on the inset path lands its
                    // outer edge exactly on the photo's edge anyway.
                    RoundedRectangle(cornerRadius: 24)
                        .inset(by: 1.5)
                        .trim(from: phase, to: min(1, end))
                        .stroke(theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .shadow(color: theme.accent.opacity(0.9), radius: 8)
                    if end > 1 {
                        RoundedRectangle(cornerRadius: 24)
                            .inset(by: 1.5)
                            .trim(from: 0, to: end - 1)
                            .stroke(theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .shadow(color: theme.accent.opacity(0.9), radius: 8)
                    }
                }
            }
        }
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 24)
            .fill(
                LinearGradient(
                    // Light pad (v1.0.51): a pale tint of the theme
                    // instead of the dark gradient — the dark pad
                    // on a light page read as a hole in the page.
                    colors: colorScheme == .light ? [theme.lightTop, theme.lightBottom] : [theme.top, theme.bottom],
                    startPoint: .top, endPoint: .bottom)
            )
            // Pad cover art (v1.0.50): a user photo cropped to the
            // pad's shape replaces the theme gradient. The border
            // and trail still draw on top, in the theme accent.
            // Clear photo (v1.0.53): the v1.0.52 frost + tint
            // blurred the photo beyond recognition — no blur, no
            // frost, no overlay at all, just the image as-is.
            .overlay(
                Group {
                    if let cover = PadCoverStore.image(for: coverVersion) {
                        Image(uiImage: cover)
                            .resizable()
                            .scaledToFill()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 24))
            )
            .overlay(padBorder)
            // Finger trail (v1.0.44): drawn on the pad itself, so
            // it tilts and scales with the pad. Clipped to the
            // rounded corners so it never spills outside the pad.
            .overlay(
                PadTrailOverlay(strokes: trail, opacity: trailOpacity, style: trailStyle, color: colorScheme == .light ? theme.accent : .white)
                    .clipShape(RoundedRectangle(cornerRadius: 24))
            )
            .frame(maxWidth: .infinity)
            .frame(height: height)
            // Press feedback (v1.0.47, retuned in v1.0.51,
            // simplified in v1.0.52): the pad tips toward the
            // finger like a platform — up to 8° at the corners —
            // and barely shrinks (0.995), so a tap reads as a tilt,
            // not a press inward. One spring, on the press state
            // only: the drag already delivers locations
            // continuously, so the tilt follows the finger directly
            // instead of chasing it through a second spring — the
            // second spring kept re-targeting on every move and
            // the tilt never got anywhere, which is why it read
            // as not tilting at all.
            .scaleEffect(isPressed ? 0.995 : 1.0)
            .rotation3DEffect(.degrees(padGeometry.tiltAngle(isPressed: isPressed, pressLocation: pressLocation)), axis: padGeometry.tiltAxis(pressLocation: pressLocation))
            .animation(.spring(response: 0.1, dampingFraction: 0.85), value: isPressed)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { setPadSize(geo.size) }
                        .onChange(of: geo.size) { setPadSize($0) }
                }
            )
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if isKeyboardOpen || dismissedTouch {
                            // The dismissing touch sends nothing —
                            // not even a key hold if the finger
                            // stays down past the onset.
                            dismissedTouch = true
                            abortTouch()
                            onDismissKeyboard()
                            return
                        }
                        isPressed = true
                        pressLocation = value.location
                        addTrailPoint(value.location)
                        let t = value.translation
                        if abs(t.width) >= Self.tapSlop || abs(t.height) >= Self.tapSlop {
                            // It's a swipe — release a held key first,
                            // then fire the first directional press.
                            // The hold task keeps running: if the
                            // onset hasn't fired yet it drives the
                            // first swipe repeat at onset and the
                            // ticks after that. If it already fired
                            // (swiped out of a key hold) start the
                            // repeat loop directly.
                            emit(gesture.moved(translation: t, slop: Self.tapSlop))
                            if gesture.isSwiping, holdTask == nil {
                                startSwipeRepeatTask()
                            }
                        } else if holdTask == nil {
                            // Finger down and still — the gesture
                            // decides single vs double-tap (and, in
                            // the mute zone, mute vs enter); start
                            // the hold timer when it says this is
                            // a tap that can be held.
                            cancelWindowTask()
                            let down = gesture.touchDown(inMuteZone: padGeometry.isMuteZone(value.location))
                            emit(down.outputs)
                            if down.startHold {
                                startHoldTask()
                            }
                        }
                    }
                    .onEnded { value in
                        if isKeyboardOpen || dismissedTouch {
                            dismissedTouch = false
                            abortTouch()
                            onDismissKeyboard()
                            return
                        }
                        isPressed = false
                        pressLocation = nil
                        trailStrokeOpen = false
                        fadeTrail()
                        cancelHoldTask()
                        onCancelRepeats()
                        emit(gesture.touchUp(translation: value.translation, slop: Self.tapSlop))
                        if gesture.isAwaitingSecondTap || gesture.isAwaitingSecondTapZone {
                            cancelWindowTask()
                            startWindowTask()
                        }
                    }
            )
            .onDisappear {
                abortTouch()
            }
    }

    /// Aborts the touch in flight (v1.0.53): releases a held key,
    /// drops the trail and any timers, and resets the gesture — the
    /// shared cleanup for the pad going away and for a touch
    /// consumed as a keyboard dismiss (a dismiss that swallows a
    /// touch which already held a key down must still release it,
    /// or the key sticks on the TV).
    private func abortTouch() {
        if gesture.isKeyHeldDown {
            onCommand(.enterUp, false)
        }
        isPressed = false
        pressLocation = nil
        trailStrokeOpen = false
        trailFadeTask?.cancel()
        trailFadeTask = nil
        trail.removeAll()
        trailOpacity = 1
        cancelHoldTask()
        onCancelRepeats()
        cancelWindowTask()
        gesture.reset()
    }

    /// Records one finger position for the trail (v1.0.44): points
    /// older than 0.8s drop off, so the tail shortens behind the
    /// finger, and points closer than 4pt to the last one are
    /// skipped. A new touch cancels any fade in flight. Each touch
    /// is its own stroke (v1.0.47): lifting and touching elsewhere
    /// starts a new streak — the strokes never connect.
    private func addTrailPoint(_ location: CGPoint) {
        trailFadeTask?.cancel()
        trailFadeTask = nil
        trailOpacity = 1
        let now = Date()
        // Drop points older than 0.8s, and strokes that emptied.
        trail = trail.map { stroke in stroke.filter { now.timeIntervalSince($0.time) <= 0.8 } }
            .filter { !$0.isEmpty }
        // A new touch — or a stroke that aged out mid-touch —
        // opens a fresh streak.
        if !trailStrokeOpen || trail.isEmpty {
            trail.append([])
            trailStrokeOpen = true
        }
        guard var stroke = trail.last else { return }
        if let last = stroke.last,
           hypot(location.x - last.point.x, location.y - last.point.y) < 4 { return }
        stroke.append(TrailPoint(point: location, time: now))
        if stroke.count > 60 { stroke.removeFirst(stroke.count - 60) }
        trail[trail.count - 1] = stroke
    }

    /// Fades the trail out after lift (v1.0.44): it lingers a beat,
    /// then fades over 0.4s and clears.
    private func fadeTrail() {
        trailFadeTask?.cancel()
        trailFadeTask = Task {
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.4)) { trailOpacity = 0 }
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            trail.removeAll()
            trailOpacity = 1
        }
    }

    /// Sends gesture outputs through the pad's callback. enterDown
    /// buzzes once at onset; a key release never buzzes. With
    /// `viaPump`, the same outputs enqueue on the session's
    /// coalescing pump instead of sending directly (v1.0.34): spam
    /// ticks and swipe repeats use the pump so the stream stops
    /// dead on lift; discrete presses always go direct.
    private func emit(_ outputs: [SwipePadGesture.Output], viaPump: Bool = false) {
        for output in outputs {
            switch output {
            case .enter(let haptic):
                if viaPump { onRepeatCommand(.enter, haptic) } else { onCommand(.enter, haptic) }
            case .enterDown:
                if viaPump { onRepeatCommand(.enterDown, true) } else { onCommand(.enterDown, true) }
            case .enterUp:
                if viaPump { onRepeatCommand(.enterUp, false) } else { onCommand(.enterUp, false) }
            case .mute(let haptic):
                if viaPump { onRepeatCommand(.mute, haptic) } else { onCommand(.mute, haptic) }
            case .up(let haptic):
                if viaPump { onRepeatCommand(.up, haptic) } else { onCommand(.up, haptic) }
            case .down(let haptic):
                if viaPump { onRepeatCommand(.down, haptic) } else { onCommand(.down, haptic) }
            case .left(let haptic):
                if viaPump { onRepeatCommand(.left, haptic) } else { onCommand(.left, haptic) }
            case .right(let haptic):
                if viaPump { onRepeatCommand(.right, haptic) } else { onCommand(.right, haptic) }
            }
        }
    }

    /// Hold timer: at onset the gesture either engages the hold
    /// (single tap), starts spamming (double-tap-hold), or fires
    /// the first repeat of a held swipe; spam and swipe repeats
    /// then tick every interval until the finger lifts. Clears its
    /// own slot when it finishes, so a later swipe out of a hold
    /// can start a fresh repeat task.
    private func startHoldTask() {
        holdTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.holdOnset)
            guard !Task.isCancelled else { return }
            // A held swipe's first repeat is a repeat, not a
            // discrete press: it goes through the pump so the
            // stream can be dropped on lift. A hold onset and the
            // first spam press are discrete and go direct.
            if gesture.isSwiping {
                emit(gesture.onsetTimerFired(), viaPump: true)
            } else {
                emit(gesture.onsetTimerFired())
            }
            while gesture.isSpamming || gesture.isSwiping, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.holdInterval)
                guard !Task.isCancelled else { return }
                emit(gesture.isSpamming ? gesture.spamTick() : gesture.swipeTick(), viaPump: true)
            }
            holdTask = nil
        }
    }

    /// Repeat loop for a swipe that started after the hold onset
    /// already fired (swiped out of a key hold): the onset gate
    /// has passed, so repeats tick every interval from here — the
    /// first one buzzes once, later ones are silent. Ticks go
    /// through the pump (v1.0.34) so they stop dead on lift.
    private func startSwipeRepeatTask() {
        holdTask = Task { @MainActor in
            while gesture.isSwiping, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.holdInterval)
                guard !Task.isCancelled else { return }
                emit(gesture.swipeTick(), viaPump: true)
            }
            holdTask = nil
        }
    }

    /// Double-tap window timer: started on a quick tap's lift; if
    /// no second tap lands, the tap stands alone. A zone-first tap
    /// sends its held-back enter here when the window expires.
    private func startWindowTask() {
        windowTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.doubleTapWindow)
            guard !Task.isCancelled else { return }
            emit(gesture.secondTapWindowExpired())
        }
    }

    private func cancelHoldTask() {
        holdTask?.cancel()
        holdTask = nil
    }

    private func cancelWindowTask() {
        windowTask?.cancel()
        windowTask = nil
    }
}
