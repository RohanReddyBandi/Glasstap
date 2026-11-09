import AppKit
import Observation

/// Owns touch mode: runs the camera (and, for tap-to-click, the microphone), turns hand
/// movement into gestures, and posts the resulting clicks, drags, scrolls and shortcuts.
@MainActor
@Observable
final class AppModel {
    /// How long after the camera loses the hand a mic tap can still use its last spot.
    static let tapMaxAge: Double = 0.45
    /// Ignore mic taps this close (seconds) to a real key press or click.
    static let inputQuietWindow: Double = 0.3
    /// After the user touches the real trackpad or mouse, the hand leaves the pointer alone
    /// for this long.
    static let pointerPauseAfterRealInput: Double = 1.0

    /// Things that need the camera. It runs while any of them does.
    enum CameraClient: Hashable {
        case touchMode, setup, calibration
    }

    private(set) var isActive = false
    private(set) var isStarting = false
    private(set) var isCameraRunning = false

    let settings = AppSettings()
    let permissions = Permissions()
    let debug = DebugStore()
    let updates = UpdateChecker()
    let calibration = CalibrationController()

    @ObservationIgnored let tracker = HandTracker()
    @ObservationIgnored let listener = TapListener()
    @ObservationIgnored let windows = WindowManager()
    @ObservationIgnored private let overlay = OverlayController()
    @ObservationIgnored private let input = InputSynthesizer()
    @ObservationIgnored private let scroller = ScrollAnimator()
    @ObservationIgnored private let activity = InputActivityMonitor()
    @ObservationIgnored private var pointer = PointerTracker()
    @ObservationIgnored private var gestures = GestureEngine(screenSize: CGSize(width: 1512, height: 982))
    @ObservationIgnored private var cameraClients: Set<CameraClient> = []
    @ObservationIgnored private var hotKey: HotKey?
    @ObservationIgnored private var lastClick: (time: Double, point: CGPoint, count: Int)?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var tapMeasurement: ((TapDetector.Event) -> Void)?

    init() {
        windows.attach(self)
        calibration.attach(self)
        tracker.onFrame = { [weak self] frame in self?.handle(frame) }
        listener.onOutcome = { [weak self] outcome in self?.handle(outcome) }
        scroller.post = { [weak self] dx, dy in self?.input.scroll(dx: dx, dy: dy) }
        activity.ownPointerPost = { [weak self] in self?.input.lastPointerPost ?? -.infinity }
        applySettings()
    }

    func launch() {
        registerHotKey()
        observeSystem()
        permissions.refresh()
        if !settings.hasCompletedSetup || !permissions.allGranted(needsMicrophone: false) {
            windows.showSetup()
        }
        updates.checkInBackgroundIfDue(settings: settings)
        #if DEBUG
        openFromLaunchArgument()
        #endif
    }

    #if DEBUG
    /// Development aid: `-GlasstapOpen settings|debug|calibration|setup:<0-4>` opens that
    /// window at launch, for checking screens without clicking through the app.
    private func openFromLaunchArgument() {
        guard let target = UserDefaults.standard.string(forKey: "GlasstapOpen") else { return }
        switch target {
        case "settings": windows.showSettings()
        case "debug": windows.showDebug()
        case "calibration": calibration.begin()
        default:
            if target.hasPrefix("setup:"), let index = Int(target.dropFirst(6)), let step = SetupView.Step(rawValue: index) {
                windows.showSetup(step: step)
            }
        }
    }
    #endif

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
        await permissions.requestMediaAccessIfNeeded(includingMicrophone: settings.tapToClick)
        guard permissions.allGranted(needsMicrophone: settings.tapToClick) else {
            windows.showSetup(step: .permissions)
            return
        }

        do {
            try startCamera(for: .touchMode)
            if settings.tapToClick { try listener.start(parameters: settings.detectorParameters) }
        } catch {
            stopCamera(for: .touchMode)
            listener.stop()
            windows.showAlert("Couldn't start touch mode", error.localizedDescription)
            return
        }

