import CoreGraphics

/// Turns the hand's camera position into a position on the built-in display: normalized,
/// origin at the bottom-left (AppKit's convention), and *not* clamped, so callers can tell
/// when the hand has gone past the edge.
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

/// One cursor position.
struct PointerSample: Sendable, Equatable {
    /// Host-clock seconds when the camera frame was captured.
    var time: Double
    /// Raw anchor in camera coordinates (Vision convention). Calibration records this.
    var camera: CGPoint
    /// Smoothed position on the display, normalized and clamped to 0...1.
    var screen: CGPoint
    /// Smoothed position before clamping.
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
    /// The other hand, if one is in view.
    var secondary: TrackedHand?
}

/// Follows up to two hands across frames. Maps each to the screen and smooths it, and
/// remembers the last second or so of cursor positions so a tap can be matched to where the
/// hand was when the sound happened.
struct PointerTracker {
    var mapping = PointerMapping.uncalibrated
    /// Restart smoothing when a hand reappears after this long out of view, so the cursor
    /// jumps to the new spot instead of gliding there.
    var restartSmoothingAfter: Double = 0.35

    private var primaryFilter = OneEuroFilter2D()
    private var secondaryFilter = OneEuroFilter2D()
    private var lastSecondary: (time: Double, camera: CGPoint)?
    private(set) var history: [PointerSample] = []
    private let historyDuration: Double = 1.5

    var latest: PointerSample? { history.last }

    mutating func setSmoothing(minCutoff: Double, beta: Double) {
        primaryFilter.minCutoff = minCutoff
        primaryFilter.beta = beta
        secondaryFilter.minCutoff = minCutoff
        secondaryFilter.beta = beta
    }

    mutating func reset() {
        history.removeAll()
        primaryFilter.reset()
        secondaryFilter.reset()
        lastSecondary = nil
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
        let primaryHand = hands[primaryIndex]

        if let last = history.last, frame.time - last.time > restartSmoothingAfter {
            primaryFilter.reset()
        }
        let primarySample = makeSample(primaryHand.metrics.anchor, time: frame.time, filter: &primaryFilter)
        history.append(primarySample)
        history.removeAll { frame.time - $0.time > historyDuration }

        var update = TrackingUpdate(primary: TrackedHand(pose: primaryHand.pose, metrics: primaryHand.metrics, sample: primarySample))

        let others = hands.indices.filter { $0 != primaryIndex }
        if let secondaryIndex = others.min(by: { a, b in
            guard let previous = lastSecondary?.camera else { return a < b }
            return hands[a].metrics.anchor.distance(to: previous) < hands[b].metrics.anchor.distance(to: previous)
        }) {
            let hand = hands[secondaryIndex]
            if let last = lastSecondary, frame.time - last.time > restartSmoothingAfter { secondaryFilter.reset() }
            let sample = makeSample(hand.metrics.anchor, time: frame.time, filter: &secondaryFilter)
            lastSecondary = (frame.time, hand.metrics.anchor)
            update.secondary = TrackedHand(pose: hand.pose, metrics: hand.metrics, sample: sample)
        } else {
            lastSecondary = nil
        }
        return update
    }

    /// Where the cursor was at `time`: the newest sample captured no later than `time`
    /// (plus a few ms of slack for camera exposure), as long as it isn't older than `maxAge`.
    ///
    /// Frames from after the tap are skipped on purpose: tapping the lid shakes the camera.
    func sample(at time: Double, maxAge: Double) -> PointerSample? {
        guard let sample = history.last(where: { $0.time <= time + 0.01 }) else { return nil }
        return time - sample.time <= maxAge ? sample : nil
    }

    private func makeSample(_ anchor: CGPoint, time: Double, filter: inout OneEuroFilter2D) -> PointerSample {
        let mapped = mapping.screenPoint(forCamera: anchor)
        let smoothed = filter.filter(mapped, at: time)
        let clamped = CGPoint(x: smoothed.x.clamped(to: 0...1), y: smoothed.y.clamped(to: 0...1))
        return PointerSample(time: time, camera: anchor, screen: clamped, motion: smoothed)
    }

    /// The hand closest to where the cursor's hand last was keeps the cursor, so a second hand
    /// entering the frame doesn't steal it. With no recent history, the larger (nearer) hand wins.
    private func choosePrimary(_ hands: [HandMetrics], at time: Double) -> Int {
        if let last = history.last, time - last.time <= restartSmoothingAfter * 2 {
            return hands.indices.min { hands[$0].anchor.distance(to: last.camera) < hands[$1].anchor.distance(to: last.camera) } ?? 0
        }
        return hands.indices.max { hands[$0].scale < hands[$1].scale } ?? 0
    }
}
