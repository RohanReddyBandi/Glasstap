import CoreGraphics

/// The measurements of one hand that gestures are built from.
///
/// Distances are divided by the hand's own size in the image, so a pinch reads the same
/// whether your hand is near the camera or far from it.
struct HandMetrics: Equatable, Sendable {
    /// Cursor anchor in camera coordinates (see `HandPose.anchor`).
    var anchor: CGPoint
    /// Wrist-to-middle-knuckle length, in aspect-corrected image units.
    var scale: CGFloat
    /// Thumb tip to index tip, relative to `scale`. Nil when either tip isn't visible.
    var indexPinch: CGFloat?
    /// Thumb tip to middle tip, relative to `scale`.
    var middlePinch: CGFloat?
    /// How many of the four fingers (not the thumb) are straight.
    var extendedFingers: Int

    var isOpenPalm: Bool { extendedFingers >= 4 }
}

extension HandMetrics {
    init?(pose: HandPose, aspectRatio: CGFloat) {
        guard let anchor = pose.anchor else { return nil }
        let joints = pose.joints
        func point(_ joint: HandJoint) -> CGPoint? {
            joints[joint].map { CGPoint(x: $0.x * aspectRatio, y: $0.y) }
        }

        let size: CGFloat
        if let wrist = point(.wrist), let knuckle = point(.middleMCP) {
            size = wrist.distance(to: knuckle)
        } else if let first = point(.indexMCP), let last = point(.littleMCP) {
            // The knuckle row is about 0.6 of the wrist-to-knuckle length.
            size = first.distance(to: last) * 1.6
        } else {
            return nil
        }
        guard size > 0.005 else { return nil }

        let thumb = point(.thumbTip)

        let wrist = point(.wrist)
        let fingers: [(knuckle: HandJoint, middle: HandJoint, tip: HandJoint)] = [
            (.indexMCP, .indexPIP, .indexTip),
            (.middleMCP, .middlePIP, .middleTip),
            (.ringMCP, .ringPIP, .ringTip),
            (.littleMCP, .littlePIP, .littleTip),
        ]
        let extended = fingers.filter { finger in
            guard let middleJoint = point(finger.middle), let tipJoint = point(finger.tip) else { return false }
            if let wrist {
                return wrist.distance(to: tipJoint) > wrist.distance(to: middleJoint) * 1.15
            }
            guard let knuckleJoint = point(finger.knuckle) else { return false }
            return knuckleJoint.distance(to: tipJoint) > knuckleJoint.distance(to: middleJoint) * 1.6
        }.count

        self.init(
            anchor: anchor,
            scale: size,
            indexPinch: Self.ratio(thumb, point(.indexTip), size),
            middlePinch: Self.ratio(thumb, point(.middleTip), size),
            extendedFingers: extended
        )
    }

    private static func ratio(_ a: CGPoint?, _ b: CGPoint?, _ scale: CGFloat) -> CGFloat? {
        guard let a, let b else { return nil }
        return a.distance(to: b) / scale
    }
}
