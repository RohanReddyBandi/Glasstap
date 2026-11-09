import CoreGraphics
import Foundation

/// A 3×3 projective transform. Maps the hand's position in the camera image onto the
/// screen: the hand moves in a rough plane in front of the display, and the camera sees that
/// plane in perspective, which is exactly what a homography models.
struct Homography: Codable, Equatable, Sendable {
    /// Row-major.
    var m: [Double]

    static let identity = Homography(m: [1, 0, 0, 0, 1, 0, 0, 0, 1])

    func apply(_ p: CGPoint) -> CGPoint {
        let x = Double(p.x), y = Double(p.y)
        let w = m[6] * x + m[7] * y + m[8]
        guard abs(w) > 1e-12 else { return p }
        return CGPoint(x: (m[0] * x + m[1] * y + m[2]) / w, y: (m[3] * x + m[4] * y + m[5]) / w)
    }

    /// The projective divisor at `p`. A good fit keeps it the same sign everywhere the hand goes.
    func weight(at p: CGPoint) -> Double {
        m[6] * Double(p.x) + m[7] * Double(p.y) + m[8]
    }

    /// Least-squares fit from four or more point pairs (normalized DLT). Nil if the points
    /// are degenerate, for example all in a line.
    static func fit(from source: [CGPoint], to target: [CGPoint]) -> Homography? {
        guard source.count == target.count, source.count >= 4,
              let sourceNormalization = normalization(for: source),
              let targetNormalization = normalization(for: target)
        else { return nil }
        let s = sourceNormalization.0
        let (t, tInverse) = targetNormalization

        let src = source.map { transform(s, $0) }
        let dst = target.map { transform(t, $0) }

        // Normal equations for the 8 unknowns (h33 = 1).
        var ata = [Double](repeating: 0, count: 64)
        var atb = [Double](repeating: 0, count: 8)
        for (p, q) in zip(src, dst) {
            let rows: [([Double], Double)] = [
                ([p.x, p.y, 1, 0, 0, 0, -q.x * p.x, -q.x * p.y], q.x),
                ([0, 0, 0, p.x, p.y, 1, -q.y * p.x, -q.y * p.y], q.y),
            ]
            for (row, b) in rows {
                for i in 0..<8 {
                    atb[i] += row[i] * b
                    for j in 0..<8 { ata[i * 8 + j] += row[i] * row[j] }
                }
            }
        }
        guard let h = solve(ata, atb, size: 8) else { return nil }

        let normalized = h + [1]
        let full = multiply(tInverse, multiply(normalized, s))
        guard abs(full[8]) > 1e-12 else { return nil }
        return Homography(m: full.map { $0 / full[8] })
    }

    // MARK: - Linear algebra

    private struct P { var x: Double; var y: Double }

    /// Hartley normalization: move the points' centroid to the origin and scale them so the
    /// mean distance is √2. Keeps the equations well conditioned.
    private static func normalization(for points: [CGPoint]) -> ([Double], [Double])? {
        let n = Double(points.count)
        let cx = points.reduce(0) { $0 + Double($1.x) } / n
        let cy = points.reduce(0) { $0 + Double($1.y) } / n
        let meanDistance = points.reduce(0) { $0 + hypot(Double($1.x) - cx, Double($1.y) - cy) } / n
        guard meanDistance > 1e-9 else { return nil }
        let k = 2.0.squareRoot() / meanDistance
        return ([k, 0, -k * cx, 0, k, -k * cy, 0, 0, 1], [1 / k, 0, cx, 0, 1 / k, cy, 0, 0, 1])
    }

    private static func transform(_ m: [Double], _ p: CGPoint) -> P {
        let x = Double(p.x), y = Double(p.y)
        return P(x: m[0] * x + m[1] * y + m[2], y: m[3] * x + m[4] * y + m[5])
    }

    private static func multiply(_ a: [Double], _ b: [Double]) -> [Double] {
        var out = [Double](repeating: 0, count: 9)
        for r in 0..<3 {
            for c in 0..<3 {
                out[r * 3 + c] = (0..<3).reduce(0) { $0 + a[r * 3 + $1] * b[$1 * 3 + c] }
            }
        }
        return out
    }

