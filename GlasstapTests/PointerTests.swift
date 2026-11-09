import CoreGraphics
import XCTest

final class OneEuroFilterTests: XCTestCase {
    func testStillInputPassesThrough() {
        var filter = OneEuroFilter2D()
        var out = CGPoint.zero
        for i in 0..<30 {
            out = filter.filter(CGPoint(x: 0.5, y: 0.25), at: Double(i) / 30)
        }
        XCTAssertEqual(out.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(out.y, 0.25, accuracy: 1e-9)
    }

    func testSmoothsJitterWhenHandIsStill() {
        var filter = OneEuroFilter2D()
        var random = SeededRandom(seed: 3)
        var raw: [CGFloat] = []
        var smoothed: [CGFloat] = []
        for i in 0..<120 {
            let x = 0.5 + CGFloat(random.nextSigned()) * 0.01
            raw.append(x)
            smoothed.append(filter.filter(CGPoint(x: x, y: 0.5), at: Double(i) / 30).x)
        }
        XCTAssertLessThan(spread(smoothed.dropFirst(30)), spread(raw.dropFirst(30)) * 0.5)
    }

    func testLagsLessThanFixedSmoothingWhenMovingFast() {
        func lag(_ filter: inout OneEuroFilter2D) -> CGFloat {
            var out = CGPoint.zero
            var truth: CGFloat = 0
            for i in 0..<15 {
                let t = Double(i) / 30
                truth = CGFloat(2 * t)
                out = filter.filter(CGPoint(x: truth, y: 0), at: t)
            }
            return truth - out.x
        }
        var adaptive = OneEuroFilter2D()
        var fixed = OneEuroFilter2D(minCutoff: 1.2, beta: 0)
        XCTAssertLessThan(lag(&adaptive), lag(&fixed) * 0.5)
    }

    private func spread<C: Collection>(_ values: C) -> CGFloat where C.Element == CGFloat {
        let mean = values.reduce(0, +) / CGFloat(values.count)
        return (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / CGFloat(values.count)).squareRoot()
    }
}

final class PointerTrackerTests: XCTestCase {
    // MARK: Trackpad mode

    func testTrackpadMovesCursorByHandMovement() {
        var tracker = PointerTracker()
        tracker.setCursor(CGPoint(x: 0.5, y: 0.5))
        // The user's hand moves to their right: in the unmirrored image, x decreases.
        var last = CGPoint.zero
        for i in 0..<20 {
            last = tracker.ingest(frame(at: Double(i) / 30, x: 0.5 - CGFloat(i) * 0.004)).primary!.sample.screen
        }
        XCTAssertGreaterThan(last.x, 0.55, "cursor follows the hand to the right")
        XCTAssertEqual(last.y, 0.5, accuracy: 0.01)
    }

    func testTrackpadHandReappearingDoesNotJump() {
        var tracker = PointerTracker()
        tracker.setCursor(CGPoint(x: 0.3, y: 0.3))
        tracker.ingest(frame(at: 0, x: 0.5))
        tracker.ingest(frame(at: 0.033, x: 0.5))
        // Gone for a second, then back somewhere else entirely.
        let update = tracker.ingest(frame(at: 1.0, x: 0.2))
        XCTAssertEqual(update.primary?.sample.screen.x ?? 0, 0.3, accuracy: 1e-6)
    }

    func testTrackpadOpenPalmPausesCursor() {
        var tracker = PointerTracker()
        tracker.setCursor(CGPoint(x: 0.5, y: 0.5))
        var last = CGPoint.zero
        for i in 0..<20 {
            last = tracker.ingest(frame(at: Double(i) / 30, x: 0.5 - CGFloat(i) * 0.01, open: true)).primary!.sample.screen
        }
        XCTAssertEqual(last, CGPoint(x: 0.5, y: 0.5))
    }

    func testTrackpadFastMovementTravelsFurther() {
        func travel(step: CGFloat, frames: Int) -> CGFloat {
            var tracker = PointerTracker()
            tracker.setCursor(CGPoint(x: 0.1, y: 0.5))
            var x: CGFloat = 0.1
            for i in 0..<frames {
                x = tracker.ingest(frame(at: Double(i) / 30, x: 0.7 - CGFloat(i) * step)).primary!.sample.screen.x
            }
            return x - 0.1
        }
        // The same total hand movement, slowly and quickly.
        let slow = travel(step: 0.002, frames: 61)
        let fast = travel(step: 0.012, frames: 11)
        XCTAssertGreaterThan(fast, slow * 2, "acceleration: a quick flick covers more screen")
    }

    func testPinnedCursorHoldsButMotionContinues() {
        var tracker = PointerTracker()
        tracker.setCursor(CGPoint(x: 0.5, y: 0.5))
        tracker.ingest(frame(at: 0, x: 0.5))
        tracker.pin(at: CGPoint(x: 0.5, y: 0.5))
        var sample: PointerSample?
        for i in 1..<10 { sample = tracker.ingest(frame(at: Double(i) / 30, x: 0.5 - CGFloat(i) * 0.01)).primary?.sample }
        XCTAssertEqual(sample?.screen, CGPoint(x: 0.5, y: 0.5))
        XCTAssertGreaterThan(sample?.motion.x ?? 0, 0.55)
    }

