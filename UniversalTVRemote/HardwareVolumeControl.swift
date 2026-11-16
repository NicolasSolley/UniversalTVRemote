import AVFoundation
import MediaPlayer
import SwiftUI

/// The iPhone's hardware volume buttons drive the TV's volume while the
/// remote is on screen (v1.0.23, fixed in v1.0.26) — the physical
/// buttons instead of the on-screen rocker, which is gone.
///
/// The standard iOS approach:
/// - An active AVAudioSession + KVO on `outputVolume` sees every
///   hardware press as a volume change; the sign of the delta is the
///   direction, and holding a button keeps the events coming, so a
///   hold keeps stepping the TV volume.
/// - A hidden MPVolumeView in the view hierarchy suppresses the
///   system volume HUD while the remote is up.
/// - After every step the system volume is reset to the anchor
///   (0.5), so both directions always have room even if the user's
///   phone volume was at an extreme. The reset's own KVO echo is
///   ignored: it reads as zero delta from the anchor.
/// - The user's original phone volume is restored when the remote
///   closes.
/// Scoped strictly to the remote view: started in RemoteView's
/// .onAppear, stopped in .onDisappear (and on backgrounding via
/// scenePhase) — the buttons do nothing on the Devices screen, and
/// nothing when the app is backgrounded. No haptics: the button
/// press itself and the TV's volume change are the feedback.
///
/// v1.0.28: volume steps go through the coalescing VolumePump
/// instead of one Task per step, so a hold stops the instant the
/// finger lifts and never blocks other keys. That same release
/// added a both-buttons-together mute (a near-simultaneous
/// opposite-direction pair in the KVO stream); v1.0.29 removes
/// that detection entirely — Nick found pressing both buttons at
/// once awkward — and the on-screen mute button is back instead.
/// The pump stays exactly as it is.
///
/// v1.0.26 diagnosis — why v1.0.23 didn't work in LiveContainer:
/// 1. The anchor was assumed, never verified. `start()` set
///    lastVolume = 0.5 and tried to move the system volume there,
///    but the MPVolumeView's slider is created lazily and may not
///    exist yet when .onAppear fires — so the anchor silently never
///    landed while lastVolume still claimed 0.5. Every press was
///    then measured against a phantom 0.5 instead of the phone's
///    real volume, so presses read the wrong direction (phone at
///    max, press down → delta from 0.5 reads as UP). The tracker
///    below now always holds the phone's REAL volume: it starts at
///    the actual outputVolume, and after a step it re-bases to the
///    anchor ONLY when the reset actually moved the slider. If the
///    slider is missing, tracking stays correct — only the range
///    anchor is lost (up does nothing at max, down at min, like
///    the phone itself).
/// 2. The MPVolumeView was 1×1 at opacity 0.01 — the marginal case
///    for the slider ever being created and for the system to treat
///    the view as the volume display (HUD suppression). It is now
///    a real-sized view (200×44, still near-invisible and
///    touch-disabled) that reports when it is in the hierarchy so
///    the anchor can be applied then.
/// 3. Audio-session activation errors were swallowed and never
///    retried: `start()` early-returned once `started` was true, so
///    a failed activation stayed failed. Without an active session
///    (and nothing playing) the buttons adjust the ringer, not
///    outputVolume, so the KVO never fires at all. Activation is
///    now retried on every start / return to foreground, and a
///    failure is surfaced in the diagnostic line instead of
///    vanishing.
final class HardwareVolumeController: NSObject, ObservableObject {
    /// Called with true for up, false for down. Runs on the main actor.
    var onStep: ((Bool) -> Void)?

    /// One short line for the remote's diagnostic area when volume
    /// capture is degraded (nil when healthy): audio-session
    /// activation failed, or the MPVolumeView slider is missing.
    @Published var captureIssue: String?

    /// The hidden MPVolumeView that must sit in the view hierarchy —
    /// it suppresses the system volume HUD. Created once; the SwiftUI
    /// side embeds this exact instance. Touch-disabled: the slider is
    /// only ever driven programmatically, and the view must never
    /// swallow touches meant for the swipe pad, which it would
    /// otherwise sit on top of (it lives in the remote view's
    /// background). HUD suppression only needs the view in the
    /// hierarchy.
    let volumeView: MPVolumeView = {
        let view = MPVolumeView()
        view.showsRouteButton = false
        view.isUserInteractionEnabled = false
        return view
    }()

