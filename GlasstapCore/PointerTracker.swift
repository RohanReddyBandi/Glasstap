import CoreGraphics
import Foundation

/// How hand movement drives the cursor.
enum PointerMode: String, Codable, Sendable, CaseIterable {
    /// Like an air trackpad: the cursor moves by how far the hand moves, with acceleration,
    /// starting from wherever it is. No calibration needed, small movements, steady aim.
    case trackpad
    /// The cursor goes where the hand is in front of the screen. Needs calibration.
    case touchscreen
}

/// Touchscreen mode's mapping from the hand's camera position to a position on the
/// built-in display: normalized, origin at the bottom-left (AppKit's convention), and *not*
/// clamped, so callers can tell when the hand has gone past the edge.
enum PointerMapping: Equatable, Sendable {
    /// Rough guess used before calibration: the image is mirrored left-right (the camera faces
    /// you), and the middle of the frame covers the screen.
    case uncalibrated
    case calibrated(Homography)

    static let defaultCameraX: ClosedRange<CGFloat> = 0.2...0.8
    static let defaultCameraY: ClosedRange<CGFloat> = 0.15...0.7

    func screenPoint(forCamera point: CGPoint) -> CGPoint {
        switch self {
        case .uncalibrated:
            let x = Self.defaultCameraX, y = Self.defaultCameraY
            return CGPoint(
                x: 1 - (point.x - x.lowerBound) / (x.upperBound - x.lowerBound),
                y: (point.y - y.lowerBound) / (y.upperBound - y.lowerBound)
            )
        case .calibrated(let homography):
            return homography.apply(point)
        }
    }
}

/// Trackpad mode's pointer speed: screen widths of cursor travel per frame height of hand
/// travel, rising with hand speed. Like macOS pointer acceleration, and Project Gameface's
/// sigmoid curve: slow movements are precise, quick ones cover the screen.
struct PointerAcceleration: Codable, Equatable, Sendable {
    /// Overall speed multiplier (the "Pointer speed" slider).
    var speed: Double = 1.0
    var enabled = true

    static let slowGain = 1.3
    static let fastGain = 6.0
    /// Hand speed (frame heights per second) at the middle of the curve.
    static let midSpeed = 0.35
    static let curveWidth = 0.1
    /// Below this hand speed the cursor doesn't move at all: tremor, not intent.
    static let deadSpeed = 0.012

    func gain(forHandSpeed v: Double) -> Double {
        guard enabled else { return 3.0 * speed }
        let s = 1 / (1 + exp(-(v - Self.midSpeed) / Self.curveWidth))
        return (Self.slowGain + (Self.fastGain - Self.slowGain) * s) * speed
    }
}

/// One cursor position.
struct PointerSample: Sendable, Equatable {
    /// Host-clock seconds when the camera frame was captured.
    var time: Double
    /// Palm center in camera coordinates (Vision convention). Calibration records this.
    var camera: CGPoint
    /// Cursor position on the display, normalized and clamped to 0...1.
    var screen: CGPoint
    /// Unclamped accumulated movement in the same units, for scrolls, which shouldn't stop
    /// at the screen edge.
    var motion: CGPoint
}

struct TrackedHand: Sendable, Equatable {
    var pose: HandPose
    var metrics: HandMetrics
    var sample: PointerSample
}

struct TrackingUpdate: Sendable, Equatable {
    /// The hand that drives the cursor.
    var primary: TrackedHand?
    /// The other hand, if one is in view (two-hand zoom).
    var secondary: TrackedHand?
}

/// Follows up to two hands across frames and turns the primary hand into a cursor, in
/// trackpad or touchscreen mode. Keeps the last second or so of cursor positions, so a tap
/// can be matched to where the cursor was when the sound happened.
struct PointerTracker {
    var mode = PointerMode.trackpad
    var mapping = PointerMapping.uncalibrated
    var acceleration = PointerAcceleration()
    /// Width / height of the screen, to keep trackpad movement the same speed in both axes.
    var screenAspect: CGFloat = 1512.0 / 982.0
    /// Used to steady the cursor while the fingers close for a click.
    var pinchThresholds = PinchThresholds(sensitivity: 0.5)
    /// A hand gone longer than this is treated as new when it comes back: smoothing restarts,
    /// and in trackpad mode it doesn't drag the cursor from where it vanished.
    var restartAfter: Double = 0.35

    private var primaryFilter = OneEuroFilter2D()
    private var lastPrimary: (time: Double, camera: CGPoint)?
    private var lastSecondary: (time: Double, camera: CGPoint)?
    private var cursor = CGPoint(x: 0.5, y: 0.5)
    private var motion = CGPoint(x: 0.5, y: 0.5)
    private var pinned: CGPoint?
    private(set) var history: [PointerSample] = []
    private let historyDuration: Double = 1.5

    /// Camera coordinates are scaled by this before smoothing, so the filter's speed-based
    /// cutoff sees numbers in the same range in both modes (roughly screen widths).
    private static let filterScale: CGFloat = 4

    var latest: PointerSample? { history.last }
    var cursorPosition: CGPoint { cursor }

    mutating func setSmoothing(minCutoff: Double, beta: Double) {
        primaryFilter.minCutoff = minCutoff
        primaryFilter.beta = beta
    }

    mutating func reset() {
        history.removeAll()
        primaryFilter.reset()
        lastPrimary = nil
        lastSecondary = nil
        pinned = nil
    }

    /// Trackpad mode: start from where the real pointer is (after the user moved it with the
    /// trackpad, or when a hand first appears).
    mutating func setCursor(_ point: CGPoint) {
        cursor = CGPoint(x: point.x.clamped(to: 0...1), y: point.y.clamped(to: 0...1))
        motion = cursor
    }

