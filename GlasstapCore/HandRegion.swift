import CoreGraphics

/// Chooses where in the camera frame to look for hands, the way MediaPipe's hand tracker does:
/// once a hand is found, the next frames are analyzed in a crop around it, so the hand fills
/// more of the model's input and its joints come out steadier. The whole frame is rescanned
/// every few frames, and whenever the hand is lost, to pick up a second hand.
///
/// It also handles a Vision ambiguity: results from a request with a region of interest can be
/// relative to that region or to the whole frame. Rather than assume, it checks which reading
/// keeps the hand where it just was, and locks in the answer once it's consistent.
struct HandRegionTracker {
    enum Space: Equatable {
        case unknown, fullFrame, cropRelative
    }

    /// Width / height of the camera frame.
    var aspectRatio: CGFloat
    var rescanEvery = 10
    /// The crop's side, as a multiple of the hand's larger dimension.
    var padding: CGFloat = 2.2
    /// Smallest crop side, in frame heights.
    var minimumSide: CGFloat = 0.35

    private(set) var space = Space.unknown
    private var fullFrameVotes = 0
    private var relativeVotes = 0
    private var region: CGRect?
    private var framesSinceScan = 0
    private var lastCenter: CGPoint?

    init(aspectRatio: CGFloat) {
        self.aspectRatio = aspectRatio
    }

    mutating func reset() {
        region = nil
        framesSinceScan = 0
        lastCenter = nil
    }

    /// Where to run detection next, in normalized Vision coordinates. Nil means the whole frame.
    mutating func nextRegion() -> CGRect? {
        guard let region, framesSinceScan < rescanEvery else {
            framesSinceScan = 0
            return nil
        }
        framesSinceScan += 1
        return region
    }

    /// Converts hands detected in `crop` to whole-frame coordinates, and plans the next crop.
    mutating func process(_ hands: [HandPose], detectedIn crop: CGRect?) -> [HandPose] {
        var result = hands
        if let crop, !hands.isEmpty {
            let converted = hands.map { Self.convert($0, from: crop) }
            switch space {
            case .fullFrame:
                break
            case .cropRelative:
                result = converted
            case .unknown:
                result = chooseSpace(raw: hands, converted: converted)
            }
        }

        if let center = Self.center(of: result.first) {
            lastCenter = center
        }
        region = planRegion(around: result)
        return result
    }

    // MARK: -

    private mutating func chooseSpace(raw: [HandPose], converted: [HandPose]) -> [HandPose] {
        // With nothing to compare against, trust whole-frame coordinates (what Vision does for
        // other requests).
        guard let previous = lastCenter,
              let rawCenter = Self.center(of: raw.first),
              let convertedCenter = Self.center(of: converted.first)
        else { return raw }

        let rawIsCloser = rawCenter.distance(to: previous) <= convertedCenter.distance(to: previous)
        if rawIsCloser { fullFrameVotes += 1 } else { relativeVotes += 1 }
        if fullFrameVotes >= 3, relativeVotes == 0 { space = .fullFrame }
        if relativeVotes >= 3, fullFrameVotes == 0 { space = .cropRelative }
        return rawIsCloser ? raw : converted
    }

    private func planRegion(around hands: [HandPose]) -> CGRect? {
        let points = hands.flatMap { $0.joints.values }
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max()
        else { return nil }

        // Work in frame heights so the crop is square on the actual image.
        let width = (maxX - minX) * aspectRatio
        let height = maxY - minY
        let side = max(max(width, height) * padding, minimumSide)
        let widthNormalized = side / aspectRatio
        guard side < 1, widthNormalized < 1 else { return nil }

        let centerX = (minX + maxX) / 2, centerY = (minY + maxY) / 2
        let x = (centerX - widthNormalized / 2).clamped(to: 0...(1 - widthNormalized))
        let y = (centerY - side / 2).clamped(to: 0...(1 - side))
        return CGRect(x: x, y: y, width: widthNormalized, height: side)
    }

    static func convert(_ hand: HandPose, from crop: CGRect) -> HandPose {
        var converted = hand
        converted.joints = hand.joints.mapValues {
            CGPoint(x: crop.minX + $0.x * crop.width, y: crop.minY + $0.y * crop.height)
        }
        return converted
    }

    private static func center(of hand: HandPose?) -> CGPoint? {
        guard let hand, !hand.joints.isEmpty else { return nil }
        var sumX: CGFloat = 0, sumY: CGFloat = 0
        for point in hand.joints.values {
            sumX += point.x
            sumY += point.y
        }
        let n = CGFloat(hand.joints.count)
        return CGPoint(x: sumX / n, y: sumY / n)
    }
}
