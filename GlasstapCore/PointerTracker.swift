import CoreGraphics

/// Turns the pointer's camera position into a normalized position on the built-in display:
/// 0...1 on both axes, origin at the bottom-left (AppKit's convention).
///
/// This is the uncalibrated guess used until the 9-dot calibration exists. The image is
/// mirrored left-right (the camera faces you), and the display maps to the lower part of the
/// frame: the camera sits above the screen, so a hand reaching for the glass shows up low in
/// the image.
struct PointerMapping: Sendable, Equatable {
    var cameraX: ClosedRange<CGFloat> = 0.15...0.85
    var cameraY: ClosedRange<CGFloat> = 0.05...0.65

    func screenPoint(forCamera point: CGPoint) -> CGPoint {
        let nx = 1 - (point.x - cameraX.lowerBound) / (cameraX.upperBound - cameraX.lowerBound)
        let ny = (point.y - cameraY.lowerBound) / (cameraY.upperBound - cameraY.lowerBound)
        return CGPoint(x: nx.clamped(to: 0...1), y: ny.clamped(to: 0...1))
    }
}

/// One cursor position: where the pointer joint was in the camera, and where that lands on
/// screen after mapping and smoothing.
struct PointerSample: Sendable, Equatable {
    /// Host-clock seconds when the camera frame was captured.
    var time: Double
    /// Raw pointer joint, Vision coordinates.
    var camera: CGPoint
    /// Smoothed position on the display, normalized, origin bottom-left.
    var screen: CGPoint
}

/// Follows one hand across frames, maps it to the screen, smooths it, and remembers the
/// last second or so of positions so a tap can be matched to where the hand was when the
/// sound happened rather than when it was processed.
struct PointerTracker {
    var mapping = PointerMapping()
    var filter = OneEuroFilter2D()
    /// Restart smoothing when the hand reappears after this long out of view, so the cursor
    /// jumps to the new spot instead of gliding there.
    var restartSmoothingAfter: Double = 0.35

    private(set) var history: [PointerSample] = []
    private let historyDuration: Double = 1.5

    var latest: PointerSample? { history.last }

    mutating func reset() {
        history.removeAll()
        filter.reset()
    }

    /// Adds a frame. Returns the new cursor sample, or nil if no usable hand was in it.
    @discardableResult
    mutating func ingest(_ frame: HandFrame) -> PointerSample? {
        guard let point = choosePointer(in: frame.hands) else { return nil }
        if let last = history.last, frame.time - last.time > restartSmoothingAfter {
            filter.reset()
        }
        let mapped = mapping.screenPoint(forCamera: point)
        let smoothed = filter.filter(mapped, at: frame.time)
        let sample = PointerSample(time: frame.time, camera: point, screen: smoothed)
        history.append(sample)
        history.removeAll { frame.time - $0.time > historyDuration }
        return sample
    }

    /// Where the cursor was at `time`: the newest sample captured no later than `time`
    /// (plus a few ms of slack for camera exposure), as long as it isn't older than `maxAge`.
    ///
    /// Frames from after the tap are skipped on purpose: tapping the lid shakes the camera.
    func sample(at time: Double, maxAge: Double) -> PointerSample? {
        guard let sample = history.last(where: { $0.time <= time + 0.01 }) else { return nil }
        return time - sample.time <= maxAge ? sample : nil
    }

    /// Picks which hand drives the cursor: the one closest to where the cursor last was, so
    /// a second hand entering the frame doesn't steal it. With no history, the most
    /// confident hand wins.
    private func choosePointer(in hands: [HandPose]) -> CGPoint? {
        let candidates = hands.compactMap { hand in hand.pointer.map { (hand, $0) } }
        guard !candidates.isEmpty else { return nil }
        if let previous = history.last?.camera {
            return candidates.min { $0.1.distance(to: previous) < $1.1.distance(to: previous) }?.1
        }
        return candidates.max { $0.0.confidence < $1.0.confidence }?.1
    }
}
