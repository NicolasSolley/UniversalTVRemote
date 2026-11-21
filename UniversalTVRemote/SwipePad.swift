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
        /// Bottom-row zones (v1.0.55): double-tap the bottom-left
        /// for Back, bottom-middle for Home, bottom-right for Exit
        /// — the same pattern as the mute zone.
        case back(haptic: Bool), home(haptic: Bool), exit(haptic: Bool)
        /// Top-left zone (v1.0.60): double-tap the top-left corner
        /// for Source — change the TV's input.
        case source(haptic: Bool)
        case up(haptic: Bool), down(haptic: Bool), left(haptic: Bool), right(haptic: Bool)
    }

    private enum State: Equatable {
        case idle
        case awaitingSecondTap
        case singleDown
        case singleHeld
        case doubleDown
        case doubleSpam
        case swiping
        /// First tap down inside a double-tap zone (v1.0.34 mute,
        /// v1.0.55 back/home/exit): no hold timer, no enter yet —
        /// the window decides.
        case zoneDown(PadZone)
        /// First tap in a zone lifted, waiting to see if a second
        /// zone tap fires the zone's action or the window expires
        /// (one enter).
        case awaitingSecondTapZone(PadZone)
        /// Second tap down inside a zone: lift fires its action.
        case zoneDoubleDown(PadZone)
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
    /// True after a quick tap in a zone lifted, while a second
    /// tap in the zone still counts as the zone's action.
    var isAwaitingSecondTapZone: Bool {
        if case .awaitingSecondTapZone = state { return true }
        return false
    }
    /// True while a swipe is being held down (repeats active).
    var isSwiping: Bool { state == .swiping }

    /// Finger down. Returns true when the view should start the hold
    /// onset timer (a fresh single or double tap); false when this
    /// touch is already a swipe that wandered back inside the slop.
    mutating func touchDown() -> Bool {
        touchDown(inMuteZone: false).startHold
    }

    /// Finger down, with the double-tap zone (v1.0.34 mute,
    /// v1.0.55 back/home/exit) or nil when outside any zone.
    /// Returns the outputs to emit now and whether the view
    /// should start the hold onset timer. A tap inside a zone
    /// never starts the hold timer — a hold in a zone is not a
    /// key hold — and its enter is held back until the
    /// double-tap window decides: a second tap in the same zone
    /// fires the zone's action, the window expiring leaves one
    /// enter, and a second tap elsewhere turns the held-back
    /// enter into half of a normal double-tap. Firing a zone's
    /// action needs both taps in that zone: a zone tap after a
    /// middle tap is just the second tap of a normal double-tap,
    /// and a second tap in a different zone fires nothing — the
    /// held-back enter stands and that tap is a fresh single.
    mutating func touchDown(inZone zone: PadZone?) -> (outputs: [Output], startHold: Bool) {
        if let zone {
            switch state {
            case .idle:
                state = .zoneDown(zone)
                return ([], false)
            case .awaitingSecondTapZone(let pending) where pending == zone:
                state = .zoneDoubleDown(zone)
                return ([], false)
            case .awaitingSecondTapZone:
                state = .singleDown
                return ([.enter(haptic: true)], true)
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

    /// Mute-zone shorthand (v1.0.34), kept for the existing
    /// tests: a zone tap is a mute-zone tap, a non-zone tap is
    /// outside every zone.
    mutating func touchDown(inMuteZone: Bool) -> (outputs: [Output], startHold: Bool) {
        touchDown(inZone: inMuteZone ? .mute : nil)
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
        case .singleDown, .doubleDown, .doubleSpam, .zoneDown, .zoneDoubleDown:
            // A swipe starting in a zone is still a swipe: the
            // zone only changes what a tap does, and no key was
            // held down, so there is nothing to release first.
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
        case .zoneDown(let zone):
            // First tap in the zone lifted: hold its enter until
            // the window decides — a second zone tap fires the
            // zone's action, the window expiring leaves one enter.
            state = .awaitingSecondTapZone(zone)
            return []
        case .zoneDoubleDown(let zone):
            if isSwipe {
                state = .idle
                return [direction(of: translation)]
            }
            state = .idle
            return [zoneAction(zone, haptic: true)]
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

    /// The action a zone fires on a double-tap lift.
    private func zoneAction(_ zone: PadZone, haptic: Bool) -> Output {
        switch zone {
        case .mute: return .mute(haptic: haptic)
        case .back: return .back(haptic: haptic)
        case .home: return .home(haptic: haptic)
        case .exit: return .exit(haptic: haptic)
        case .source: return .source(haptic: haptic)
        }
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
/// header, ten gesture cards (v1.0.55: the three bottom zones
/// joined the original six; v1.0.60: the top-left source zone
/// joined them).

/// A double-tap zone on the pad (v1.0.34 mute, v1.0.55
/// back/home/exit, v1.0.60 source): the zone only changes what a double-tap
/// does — a single tap inside one still sends OK.
enum PadZone: Equatable, Hashable {
    case mute, back, home, exit, source
}

/// Pure pad geometry (v1.0.53): the tilt and mute-zone math as
/// functions of the pad size and the press location — no SwiftUI, so
/// unit tests can drive it directly. Extracted from SwipePadView
/// when the pad moved into its own file.
struct PadGeometry {
    /// Whether the connected TV has a real exit key (v1.0.78):
    /// false on Roku and Android TV, whose protocols have no
    /// exit key — on those brands the bottom-right zone is plain
    /// pad (a double-tap there is just OK twice) and the Exit
    /// icon and guide card are hidden. Defaults true in the init
    /// below, so the zone math stays exactly as before unless a
    /// caller says otherwise.
    let supportsExit: Bool

    /// Max tilt: 4° (v1.0.58) — back from 6° in v1.0.54, whose field
    /// test still found it slightly too strong. Same single-spring
    /// behavior, just a lower max.
    static let maxTiltDegrees: Double = 4
    /// Mute zone (v1.0.34): the middle-right of the pad — the right
    /// third horizontally, the middle half vertically. A double-tap
    /// with both taps here mutes; the middle stays for taps/holds.
    static let muteZoneMinX: CGFloat = 0.67
    static let muteZoneMinY: CGFloat = 0.25
    static let muteZoneMaxY: CGFloat = 0.75
    /// Bottom zones (v1.0.55): the bottom quarter of the pad,
    /// split into thirds — left is Back, middle is Home, right is
    /// Exit. Same double-tap pattern as the mute zone.
    static let bottomZoneMinY: CGFloat = 0.75
    static let backZoneMaxX: CGFloat = 1 / 3
    static let homeZoneMaxX: CGFloat = 2 / 3
    /// Source zone (v1.0.60): the top-left corner — the top
    /// quarter of the pad, left third. Double-tap it to change
    /// the TV's input. Same double-tap pattern as the other
    /// zones; top-middle and top-right stay plain pad.
    static let sourceZoneMaxY: CGFloat = 0.25
    static let sourceZoneMaxX: CGFloat = 1 / 3

    let size: CGSize

    /// Explicit init (v1.0.78): the synthesized memberwise init
    /// takes its parameters in declaration order (supportsExit,
    /// then size), so the call-site order (size, supportsExit)
    /// does not compile — this init takes them in call-site order
    /// and keeps the supportsExit default, so the plain size-only
    /// callers (tests, zone overlay) keep working unchanged.
    init(size: CGSize, supportsExit: Bool = true) {
        self.size = size
        self.supportsExit = supportsExit
    }

    /// The zone a tap location falls in, if any. Mute wins on the
    /// shared y = 0.75 boundary (a tap there is still a mute tap,
    /// as before); back wins on the x = 1/3 boundary, home on
    /// x = 2/3. Source never overlaps mute (different x thirds),
    /// and a tap exactly on y = 0.25 is not a source tap — the
    /// source strip starts strictly above it.
    func zone(at location: CGPoint) -> PadZone? {
        if isMuteZone(location) { return .mute }
        if isSourceZone(location) { return .source }
        if isBackZone(location) { return .back }
        if isHomeZone(location) { return .home }
        if isExitZone(location) { return .exit }
        return nil
    }

    /// The center of a zone, in pad coordinates — where the zone
    /// overlay (v1.0.56) puts the zone's icon. Nil until the size
    /// is known.
    func center(of zone: PadZone) -> CGPoint? {
        guard size.width > 0, size.height > 0 else { return nil }
        switch zone {
        case .mute:
            return CGPoint(x: (Self.muteZoneMinX + 1) / 2 * size.width,
                           y: (Self.muteZoneMinY + Self.muteZoneMaxY) / 2 * size.height)
        case .back:
            return CGPoint(x: Self.backZoneMaxX / 2 * size.width,
                           y: (Self.bottomZoneMinY + 1) / 2 * size.height)
        case .home:
            return CGPoint(x: (Self.backZoneMaxX + Self.homeZoneMaxX) / 2 * size.width,
                           y: (Self.bottomZoneMinY + 1) / 2 * size.height)
        case .exit:
            return CGPoint(x: (Self.homeZoneMaxX + 1) / 2 * size.width,
                           y: (Self.bottomZoneMinY + 1) / 2 * size.height)
        case .source:
            return CGPoint(x: Self.sourceZoneMaxX / 2 * size.width,
                           y: Self.sourceZoneMaxY / 2 * size.height)
        }
    }

    /// True when a tap location (in the pad's own coordinates)
    /// falls inside the mute zone. False until the size is known.
    func isMuteZone(_ location: CGPoint) -> Bool {
        guard size.width > 0, size.height > 0 else { return false }
        let x = location.x / size.width
        let y = location.y / size.height
        // Epsilon: a tap exactly on the 0.67 boundary computes to
        // 0.6699999999999999 in floating point and would be rejected.
        let eps: CGFloat = 1e-9
        return x + eps >= Self.muteZoneMinX && y + eps >= Self.muteZoneMinY && y - eps <= Self.muteZoneMaxY
    }

    /// True when a tap location falls in the bottom-left zone
    /// (Back). The bottom strip starts strictly below y = 0.75,
    /// so it never overlaps the mute zone — a tap exactly on the
    /// shared y = 0.75 line is a mute tap (x >= 0.67) or no zone
    /// at all, never a bottom zone. False until the size is known.
    func isBackZone(_ location: CGPoint) -> Bool {
        guard size.width > 0, size.height > 0 else { return false }
        let x = location.x / size.width
        let y = location.y / size.height
        let eps: CGFloat = 1e-9
        return x - eps < Self.backZoneMaxX && y - eps > Self.bottomZoneMinY
    }

    /// True when a tap location falls in the bottom-middle zone
    /// (Home). Same strict-below-y = 0.75 rule as the other bottom
    /// zones. False until the size is known.
    func isHomeZone(_ location: CGPoint) -> Bool {
        guard size.width > 0, size.height > 0 else { return false }
        let x = location.x / size.width
        let y = location.y / size.height
        let eps: CGFloat = 1e-9
        return x + eps >= Self.backZoneMaxX && x - eps < Self.homeZoneMaxX && y - eps > Self.bottomZoneMinY
    }

    /// True when a tap location falls in the bottom-right zone
    /// (Exit). Same strict-below-y = 0.75 rule as the other bottom
    /// zones. False until the size is known — and always false
    /// when the TV has no exit key (v1.0.78): the zone is plain
    /// pad there, not an Exit tap.
    func isExitZone(_ location: CGPoint) -> Bool {
        guard supportsExit, size.width > 0, size.height > 0 else { return false }
        let x = location.x / size.width
        let y = location.y / size.height
        let eps: CGFloat = 1e-9
        return x + eps >= Self.homeZoneMaxX && y - eps > Self.bottomZoneMinY
    }

    /// True when a tap location falls in the top-left zone
    /// (Source). The top strip starts strictly above y = 0.25,
    /// so it never overlaps the mute zone — a tap exactly on the
    /// shared y = 0.25 line is a mute tap (x >= 0.67) or no zone
    /// at all, never a source tap. False until the size is known.
    func isSourceZone(_ location: CGPoint) -> Bool {
        guard size.width > 0, size.height > 0 else { return false }
        let x = location.x / size.width
        let y = location.y / size.height
        let eps: CGFloat = 1e-9
        return x - eps < Self.sourceZoneMaxX && y + eps < Self.sourceZoneMaxY
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

/// One finger position on the trail (v1.0.44): where the finger
/// was, and when. Points live 0.25s (v1.0.59, was 0.8s): a short
/// tail right behind the finger, like the iOS keyboard swipe
/// trail — visible while swiping, decaying as time goes on even
/// mid-drag, and gone almost immediately after lift.
struct TrailPoint {
    /// How long a trail point lives. The single lifetime for
    /// both styles: Line's tail shortens as points age out,
    /// and Dots fade/shrink to nothing within it.
    static let lifetime: TimeInterval = 0.25
    var point: CGPoint
    var time: Date
}

/// One resampled point on a smoothed trail stroke: the position
/// on the curve and the time it was touched, so the tail can
/// taper and fade by age.
struct SmoothedTrailPoint {
    var point: CGPoint
    var time: Date
}

/// QuickPath-style smoothing (v1.0.55): resamples a stroke's
/// points through a Catmull-Rom spline into a smooth continuous
/// curve, ~6pt apart, passing through the first and last points
/// exactly — the iOS keyboard swipe-to-type line, not a polyline
/// of straight segments. Pure, so tests can drive it directly.
/// Times are interpolated along each segment, so the tail still
/// knows its age. Long strokes are capped at 40 samples so the
/// tapered render stays cheap.
enum TrailSmoothing {
    static func smoothStroke(_ stroke: [TrailPoint], step: CGFloat = 6) -> [SmoothedTrailPoint] {
        guard stroke.count >= 2 else {
            return stroke.map { SmoothedTrailPoint(point: $0.point, time: $0.time) }
        }
        var out: [SmoothedTrailPoint] = []
        for i in 0..<(stroke.count - 1) {
            let p0 = stroke[max(0, i - 1)].point
            let p1 = stroke[i].point
            let p2 = stroke[i + 1].point
            let p3 = stroke[min(stroke.count - 1, i + 2)].point
            let len = hypot(p2.x - p1.x, p2.y - p1.y)
            let samples = max(1, Int(len / step))
            for s in 0..<samples {
                let t = CGFloat(s) / CGFloat(samples)
                let point = catmullRom(p0: p0, p1: p1, p2: p2, p3: p3, t: t)
                // Skip near-duplicates (a held finger samples the
                // same spot): a zero-length segment would draw a
                // stray round-cap dot.
                if let last = out.last,
                   hypot(point.x - last.point.x, point.y - last.point.y) < 0.5 { continue }
                out.append(SmoothedTrailPoint(
                    point: point,
                    time: stroke[i].time.addingTimeInterval(stroke[i + 1].time.timeIntervalSince(stroke[i].time) * Double(t))))
            }
        }
        let last = SmoothedTrailPoint(point: stroke.last!.point, time: stroke.last!.time)
        if let prev = out.last, hypot(last.point.x - prev.point.x, last.point.y - prev.point.y) < 0.5 {
            out[out.count - 1] = last
        } else {
            out.append(last)
        }
        guard out.count > 40 else { return out }
        let stride = Double(out.count - 1) / 39.0
        var capped: [SmoothedTrailPoint] = (0..<39).map { out[Int(Double($0) * stride)] }
        capped.append(out.last!)
        return capped
    }

    /// One point on a Catmull-Rom spline through p0…p3 at
    /// parameter t (0 at p1, 1 at p2).
    static func catmullRom(p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint, t: CGFloat) -> CGPoint {
        let t2 = t * t
        let t3 = t2 * t
        let x = catmullRomAxis(p0: p0.x, p1: p1.x, p2: p2.x, p3: p3.x, t: t, t2: t2, t3: t3)
        let y = catmullRomAxis(p0: p0.y, p1: p1.y, p2: p2.y, p3: p3.y, t: t, t2: t2, t3: t3)
        return CGPoint(x: x, y: y)
    }

    /// One axis of the Catmull-Rom spline.
    static func catmullRomAxis(p0: CGFloat, p1: CGFloat, p2: CGFloat, p3: CGFloat, t: CGFloat, t2: CGFloat, t3: CGFloat) -> CGFloat {
        0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 + (-p0 + 3 * p1 - 3 * p2 + p3) * t3)
    }
}

/// One tap ripple (v1.0.64): a small circle at the tap point
/// that expands slightly and fades out — the visible mark a tap
/// leaves, in the pad's theme color. Purely visual, separate
/// from the drag trail: it shows even with the trail Off.
struct TapRipple: Identifiable {
    /// Total life: 0.35s — quick enough to read as a tap, long
    /// enough to see.
    static let lifetime: TimeInterval = 0.35
    /// Diameter: 14pt fresh, expanding slightly to 30pt by the
    /// end of its life. Pure, so tests drive it directly.
    static let startDiameter: CGFloat = 14
    static let endDiameter: CGFloat = 30
    /// Peak opacity at birth.
    static let startOpacity: Double = 0.5

    static func diameter(at age: TimeInterval) -> CGFloat {
        let p = min(1, max(0, age / lifetime))
        return startDiameter + (endDiameter - startDiameter) * CGFloat(p)
    }

    static func opacity(at age: TimeInterval) -> Double {
        let p = min(1, max(0, age / lifetime))
        return startOpacity * (1 - p)
    }

    let id = UUID()
    var location: CGPoint
    var born: Date
}

/// The tap ripples (v1.0.64), drawn in the pad's own coordinates.
/// A TimelineView drives the animation — each ripple's size and
/// opacity come from its age, so there is no per-ripple state to
/// animate. Mounted only while a ripple is alive (the pad gates
/// it on ripples.isEmpty), so there is no animation cost at rest.
struct TapRippleOverlay: View {
    var ripples: [TapRipple]
    var color: Color = .white

    var body: some View {
        TimelineView(.animation) { timeline in
            ZStack {
                ForEach(ripples) { ripple in
                    let age = timeline.date.timeIntervalSince(ripple.born)
                    if age <= TapRipple.lifetime {
                        Circle()
                            .fill(color.opacity(TapRipple.opacity(at: age)))
                            .frame(width: TapRipple.diameter(at: age), height: TapRipple.diameter(at: age))
                            .position(ripple.location)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// The finger trail (v1.0.44, styles in v1.0.46), drawn in the
/// pad's own coordinates. Each touch is its own stroke (v1.0.47):
/// lifting and touching elsewhere starts a new streak instead of
/// drawing a connector line across the pad. Line is the QuickPath
/// line (v1.0.55, renamed from Glow in v1.0.58): the stroke is
/// smoothed into a continuous curve and drawn as one thin path,
/// so it reads as a single smooth line with no dots along it.
/// Dots is a row of circles that shrink and fade with age. Off
/// draws nothing. Fades as a whole after lift (see trailOpacity).
/// Everything is very faint — just enough to know the touch
/// registered.
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
            case .line:
                // Line (v1.0.58, was Glow): one continuous thin
                // line per stroke. The old render stroked every
                // ~6pt segment on its own with round caps, so the
                // wide halo caps read as a row of dots all along
                // the line. A single Path through the smoothed
                // points, stroked once, has round caps only at
                // its two ends: thin, smooth, continuous, no
                // dots. The soft under-stroke gives it the faint
                // glow; the tail still fades because points age
                // out after 0.25s and the whole overlay fades on
                // lift. A stroke of fewer than two points (a tap
                // with no drag) draws nothing.
                ForEach(strokes.indices, id: \.self) { i in
                    let points = TrailSmoothing.smoothStroke(strokes[i]).map(\.point)
                    if points.count >= 2 {
                        linePath(points)
                            .stroke(color.opacity(0.07), style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
                        linePath(points)
                            .stroke(color.opacity(0.28), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    }
                }
            case .dots:
                ForEach(strokes.indices, id: \.self) { i in
                    ForEach(strokes[i].indices, id: \.self) { j in
                        let point = strokes[i][j]
                        let age = Date().timeIntervalSince(point.time)
                        Circle()
                            .fill(color.opacity(0.35 * max(0, 1 - age / TrailPoint.lifetime)))
                            .frame(width: dotSize(age), height: dotSize(age))
                            .position(point.point)
                    }
                }
            }
        }
        .opacity(opacity)
        .allowsHitTesting(false)
    }

    /// One continuous path through a stroke's smoothed points,
    /// for the Line render: a single stroke, so the line is
    /// smooth end to end with no beads at the sample points.
    private func linePath(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        return path
    }

    /// A dot's size by age: 12pt fresh, shrinking to 3pt by the
    /// end of the point's life.
    private func dotSize(_ age: TimeInterval) -> CGFloat {
        max(3, 12 - age * (9 / TrailPoint.lifetime))
    }
}

/// Source glyph (v1.0.62): the TV-input icon, drawn with
/// explicit shapes — a screen with a bold arrow pointing into
/// it from the top-right, the classic "change input" pictogram.
/// v1.0.60's SF Symbol (`rectangle.and.arrow.up.right`)
/// rendered as a blank circle on device (that name doesn't
/// exist), and v1.0.61's drawn version looked horrible on
/// device: 1.75pt strokes, a 14x10 screen floating in the
/// frame, and a stroked two-barb arrowhead that read as a
/// squiggle. This redraw keeps the same concept but fills
/// the 20pt frame — a 16x11.5 screen on 2.75pt strokes and a
/// thick shaft ending in a FILLED triangular arrowhead, so
/// it matches the bold SF Symbols in the other zones at a
/// glance. Shapes always render, no symbol name to trust.
struct SourceGlyph: View {
    var tint: Color

    var body: some View {
        ZStack {
            // Screen, lower-left, filling most of the frame.
            RoundedRectangle(cornerRadius: 2.5)
                .stroke(tint, lineWidth: 2.75)
                .frame(width: 16, height: 11.5)
                .offset(x: -1.75, y: 4.25)
            // Bold arrow entering from the top-right, pointing
            // down-left into the screen: thick shaft, round
            // cap, and a filled arrowhead whose tip lands just
            // inside the screen's top edge.
            Path { path in
                path.move(to: CGPoint(x: 19.5, y: 0.5))
                path.addLine(to: CGPoint(x: 11.5, y: 8.5))
            }
            .stroke(tint, style: StrokeStyle(lineWidth: 2.75, lineCap: .round))
            Path { path in
                path.move(to: CGPoint(x: 10.5, y: 9.5))
                path.addLine(to: CGPoint(x: 17.2, y: 7.7))
                path.addLine(to: CGPoint(x: 12.3, y: 2.8))
                path.closeSubpath()
            }
            .fill(tint)
        }
        .frame(width: 20, height: 20)
    }
}

/// Zone overlay (v1.0.56): faint lines separating the pad's
/// double-tap zones, with an icon in each one — mute top-right,
/// back / home / exit along the bottom. The direction hints
/// (v1.0.58 swipe arrows + tap-OK chip) were removed in v1.0.59:
/// the pad is self-explanatory without them, and the right
/// arrow cut into the mute zone's line. Purely visual:
/// `.allowsHitTesting(false)`,
/// so taps, swipes, holds and double-taps pass straight through
/// to the pad underneath. The lines come straight from PadGeometry's
/// zone constants, so they sit exactly on the real tap boundaries;
/// the icons reuse the help sheet's icon + tint pairs. Guide-only:
/// all of it renders only while the overlay is toggled on — the
/// plain pad stays clean.
struct PadZoneOverlay: View {
    var size: CGSize
    /// Whether the connected TV has a real exit key (v1.0.78):
    /// when false the Exit icon is left out — the bottom-right
    /// is plain pad there. The divider lines stay as they are:
    /// the x = 2/3 line is still Home's right edge, a real
    /// boundary either way.
    var supportsExit: Bool = true

    var body: some View {
        ZStack {
            if size.width > 0, size.height > 0 {
                zoneLines
                ForEach(zonesShown, id: \.self) { zone in
                    if let center = PadGeometry(size: size).center(of: zone) {
                        zoneIcon(zone)
                            .position(center)
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// The zones that get an icon: everything, except Exit on
    /// TVs without a real exit key (v1.0.78).
    private var zonesShown: [PadZone] {
        supportsExit
            ? [.mute, .source, .back, .home, .exit]
            : [.mute, .source, .back, .home]
    }

    /// The divider lines: the mute zone's left and top edges,
    /// the shared y = 0.75 line across the whole pad (mute
    /// zone's bottom edge and the bottom strip's top edge in
    /// one), the two verticals splitting the bottom strip
    /// into thirds, and the source zone's edges — the y = 0.25
    /// line across the left third and the vertical splitting
    /// the top strip at x = 1/3. Primary at low opacity, so the
    /// lines read faint on both the light and the dark pad.
    private var zoneLines: some View {
        Path { path in
            let w = size.width, h = size.height
            // Mute zone: left edge, then top edge.
            path.move(to: CGPoint(x: PadGeometry.muteZoneMinX * w, y: PadGeometry.muteZoneMinY * h))
            path.addLine(to: CGPoint(x: PadGeometry.muteZoneMinX * w, y: PadGeometry.muteZoneMaxY * h))
            path.move(to: CGPoint(x: PadGeometry.muteZoneMinX * w, y: PadGeometry.muteZoneMinY * h))
            path.addLine(to: CGPoint(x: w, y: PadGeometry.muteZoneMinY * h))
            // Shared y = 0.75 line, full width.
            path.move(to: CGPoint(x: 0, y: PadGeometry.bottomZoneMinY * h))
            path.addLine(to: CGPoint(x: w, y: PadGeometry.bottomZoneMinY * h))
            // Bottom strip thirds.
            path.move(to: CGPoint(x: PadGeometry.backZoneMaxX * w, y: PadGeometry.bottomZoneMinY * h))
            path.addLine(to: CGPoint(x: PadGeometry.backZoneMaxX * w, y: h))
            path.move(to: CGPoint(x: PadGeometry.homeZoneMaxX * w, y: PadGeometry.bottomZoneMinY * h))
            path.addLine(to: CGPoint(x: PadGeometry.homeZoneMaxX * w, y: h))
            // Source zone: bottom edge (y = 0.25, left third only)
            // and right edge (x = 1/3, top quarter only).
            path.move(to: CGPoint(x: 0, y: PadGeometry.sourceZoneMaxY * h))
            path.addLine(to: CGPoint(x: PadGeometry.sourceZoneMaxX * w, y: PadGeometry.sourceZoneMaxY * h))
            path.move(to: CGPoint(x: PadGeometry.sourceZoneMaxX * w, y: 0))
            path.addLine(to: CGPoint(x: PadGeometry.sourceZoneMaxX * w, y: PadGeometry.sourceZoneMaxY * h))
        }
        .stroke(Color.primary.opacity(0.25), lineWidth: 1)
    }

    /// One zone's icon: the help sheet's icon + tint, on a
    /// faint tinted chip so it reads on any pad color or cover
    /// photo. Small on purpose — the pad stays a pad, not a
    /// legend. Source draws its own glyph (v1.0.62 redraw):
    /// the v1.0.60 SF Symbol rendered as a blank circle on
    /// device, and the v1.0.61 drawn version was too thin, so
    /// the screen-with-arrow is drawn big and bold with
    /// explicit shapes (see SourceGlyph above).
    @ViewBuilder
    private func zoneIcon(_ zone: PadZone) -> some View {
        if zone == .source {
            SourceGlyph(tint: .teal)
                .frame(width: 34, height: 34)
                .background(Color.teal.opacity(0.15), in: Circle())
        } else {
            let (icon, tint): (String, Color) = {
                switch zone {
                case .mute: return ("speaker.slash.fill", .red)
                case .back: return ("arrow.left", .orange)
                case .home: return ("house", .purple)
                case .exit: return ("rectangle.portrait.and.arrow.right", .pink)
                case .source: return ("", .teal) // unreachable: handled above
                }
            }()
            Image(systemName: icon)
                .font(.subheadline.bold())
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.15), in: Circle())
        }
    }
}


/// Big swipe pad (the Swipe half of the toggle): near full-width,
/// a bare pad — no chevrons, no hand icon, no label.
/// One drag is one command on release (tap = select) — the same
/// gesture as the old touchpad, only the size and the look changed.
/// Modes (decided by the pure SwipePadGesture above):
/// - Quick tap: exactly one OK press on lift; quick double-tap two.
/// - Single tap held past the 0.3s onset: the OK key goes DOWN at
///   onset and UP on lift — no enter on lift (v1.0.25).
/// - Double-tap held past onset: spams OK presses (first repeat at
///   onset, then one every 0.12s) until lift (v1.0.25).
/// - Swipe: the first directional press fires at once, and held past
///   onset it repeats that same direction every 0.12s until lift;
///   a quick swipe-and-lift is still exactly one press (v1.0.27).
///   Swiping out of a hold releases the key first, so a key is never
///   left stuck down.
/// - Mute zone (v1.0.34): a double-tap on the middle-right of the pad
///   mutes/unmutes; the middle keeps its taps and holds exactly as
///   before — the zone never starts a hold, and a swipe starting in
///   it is still a swipe.
/// - Bottom zones (v1.0.55): a double-tap on the bottom-left goes
///   Back, bottom-middle goes Home, bottom-right Exits — the same
///   pattern as the mute zone, and a single tap in any zone is
///   still OK. The on-screen Back / Home / Exit buttons are gone:
///   they live in the pad now.
/// The height comes from the layout so the pad fits the
/// non-scrollable page on small phones.
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
    /// Zone overlay toggle (v1.0.56): when true the pad draws
    /// the faint zone lines + icons on top (PadZoneOverlay).
    /// A plain value from RemoteView — @State there, not
    /// persisted: it resets when the remote closes.
    var showZones: Bool
    /// Whether the connected TV has a real exit key (v1.0.78):
    /// from the session's capabilities. When false the
    /// bottom-right double-tap zone is plain pad and the Exit
    /// icon and guide card are hidden.
    var supportsExit: Bool

    /// Explicit init (v1.0.53): the synthesized memberwise init is
    /// private to this file because of the private @State /
    /// @AppStorage properties below, so RemoteView in ContentView.swift
    /// needs this to construct the pad.
    init(height: CGFloat, onCommand: @escaping (RemoteCommand, Bool) -> Void, onRepeatCommand: @escaping (RemoteCommand, Bool) -> Void, onCancelRepeats: @escaping () -> Void, isKeyboardOpen: Bool, onDismissKeyboard: @escaping () -> Void, showZones: Bool, supportsExit: Bool) {
        self.height = height
        self.onCommand = onCommand
        self.onRepeatCommand = onRepeatCommand
        self.onCancelRepeats = onCancelRepeats
        self.isKeyboardOpen = isKeyboardOpen
        self.onDismissKeyboard = onDismissKeyboard
        self.showZones = showZones
        self.supportsExit = supportsExit
    }

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
    /// never tilted and the mute zone never matched a tap.
    /// (v1.0.58: the size used to be remembered in UserDefaults
    /// for the cover cropper, but the stored measurement went
    /// stale whenever Settings opened before the remote — the
    /// cropper now computes the pad's aspect from the layout
    /// math instead, so nothing writes it anymore.)
    private func setPadSize(_ size: CGSize) {
        // Only write on change: onAppear fires on every appear and
        // the geometry fires on every layout pass, so an unconditional
        // write churned UserDefaults (and re-rendered the pad) for
        // the same size.
        guard size != padSize else { return }
        padSize = size
    }
    /// Press feedback (v1.0.34, retuned in v1.0.47 and v1.0.51,
    /// simplified in v1.0.52 — the tilt does the talking now: 4°
    /// toward the finger (v1.0.58: back from 6° — his field test
    /// found 6° still slightly too strong), scale barely 0.995 — so a tap reads
    /// as a tilt, not a press inward): while a finger is down the pad
    /// dips toward it and springs back on lift.
    @State private var isPressed = false
    @State private var pressLocation: CGPoint? = nil
    /// Finger trail (v1.0.44): a short faint line that follows the
    /// finger across the pad and fades shortly after lift, so the
    /// pad feels alive to touch. Points older than 0.25s drop off
    /// while dragging; on lift the whole trail fades out. One
    /// stroke per touch (v1.0.47): lifting and touching elsewhere
    /// starts a new streak — the strokes never connect.
    @State private var trail: [[TrailPoint]] = []
    @State private var trailStrokeOpen = false
    @State private var trailOpacity: Double = 1
    @State private var trailFadeTask: Task<Void, Never>?
    /// Tap ripples (v1.0.64, tap-only v1.0.67): one small
    /// expanding/fading circle per tap — the visible mark a tap
    /// leaves. Spawned on lift, only when the touch was a tap
    /// (never while dragging). Purely visual; pruned on spawn
    /// and by a delayed cleanup, so nothing lingers.
    @State private var ripples: [TapRipple] = []
    /// Settings (v1.0.46), read live so the pad re-renders when
    /// they change: color theme, border effect, trail style.
    @AppStorage("padTheme") private var padThemeRaw = "midnight"
    @AppStorage("padBorder") private var padBorderRaw = "glow"
    @AppStorage("trailStyle") private var trailStyleRaw = "line"
    /// Pad cover art (v1.0.50): bumped whenever the cover is
    /// set, re-cropped, or removed, so the pad re-renders.
    @AppStorage("padCoverVersion") private var coverVersion = 0
    private var theme: PadTheme { PadTheme(rawValue: padThemeRaw) ?? .midnight }
    private var borderEffect: PadBorder { PadBorder(rawValue: padBorderRaw) ?? .glow }
    private var trailStyle: TrailStyle { TrailStyle(rawValue: trailStyleRaw) ?? .line }
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
    private var padGeometry: PadGeometry { PadGeometry(size: padSize, supportsExit: supportsExit) }

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
            // Bounded to the pad (v1.0.58): scaledToFill on its
            // own sizes the image LARGER than the frame in the
            // overflow dimension, and the clipShape below sizes
            // to the image, not the pad — so a cover whose aspect
            // didn't match the pad spilled past the pad's border
            // (photo wider than the pad, text cut off at the
            // screen edges). An explicit frame at the pad's live
            // size + .clipped() confines the photo to the pad,
            // whatever the saved image's aspect.
            .overlay(
                Group {
                    if let cover = PadCoverStore.image(for: coverVersion) {
                        GeometryReader { geo in
                            Image(uiImage: cover)
                                .resizable()
                                .scaledToFill()
                                .frame(width: geo.size.width, height: geo.size.height)
                                .clipped()
                        }
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
            // Tap ripple (v1.0.64): a small expanding/fading circle
            // at each tap point — the visible mark a tap leaves, in
            // the theme accent. Separate from the drag trail, so it
            // shows even with the trail Off. Mounted only while a
            // ripple is alive, so there is no animation cost at
            // rest. Clipped to the rounded corners like the trail.
            .overlay(
                Group {
                    if !ripples.isEmpty {
                        TapRippleOverlay(ripples: ripples, color: colorScheme == .light ? theme.accent : .white)
                            .clipShape(RoundedRectangle(cornerRadius: 24))
                    }
                }
            )
            // Zone overlay (v1.0.56): faint zone lines + icons,
            // shown on demand from the remote's top bar. Purely
            // visual — .allowsHitTesting(false) inside — so taps,
            // swipes, holds and double-taps pass straight through.
            .overlay(
                Group {
                    if showZones {
                        PadZoneOverlay(size: padSize, supportsExit: supportsExit)
                            .clipShape(RoundedRectangle(cornerRadius: 24))
                    }
                }
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
                        // Tap ripple (v1.0.64, tap-only v1.0.67):
                        // NOT spawned here — a touch that starts
                        // still and then drags is a swipe, and the
                        // ripple must never show while dragging.
                        // It spawns on lift, in onEnded, only when
                        // the touch never moved past the tap slop.
                        // Purely visual: it never emits a command.
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
                            // a zone, the zone's action vs enter);
                            // start the hold timer when it says
                            // this is a tap that can be held.
                            cancelWindowTask()
                            let down = gesture.touchDown(inZone: padGeometry.zone(at: value.location))
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
                        // Tap ripple (v1.0.67): only on a tap, never
                        // while dragging. The gesture classifies a
                        // touch as a swipe by the same rule — the
                        // lift translation past the tap slop — so
                        // the ripple matches what the pad did: a
                        // tap (or tap-and-hold, which never moved)
                        // ripples at the lift point; a swipe never
                        // does. Each tap of a double-tap ripples.
                        if abs(value.translation.width) < Self.tapSlop, abs(value.translation.height) < Self.tapSlop {
                            spawnRipple(at: value.location)
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
        ripples.removeAll()
        cancelHoldTask()
        onCancelRepeats()
        cancelWindowTask()
        gesture.reset()
    }

    /// Spawns a tap ripple (v1.0.64, tap-only v1.0.67): a small
    /// circle at the touch point that expands slightly and fades
    /// out over 0.35s. Called on lift only, when the touch was a
    /// tap — never while dragging. Expired ripples are pruned on
    /// spawn, and a delayed cleanup removes this one — no
    /// lingering state. The cleanup runs on the main actor:
    /// @State must never mutate off it.
    private func spawnRipple(at location: CGPoint) {
        let now = Date()
        ripples.removeAll { now.timeIntervalSince($0.born) > TapRipple.lifetime }
        let ripple = TapRipple(location: location, born: now)
        ripples.append(ripple)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            ripples.removeAll { $0.id == ripple.id }
        }
    }

    /// Records one finger position for the trail (v1.0.44): points
    /// older than TrailPoint.lifetime drop off, so the tail
    /// shortens behind the finger, and points closer than 4pt to
    /// the last one are skipped. The prune runs on every touch
    /// event, before the 4pt guard — so old points age out while
    /// the finger is still moving, and at any moment only a
    /// short tail right behind the finger is visible, never a
    /// long line spanning the pad. A new touch cancels any fade
    /// in flight. Each touch is its own stroke (v1.0.47): lifting
    /// and touching elsewhere starts a new streak — the strokes
    /// never connect.
    private func addTrailPoint(_ location: CGPoint) {
        trailFadeTask?.cancel()
        trailFadeTask = nil
        trailOpacity = 1
        let now = Date()
        // Drop points older than the lifetime, and strokes that emptied.
        trail = trail.map { stroke in stroke.filter { now.timeIntervalSince($0.time) <= TrailPoint.lifetime } }
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

    /// Fades the trail out after lift (v1.0.44, quickened in
    /// v1.0.59): a short 0.05s beat, then fades over 0.2s and
    /// clears — the line is gone almost immediately once the
    /// finger lifts, instead of lingering on the pad.
    private func fadeTrail() {
        trailFadeTask?.cancel()
        trailFadeTask = Task {
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { trailOpacity = 0 }
            try? await Task.sleep(nanoseconds: 200_000_000)
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
            case .back(let haptic):
                if viaPump { onRepeatCommand(.back, haptic) } else { onCommand(.back, haptic) }
            case .home(let haptic):
                if viaPump { onRepeatCommand(.home, haptic) } else { onCommand(.home, haptic) }
            case .exit(let haptic):
                if viaPump { onRepeatCommand(.exit, haptic) } else { onCommand(.exit, haptic) }
            case .source(let haptic):
                if viaPump { onRepeatCommand(.input, haptic) } else { onCommand(.input, haptic) }
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