    private let audioSession = AVAudioSession.sharedInstance()
    private var observation: NSKeyValueObservation?
    private var originalVolume: Float = 0.5
    private var tracker = VolumeStepTracker(startingVolume: 0.5)
    private var started = false
    private var sessionActive = false
    private var viewReady = false

    /// Mid-point anchor: both directions always have room.
    private static let anchorVolume: Float = 0.5
    /// iOS volume steps are 1/16 (0.0625); anything smaller is noise
    /// or the reset echo, which reads as exactly zero delta.
    private static let stepEpsilon: Float = 0.01

    /// Pure direction test (unit-testable): nil means "not a step".
    static func direction(from old: Float, to new: Float) -> Bool? {
        let delta = new - old
        guard abs(delta) > stepEpsilon else { return nil }
        return delta > 0
    }

    /// The volume view is in the hierarchy now (called once from
    /// HiddenVolumeView.makeUIView): the slider exists, so the anchor
    /// can finally be applied for real.
    @MainActor
    func volumeViewDidAppear() {
        viewReady = true
        guard started else { return }
        applyAnchor()
        refreshCaptureIssue()
    }

    @MainActor
    func start() {
        if !started {
            started = true
            originalVolume = audioSession.outputVolume
            // lastVolume starts at the phone's REAL volume — the
            // v1.0.23 bug was assuming the 0.5 anchor here before
            // the slider had ever moved anything.
            tracker = VolumeStepTracker(startingVolume: originalVolume)
            observation = audioSession.observe(\.outputVolume, options: [.new]) { [weak self] _, _ in
                guard let self else { return }
                // Serialize all handling on the main actor: KVO can
                // arrive on any thread, and lastVolume/reset must not race.
                Task { @MainActor in
                    self.handleVolumeChange()
                }
            }
        }
        // Activation is retried on every start (and on every return
        // to foreground): a failed setActive in v1.0.23 stayed
        // failed forever because start() early-returned.
        activateSessionIfNeeded()
        applyAnchor()
        refreshCaptureIssue()
    }

    @MainActor
    func stop() {
        guard started else { return }
        started = false
        sessionActive = false
        viewReady = false
        observation?.invalidate()
        observation = nil
        captureIssue = nil
        // Restore the user's phone volume. Observation is already
        // gone, so the restore can't fire a spurious step. Best
        // effort: if the slider never existed, the anchor never
        // moved the volume either, so there is nothing to restore.
        _ = setSystemVolume(originalVolume)
        try? audioSession.setActive(false, options: [.notifyOthersOnDeactivation])
    }

    @MainActor
    private func activateSessionIfNeeded() {
        guard !sessionActive else { return }
        do {
            try audioSession.setCategory(.ambient, options: [.mixWithOthers])
            try audioSession.setActive(true)
            sessionActive = true
        } catch {
            // Without an active session the buttons adjust the
            // ringer instead of outputVolume and the KVO never
            // fires — surface it instead of swallowing it.
            sessionActive = false
            captureIssue = "Vol capture: audio session failed (\(error.localizedDescription))"
        }
    }

    /// Moves the system volume to the anchor and re-bases the tracker
    /// — but ONLY when the slider actually moved. A failed anchor
    /// never leaves lastVolume lying about the real volume.
    @MainActor
    private func applyAnchor() {
        if setSystemVolume(Self.anchorVolume) {
            tracker.noteAnchorApplied()
        }
    }

    @MainActor
    private func handleVolumeChange() {
        let newVolume = audioSession.outputVolume
        // Reset first (its echo arrives as a separate KVO event and
        // reads as zero delta from the anchor, so it is ignored),
        // then read the step against the real previous volume.
        let resetOk = setSystemVolume(Self.anchorVolume)
        guard let up = tracker.step(to: newVolume, resetSucceeded: resetOk) else { return }
        onStep?(up)
    }

    @MainActor
    private func refreshCaptureIssue() {
        if !sessionActive {
            // Kept from activateSessionIfNeeded; a nil here would
            // mean the session failed before start() ever ran, which
            // cannot happen — start() always activates first.
            if captureIssue == nil {
                captureIssue = "Vol capture: audio session inactive"
            }
            return
        }
        // Session is fine: the only remaining degradation is a
        // missing slider (anchor never lands; direction still works,
        // range does not). Only report it once the view has actually
        // appeared — before that the slider legitimately doesn't
        // exist yet.
        if viewReady, volumeSlider() == nil {
            captureIssue = "Vol capture: volume slider missing"
        } else if captureIssue != nil {
            captureIssue = nil
        }
    }

