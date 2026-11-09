import AppKit
import Observation
import SwiftUI

/// Runs the full-screen calibration: nine dots, one pinch each, then a fit, then an optional
/// practice round where you pinch at targets with the new calibration.
///
/// Everything can be done hands-only (pinch to start, pinch to advance), or with the trackpad
/// and keyboard (buttons, Esc to cancel, Delete to redo the last dot).
@MainActor
@Observable
final class CalibrationController {
    enum Phase: Equatable {
        case intro
        case capturing
        case result(Outcome)
        case practice
    }

    enum Outcome: Equatable {
        case success(CalibrationProfile)
        case failure(String)
    }

    static let practiceGoal = 5
    /// Practice target radius, as a fraction of the screen width.
    static let practiceRadius: CGFloat = 0.045

    private(set) var isRunning = false
    private(set) var phase = Phase.intro
    private(set) var session = CalibrationSession()
    private(set) var handVisible = false
    private(set) var pinchProgress: Double = 0
    private(set) var isPinched = false
    private(set) var cursor: CGPoint?
    private(set) var practiceTarget: CGPoint?
    private(set) var practiceHits = 0
    private(set) var practiceMisses = 0
    /// Bumped on every captured dot or practice hit, to trigger animations.
    private(set) var captureCount = 0

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var pinch = PinchDetector()
    @ObservationIgnored private var history: [(time: Double, camera: CGPoint, screen: CGPoint)] = []
    @ObservationIgnored private var lastHandTime = -Double.infinity
    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private(set) var screenSize = CGSize(width: 1512, height: 982)

    func attach(_ model: AppModel) {
        self.model = model
    }

    // MARK: - Flow

    func begin() {
        guard let model else { return }
        if isRunning {
            window?.makeKeyAndOrderFront(nil)
            return
        }
        guard let screen = NSScreen.builtIn else {
            model.windows.showAlert("Glasstap needs the built-in display", "Open your MacBook's lid to calibrate.")
            return
        }
        Task {
            await model.permissions.requestMediaAccessIfNeeded(includingMicrophone: false)
            guard model.permissions.camera == .granted else {
                model.windows.showSetup(step: .permissions)
                return
            }
            do {
                try model.startCamera(for: .calibration)
            } catch {
                model.windows.showAlert("Couldn't start the camera", error.localizedDescription)
                return
            }
            screenSize = screen.frame.size
            pinch = PinchDetector(thresholds: PinchThresholds(sensitivity: model.settings.gestures.pinchSensitivity))
            history = []
            session = CalibrationSession()
            phase = .intro
            isRunning = true
            model.calibrationStarted()
            showWindow(on: screen)
        }
    }

    func startCapture() {
        session = CalibrationSession()
        phase = .capturing
    }

    func undoLast() {
        guard phase == .capturing else { return }
        session.undo()
    }

    func startPractice() {
        practiceHits = 0
        practiceMisses = 0
        nextPracticeTarget()
        phase = .practice
    }

    func cancel() {
        guard isRunning else { return }
        isRunning = false
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        window?.orderOut(nil)
        window?.contentView = nil
        window = nil
        model?.stopCamera(for: .calibration)
        model?.calibrationEnded()
    }

    func finish() {
        cancel()
    }

    // MARK: - Frames

    func handle(frame: HandFrame, update: TrackingUpdate) {
        guard isRunning else { return }
        let time = frame.time

        guard let hand = update.primary else {
            if time - lastHandTime > 0.4 {
                handVisible = false
                cursor = nil
            }
            _ = pinch.update(ratio: nil, time: time)
            isPinched = pinch.isPinched
            pinchProgress = isPinched ? 1 : 0
            return
        }

        lastHandTime = time
        handVisible = true
        history.append((time, hand.sample.camera, hand.sample.screen))
        history.removeAll { time - $0.time > 1.0 }
        cursor = hand.sample.screen

        let event = pinch.update(ratio: hand.metrics.indexPinch, time: time)
        isPinched = pinch.isPinched
        pinchProgress = pinch.progress(for: hand.metrics.indexPinch)
        guard case .down(let closingSince)? = event else { return }

        // Use where the hand was just before the fingers started closing: pinching moves
        // the knuckles a little.
        let aimedAt = max(closingSince, time - 0.3)
        switch phase {
        case .intro:
            startCapture()
        case .capturing:
            capture(before: aimedAt)
        case .result(.success):
            startPractice()
        case .result(.failure):
            startCapture()
        case .practice:
            practicePinch(before: aimedAt)
        }
    }

    private func capture(before time: Double) {
        let recent = history.filter { $0.time <= time && $0.time >= time - 0.25 }.map(\.camera)
        guard let fallback = history.last?.camera else { return }
        let points = recent.isEmpty ? [fallback] : recent
        session.record(CGPoint(x: Self.median(points.map(\.x)), y: Self.median(points.map(\.y))))
        captureCount += 1
        if session.isComplete { finishCapture() }
    }

    private func finishCapture() {
        switch session.makeProfile(screenAspect: screenSize.width / screenSize.height) {
        case .success(let profile):
            model?.applyCalibration(profile)
            phase = .result(.success(profile))
        case .failure(let failure):
            phase = .result(.failure(failure.message))
        }
    }

    private func practicePinch(before time: Double) {
        guard let target = practiceTarget else { return }
        let point = history.last(where: { $0.time <= time })?.screen ?? cursor ?? .zero
        let dx = (point.x - target.x) * screenSize.width
        let dy = (point.y - target.y) * screenSize.height
        if hypot(dx, dy) <= Self.practiceRadius * screenSize.width {
            practiceHits += 1
            captureCount += 1
            if practiceHits >= Self.practiceGoal {
                practiceTarget = nil
            } else {
                nextPracticeTarget()
            }
        } else {
            practiceMisses += 1
        }
    }

    private func nextPracticeTarget() {
        var next: CGPoint
        repeat {
            next = CGPoint(x: .random(in: 0.12...0.88), y: .random(in: 0.18...0.8))
        } while practiceTarget.map({ hypot(($0.x - next.x) * screenSize.width, ($0.y - next.y) * screenSize.height) < 250 }) ?? false
        practiceTarget = next
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    // MARK: - Window

    private func showWindow(on screen: NSScreen) {
        guard let model else { return }
        let window = CalibrationWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        // Just under the overlay, so the touch-mode border still shows if it's on.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: CalibrationView(controller: self, model: model))
        window.setFrame(screen.frame, display: true)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        self.window = window

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isRunning else { return event }
            switch Int(event.keyCode) {
            case 53:  // Esc
                self.cancel()
                return nil
            case 51:  // Delete
                self.undoLast()
                return nil
            default:
                return event
            }
        }
    }
}

final class CalibrationWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
