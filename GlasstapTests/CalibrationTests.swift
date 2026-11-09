import CoreGraphics
import XCTest

final class CalibrationTests: XCTestCase {
    /// A camera→screen mapping with real perspective in it.
    private let truth = Homography(m: [-1.9, 0.12, 1.25, 0.08, 1.7, -0.3, 0.15, -0.2, 1])

    func testHomographyRecoversKnownTransform() throws {
        var source: [CGPoint] = []
        for row in 0..<3 {
            for column in 0..<4 {
                let x: CGFloat = 0.2 + 0.15 * CGFloat(column)
                let y: CGFloat = 0.2 + 0.2 * CGFloat(row)
                source.append(CGPoint(x: x, y: y))
            }
        }
        let target = source.map(truth.apply)
        let fitted = try XCTUnwrap(Homography.fit(from: source, to: target))
        for probe in [CGPoint(x: 0.33, y: 0.41), CGPoint(x: 0.61, y: 0.27)] {
            let expected = truth.apply(probe), actual = fitted.apply(probe)
            XCTAssertEqual(actual.x, expected.x, accuracy: 1e-6)
            XCTAssertEqual(actual.y, expected.y, accuracy: 1e-6)
        }
    }

    func testFitRejectsPointsInALine() {
        let source = (0..<6).map { CGPoint(x: 0.1 * Double($0), y: 0.1 * Double($0)) }
        XCTAssertNil(Homography.fit(from: source, to: source))
    }

    func testSessionFitsConsistentHand() throws {
        var session = CalibrationSession()
        var random = SeededRandom(seed: 11)
        // Mirrored and squashed, the way the camera sees a hand moving in front of the screen,
        // plus a little tremor.
        for target in CalibrationSession.targets {
            let jitter = CGPoint(x: CGFloat(random.nextSigned()) * 0.002, y: CGFloat(random.nextSigned()) * 0.002)
            session.record(CGPoint(x: 0.7 - 0.4 * target.x + jitter.x, y: 0.25 + 0.35 * target.y + jitter.y))
        }
        XCTAssertTrue(session.isComplete)
        let profile = try session.makeProfile(screenAspect: 1512.0 / 982.0).get()
        XCTAssertEqual(profile.quality, .great)

        let center = profile.homography.apply(CGPoint(x: 0.5, y: 0.425))
        XCTAssertEqual(center.x, 0.5, accuracy: 0.02)
        XCTAssertEqual(center.y, 0.5, accuracy: 0.02)
    }

    func testSessionRejectsHandThatBarelyMoved() {
        var session = CalibrationSession()
        for target in CalibrationSession.targets {
            session.record(CGPoint(x: 0.5 + 0.01 * target.x, y: 0.5 + 0.01 * target.y))
        }
        XCTAssertEqual(session.makeProfile(screenAspect: 1.5), .failure(.handBarelyMoved))
    }

    func testSessionRejectsScrambledPoints() {
        var session = CalibrationSession()
        var random = SeededRandom(seed: 5)
        for _ in CalibrationSession.targets {
            session.record(CGPoint(x: 0.5 + CGFloat(random.nextSigned()) * 0.2, y: 0.5 + CGFloat(random.nextSigned()) * 0.2))
        }
        guard case .failure = session.makeProfile(screenAspect: 1.5) else {
            return XCTFail("random points shouldn't produce a calibration")
        }
    }

    func testUndoRemovesLastPoint() {
        var session = CalibrationSession()
        session.record(.zero)
        session.record(.zero)
        session.undo()
        XCTAssertEqual(session.samples.count, 1)
        XCTAssertEqual(session.currentTarget, CalibrationSession.targets[1])
    }
}

final class SemanticVersionTests: XCTestCase {
    func testComparesReleaseTags() throws {
        let a = try XCTUnwrap(SemanticVersion("v1.2.0"))
        let b = try XCTUnwrap(SemanticVersion("1.10"))
        XCTAssertLessThan(a, b)
        XCTAssertEqual(SemanticVersion("0.1"), SemanticVersion("0.1.0"))
        XCTAssertEqual(SemanticVersion("1.0.0-beta.2"), SemanticVersion("1.0.0"))
        XCTAssertNil(SemanticVersion("latest"))
    }
}
