import CoreGraphics

/// Pinch thresholds, as thumb-to-fingertip distance relative to hand size.
struct PinchThresholds: Codable, Equatable, Sendable {
    /// Closer than this counts as pinched.
    var down: CGFloat
    /// Further than this counts as released. The gap between `down` and `up` stops the pinch
    /// flickering when the fingers hover near the threshold.
    var up: CGFloat
    /// Closer than this means the fingers are on their way together. Used to remember where
    /// the cursor was *before* the pinch started, and to steady the cursor while they close.
    var arm: CGFloat

    init(down: CGFloat, up: CGFloat, arm: CGFloat) {
        self.down = down
        self.up = up
        self.arm = arm
    }

    /// `sensitivity` 0...1. Higher registers a pinch with the fingers further apart.
    init(sensitivity: Double) {
        let s = CGFloat(sensitivity.clamped(to: 0...1))
        down = 0.20 + 0.18 * s
        up = down + 0.14
        arm = up + 0.10
    }
}

/// Turns a stream of pinch distances into pinch-down and pinch-up events.
///
/// Like Apple's hand-pose sample and other open-source hand mice, a change of state needs
/// evidence from more than one frame, so a single noisy frame can't click or let go.
struct PinchDetector {
    enum Event: Equatable, Sendable {
        /// `closingSince` is when the fingers started coming together.
        case down(closingSince: Double)
        case up
    }

    var thresholds: PinchThresholds
    /// Consecutive frames under `down` needed to register a pinch.
    var framesToPress = 2
    /// Consecutive frames over `up` needed to let go.
    var framesToRelease = 2
    private(set) var isPinched = false
    private var closingSince: Double?
    private var closedFrames = 0
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
        closedFrames = 0
        openFrames = 0
        unknownSince = nil
    }

    mutating func update(ratio: CGFloat?, time: Double) -> Event? {
        guard let ratio else {
            closedFrames = 0
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
            if ratio > thresholds.up {
                openFrames += 1
                if openFrames >= framesToRelease {
                    reset()
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
            closedFrames += 1
            if closedFrames >= framesToPress {
                isPinched = true
                closedFrames = 0
                openFrames = 0
                let since = closingSince ?? time
                closingSince = nil
                return .down(closingSince: since)
            }
        } else {
            closedFrames = 0
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

/// Learns one person's pinch from a few practice pinches, so thresholds sit between how
/// *their* open hand and *their* pinch look to the camera rather than at a generic guess.
struct PinchTrainer {
    enum Result: Equatable {
        case trained(PinchThresholds)
        /// Open and pinched look too alike to the camera to set reliable thresholds.
        case tooSimilar
    }

    static let pinchesNeeded = 3

    private(set) var pinchMinimums: [CGFloat] = []
    private var openSamples: [CGFloat] = []
    private var currentMinimum: CGFloat?
    private var closedFrames = 0

    // Deliberately loose: just enough to segment practice pinches.
    private let looseDown: CGFloat = 0.42
    private let looseUp: CGFloat = 0.55

    var pinchCount: Int { pinchMinimums.count }
    var isComplete: Bool { pinchMinimums.count >= Self.pinchesNeeded }

    /// Feed every frame's thumb-index ratio. Returns true when a practice pinch finishes.
    @discardableResult
    mutating func add(_ ratio: CGFloat?) -> Bool {
        guard let ratio, !isComplete else { return false }
        if let minimum = currentMinimum {
            let lowest = min(minimum, ratio)
            if ratio > looseUp {
                // A dip that lasted at least two frames counts as a pinch; one frame is noise.
                let counted = closedFrames >= 2
                if counted { pinchMinimums.append(lowest) }
                currentMinimum = nil
                closedFrames = 0
                return counted
            }
            currentMinimum = lowest
            closedFrames += 1
            return false
        }
        if ratio < looseDown {
            currentMinimum = ratio
            closedFrames = 1
        } else if ratio > looseUp {
            openSamples.append(ratio)
            if openSamples.count > 300 { openSamples.removeFirst(openSamples.count - 300) }
        }
        return false
    }

    func result() -> Result? {
        guard isComplete, openSamples.count >= 10 else { return nil }
        let closed = Self.median(pinchMinimums)
        // The lower part of the open readings: the hand at its most relaxed, not spread wide.
        let open = Self.percentile(openSamples, 0.25)
        let range = open - closed
        guard range > 0.18 else { return .tooSimilar }
        return .trained(PinchThresholds(
            down: closed + 0.35 * range,
            up: closed + 0.55 * range,
            arm: closed + 0.75 * range
        ))
    }

    private static func median(_ values: [CGFloat]) -> CGFloat { percentile(values, 0.5) }

    private static func percentile(_ values: [CGFloat], _ p: Double) -> CGFloat {
        let sorted = values.sorted()
        let index = Int((Double(sorted.count - 1) * p).rounded())
        return sorted[index]
    }
}
