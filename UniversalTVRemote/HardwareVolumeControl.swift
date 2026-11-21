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
/// v1.0.28: volume steps go through the coalescing pump instead of
/// one Task per step, so a hold stops the instant the finger lifts
/// and never blocks other keys. That same release added a
/// both-buttons-together mute; v1.0.29 removes that detection
/// entirely — Nick found pressing both buttons at once awkward —
/// and the on-screen mute button is back instead. The pump stays
/// exactly as it is.
///
/// v1.0.26 diagnosis (full post-mortem in git history): the anchor
/// was assumed, never verified (the slider is created lazily and
/// may not exist at .onAppear, so presses read against a phantom
/// 0.5); the MPVolumeView was 1×1 at opacity 0.01 (marginal for
/// the slider ever being created); and activation errors were
/// swallowed and never retried. Fixed: the tracker holds the
/// phone's real volume and re-bases only when the reset actually
/// moved the slider, the view is real-sized (200×44) and reports
/// readiness, and activation is retried on every start with
/// failures surfaced in the diagnostic line.
/// v1.0.77: the capture layer is rebuilt around one lesson from
/// v1.0.68 — the hidden MPVolumeView must be OPAQUE. v1.0.68 set
/// it to opacity 0 to kill the ghost, and a fully transparent
/// MPVolumeView is dead to iOS: its slider is never created, the
/// system HUD is no longer suppressed, and the anchor reset never
/// lands, so the phone volume saturates after ~10 presses and the
/// buttons stop working in both directions (and the old "volume
/// down does nothing on the QM7" note was this same bug, not the
/// TV — up and down travel the identical key path). The view is
/// now parked offscreen at full opacity instead, and a failed
/// anchor reset surfaces in the diagnostic line the moment it
/// happens instead of failing silently.
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
    /// hierarchy. Opaque and offscreen (v1.0.77) — never opacity 0:
    /// a fully transparent MPVolumeView is dead to iOS (no slider,
    /// no HUD suppression, no anchor reset); see ContentView.
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
        if !resetOk {
            // The anchor is the only thing standing between the
            // buttons and saturation: without it the phone volume
            // walks to an extreme in ~10 presses and that
            // direction stops firing KVO at all (v1.0.77 — the
            // v1.0.68 opacity-0 view starved the slider). Say so
            // in the diagnostic line right away instead of failing
            // silently; refreshCaptureIssue otherwise only runs at
            // start and on appear, which is too late once presses
            // are live.
            refreshCaptureIssue()
        }
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

/// Coalescing pump (v1.0.53 — the v1.0.28 VolumePump and the
/// v1.0.34 RepeatPump, merged: they were the same machine with a
/// different payload). Hardware volume steps and pad repeat presses
/// funnel through ONE pump each instead of spawning one Task per
/// step/press. The bugs it fixes: every volume step spawned its own
/// `Task { await session.send(...) }`, and Samsung's throttle
/// reserves a 200 ms slot per call, so a 3 s hold queued seconds of
/// slots that drained long after release — and every other key
/// queued behind them. The repeat loop had the same shape: a press
/// every 0.12s, but each send takes longer than that to land, so
/// presses piled up in flight and kept arriving for seconds after
/// the finger lifted.
///
/// The pump keeps exactly one pending value (the latest wins) plus
/// one in-flight send. A hold therefore sends at the TV's own pace
/// — one step per send — and the moment the finger lifts, no new
/// value arrives, the in-flight send finishes, the loop finds
/// nothing pending and stops: at most one step of overshoot, never
/// a catch-up backlog. Non-pumped commands never touch a pump, so
/// a pad tap waits behind at most one pumped send, not a whole
/// hold's worth.
///
/// Pure enough to unit-test: the actual send is injected
/// (RemoteSession wires the Bool pump to `send(.volumeUp/.volumeDown)`
/// and the RemoteCommand pump to `send(_:)`).
@MainActor
final class CoalescingPump<T> {
    /// The actual send: one pumped value to the TV. Nil until
    /// RemoteSession wires it (tests set a fake).
    var send: ((T) async -> Void)?

    private var pending: T?
    private var pumping = false

    /// True while a pump run is in progress (a send is in flight,
    /// or a pending value is waiting on it).
    var isPumping: Bool { pumping }

    /// One step/press: remember the latest value and make sure the
    /// pump is running. Values arriving while a send is in flight
    /// just overwrite the single pending slot — they never spawn a
    /// task, never reserve a throttle slot.
    func enqueue(_ value: T) {
        pending = value
        guard !pumping else { return }
        pumping = true
        Task { await run() }
    }

    /// Drop the pending value, if any. The in-flight send (if one)
    /// still finishes — it is already on the wire — but nothing
    /// further goes out. Called on finger lift / disconnect, so no
    /// step or press fires after the hold is over or the remote
    /// is gone.
    func cancel() {
        pending = nil
    }

    private func run() async {
        while true {
            if let value = pending {
                pending = nil
                await send?(value)
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
/// for real. The coordinator's flag is what makes it once: the view
/// can be recreated (state changes re-evaluate the background), and
/// every makeUIView would otherwise re-fire the anchor.
struct HiddenVolumeView: UIViewRepresentable {
    let volumeView: MPVolumeView
    var onReady: (() -> Void)?

    final class Coordinator {
        var fired = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MPVolumeView {
        DispatchQueue.main.async {
            guard !context.coordinator.fired else { return }
            context.coordinator.fired = true
            onReady?()
        }
        return volumeView
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
