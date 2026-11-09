import CoreGraphics
import Foundation

/// One Euro filter (Casiez, Roussel & Vogel, CHI 2012) for a 2D point.
///
/// It's a low-pass filter whose cutoff rises with speed: when the hand is nearly still the
/// cutoff is low and jitter is smoothed away, and when the hand moves fast the cutoff goes up
/// so the cursor doesn't lag behind. Both axes share one speed estimate so the cursor moves
/// as a unit instead of sliding diagonally.
///
/// Units: positions are whatever the caller uses (here, normalized screen coordinates, so a
/// speed of 1 means one screen width per second).
struct OneEuroFilter2D {
    /// Cutoff in Hz when still. Lower = smoother but laggier at rest.
    var minCutoff: Double
    /// How much the cutoff rises per unit of speed. Higher = less lag when moving fast.
    var beta: Double
    /// Cutoff in Hz for the speed estimate itself.
    var derivativeCutoff: Double

    private var last: CGPoint?
    private var lastDerivative = CGVector.zero
    private var lastTime: Double?

    init(minCutoff: Double = 1.2, beta: Double = 3.0, derivativeCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
    }

    mutating func reset() {
        last = nil
        lastDerivative = .zero
        lastTime = nil
    }

    mutating func filter(_ point: CGPoint, at time: Double) -> CGPoint {
        guard let previous = last, let previousTime = lastTime else {
            last = point
            lastTime = time
            return point
        }
        guard time > previousTime else { return previous }

        let dt = max(time - previousTime, 1.0 / 240.0)
        let rawDerivative = CGVector(dx: (point.x - previous.x) / dt, dy: (point.y - previous.y) / dt)
        let derivativeAlpha = Self.alpha(cutoff: derivativeCutoff, dt: dt)
        let derivative = CGVector(
            dx: derivativeAlpha * rawDerivative.dx + (1 - derivativeAlpha) * lastDerivative.dx,
            dy: derivativeAlpha * rawDerivative.dy + (1 - derivativeAlpha) * lastDerivative.dy
        )
        let speed = hypot(derivative.dx, derivative.dy)
        let alpha = Self.alpha(cutoff: minCutoff + beta * speed, dt: dt)
        let filtered = CGPoint(
            x: alpha * point.x + (1 - alpha) * previous.x,
            y: alpha * point.y + (1 - alpha) * previous.y
        )
        last = filtered
        lastDerivative = derivative
        lastTime = time
        return filtered
    }

    private static func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1.0 / (2.0 * .pi * cutoff)
        return 1.0 / (1.0 + tau / dt)
    }
}