    // MARK: Touchscreen mode

    func testMappingMirrorsCamera() {
        let mapping = PointerMapping.uncalibrated
        XCTAssertGreaterThan(mapping.screenPoint(forCamera: CGPoint(x: 0.22, y: 0.4)).x, 0.9)
        XCTAssertLessThan(mapping.screenPoint(forCamera: CGPoint(x: 0.78, y: 0.4)).x, 0.1)
    }

    func testTouchscreenCursorIsClampedButMotionIsNot() {
        var tracker = PointerTracker()
        tracker.mode = .touchscreen
        let update = tracker.ingest(frame(at: 0, x: 0.05))
        XCTAssertEqual(update.primary?.sample.screen.x, 1)
        XCTAssertGreaterThan(update.primary?.sample.motion.x ?? 0, 1)
    }

    func testTouchscreenUsesCalibration() {
        var tracker = PointerTracker()
        tracker.mode = .touchscreen
        tracker.mapping = .calibrated(Homography(m: [0, 0, 0.25, 0, 0, 0.75, 0, 0, 1]))
        let update = tracker.ingest(frame(at: 0, x: 0.5))
        XCTAssertEqual(update.primary?.sample.screen, CGPoint(x: 0.25, y: 0.75))
    }

    // MARK: Both

    func testTapUsesLatestFrameBeforeTheSound() {
        var tracker = PointerTracker()
        for i in 0..<10 {
            tracker.ingest(frame(at: Double(i) / 30, x: 0.3 + CGFloat(i) * 0.01))
        }
        // Tap at 0.185 s: the frame at 0.2 s (i = 6) came after the sound and is past the
        // 10 ms exposure slack, so the 0.167 s frame (i = 5) is the one to use.
        let sample = tracker.sample(at: 0.185, maxAge: 0.45)
        XCTAssertEqual(sample?.time ?? -1, 5.0 / 30, accuracy: 1e-9)
    }

    func testTapIgnoredWhenHandLongGone() {
        var tracker = PointerTracker()
        tracker.ingest(frame(at: 0, x: 0.4))
        tracker.ingest(frame(at: 0.033, x: 0.4))
        XCTAssertNotNil(tracker.sample(at: 0.3, maxAge: 0.45))
        XCTAssertNil(tracker.sample(at: 0.6, maxAge: 0.45))
    }

    func testFramesWithoutHandsDontCount() {
        var tracker = PointerTracker()
        XCTAssertNil(tracker.ingest(HandFrame(time: 0, hands: [], visionMilliseconds: 5)).primary)
        XCTAssertNil(tracker.latest)
    }

    func testCursorStaysWithSameHandWhenSecondHandAppears() {
        var tracker = PointerTracker()
        tracker.ingest(frame(at: 0, x: 0.30))
        let update = tracker.ingest(HandFrame(time: 0.033, hands: [hand(x: 0.7, size: 0.2), hand(x: 0.31)], visionMilliseconds: 5))
        XCTAssertEqual(update.primary?.metrics.anchor.x ?? 0, 0.31, accuracy: 1e-9)
        XCTAssertEqual(update.secondary?.metrics.anchor.x ?? 0, 0.7, accuracy: 1e-9)
    }

    // MARK: - Helpers

    private func hand(x: CGFloat, size: CGFloat = 0.12, open: Bool = false) -> HandPose {
        var joints: [HandJoint: CGPoint] = [
            .indexMCP: CGPoint(x: x - 0.01, y: 0.4),
            .middleMCP: CGPoint(x: x + 0.01, y: 0.4),
            .wrist: CGPoint(x: x, y: 0.4 - size),
        ]
        if open {
            // Four straight fingers pointing up.
            let fingers: [(HandJoint, HandJoint, HandJoint, HandJoint, CGFloat)] = [
                (.indexMCP, .indexPIP, .indexDIP, .indexTip, -0.03),
                (.middleMCP, .middlePIP, .middleDIP, .middleTip, -0.01),
                (.ringMCP, .ringPIP, .ringDIP, .ringTip, 0.01),
                (.littleMCP, .littlePIP, .littleDIP, .littleTip, 0.03),
            ]
            for (mcp, pip, dip, tip, offset) in fingers {
                joints[mcp] = CGPoint(x: x + offset, y: 0.4)
                joints[pip] = CGPoint(x: x + offset, y: 0.45)
                joints[dip] = CGPoint(x: x + offset, y: 0.48)
                joints[tip] = CGPoint(x: x + offset, y: 0.51)
            }
        }
        return HandPose(joints: joints, confidence: 0.9)
    }

    private func frame(at time: Double, x: CGFloat, open: Bool = false) -> HandFrame {
        HandFrame(time: time, hands: [hand(x: x, open: open)], visionMilliseconds: 5)
    }
}