    /// Holds the cursor still while a click or scroll is in progress. Hand movement still
    /// counts toward `motion`, which is what scrolling uses.
    mutating func pin(at point: CGPoint) {
        pinned = point
        cursor = point
    }

    mutating func unpin() {
        pinned = nil
    }

    @discardableResult
    mutating func ingest(_ frame: HandFrame) -> TrackingUpdate {
        let hands = frame.hands.compactMap { pose -> (pose: HandPose, metrics: HandMetrics)? in
            HandMetrics(pose: pose, aspectRatio: frame.aspectRatio).map { (pose, $0) }
        }
        guard !hands.isEmpty else {
            lastSecondary = nil
            return TrackingUpdate()
        }

        let primaryIndex = choosePrimary(hands.map(\.metrics), at: frame.time)
        let primary = hands[primaryIndex]
        let sample = advance(with: primary.metrics, at: frame.time)
        history.append(sample)
        history.removeAll { frame.time - $0.time > historyDuration }
        var update = TrackingUpdate(primary: TrackedHand(pose: primary.pose, metrics: primary.metrics, sample: sample))

        let others = hands.indices.filter { $0 != primaryIndex }
        if let secondaryIndex = others.min(by: { a, b in
            guard let previous = lastSecondary?.camera else { return a < b }
            return hands[a].metrics.mirrored.distance(to: previous) < hands[b].metrics.mirrored.distance(to: previous)
        }) {
            let hand = hands[secondaryIndex]
            lastSecondary = (frame.time, hand.metrics.mirrored)
            let secondarySample = PointerSample(time: frame.time, camera: hand.metrics.anchor, screen: .zero, motion: .zero)
            update.secondary = TrackedHand(pose: hand.pose, metrics: hand.metrics, sample: secondarySample)
        } else {
            lastSecondary = nil
        }
        return update
    }

    /// Where the cursor was at `time`: the newest sample captured no later than `time`
    /// (plus a few ms of slack for camera exposure), as long as it isn't older than `maxAge`.
    func sample(at time: Double, maxAge: Double) -> PointerSample? {
        guard let sample = history.last(where: { $0.time <= time + 0.01 }) else { return nil }
        return time - sample.time <= maxAge ? sample : nil
    }

    // MARK: - Moving the cursor

    private mutating func advance(with metrics: HandMetrics, at time: Double) -> PointerSample {
        let isContinuing = lastPrimary.map { time - $0.time <= restartAfter } ?? false
        if !isContinuing { primaryFilter.reset() }
        // An open palm pauses the cursor: it's the swipe pose, and in trackpad mode it's how
        // you reposition your hand without moving the cursor.
        let steering = !metrics.isOpenPalm

        switch mode {
        case .trackpad:
            let scaled = CGPoint(x: metrics.mirrored.x * Self.filterScale, y: metrics.mirrored.y * Self.filterScale)
            let smoothed = primaryFilter.filter(scaled, at: time)
            let camera = CGPoint(x: smoothed.x / Self.filterScale, y: smoothed.y / Self.filterScale)
            if isContinuing, let last = lastPrimary, steering {
                let dx = camera.x - last.camera.x, dy = camera.y - last.camera.y
                let dt = max(time - last.time, 1.0 / 120.0)
                let handSpeed = Double(hypot(dx, dy)) / dt
                if handSpeed > PointerAcceleration.deadSpeed {
                    let gain = CGFloat(acceleration.gain(forHandSpeed: handSpeed)) * steadying(metrics.indexPinch)
                    let delta = CGVector(dx: dx * gain, dy: dy * gain * screenAspect)
                    motion.x += delta.dx
                    motion.y += delta.dy
                    if pinned == nil {
                        cursor = CGPoint(x: (cursor.x + delta.dx).clamped(to: 0...1), y: (cursor.y + delta.dy).clamped(to: 0...1))
                    }
                }
            }
            lastPrimary = (time, camera)

        case .touchscreen:
            let mapped = mapping.screenPoint(forCamera: metrics.anchor)
            let smoothed = primaryFilter.filter(mapped, at: time)
            if steering || !isContinuing {
                motion = smoothed
                if pinned == nil {
                    cursor = CGPoint(x: smoothed.x.clamped(to: 0...1), y: smoothed.y.clamped(to: 0...1))
                }
            }
            lastPrimary = (time, metrics.mirrored)
        }

        return PointerSample(time: time, camera: metrics.anchor, screen: cursor, motion: motion)
    }

    /// Closing the fingers for a pinch nudges the palm. Damp the cursor on the way in so a
    /// click lands where you aimed; full speed again once pinched (for dragging).
    private func steadying(_ ratio: CGFloat?) -> CGFloat {
        guard let ratio else { return 1 }
        let t = pinchThresholds
        guard ratio > t.down, ratio < t.arm else { return 1 }
        let x = (ratio - t.down) / (t.arm - t.down)
        return 0.15 + 0.85 * x * x
    }

    /// The hand closest to where the cursor's hand last was keeps the cursor, so a second hand
    /// entering the frame doesn't steal it. With no recent history, the larger (nearer) hand wins.
    private func choosePrimary(_ hands: [HandMetrics], at time: Double) -> Int {
        // `lastPrimary.camera` is in mirror space in both modes.
        if let last = lastPrimary, time - last.time <= restartAfter * 2 {
            return hands.indices.min {
                hands[$0].mirrored.distance(to: last.camera) < hands[$1].mirrored.distance(to: last.camera)
            } ?? 0
        }
        return hands.indices.max { hands[$0].scale < hands[$1].scale } ?? 0
    }
}