    /// Gaussian elimination with partial pivoting.
    private static func solve(_ matrix: [Double], _ vector: [Double], size n: Int) -> [Double]? {
        var a = matrix
        var b = vector
        for col in 0..<n {
            var pivot = col
            for row in col + 1..<n where abs(a[row * n + col]) > abs(a[pivot * n + col]) { pivot = row }
            guard abs(a[pivot * n + col]) > 1e-12 else { return nil }
            if pivot != col {
                for k in 0..<n { a.swapAt(col * n + k, pivot * n + k) }
                b.swapAt(col, pivot)
            }
            for row in col + 1..<n {
                let factor = a[row * n + col] / a[col * n + col]
                guard factor != 0 else { continue }
                for k in col..<n { a[row * n + k] -= factor * a[col * n + k] }
                b[row] -= factor * b[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = b[row]
            for k in row + 1..<n { sum -= a[row * n + k] * x[k] }
            x[row] = sum / a[row * n + row]
        }
        return x
    }
}

/// A saved calibration.
struct CalibrationProfile: Codable, Equatable, Sendable {
    var homography: Homography
    /// Root-mean-square miss at the calibration dots, as a fraction of the screen's width.
    var rmsError: Double
    var date: Date

    enum Quality: String {
        case great = "Great"
        case good = "Good"
        case rough = "Rough"
    }

    var quality: Quality {
        switch rmsError {
        case ..<0.02: .great
        case ..<0.04: .good
        default: .rough
        }
    }
}

/// Collects one camera position per calibration dot, then fits the mapping.
struct CalibrationSession {
    enum Failure: Error, Equatable {
        /// The hand barely moved between dots, so the mapping would magnify every tremor.
        case handBarelyMoved
        /// The points don't fit any consistent mapping, usually because a pinch was
        /// recorded while the hand was somewhere else.
        case inconsistent
        /// It fits, but badly.
        case poorFit(rmsError: Double)

        var message: String {
            switch self {
            case .handBarelyMoved:
                "Your hand hardly moved between the dots. Move your hand to sit in front of each dot, the way you'd reach for it."
            case .inconsistent:
                "Some points didn't line up with the others. Hold still for a moment before each pinch."
            case .poorFit:
                "The points were too scattered to line up well. Try again, holding still for a moment before each pinch."
            }
        }
    }

    /// Visit order: center first, then a clockwise loop from the top-left, so the hand
    /// moves smoothly from dot to dot. Normalized screen coordinates, origin bottom-left.
    static let targets: [CGPoint] = [
        CGPoint(x: 0.5, y: 0.5),
        CGPoint(x: 0.1, y: 0.9), CGPoint(x: 0.5, y: 0.9), CGPoint(x: 0.9, y: 0.9),
        CGPoint(x: 0.9, y: 0.5),
        CGPoint(x: 0.9, y: 0.1), CGPoint(x: 0.5, y: 0.1), CGPoint(x: 0.1, y: 0.1),
        CGPoint(x: 0.1, y: 0.5),
    ]

    /// Camera-space hand positions, one per completed dot.
    private(set) var samples: [CGPoint] = []

    var currentTarget: CGPoint? {
        samples.count < Self.targets.count ? Self.targets[samples.count] : nil
    }
    var isComplete: Bool { samples.count == Self.targets.count }

    mutating func record(_ cameraPoint: CGPoint) {
        guard !isComplete else { return }
        samples.append(cameraPoint)
    }

    mutating func undo() {
        if !samples.isEmpty { samples.removeLast() }
    }

    /// `screenAspect` is width / height, so errors are measured in screen widths in both axes.
    func makeProfile(screenAspect: Double, date: Date = Date()) -> Result<CalibrationProfile, Failure> {
        guard isComplete else { return .failure(.inconsistent) }

        let xs = samples.map(\.x), ys = samples.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max(),
              maxX - minX >= 0.06, maxY - minY >= 0.04
        else { return .failure(.handBarelyMoved) }

        guard let homography = Homography.fit(from: samples, to: Self.targets) else { return .failure(.inconsistent) }

        // The projective divisor must not change sign inside the area the hand covered, or
        // the mapping folds over itself between the dots.
        let weights = samples.map { homography.weight(at: $0) }
        guard weights.allSatisfy({ $0 > 0 }) || weights.allSatisfy({ $0 < 0 }) else { return .failure(.inconsistent) }

        let squaredErrors = zip(samples, Self.targets).map { sample, target -> Double in
            let mapped = homography.apply(sample)
            let dx = Double(mapped.x - target.x)
            let dy = Double(mapped.y - target.y) / screenAspect
            return dx * dx + dy * dy
        }
        let rms = (squaredErrors.reduce(0, +) / Double(squaredErrors.count)).squareRoot()
        guard rms < 0.08 else { return .failure(.poorFit(rmsError: rms)) }
        return .success(CalibrationProfile(homography: homography, rmsError: rms, date: date))
    }
}
