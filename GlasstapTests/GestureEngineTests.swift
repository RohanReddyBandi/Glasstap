import CoreGraphics
import XCTest

final class GestureEngineTests: XCTestCase {
    private let screen = CGSize(width: 1512, height: 982)
    private var engine: GestureEngine!
    private var time = 0.0
    private var actions: [GestureAction] = []
    private var lastFeedback: CursorFeedback?

    override func setUp() {
        engine = GestureEngine(screenSize: screen)
        time = 0
        actions = []
    }

    // MARK: Click

    func testPinchAndReleaseClicks() {
        frames(4, at: CGPoint(x: 0.5, y: 0.5), pinch: 0.9)
        frames(1, at: CGPoint(x: 0.5, y: 0.5), pinch: 0.2)
        XCTAssertEqual(lastFeedback?.state, .pressed)
        frames(2, at: CGPoint(x: 0.5, y: 0.5), pinch: 0.9)
        XCTAssertEqual(actions, [.click(CGPoint(x: 0.5, y: 0.5))])
    }

    func testClickLandsWhereHandWasBeforeFingersClosed() {
        frames(4, at: CGPoint(x: 0.5, y: 0.5), pinch: 0.9)
        frames(1, at: CGPoint(x: 0.5, y: 0.5), pinch: 0.5)    // fingers start closing
        frames(1, at: CGPoint(x: 0.504, y: 0.497), pinch: 0.35)
        frames(1, at: CGPoint(x: 0.508, y: 0.494), pinch: 0.2) // pinched; knuckles drifted a little
        frames(2, at: CGPoint(x: 0.508, y: 0.494), pinch: 0.9)
        XCTAssertEqual(actions, [.click(CGPoint(x: 0.5, y: 0.5))])
    }

    func testOneNoisyOpenFrameDoesNotRelease() {
        frames(3, at: CGPoint(x: 0.5, y: 0.5), pinch: 0.9)
        frames(2, at: CGPoint(x: 0.5, y: 0.5), pinch: 0.2)
        frames(1, at: CGPoint(x: 0.5, y: 0.5), pinch: 0.6)
        frames(2, at: CGPoint(x: 0.5, y: 0.5), pinch: 0.2)
        XCTAssertTrue(actions.isEmpty)
    }

    func testDisabledClickDoesNothing() {
        engine.settings.click = false
        frames(3, at: CGPoint(x: 0.5, y: 0.5), pinch: 0.9)
        frames(2, at: CGPoint(x: 0.5, y: 0.5), pinch: 0.2)
        frames(2, at: CGPoint(x: 0.5, y: 0.5), pinch: 0.9)
        XCTAssertTrue(actions.isEmpty)
    }

    // MARK: Scroll and drag

    func testPinchAndMoveScrollsInsteadOfClicking() {
        frames(3, at: CGPoint(x: 0.5, y: 0.4), pinch: 0.9)
        frames(1, at: CGPoint(x: 0.5, y: 0.4), pinch: 0.2)
        for i in 1...5 { frames(1, at: CGPoint(x: 0.5, y: 0.4 + Double(i) * 0.04), pinch: 0.2) }
        XCTAssertEqual(lastFeedback?.state, .scrolling)
        frames(2, at: CGPoint(x: 0.5, y: 0.6), pinch: 0.9)

        let scrolled: CGFloat = actions.compactMap { action -> CGFloat? in if case .scroll(let v) = action { v.dy } else { nil } }.reduce(0, +)
        XCTAssertEqual(scrolled, 0.2 * screen.height, accuracy: 1, "content should follow the hand one-to-one")
        XCTAssertFalse(actions.contains { if case .click = $0 { true } else { false } })
        guard case .scrollEnded(let velocity)? = actions.last else { return XCTFail("expected scrollEnded, got \(actions)") }
        XCTAssertGreaterThan(velocity.dy, 0)
    }

    func testPinchHoldThenMoveDrags() {
        frames(3, at: CGPoint(x: 0.3, y: 0.3), pinch: 0.9)
        frames(16, at: CGPoint(x: 0.3, y: 0.3), pinch: 0.2)  // ~0.5 s held still
        XCTAssertEqual(actions, [.dragBegan(CGPoint(x: 0.3, y: 0.3))])
        frames(1, at: CGPoint(x: 0.4, y: 0.3), pinch: 0.2)
        XCTAssertEqual(lastFeedback?.state, .dragging)
        frames(2, at: CGPoint(x: 0.5, y: 0.3), pinch: 0.9)
        XCTAssertEqual(actions.first, .dragBegan(CGPoint(x: 0.3, y: 0.3)))
        XCTAssertTrue(actions.contains(.dragMoved(CGPoint(x: 0.4, y: 0.3))))
        XCTAssertEqual(actions.last, .dragEnded(CGPoint(x: 0.5, y: 0.3)))
    }

    func testLosingHandMidDragReleasesIt() {
        frames(3, at: CGPoint(x: 0.3, y: 0.3), pinch: 0.9)
        frames(16, at: CGPoint(x: 0.3, y: 0.3), pinch: 0.2)
        for _ in 0..<10 { step(primary: nil) }
        XCTAssertEqual(actions.last, .dragEnded(CGPoint(x: 0.3, y: 0.3)))
    }

    // MARK: Right-click

    func testMiddleFingerPinchRightClicks() {
        frames(3, at: CGPoint(x: 0.7, y: 0.6), pinch: 0.9, middle: 0.9)
        frames(1, at: CGPoint(x: 0.7, y: 0.6), pinch: 0.9, middle: 0.2)
        XCTAssertEqual(actions, [.rightClick(CGPoint(x: 0.7, y: 0.6))])
    }

