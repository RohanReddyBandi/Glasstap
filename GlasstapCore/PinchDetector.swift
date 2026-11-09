import CoreGraphics

/// Pinch thresholds, as thumb-to-fingertip distance relative to hand size.
struct PinchThresholds: Equatable, Sendable {
    /// Closer than this counts as pinched.
    var down: CGFloat
    /// Further than this counts as released. The gap between `down` and `up` stops the pinch
    /// flickering when the fingers hover near the threshold.
    var up: CGFloat
    /// Closer than this means the fingers are on their way together. Used to remember where
    /// the cursor was *before* the pinch started, so clicks land where you aimed.
    var arm: CGFloat

    /// `sensitivity` 0...1. Higher registers a pinch with the fingers further apart.
    init(sensitivity: Double) {
        let s = CGFloat(sensitivity.clamped(to: 0...1))
        down = 0.20 + 0.18 * s
        up = down + 0.14
        arm = up + 0.10
    }
}

/// Turns a stream of pinch distances into pinch-down and pinch-up events.
struct PinchDetector {
    enum Event: Equatable, Sendable {
        /// `closingSince` is when the fingers started coming together.
        case down(closingSince: Double)
        case up
    }

    var thresholds: PinchThresholds
    private(set) var isPinched = false
    private var closingSince: Double?
    private var openFrames = 0
    private var unknownSince: Double?

    /// Fingertips often vanish from Vision's output while pressed together. A pinch holds
    /// through that, and only lets go if they stay hidden this long.
    static let hiddenReleaseAfter = 0.35

    init(thresholds: PinchThresholds = PinchThresholds(sensitivity: 0.5)) {
        self.thresholds = thresholds
    }

    mutating func reset() {
        isPinched = false
        closingSince = nil
        openFrames = 0
        unknownSince = nil
    }

    mutating func update(ratio: CGFloat?, time: Double) -> Event? {
        guard let ratio else {
            guard isPinched else { return nil }
            if let since = unknownSince {
                if time - since > Self.hiddenReleaseAfter {
                    reset()
                    return .up
                }
            } else {
                unknownSince = time
            }
            return nil
        }
        unknownSince = nil

        if isPinched {
            // Two frames in a row above the release threshold, so one noisy frame can't drop it.
            if ratio > thresholds.up {
                openFrames += 1
                if openFrames >= 2 {
                    isPinched = false
                    openFrames = 0
                    closingSince = nil
                    return .up
                }
            } else {
                openFrames = 0
            }
            return nil
        }

        if ratio < thresholds.arm {
            if closingSince == nil { closingSince = time }
        } else {
            closingSince = nil
        }
        if ratio < thresholds.down {
            isPinched = true
            let since = closingSince ?? time
            closingSince = nil
            return .down(closingSince: since)
        }
        return nil
    }

    /// 0 with the fingers apart, rising to 1 as they meet. Drives the cursor animation.
    func progress(for ratio: CGFloat?) -> Double {
        if isPinched { return 1 }
        guard let ratio else { return 0 }
        let open = thresholds.arm + 0.15
        return Double(((open - ratio) / (open - thresholds.down)).clamped(to: 0...1))
    }
}
