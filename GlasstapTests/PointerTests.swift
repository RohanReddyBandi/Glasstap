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
        // Hand sweeping across the screen at two screen-widths per second.
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
    func testMappingMirrorsCamera() {
        let mapping = PointerMapping()
        // Your right hand shows up on the left of the unmirrored image, and should drive the
        // right side of the screen.
        XCTAssertGreaterThan(mapping.screenPoint(forCamera: CGPoint(x: 0.2, y: 0.3)).x, 0.9)
        XCTAssertLessThan(mapping.screenPoint(forCamera: CGPoint(x: 0.8, y: 0.3)).x, 0.1)
        let clamped = mapping.screenPoint(forCamera: CGPoint(x: -1, y: 2))
        XCTAssertEqual(clamped, CGPoint(x: 1, y: 1))
    }

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
        XCTAssertNil(tracker.ingest(HandFrame(time: 0, hands: [], visionMilliseconds: 5)))
        XCTAssertNil(tracker.latest)
    }

    func testFollowsSameHandWhenSecondHandAppears() {
        var tracker = PointerTracker()
        tracker.ingest(frame(at: 0, x: 0.30))
        let other = HandPose(joints: [.indexTip: CGPoint(x: 0.8, y: 0.3)], confidence: 0.99)
        let same = HandPose(joints: [.indexTip: CGPoint(x: 0.31, y: 0.3)], confidence: 0.5)
        let sample = tracker.ingest(HandFrame(time: 0.033, hands: [other, same], visionMilliseconds: 5))
        XCTAssertEqual(sample?.camera.x ?? 0, 0.31, accuracy: 1e-9)
    }

    func testFallsBackToLowerIndexJointWhenTipHidden() {
        let hand = HandPose(joints: [.indexPIP: CGPoint(x: 0.4, y: 0.2), .wrist: .zero], confidence: 0.9)
        XCTAssertEqual(hand.pointer, CGPoint(x: 0.4, y: 0.2))
    }

    private func frame(at time: Double, x: CGFloat) -> HandFrame {
        HandFrame(
            time: time,
            hands: [HandPose(joints: [.indexTip: CGPoint(x: x, y: 0.3)], confidence: 0.9)],
            visionMilliseconds: 5
        )
    }
}
