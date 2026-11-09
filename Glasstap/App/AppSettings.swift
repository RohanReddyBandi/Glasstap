import Foundation
import Observation

/// User preferences, saved in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    private let defaults: UserDefaults

    /// Quietest sound that counts as a tap, in dBFS. Lower is more sensitive.
    var tapThresholdDB: Float {
        didSet { defaults.set(tapThresholdDB, forKey: Key.tapThreshold) }
    }
    var showCursor: Bool {
        didSet { defaults.set(showCursor, forKey: Key.showCursor) }
    }
    var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Key.onboarded) }
    }
    var toggleHotKey: KeyCombo {
        didSet { defaults.set(try? JSONEncoder().encode(toggleHotKey), forKey: Key.hotKey) }
    }

    static let tapThresholdRange: ClosedRange<Float> = -70 ... -10

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        tapThresholdDB = defaults.object(forKey: Key.tapThreshold) != nil
            ? defaults.float(forKey: Key.tapThreshold)
            : TapDetector.Parameters().minPeakDB
        showCursor = defaults.object(forKey: Key.showCursor) as? Bool ?? true
        hasCompletedOnboarding = defaults.bool(forKey: Key.onboarded)
        toggleHotKey = defaults.data(forKey: Key.hotKey)
            .flatMap { try? JSONDecoder().decode(KeyCombo.self, from: $0) } ?? .defaultToggle
    }

    var detectorParameters: TapDetector.Parameters {
        var parameters = TapDetector.Parameters()
        parameters.minPeakDB = tapThresholdDB
        return parameters
    }

    private enum Key {
        static let tapThreshold = "tapThresholdDB"
        static let showCursor = "showCursor"
        static let onboarded = "hasCompletedOnboarding"
        static let hotKey = "toggleHotKey"
    }
}