    /// The MPVolumeView's slider — the only programmatic route to
    /// the system volume. Lays the view out first; nil until the
    /// view has been laid out in a window.
    private func volumeSlider() -> UISlider? {
        volumeView.layoutIfNeeded()
        return volumeView.subviews.compactMap({ $0 as? UISlider }).first
    }

    /// Sets the system volume through the slider. Returns whether
    /// the slider existed and was moved — callers must not assume
    /// the volume changed when this is false.
    @discardableResult
    private func setSystemVolume(_ value: Float) -> Bool {
        guard let slider = volumeSlider() else { return false }
        slider.setValue(value, animated: false)
        return true
    }
}

/// Pure step tracking behind the outputVolume KVO (unit-testable, no
/// AVFoundation): `lastVolume` always holds the phone's real volume.
/// A step's direction is the sign of the delta from it; the anchor
/// reset afterwards only re-bases `lastVolume` to 0.5 when the reset
/// actually moved the slider.
struct VolumeStepTracker {
    private(set) var lastVolume: Float

    static let anchor: Float = 0.5

    init(startingVolume: Float) {
        lastVolume = startingVolume
    }

    /// The anchor landed (the slider moved the system volume to
    /// 0.5): future presses are measured from the anchor.
    mutating func noteAnchorApplied() {
        lastVolume = Self.anchor
    }

    /// One outputVolume change. `resetSucceeded` says whether the
    /// system volume was actually moved back to the anchor after
    /// this step. Returns up=true / down=false, or nil for the
    /// reset echo (exactly zero delta) and sub-step noise. On a real
    /// step, lastVolume becomes the anchor when the reset landed,
    /// otherwise the new real volume — never a phantom.
    mutating func step(to newVolume: Float, resetSucceeded: Bool) -> Bool? {
        guard let up = HardwareVolumeController.direction(from: lastVolume, to: newVolume) else { return nil }
        lastVolume = resetSucceeded ? Self.anchor : newVolume
        return up
    }
}

/// The TV's volume level for the HUD slider (v1.0.30). Pure and
/// unit-testable: no AVFoundation, no network.
/// - LG reports the real level (getVolume); every other brand
///   tracks from the steps we send, starting at 50 (unknown) and
///   clamping 0–100. Every brand steps 1 level per volume key
///   (Samsung KEY_VOLUP/VOLDOWN, LG VOLUMEUP/DOWN, Roku
///   VolumeUp/Down, Android TV key 24/25) on a 0–100 scale, so
///   one tracked step is one level.
/// - `isReported` says the level came from the TV itself. A
///   tracked level can drift if the volume moves another way
///   (the TV's own remote, another app) — LG resyncs whenever
///   the slider appears, so its drift never lasts long.
struct TVVolumeLevel {
    private(set) var level: Int
    private(set) var isReported: Bool

    static let minLevel = 0
    static let maxLevel = 100
    /// Starting level when the TV never reported one: a neutral
    /// midpoint. The first real step or LG report replaces it.
    static let unknownLevel = 50

    init(level: Int = unknownLevel, isReported: Bool = false) {
        self.level = min(max(level, Self.minLevel), Self.maxLevel)
        self.isReported = isReported
    }

    /// One volume step actually sent to the TV.
    mutating func noteStep(up: Bool) {
        level = min(max(level + (up ? 1 : -1), Self.minLevel), Self.maxLevel)
    }

    /// The TV reported its real level: adopt it wholesale.
    mutating func setReported(_ newLevel: Int) {
        level = min(max(newLevel, Self.minLevel), Self.maxLevel)
        isReported = true
    }

    /// Steps from here to `target` (clamped 0–100): how many, and
    /// in which direction. (0, _) when already there — the
    /// direction is meaningless at zero steps.
    func steps(to target: Int) -> (count: Int, up: Bool) {
        let clamped = min(max(target, Self.minLevel), Self.maxLevel)
        let delta = clamped - level
        return (abs(delta), delta > 0)
    }
}

