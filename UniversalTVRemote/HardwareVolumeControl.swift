import AVFoundation
import MediaPlayer
import SwiftUI

/// The iPhone's hardware volume buttons drive the TV's volume while the
/// remote is on screen (v1.0.23) — the physical buttons instead of the
/// on-screen rocker, which is gone.
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
///   ignored: `lastVolume` is set to the anchor BEFORE the slider
///   moves, so the echo reads as zero delta.
/// - The user's original phone volume is restored when the remote
///   closes.
/// Scoped strictly to the remote view: started in RemoteView's
/// .onAppear, stopped in .onDisappear (and on backgrounding via
/// scenePhase) — the buttons do nothing on the Devices screen, and
/// nothing when the app is backgrounded. No haptics: the button
/// press itself and the TV's volume change are the feedback.
///
/// LiveContainer caveat (unverified): this is the standard approach
/// for a normal app, but nothing here runs inside LiveContainer's
/// guest sandbox in CI — if the capture doesn't work there, the
/// fallback is restoring the on-screen rocker.
final class HardwareVolumeController: NSObject, ObservableObject {
    /// Called with true for up, false for down. Runs on the main actor.
    var onStep: ((Bool) -> Void)?

    /// The hidden MPVolumeView that must sit in the view hierarchy —
    /// it suppresses the system volume HUD. Created once; the SwiftUI
    /// side embeds this exact instance.
    let volumeView: MPVolumeView = {
        let view = MPVolumeView()
        view.showsRouteButton = false
        return view
    }()

    private let audioSession = AVAudioSession.sharedInstance()
    private var observation: NSKeyValueObservation?
    private var originalVolume: Float = 0.5
    private var lastVolume: Float = 0.5
    private var started = false

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

    func start() {
        guard !started else { return }
        started = true
        originalVolume = audioSession.outputVolume
        lastVolume = Self.anchorVolume
        do {
            try audioSession.setCategory(.ambient, options: [.mixWithOthers])
            try audioSession.setActive(true)
        } catch {
            // Without an active session the KVO may never fire; keep
            // going — the MPVolumeView still suppresses the HUD, and
            // the observer may still deliver changes.
        }
        setSystemVolume(Self.anchorVolume)
        observation = audioSession.observe(\.outputVolume, options: [.new]) { [weak self] _, _ in
            guard let self else { return }
            // Serialize all handling on the main actor: KVO can
            // arrive on any thread, and lastVolume/reset must not race.
            Task { @MainActor in
                self.handleVolumeChange()
            }
        }
    }

    func stop() {
        guard started else { return }
        started = false
        observation?.invalidate()
        observation = nil
        // Restore the user's phone volume. Observation is already
        // gone, so the restore can't fire a spurious step.
        lastVolume = originalVolume
        setSystemVolume(originalVolume)
        try? audioSession.setActive(false, options: [.notifyOthersOnDeactivation])
    }

    @MainActor
    private func handleVolumeChange() {
        let newVolume = audioSession.outputVolume
        guard let up = Self.direction(from: lastVolume, to: newVolume) else { return }
        lastVolume = newVolume
        // Reset first — lastVolume = anchor BEFORE the slider moves,
        // so the reset's own KVO echo reads as zero delta and is
        // ignored — then report the step.
        resetSystemVolume()
        onStep?(up)
    }

    private func resetSystemVolume() {
        lastVolume = Self.anchorVolume
        setSystemVolume(Self.anchorVolume)
    }

    /// Sets the system volume through the MPVolumeView's slider — the
    /// only programmatic route. The slider is created lazily, so lay
    /// the view out first; if it isn't there yet, nothing happens.
    /// That only weakens the anchor: direction still works from the
    /// tracked volume, and the next step retries the reset once the
    /// view has laid out.
    private func setSystemVolume(_ value: Float) {
        volumeView.layoutIfNeeded()
        guard let slider = volumeView.subviews.compactMap({ $0 as? UISlider }).first else { return }
        slider.setValue(value, animated: false)
    }
}

/// Embeds the controller's hidden MPVolumeView (1×1, near-invisible)
/// so it sits in the view hierarchy and suppresses the system volume
/// HUD while the remote is up.
struct HiddenVolumeView: UIViewRepresentable {
    let volumeView: MPVolumeView

    func makeUIView(context: Context) -> MPVolumeView { volumeView }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