    // MARK: Swipe

    func testFastOpenHandSwipeLeft() {
        frames(3, at: CGPoint(x: 0.8, y: 0.5), pinch: 0.9, fingers: 4)
        for i in 1...6 { frames(1, at: CGPoint(x: 0.8 - Double(i) * 0.1, y: 0.5), pinch: 0.9, fingers: 4) }
        XCTAssertEqual(actions, [.swipe(.left)])
    }

    func testFastOpenHandSwipeUp() {
        frames(3, at: CGPoint(x: 0.5, y: 0.2), pinch: 0.9, fingers: 4)
        for i in 1...6 { frames(1, at: CGPoint(x: 0.5, y: 0.2 + Double(i) * 0.1), pinch: 0.9, fingers: 4) }
        XCTAssertEqual(actions, [.swipe(.up)])
    }

    func testSlowHandMoveIsNotASwipe() {
        for i in 0...60 { frames(1, at: CGPoint(x: 0.8 - Double(i) * 0.01, y: 0.5), pinch: 0.9, fingers: 4) }
        XCTAssertTrue(actions.isEmpty)
    }

    func testFastMoveWithFistIsNotASwipe() {
        frames(3, at: CGPoint(x: 0.8, y: 0.5), pinch: 0.9, fingers: 1)
        for i in 1...6 { frames(1, at: CGPoint(x: 0.8 - Double(i) * 0.1, y: 0.5), pinch: 0.9, fingers: 1) }
        XCTAssertTrue(actions.isEmpty)
    }

    // MARK: Zoom

    func testTwoHandPinchSpreadZoomsInWithoutClicking() {
        let left = CGPoint(x: 0.4, y: 0.5), right = CGPoint(x: 0.6, y: 0.5)
        for _ in 0..<3 { step(primary: hand(left, pinch: 0.9), secondary: hand(right, pinch: 0.9)) }
        for _ in 0..<2 { step(primary: hand(left, pinch: 0.2), secondary: hand(right, pinch: 0.2)) }
        XCTAssertEqual(lastFeedback?.state, .zooming)
        step(primary: hand(CGPoint(x: 0.35, y: 0.5), pinch: 0.2), secondary: hand(CGPoint(x: 0.65, y: 0.5), pinch: 0.2))
        XCTAssertEqual(actions, [.zoom(1)])
        // Let go with one hand, then the other: no stray click.
        let spreadLeft = CGPoint(x: 0.35, y: 0.5), spreadRight = CGPoint(x: 0.65, y: 0.5)
        for _ in 0..<2 { step(primary: hand(spreadLeft, pinch: 0.2), secondary: hand(spreadRight, pinch: 0.9)) }
        for _ in 0..<2 { step(primary: hand(spreadLeft, pinch: 0.9), secondary: hand(spreadRight, pinch: 0.9)) }
        XCTAssertEqual(actions, [.zoom(1)])
    }

    // MARK: - Helpers

    private func frames(_ count: Int, at point: CGPoint, pinch: CGFloat, middle: CGFloat = 0.9, fingers: Int = 1) {
        for _ in 0..<count { step(primary: hand(point, pinch: pinch, middle: middle, fingers: fingers)) }
    }

    private func step(primary: HandInput?, secondary: HandInput? = nil) {
        let result = engine.update(time: time, primary: primary, secondary: secondary)
        actions += result.actions
        lastFeedback = result.feedback
        time += 1.0 / 30.0
    }

    private func hand(_ point: CGPoint, pinch: CGFloat, middle: CGFloat = 0.9, fingers: Int = 1) -> HandInput {
        HandInput(
            metrics: HandMetrics(anchor: .zero, scale: 0.15, indexPinch: pinch, middlePinch: middle, extendedFingers: fingers),
            cursor: point,
            motion: point
        )
    }
}

final class PinchDetectorTests: XCTestCase {
    func testHiddenFingertipsKeepPinchBriefly() {
        var detector = PinchDetector()
        XCTAssertEqual(detector.update(ratio: 0.2, time: 0), .down(closingSince: 0))
        XCTAssertNil(detector.update(ratio: nil, time: 0.1))
        XCTAssertNil(detector.update(ratio: nil, time: 0.3))
        XCTAssertTrue(detector.isPinched)
        XCTAssertEqual(detector.update(ratio: nil, time: 0.5), .up)
    }

    func testSensitivityWidensThreshold() {
        let strict = PinchThresholds(sensitivity: 0)
        let loose = PinchThresholds(sensitivity: 1)
        XCTAssertLessThan(strict.down, loose.down)
        XCTAssertGreaterThan(strict.up, strict.down)
        XCTAssertGreaterThan(strict.arm, strict.up)
    }

    func testMetricsFromPose() {
        // Thumb and index tips touching, other fingers curled, wrist below the knuckles.
        let pose = HandPose(joints: [
            .wrist: CGPoint(x: 0.5, y: 0.2),
            .indexMCP: CGPoint(x: 0.48, y: 0.35), .middleMCP: CGPoint(x: 0.5, y: 0.36),
            .thumbTip: CGPoint(x: 0.45, y: 0.42), .indexTip: CGPoint(x: 0.452, y: 0.425),
        ], confidence: 0.9)
        let metrics = HandMetrics(pose: pose, aspectRatio: 4.0 / 3.0)
        XCTAssertNotNil(metrics)
        XCTAssertEqual(metrics?.anchor.x ?? 0, 0.49, accuracy: 1e-9)
        XCTAssertLessThan(metrics?.indexPinch ?? 1, 0.1)
        XCTAssertEqual(metrics?.extendedFingers, 0)
    }
}
