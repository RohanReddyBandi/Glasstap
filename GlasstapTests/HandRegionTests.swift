import CoreGraphics
import XCTest

final class HandRegionTests: XCTestCase {
    private let hand = HandPose(joints: [
        .wrist: CGPoint(x: 0.4, y: 0.3),
        .middleTip: CGPoint(x: 0.45, y: 0.5),
        .indexMCP: CGPoint(x: 0.42, y: 0.4),
    ], confidence: 0.9)

    func testFirstFrameScansWholeFrameThenCropsAroundHand() throws {
        var tracker = HandRegionTracker(aspectRatio: 4.0 / 3.0)
        XCTAssertNil(tracker.nextRegion())
        _ = tracker.process([hand], detectedIn: nil)
        let crop = try XCTUnwrap(tracker.nextRegion())
        XCTAssertTrue(crop.contains(CGPoint(x: 0.4, y: 0.3)))
        XCTAssertTrue(crop.contains(CGPoint(x: 0.45, y: 0.5)))
        XCTAssertLessThan(crop.width, 0.8)
        // Square on the image: width × aspect == height.
        XCTAssertEqual(crop.width * 4.0 / 3.0, crop.height, accuracy: 1e-9)
    }

    func testRescansWholeFramePeriodically() {
        var tracker = HandRegionTracker(aspectRatio: 4.0 / 3.0)
        tracker.rescanEvery = 3
        _ = tracker.process([hand], detectedIn: nil)
        var regions: [CGRect?] = []
        for _ in 0..<5 {
            let region = tracker.nextRegion()
            regions.append(region)
            _ = tracker.process([hand], detectedIn: region)
        }
        XCTAssertTrue(regions.contains { $0 == nil }, "a full-frame scan happens within the interval")
    }

    func testLosingHandGoesBackToWholeFrame() {
        var tracker = HandRegionTracker(aspectRatio: 4.0 / 3.0)
        _ = tracker.process([hand], detectedIn: nil)
        _ = tracker.process([], detectedIn: tracker.nextRegion())
        XCTAssertNil(tracker.nextRegion())
    }

    func testLearnsCropRelativeCoordinates() throws {
        var tracker = HandRegionTracker(aspectRatio: 4.0 / 3.0)
        _ = tracker.process([hand], detectedIn: nil)
        for _ in 0..<3 {
            let crop = try XCTUnwrap(tracker.nextRegion())
            // Vision reports the same hand relative to the crop.
            let relative = HandPose(joints: hand.joints.mapValues {
                CGPoint(x: ($0.x - crop.minX) / crop.width, y: ($0.y - crop.minY) / crop.height)
            }, confidence: 0.9)
            let result = tracker.process([relative], detectedIn: crop)
            XCTAssertEqual(result.first?.joints[.wrist]?.x ?? 0, 0.4, accuracy: 1e-9)
        }
        XCTAssertEqual(tracker.space, .cropRelative)
    }

    func testLearnsWholeFrameCoordinates() throws {
        var tracker = HandRegionTracker(aspectRatio: 4.0 / 3.0)
        _ = tracker.process([hand], detectedIn: nil)
        for _ in 0..<3 {
            let crop = try XCTUnwrap(tracker.nextRegion())
            let result = tracker.process([hand], detectedIn: crop)
            XCTAssertEqual(result.first?.joints[.wrist]?.x ?? 0, 0.4, accuracy: 1e-9)
        }
        XCTAssertEqual(tracker.space, .fullFrame)
    }
}
