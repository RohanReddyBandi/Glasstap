import Foundation
import Observation

/// The setup assistant's "Try it" step: watches the camera while the user moves, pinches and
/// opens their hand, and learns their pinch from the three practice pinches.
@MainActor
@Observable
final class PracticeSession {
    private(set) var handVisible = false
    private(set) var moved = false
    private(set) var pinches = 0
    private(set) var openHand = false
    private(set) var pinchResult: PinchTrainer.Result?
    /// Live readouts for the UI.
    private(set) var pinchGap: CGFloat?
    private(set) var isOpenPalm = false
    private(set) var error: String?

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var trainer = PinchTrainer()
    @ObservationIgnored private var travel: CGFloat = 0
    @ObservationIgnored private var lastPalm: CGPoint?
    @ObservationIgnored private var openFrames = 0
    @ObservationIgnored private var running = false

    var pinchTrained: Bool {
        if case .trained = pinchResult { return true }
        return false
    }

    var isComplete: Bool { moved && pinchTrained && openHand }

    func start(model: AppModel) async {
        guard !running else { return }
        self.model = model
        await model.permissions.requestMediaAccessIfNeeded(includingMicrophone: false)
        guard model.permissions.camera == .granted else {
            error = "Camera access is off. Go back a step and allow it."
            return
        }
        do {
            try model.startCamera(for: .setup)
            running = true
            model.frameObserver = { [weak self] _, update in self?.handle(update) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func stop() {
        guard running else { return }
        running = false
        model?.frameObserver = nil
        model?.stopCamera(for: .setup)
    }

    func retrainPinch() {
        trainer = PinchTrainer()
        pinches = 0
        pinchResult = nil
    }

    private func handle(_ update: TrackingUpdate) {
        guard let hand = update.primary else {
            handVisible = false
            lastPalm = nil
            openFrames = 0
            return
        }
        handVisible = true
        let metrics = hand.metrics
        pinchGap = metrics.indexPinch
        isOpenPalm = metrics.isOpenPalm

        // Moved: about three palm lengths of deliberate movement (tiny frame-to-frame wobble
        // doesn't count).
        if !metrics.isOpenPalm, let last = lastPalm {
            let step = last.distance(to: metrics.mirrored) / metrics.scale
            if step > 0.02 { travel += step }
            if travel > 3 { moved = true }
        }
        lastPalm = metrics.mirrored

        if metrics.isOpenPalm {
            openFrames += 1
            if openFrames >= 8 { openHand = true }
        } else {
            openFrames = 0
        }

        guard pinchResult == nil else { return }
        if trainer.add(metrics.indexPinch) {
            pinches = trainer.pinchCount
        }
        if trainer.isComplete, let result = trainer.result() {
            pinchResult = result
            if case .trained(let thresholds) = result, let model {
                model.settings.gestures.pinchProfile = thresholds
                model.applySettings()
                model.debug.log(.info, String(
                    format: "Pinch trained: pinched under %.2f, released over %.2f.", thresholds.down, thresholds.up
                ))
            }
        }
    }
}
