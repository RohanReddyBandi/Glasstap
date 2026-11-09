import Foundation
import Observation

/// User preferences, saved in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    private let defaults: UserDefaults

    // MARK: General

    var hasCompletedSetup: Bool {
        didSet { defaults.set(hasCompletedSetup, forKey: Key.setupDone) }
    }
    var toggleHotKey: KeyCombo {
        didSet { save(toggleHotKey, Key.hotKey) }
    }
    /// Trackpad (relative, the default) or touchscreen (absolute, calibrated) pointing.
    var pointerMode: PointerMode {
        didSet { defaults.set(pointerMode.rawValue, forKey: Key.pointerMode) }
    }
    /// Trackpad mode's speed multiplier.
    var pointerSpeed: Double {
        didSet { defaults.set(pointerSpeed, forKey: Key.pointerSpeed) }
    }
    var pointerAcceleration: Bool {
        didSet { defaults.set(pointerAcceleration, forKey: Key.pointerAcceleration) }
    }
    /// The translucent ring that follows your hand.
    var showCursor: Bool {
        didSet { defaults.set(showCursor, forKey: Key.showCursor) }
    }
    /// Touchscreen mode: also move the real mouse pointer with your hand, so buttons light
    /// up on hover. (Trackpad mode always moves it; the pointer is the cursor.)
    var movePointer: Bool {
        didSet { defaults.set(movePointer, forKey: Key.movePointer) }
    }
    /// 0 = most responsive, 1 = steadiest.
    var smoothing: Double {
        didSet { defaults.set(smoothing, forKey: Key.smoothing) }
    }
    var autoCheckForUpdates: Bool {
        didSet { defaults.set(autoCheckForUpdates, forKey: Key.autoUpdates) }
    }
    var lastUpdateCheck: Date? {
        didSet { defaults.set(lastUpdateCheck, forKey: Key.lastUpdateCheck) }
    }

    // MARK: Gestures

    var gestures: GestureSettings {
        didSet { save(gestures, Key.gestures) }
    }
    var reverseScroll: Bool {
        didSet { defaults.set(reverseScroll, forKey: Key.reverseScroll) }
    }

    // MARK: Calibration

    var calibration: CalibrationProfile? {
        didSet { save(calibration, Key.calibration) }
    }

    // MARK: Tapping the glass

    /// Also click when the microphone hears a tap on the screen. Off by default: pinching is
    /// more reliable, and this needs the microphone.
    var tapToClick: Bool {
        didSet { defaults.set(tapToClick, forKey: Key.tapToClick) }
    }
    /// Quietest sound that counts as a tap, in dBFS. Lower is more sensitive.
    var tapThresholdDB: Float {
        didSet { defaults.set(tapThresholdDB, forKey: Key.tapThreshold) }
    }
    var tapRiseDB: Float {
        didSet { defaults.set(tapRiseDB, forKey: Key.tapRise) }
    }
    var tapAttackDB: Float {
        didSet { defaults.set(tapAttackDB, forKey: Key.tapAttack) }
    }

    static let tapThresholdRange: ClosedRange<Float> = -75 ... -15

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let detector = TapDetector.Parameters()
        hasCompletedSetup = defaults.bool(forKey: Key.setupDone)
        pointerMode = defaults.string(forKey: Key.pointerMode).flatMap(PointerMode.init(rawValue:)) ?? .trackpad
        pointerSpeed = defaults.object(forKey: Key.pointerSpeed) as? Double ?? 1.0
        pointerAcceleration = defaults.object(forKey: Key.pointerAcceleration) as? Bool ?? true
        toggleHotKey = Self.load(KeyCombo.self, Key.hotKey, from: defaults) ?? .defaultToggle
        showCursor = defaults.object(forKey: Key.showCursor) as? Bool ?? true
        movePointer = defaults.object(forKey: Key.movePointer) as? Bool ?? true
        smoothing = defaults.object(forKey: Key.smoothing) as? Double ?? 0.5
        autoCheckForUpdates = defaults.object(forKey: Key.autoUpdates) as? Bool ?? true
        lastUpdateCheck = defaults.object(forKey: Key.lastUpdateCheck) as? Date
        gestures = Self.load(GestureSettings.self, Key.gestures, from: defaults) ?? GestureSettings()
        reverseScroll = defaults.bool(forKey: Key.reverseScroll)
        calibration = Self.load(CalibrationProfile.self, Key.calibration, from: defaults)
        tapToClick = defaults.bool(forKey: Key.tapToClick)
        tapThresholdDB = Self.float(Key.tapThreshold, in: defaults) ?? detector.minPeakDB
        tapRiseDB = Self.float(Key.tapRise, in: defaults) ?? detector.minRiseDB
        tapAttackDB = Self.float(Key.tapAttack, in: defaults) ?? detector.minAttackDB
    }

    var detectorParameters: TapDetector.Parameters {
        var parameters = TapDetector.Parameters()
        parameters.minPeakDB = tapThresholdDB
        parameters.minRiseDB = tapRiseDB
        parameters.minAttackDB = tapAttackDB
        return parameters
    }

    /// One Euro filter settings for the chosen smoothing.
    var filter: (minCutoff: Double, beta: Double) {
        let s = smoothing.clamped(to: 0...1)
        return (minCutoff: 2.5 * pow(0.15, s), beta: 4.0 - 2.0 * s)
    }

    var mapping: PointerMapping {
        calibration.map { .calibrated($0.homography) } ?? .uncalibrated
    }

    var acceleration: PointerAcceleration {
        PointerAcceleration(speed: pointerSpeed, enabled: pointerAcceleration)
    }

    func resetTapTuning() {
        let detector = TapDetector.Parameters()
        tapThresholdDB = detector.minPeakDB
        tapRiseDB = detector.minRiseDB
        tapAttackDB = detector.minAttackDB
    }

    // MARK: -

    private func save<T: Encodable>(_ value: T?, _ key: String) {
        if let value, let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private static func load<T: Decodable>(_ type: T.Type, _ key: String, from defaults: UserDefaults) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    private static func float(_ key: String, in defaults: UserDefaults) -> Float? {
        defaults.object(forKey: key) != nil ? defaults.float(forKey: key) : nil
    }

    private enum Key {
        // v2: the setup assistant gained a practice step that trains the pinch.
        static let setupDone = "hasCompletedSetup.v2"
        static let pointerMode = "pointerMode"
        static let pointerSpeed = "pointerSpeed"
        static let pointerAcceleration = "pointerAcceleration"
        static let hotKey = "toggleHotKey"
        static let showCursor = "showCursor"
        static let movePointer = "movePointer"
        static let smoothing = "smoothing"
        static let autoUpdates = "autoCheckForUpdates"
        static let lastUpdateCheck = "lastUpdateCheck"
        static let gestures = "gestures"
        static let reverseScroll = "reverseScroll"
        // v2: the cursor anchor moved from the knuckle midpoint to the palm center, so older
        // calibrations no longer line up.
        static let calibration = "calibration.v2"
        static let tapToClick = "tapToClick"
        static let tapThreshold = "tapThresholdDB.v2"
        static let tapRise = "tapRiseDB"
        static let tapAttack = "tapAttackDB"
    }
}