        gestures.screenSize = screen.frame.size
        _ = gestures.reset()
        lastClick = nil
        activity.start()
        overlay.showsCursor = settings.showCursor
        overlay.show(on: screen)
        isActive = true
        if settings.calibration == nil {
            overlay.toast("Touch mode on. Calibrate for better aim.", symbol: "scope")
        } else {
            overlay.toast("Touch mode on", symbol: "hand.pinch.fill")
        }
        debug.log(.info, "Touch mode on. Camera: \(tracker.summary).\(settings.tapToClick ? " Mic: \(listener.deviceName)." : "")")
    }

    func deactivate(announce: Bool = true) {
        guard isActive else { return }
        isActive = false
        perform(gestures.reset(), time: CACurrentMediaTime())
        input.releaseAll()
        scroller.stop()
        stopCamera(for: .touchMode)
        if tapMeasurement == nil { listener.stop() }
        activity.stop()
        overlay.updateCursor(nil, stale: true)
        if announce {
            overlay.toast("Touch mode off", symbol: "hand.raised.slash")
        }
        overlay.hide(after: announce ? 1.9 : 0)
        debug.log(.info, "Touch mode off.")
    }

    // MARK: - Camera

    func startCamera(for client: CameraClient) throws {
        if cameraClients.isEmpty {
            pointer.reset()
            try tracker.start()
            isCameraRunning = true
        }
        cameraClients.insert(client)
    }

    func stopCamera(for client: CameraClient) {
        guard cameraClients.remove(client) != nil else { return }
        if cameraClients.isEmpty {
            tracker.stop()
            isCameraRunning = false
            pointer.reset()
        }
    }

    // MARK: - Settings

    /// Pushes changed settings into the running pipeline.
    func applySettings() {
        let filter = settings.filter
        pointer.setSmoothing(minCutoff: filter.minCutoff, beta: filter.beta)
        if pointer.mapping != settings.mapping {
            pointer.mapping = settings.mapping
            pointer.reset()
        }
        gestures.settings = settings.gestures
        overlay.showsCursor = settings.showCursor
        if tapMeasurement == nil {
            listener.update(parameters: settings.detectorParameters)
        }
    }

    func applyCalibration(_ profile: CalibrationProfile) {
        settings.calibration = profile
        applySettings()
        debug.log(.info, "Calibrated: \(profile.quality.rawValue.lowercased()), off by about \(Int(profile.rmsError * 100 * 10) / 10)% of the screen width.")
    }

    /// Turns tap-to-click on or off, asking for the microphone if needed.
    func setTapToClick(_ enabled: Bool) async {
        if enabled {
            await permissions.requestMediaAccessIfNeeded(includingMicrophone: true)
            guard permissions.microphone == .granted else {
                Permissions.open(.microphone)
                return
            }
        }
        settings.tapToClick = enabled
        guard isActive, tapMeasurement == nil else { return }
        if enabled {
            do {
                try listener.start(parameters: settings.detectorParameters)
            } catch {
                windows.showAlert("Couldn't start the microphone", error.localizedDescription)
            }
        } else {
            listener.stop()
        }
    }

    func registerHotKey() {
        hotKey = nil
        hotKey = HotKey(combo: settings.toggleHotKey) { [weak self] in self?.toggle() }
        if hotKey == nil {
            debug.log(.warning, "Couldn't register \(settings.toggleHotKey.displayString). Another app may already use it.")
        }
    }

    /// While the shortcut recorder listens, the current shortcut mustn't fire.
    func suspendHotKey() {
        hotKey = nil
    }

    // MARK: - Tap tuning

    /// Listens with very loose thresholds and reports every tap, for tuning sensitivity.
    func beginTapMeasurement(_ onTap: @escaping (TapDetector.Event) -> Void) throws {
        tapMeasurement = onTap
        var loose = TapDetector.Parameters()
        loose.minPeakDB = -80
        loose.minRiseDB = 6
        loose.minAttackDB = 4
        if listener.isRunning {
            listener.update(parameters: loose)
        } else {
            try listener.start(parameters: loose)
        }
    }

    func endTapMeasurement() {
        guard tapMeasurement != nil else { return }
        tapMeasurement = nil
        if isActive, settings.tapToClick {
            listener.update(parameters: settings.detectorParameters)
        } else {
            listener.stop()
        }
    }

    /// Sets the tap thresholds just under the quietest of the user's sample taps.
    func applyTapTuning(_ events: [TapDetector.Event]) {
        guard let quietest = events.map(\.peakDB).min(),
              let softestRise = events.map(\.riseDB).min(),
              let softestAttack = events.map(\.attackDB).min()
        else { return }
        settings.tapThresholdDB = (quietest - 6).clamped(to: AppSettings.tapThresholdRange)
        settings.tapRiseDB = (softestRise - 4).clamped(to: 6...15)
        settings.tapAttackDB = (softestAttack - 3).clamped(to: 4...10)
        applySettings()
    }

    // MARK: - Calibration hooks

    func calibrationStarted() {
        if isActive {
            perform(gestures.reset(), time: CACurrentMediaTime())
            scroller.stop()
        }
        overlay.updateCursor(nil, stale: true)
    }

    func calibrationEnded() {
        pointer.reset()
    }

    // MARK: - Camera → gestures

    private func handle(_ frame: HandFrame) {
        guard isCameraRunning else { return }
        debug.record(frame)
        let update = pointer.ingest(frame)
        debug.latestUpdate = update

        if calibration.isRunning {
            calibration.handle(frame: frame, update: update)
            return
        }
        guard isActive else { return }

        let primary = update.primary.map { HandInput(metrics: $0.metrics, cursor: $0.sample.screen, motion: $0.sample.motion) }
        let secondary = update.secondary.map { HandInput(metrics: $0.metrics, cursor: $0.sample.screen, motion: $0.sample.motion) }
        let result = gestures.update(time: frame.time, primary: primary, secondary: secondary)
        perform(result.actions, time: frame.time)
        debug.gestureState = result.feedback.map { "\($0.state)" } ?? "no hand"

        if let feedback = result.feedback {
            overlay.updateCursor(feedback, stale: false)
            steerPointer(feedback)
        } else if let last = pointer.latest, frame.time - last.time <= Self.tapMaxAge {
            overlay.updateCursor(CursorFeedback(position: last.screen), stale: true)
        } else {
            overlay.updateCursor(nil, stale: true)
        }
    }

    /// Moves the real pointer with the hand, so hover effects work and the arrow shows where
    /// a click will land. During a scroll it stays put, over whatever is scrolling.
    private func steerPointer(_ feedback: CursorFeedback) {
        guard settings.movePointer,
              !activity.pointerUsed(within: Self.pointerPauseAfterRealInput),
              let screen = NSScreen.builtIn
        else { return }
        switch feedback.state {
        case .hover, .pressed:
            input.movePointer(to: screen.quartzPoint(fromNormalized: feedback.position))
        case .dragging, .scrolling, .zooming:
            break
        }
    }

    private func perform(_ actions: [GestureAction], time: Double) {
        guard !actions.isEmpty, let screen = NSScreen.builtIn else { return }
        func quartz(_ p: CGPoint) -> CGPoint { screen.quartzPoint(fromNormalized: p) }
        let flip: CGFloat = settings.reverseScroll ? -1 : 1

        for action in actions {
            switch action {
            case .click(let p):
                let point = quartz(p)
                let count = clickCount(at: time, point: point)
                input.click(at: point, count: count)
                overlay.pulse(at: p, style: .primary)
                let kind = count == 2 ? "Double-click" : count == 3 ? "Triple-click" : "Click"
                debug.log(.click, "\(kind) at \(Int(point.x)), \(Int(point.y)).")
            case .rightClick(let p):
                input.rightClick(at: quartz(p))
                overlay.pulse(at: p, style: .secondary)
                debug.log(.click, "Right-click at \(Int(quartz(p).x)), \(Int(quartz(p).y)).")
            case .dragBegan(let p):
                input.mouseDown(at: quartz(p))
                debug.log(.click, "Drag started.")
            case .dragMoved(let p):
                input.drag(to: quartz(p))
            case .dragEnded(let p):
                input.mouseUp(at: quartz(p))
                debug.log(.click, "Drag ended.")
            case .scroll(let v):
                scroller.add(CGVector(dx: v.dx * flip, dy: v.dy * flip))
            case .scrollEnded(let v):
                scroller.fling(CGVector(dx: v.dx * flip, dy: v.dy * flip))
            case .zoom(let steps):
                input.zoom(steps)
                overlay.toast(steps > 0 ? "Zoom in" : "Zoom out", symbol: steps > 0 ? "plus.magnifyingglass" : "minus.magnifyingglass")
                debug.log(.click, steps > 0 ? "Zoom in." : "Zoom out.")
            case .swipe(let direction):
                input.perform(direction)
                overlay.toast(direction.title, symbol: direction.symbol)
                debug.log(.click, "Swipe \(direction.rawValue): \(direction.title).")
            }
        }
    }

    /// Clicks close together in time and space become double and triple clicks, using the
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

    // MARK: - Microphone → click (optional)

    private func handle(_ outcome: TapDetector.Outcome) {
        if let measure = tapMeasurement {
            if case .tap(let event) = outcome { measure(event) }
            return
        }
        guard isActive, settings.tapToClick else { return }
        switch outcome {
        case .sustained(let event):
            debug.log(.rejected, "Sound at \(event.peakDB.dBText) kept going (fell only \(event.decayDB.dBText)), so not a tap.")
        case .tap(let event):
            handleTap(event)
        }
    }

    private func handleTap(_ event: TapDetector.Event) {
        let heard = "Tap at \(event.peakDB.dBText)"
        if activity.keyOrClick(near: event.time, within: Self.inputQuietWindow) {
            debug.log(.rejected, "\(heard) ignored: keyboard or trackpad in use.")
            return
        }
        if gestures.isPressing {
            debug.log(.rejected, "\(heard) ignored: a pinch is in progress.")
            return
        }
        guard let sample = pointer.sample(at: event.time, maxAge: Self.tapMaxAge), let screen = NSScreen.builtIn else {
            debug.log(.rejected, "\(heard) ignored: no hand in view.")
            return
        }
        let point = screen.quartzPoint(fromNormalized: sample.screen)
        let count = clickCount(at: event.time, point: point)
        input.click(at: point, count: count)
        overlay.pulse(at: sample.screen, style: .primary)
        let age = Int(((event.time - sample.time) * 1000).rounded())
        debug.log(.click, "\(heard) → click at \(Int(point.x)), \(Int(point.y)). Hand last seen \(age) ms before the tap.")
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
                MainActor.assumeIsolated {
                    self?.deactivate(announce: false)
                    self?.calibration.cancel()
                }
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
            gestures.screenSize = screen.frame.size
            overlay.show(on: screen)
        } else {
            deactivate()
        }
    }
}

extension SwipeDirection {
    var title: String {
        switch self {
        case .left: "Space to the right"
        case .right: "Space to the left"
        case .up: "Mission Control"
        case .down: "App windows"
        }
    }

    var symbol: String {
        switch self {
        case .left: "arrow.right"
        case .right: "arrow.left"
        case .up: "rectangle.3.group"
        case .down: "macwindow.on.rectangle"
        }
    }
}