/// Coalescing volume pump (v1.0.28): hardware volume steps funnel
/// through ONE pump instead of spawning one Task per step. The
/// v1.0.23–v1.0.27 bug: every step spawned its own
/// `Task { await session.send(...) }`, and Samsung's throttle
/// reserves a 200 ms slot per call, so a 3 s hold queued seconds of
/// slots that drained long after release — and every other key
/// (which also throttles) queued behind them, so the remote did
/// nothing until the volume finished. Roku's serial enqueue chain
/// had the same backlog shape.
///
/// The pump keeps exactly one pending step (the latest direction
/// wins) plus one in-flight send. A hold therefore sends at the
/// TV's own pace — one step per send — and the moment the finger
/// lifts, no new step arrives, the in-flight send finishes, the
/// loop finds nothing pending and stops: at most one step of
/// overshoot, never a catch-up backlog. Non-volume commands never
/// touch the pump, so a pad tap waits behind at most one volume
/// send (~200 ms on Samsung), not a whole hold's worth.
///
/// Pure enough to unit-test: the actual send is injected
/// (RemoteSession wires it to `send(.volumeUp/.volumeDown)`).
@MainActor
final class VolumePump {
    /// The actual send: one volume step to the TV. Nil until
    /// RemoteSession wires it (tests set a fake).
    var send: ((Bool) async -> Void)?

    private var pendingDirection: Bool?
    /// Drive mode (v1.0.30): remaining steps toward a dragged
    /// slider target, in `driveDirection`. A later drive call
    /// replaces the count (retarget); a hardware step cancels the
    /// drive outright (see enqueue). Zero means no drive.
    private var pendingSteps = 0
    private var driveDirection = true
    private var pumping = false

    /// True while a pump run is in progress (a send is in flight,
    /// or a pending step is waiting on it).
    var isPumping: Bool { pumping }

    /// One hardware step: remember the latest direction and make
    /// sure the pump is running. Steps arriving while a send is in
    /// flight just overwrite the single pending slot — they never
    /// spawn a task, never reserve a throttle slot. Cancels any
    /// slider drive in progress: the finger on the button is the
    /// authority, and the drive's target is already stale.
    func enqueue(up: Bool) {
        pendingSteps = 0
        pendingDirection = up
        guard !pumping else { return }
        pumping = true
        Task { await run() }
    }

    /// Drive toward a dragged slider target: send up to `count`
    /// steps in `direction`, one per pump cycle. A later drive call
    /// replaces the remaining count (retarget — dragging to a new
    /// target cancels the steps toward the old one); drive(steps: 0)
    /// stops the drive. A queued (not yet sent) hardware step is
    /// dropped — the drag's absolute target supersedes it — but a
    /// send already on the wire still lands, so the final level can
    /// sit at most one step past the target.
    func drive(steps count: Int, up: Bool) {
        pendingSteps = count
        driveDirection = up
        pendingDirection = nil
        guard count > 0 else { return }
        guard !pumping else { return }
        pumping = true
        Task { await run() }
    }

    /// Drop the pending step and any drive, if any. The in-flight
    /// send (if one) still finishes — it is already on the wire —
    /// but nothing further goes out. Called on disconnect, so no
    /// volume step fires after the remote is gone.
    func cancel() {
        pendingDirection = nil
        pendingSteps = 0
    }

    private func run() async {
        while true {
            if let direction = pendingDirection {
                pendingDirection = nil
                await send?(direction)
            } else if pendingSteps > 0 {
                pendingSteps -= 1
                await send?(driveDirection)
            } else {
                break
            }
        }
        pumping = false
    }
}

/// Embeds the controller's hidden MPVolumeView so it sits in the view
/// hierarchy and suppresses the system volume HUD while the remote is
/// up. Real-sized (200×44, v1.0.26) — MPVolumeView only creates its
/// slider when laid out at a real size — still near-invisible, and it
/// lives in the remote view's background so it takes no layout space.
/// `onReady` fires once, on the main thread, after the view is in
/// the hierarchy and the slider exists, so the anchor can be applied
/// for real.
struct HiddenVolumeView: UIViewRepresentable {
    let volumeView: MPVolumeView
    var onReady: (() -> Void)?

    func makeUIView(context: Context) -> MPVolumeView {
        DispatchQueue.main.async { onReady?() }
        return volumeView
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
