import CoreGraphics

/// The measurements of one hand that pointing and gestures are built from.
///
/// Distances are divided by the hand's own size in the image, so a pinch reads the same
/// whether the hand is near the camera or far from it.
struct HandMetrics: Equatable, Sendable {
    /// Palm center (the mean of the visible knuckles), in Vision coordinates. Calibration
    /// records this. Knuckles barely move when the fingers pinch, so it holds still while
    /// you click.
    var anchor: CGPoint
    /// The palm center in "mirror space": x flipped so +x is the user's right, and both axes
    /// measured in frame heights so distances aren't stretched by the 4:3 image.
    var mirrored: CGPoint
    /// Palm length (wrist to middle knuckle) in frame heights. When the wrist is out of view
    /// or the palm is tilted, it's estimated from the knuckle row instead.
    var scale: CGFloat
    /// Thumb tip to index tip, relative to `scale`. Nil when it can't be measured.
    var indexPinch: CGFloat?
    /// Thumb tip to middle tip, relative to `scale`.
    var middlePinch: CGFloat?
    /// How many of the four fingers (not the thumb) are straight.
    var extendedFingers: Int

    /// An open hand, fingers spread: pauses the cursor, and is the pose for swipes.
    var isOpenPalm: Bool { extendedFingers >= 4 }

    init(anchor: CGPoint, mirrored: CGPoint? = nil, scale: CGFloat, indexPinch: CGFloat?, middlePinch: CGFloat?, extendedFingers: Int) {
        self.anchor = anchor
        self.mirrored = mirrored ?? anchor
        self.scale = scale
        self.indexPinch = indexPinch
        self.middlePinch = middlePinch
        self.extendedFingers = extendedFingers
    }
}

extension HandMetrics {
    init?(pose: HandPose, aspectRatio: CGFloat) {
        let joints = pose.joints
        /// Joint in frame-height units (x scaled by the aspect ratio).
        func point(_ joint: HandJoint) -> CGPoint? {
            joints[joint].map { CGPoint(x: $0.x * aspectRatio, y: $0.y) }
        }

        // Palm center from the knuckles (Gstrl's approach); the wrist as a last resort.
        let knuckles = [HandJoint.indexMCP, .middleMCP, .ringMCP, .littleMCP].compactMap { joints[$0] }
        let anchor: CGPoint
        if knuckles.count >= 2 {
            var sumX: CGFloat = 0, sumY: CGFloat = 0
            for knuckle in knuckles {
                sumX += knuckle.x
                sumY += knuckle.y
            }
            anchor = CGPoint(x: sumX / CGFloat(knuckles.count), y: sumY / CGFloat(knuckles.count))
        } else if let wrist = joints[.wrist] {
            anchor = wrist
        } else {
            return nil
        }

        // Hand size: the larger of the palm length and the knuckle row scaled up to a palm
        // length, so turning the hand edge-on or tilting it doesn't shrink the estimate much.
        var size: CGFloat = 0
        if let wrist = point(.wrist), let knuckle = point(.middleMCP) {
            size = max(size, wrist.distance(to: knuckle))
        }
        if let first = point(.indexMCP), let last = point(.littleMCP) {
            size = max(size, first.distance(to: last) * 1.6)
        }
        guard size > 0.01 else { return nil }

        // Pinch: thumb tip to index tip. Fingertips often vanish while pressed together;
        // then the joint below the tip stands in.
        let thumb = point(.thumbTip)
        let indexPinch = Self.gap(thumb, point(.indexTip), size)
            ?? Self.gap(thumb, point(.indexDIP), size).map { $0 * 0.85 }
        let middlePinch = Self.gap(thumb, point(.middleTip), size)
            ?? Self.gap(thumb, point(.middleDIP), size).map { $0 * 0.85 }

        // A finger is straight when its two segments point the same way (within 60°).
        // Works whatever way the hand is turned, unlike measuring from the wrist.
        let fingers: [(HandJoint, HandJoint, HandJoint, HandJoint)] = [
            (.indexMCP, .indexPIP, .indexDIP, .indexTip),
            (.middleMCP, .middlePIP, .middleDIP, .middleTip),
            (.ringMCP, .ringPIP, .ringDIP, .ringTip),
            (.littleMCP, .littlePIP, .littleDIP, .littleTip),
        ]
        var extended = 0
        for (knuckleJoint, middleJoint, upperJoint, tipJoint) in fingers {
            guard let base = point(knuckleJoint), let bend = point(middleJoint),
                  let end = point(tipJoint) ?? point(upperJoint)
            else { continue }
            if Self.isStraight(base, bend, end, minimumLength: size * 0.12) { extended += 1 }
        }

        self.init(
            anchor: anchor,
            mirrored: CGPoint(x: (1 - anchor.x) * aspectRatio, y: anchor.y),
            scale: size,
            indexPinch: indexPinch,
            middlePinch: middlePinch,
            extendedFingers: extended
        )
    }

    private static func gap(_ a: CGPoint?, _ b: CGPoint?, _ scale: CGFloat) -> CGFloat? {
        guard let a, let b else { return nil }
        return a.distance(to: b) / scale
    }

    private static func isStraight(_ base: CGPoint, _ bend: CGPoint, _ end: CGPoint, minimumLength: CGFloat) -> Bool {
        let first = CGVector(dx: bend.x - base.x, dy: bend.y - base.y)
        let second = CGVector(dx: end.x - bend.x, dy: end.y - bend.y)
        let a = hypot(first.dx, first.dy), b = hypot(second.dx, second.dy)
        // A finger pointing at the camera is foreshortened to almost nothing; don't guess.
        guard a > minimumLength * 0.5, b > minimumLength * 0.5, a + b > minimumLength else { return false }
        return (first.dx * second.dx + first.dy * second.dy) / (a * b) > 0.5
    }
}
