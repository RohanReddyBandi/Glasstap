import CoreGraphics

/// The 21 hand landmarks Vision reports, in a form the rest of the app can use without
/// importing Vision.
enum HandJoint: Int, CaseIterable, Sendable {
    case wrist
    case thumbCMC, thumbMP, thumbIP, thumbTip
    case indexMCP, indexPIP, indexDIP, indexTip
    case middleMCP, middlePIP, middleDIP, middleTip
    case ringMCP, ringPIP, ringDIP, ringTip
    case littleMCP, littlePIP, littleDIP, littleTip

    /// Joint pairs drawn as bones in the debug view.
    static let bones: [(HandJoint, HandJoint)] = [
        (.wrist, .thumbCMC), (.thumbCMC, .thumbMP), (.thumbMP, .thumbIP), (.thumbIP, .thumbTip),
        (.wrist, .indexMCP), (.indexMCP, .indexPIP), (.indexPIP, .indexDIP), (.indexDIP, .indexTip),
        (.wrist, .middleMCP), (.middleMCP, .middlePIP), (.middlePIP, .middleDIP), (.middleDIP, .middleTip),
        (.wrist, .ringMCP), (.ringMCP, .ringPIP), (.ringPIP, .ringDIP), (.ringDIP, .ringTip),
        (.wrist, .littleMCP), (.littleMCP, .littlePIP), (.littlePIP, .littleDIP), (.littleDIP, .littleTip),
        (.indexMCP, .middleMCP), (.middleMCP, .ringMCP), (.ringMCP, .littleMCP),
    ]
}

/// One detected hand.
///
/// Positions are normalized camera coordinates in Vision's convention: origin at the
/// bottom-left of the *unmirrored* camera image, y pointing up. The user's right hand
/// therefore appears on the left half of the image.
struct HandPose: Sendable, Equatable {
    var joints: [HandJoint: CGPoint]
    var confidence: Float

    /// The point that drives the cursor: midway between the index and middle knuckles.
    /// Knuckles barely move when the fingers pinch, so the cursor holds still while you click.
    var anchor: CGPoint? {
        switch (joints[.indexMCP], joints[.middleMCP]) {
        case let (a?, b?): CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        case let (a?, nil): a
        case let (nil, b?): b
        case (nil, nil): nil
        }
    }
}

/// The hands found in one camera frame.
struct HandFrame: Sendable, Equatable {
    /// Host-clock seconds (same clock as `CACurrentMediaTime()`) when the frame was captured.
    var time: Double
    var hands: [HandPose]
    /// How long hand detection took for this frame.
    var visionMilliseconds: Double
    /// Width / height of the camera image, needed to measure distances between joints
    /// (Vision normalizes x and y by different lengths).
    var aspectRatio: CGFloat = 4.0 / 3.0
}

extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        hypot(x - other.x, y - other.y)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
