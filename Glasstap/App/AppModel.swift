import AppKit
import Observation

/// Owns touch mode: starts and stops the camera and microphone, and turns "hand position +
/// tap sound" into clicks.
@MainActor
@Observable
final class AppModel {
    /// How long after the camera loses sight of the hand a tap can still use its last spot.
    /// The camera sits in the same plane as the screen, so the fingertip often leaves the
    /// frame in the last few centimeters before it touches the glass.
    static let tapMaxAge: Double = 0.45
    /// Ignore taps this close (seconds) to a real key press or trackpad click.
    static let inputQuietWindow: Double = 0.3

    private(set) var isActive = false
    private(set) var isStarting = false

    let settings = AppSettings()
    let permissions = Permissions()
    let debug = DebugStore()

    @ObservationIgnored let tracker = HandTracker()
    @ObservationIgnored let listener = TapListener()
    @ObservationIgnored let windows = WindowManager()
    @ObservationIgnored private let overlay = OverlayController()
    @ObservationIgnored private let poster = EventPoster()
    @ObservationIgnored private let inputMonitor = InputActivityMonitor()
    @ObservationIgnored private var pointer = PointerTracker()
    @ObservationIgnored private var hotKey: HotKey?
    @ObservationIgnored private var lastClick: (time: Double, point: CGPoint, count: Int)?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        windows.attach(self)
        tracker.onFrame = { [weak self] frame in self?.handle(frame) }
        listener.onOutcome = { [weak self] outcome in self?.handle(outcome) }
    }

    func launch() {
        registerHotKey()
        observeSystem()
        permissions.refresh()
        if !settings.hasCompletedOnboarding || !permissions.allGranted {
            windows.showOnboarding()
        }
    }

    // MARK: - Touch mode

    func toggle() {
        if isActive {
            deactivate()
        } else {
            Task { await activate() }
        }
    }

    func activate() async {
        guard !isActive, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }

        guard let screen = NSScreen.builtIn else {
            windows.showAlert(
                "Glasstap needs the built-in display",
                "Touch mode works on your MacBook's own screen. Open the lid (or leave clamshell mode) and try again."
            )
            return
        }
        await permissions.requestMediaAccessIfNeeded()
        guard permissions.allGranted else {
            windows.showOnboarding()
            return
        }

        do {
            try tracker.start()
            try listener.start(parameters: settings.detectorParameters)
        } catch {
            tracker.stop()
            listener.stop()
            windows.showAlert("Couldn't start touch mode", error.localizedDescription)
            return
        }

        pointer.reset()
        lastClick = nil
        inputMonitor.start()
        overlay.showsCursor = settings.showCursor
        overlay.show(on: screen)
        overlay.toast("Touch mode on", symbol: "hand.tap.fill")
        isActive = true
        debug.log(.info, "Touch mode on. Camera: \(tracker.summary). Mic: \(listener.deviceName).")
    }

    func deactivate(announce: Bool = true) {
        guard isActive else { return }
        isActive = false
        tracker.stop()
        listener.stop()
        inputMonitor.stop()
        pointer.reset()
        overlay.updatePointer(nil, stale: true)
        if announce {
            overlay.toast("Touch mode off", symbol: "hand.raised.slash")
        }
        overlay.hide(after: announce ? 1.9 : 0)
        debug.log(.info, "Touch mode off.")
    }

    /// Pushes changed settings into the running pipeline.
    func settingsChanged() {
        listener.update(parameters: settings.detectorParameters)
        overlay.showsCursor = settings.showCursor
    }

    func registerHotKey() {
        hotKey = nil
        hotKey = HotKey(combo: settings.toggleHotKey) { [weak self] in self?.toggle() }
        if hotKey == nil {
            debug.log(.warning, "Couldn't register \(settings.toggleHotKey.displayString). Another app may already use it.")
        }
    }

    // MARK: - Camera → cursor

    private func handle(_ frame: HandFrame) {
        guard isActive else { return }
        debug.record(frame)
        if let sample = pointer.ingest(frame) {
            debug.latestPointer = sample
            overlay.updatePointer(sample.screen, stale: false)
        } else if let last = pointer.latest, frame.time - last.time <= Self.tapMaxAge {
            overlay.updatePointer(last.screen, stale: true)
        } else {
            overlay.updatePointer(nil, stale: true)
        }
    }

    // MARK: - Microphone → click

    private func handle(_ outcome: TapDetector.Outcome) {
        guard isActive else { return }
        switch outcome {
        case .sustained(let event):
            debug.log(.rejected, "Sound at \(event.peakDB.dBText) kept going (fell only \(event.decayDB.dBText)), so not a tap.")
        case .tap(let event):
            handleTap(event)
        }
    }

    private func handleTap(_ event: TapDetector.Event) {
        let heard = "Tap at \(event.peakDB.dBText)"
        if inputMonitor.wasActive(near: event.time, within: Self.inputQuietWindow) {
            debug.log(.rejected, "\(heard) ignored: keyboard or trackpad in use.")
            return
        }
        guard let sample = pointer.sample(at: event.time, maxAge: Self.tapMaxAge),
              let screen = NSScreen.builtIn
        else {
            debug.log(.rejected, "\(heard) ignored: no hand in view.")
            return
        }

        let point = screen.quartzPoint(fromNormalized: sample.screen)
        let count = clickCount(at: event.time, point: point)
        poster.click(at: point, clickCount: count)
        overlay.pulse(at: sample.screen)

        let age = Int(((event.time - sample.time) * 1000).rounded())
        let kind = count == 2 ? "Double-click" : count == 3 ? "Triple-click" : "Click"
        debug.log(.click, "\(heard) → \(kind) at \(Int(point.x)), \(Int(point.y)). Hand last seen \(age) ms before the tap.")
    }

    /// Taps close together in time and space become double and triple clicks, using the
    /// system's double-click speed.
    private func clickCount(at time: Double, point: CGPoint) -> Int {
        var count = 1
        if let last = lastClick,
           time - last.time <= NSEvent.doubleClickInterval,
           hypot(point.x - last.point.x, point.y - last.point.y) <= 40 {
            count = min(last.count + 1, 3)
        }
        lastClick = (time, point, count)
        return count
    }

    // MARK: - System events

    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        let stopOn = [
            NSWorkspace.willSleepNotification,
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification,
        ]
        for name in stopOn {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.deactivate(announce: false) }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        })
    }

    private func screensChanged() {
        guard isActive else { return }
        if let screen = NSScreen.builtIn {
            overlay.show(on: screen)
        } else {
            deactivate()
        }
    }
}
