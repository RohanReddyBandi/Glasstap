import XCTest

final class TapDetectorTests: XCTestCase {
    private let rate = 48_000.0

    func testDetectsSharpTapInQuietRoom() {
        var signal = Signal(rate: rate, seconds: 1, noise: 0.001)
        signal.addTap(at: 0.5, amplitude: 0.3)

        let taps = run(signal.samples).taps
        XCTAssertEqual(taps.count, 1)
        XCTAssertEqual(taps.first?.time ?? 0, 0.5, accuracy: 0.003, "onset time should be within a few ms")
        XCTAssertGreaterThan(taps.first?.peakDB ?? -100, -15)
    }

    func testIgnoresTapBelowThreshold() {
        var signal = Signal(rate: rate, seconds: 1, noise: 0.001)
        signal.addTap(at: 0.5, amplitude: 0.004)  // ≈ -48 dBFS, threshold is -42
        XCTAssertTrue(run(signal.samples).taps.isEmpty)
    }

    func testRaisingThresholdHidesTap() {
        var signal = Signal(rate: rate, seconds: 1, noise: 0.001)
        signal.addTap(at: 0.5, amplitude: 0.3)  // ≈ -10 dBFS
        var strict = TapDetector.Parameters()
        strict.minPeakDB = -5
        XCTAssertTrue(run(signal.samples, parameters: strict).taps.isEmpty)
    }

    func testRejectsVoiceLikeSound() {
        var signal = Signal(rate: rate, seconds: 1, noise: 0.001)
        signal.addTone(at: 0.3, duration: 0.4, attack: 0.025, amplitude: 0.2)
        XCTAssertTrue(run(signal.samples).taps.isEmpty)
    }

    func testRejectsSuddenContinuousNoise() {
        var signal = Signal(rate: rate, seconds: 1.2, noise: 0.001)
        signal.addNoise(at: 0.3, duration: 0.7, amplitude: 0.1)
        let outcomes = run(signal.samples)
        XCTAssertTrue(outcomes.taps.isEmpty)
        XCTAssertFalse(outcomes.sustained.isEmpty, "a sharp start that keeps going should be reported as sustained")
    }

    func testDoubleHitWithinRefractoryCountsOnce() {
        var signal = Signal(rate: rate, seconds: 1, noise: 0.001)
        signal.addTap(at: 0.40, amplitude: 0.3)
        signal.addTap(at: 0.46, amplitude: 0.2)
        XCTAssertEqual(run(signal.samples).taps.count, 1)
    }

    func testSeparateTapsBothCount() {
        var signal = Signal(rate: rate, seconds: 1, noise: 0.001)
        signal.addTap(at: 0.3, amplitude: 0.3)
        signal.addTap(at: 0.7, amplitude: 0.3)
        let taps = run(signal.samples).taps
        XCTAssertEqual(taps.count, 2)
        XCTAssertEqual(taps.last?.time ?? 0, 0.7, accuracy: 0.003)
    }

    func testTapOverBackgroundChatterStillDetected() {
        var signal = Signal(rate: rate, seconds: 1.5, noise: 0.001)
        signal.addTone(at: 0.1, duration: 1.3, attack: 0.03, amplitude: 0.01)  // quiet voice-level hum
        signal.addTap(at: 0.9, amplitude: 0.3)
        let taps = run(signal.samples).taps
        XCTAssertEqual(taps.count, 1)
        XCTAssertEqual(taps.first?.time ?? 0, 0.9, accuracy: 0.003)
    }

    // MARK: - Helpers

    private func run(_ samples: [Float], parameters: TapDetector.Parameters = .init(), chunk: Int = 512) -> [TapDetector.Outcome] {
        var detector = TapDetector(sampleRate: rate, parameters: parameters)
        var outcomes: [TapDetector.Outcome] = []
        var start = 0
        while start < samples.count {
            let end = min(start + chunk, samples.count)
            samples[start..<end].withUnsafeBufferPointer { buffer in
                if let outcome = detector.process(buffer, startTime: Double(start) / rate) {
                    outcomes.append(outcome)
                }
            }
            start = end
        }
        return outcomes
    }
}

private extension Array where Element == TapDetector.Outcome {
    var taps: [TapDetector.Event] {
        compactMap { if case .tap(let event) = $0 { event } else { nil } }
    }
    var sustained: [TapDetector.Event] {
        compactMap { if case .sustained(let event) = $0 { event } else { nil } }
    }
}

/// Builds synthetic microphone signals.
struct Signal {
    let rate: Double
    private(set) var samples: [Float]
    private var random = SeededRandom(seed: 0x9E37_79B9)

    init(rate: Double, seconds: Double, noise: Float) {
        self.rate = rate
        var random = SeededRandom(seed: 7)
        samples = (0..<Int(rate * seconds)).map { _ in random.nextSigned() * noise }
    }

    /// A tap: a burst of broadband noise with a very fast attack and an exponential decay.
    mutating func addTap(at time: Double, amplitude: Float, decay: Double = 0.004) {
        let start = Int(time * rate)
        for i in 0..<Int(0.06 * rate) where start + i < samples.count {
            let envelope = Float(exp(-Double(i) / rate / decay))
            samples[start + i] += random.nextSigned() * amplitude * envelope
        }
    }

    /// A voiced sound: a 180 Hz tone with harmonics and a ramped attack, held steady.
    mutating func addTone(at time: Double, duration: Double, attack: Double, amplitude: Float, frequency: Double = 180) {
        let start = Int(time * rate)
        for i in 0..<Int(duration * rate) where start + i < samples.count {
            let t = Double(i) / rate
            let envelope = min(1, t / attack)
            let phase = 2 * Double.pi * frequency * t
            let wave = (sin(phase) + 0.5 * sin(2 * phase) + 0.25 * sin(3 * phase)) / 1.75
            samples[start + i] += amplitude * Float(envelope * wave)
        }
    }

    /// Noise that switches on abruptly and keeps going (a fan, a vacuum, static).
    mutating func addNoise(at time: Double, duration: Double, amplitude: Float) {
        let start = Int(time * rate)
        for i in 0..<Int(duration * rate) where start + i < samples.count {
            samples[start + i] += random.nextSigned() * amplitude
        }
    }
}

struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed == 0 ? 1 : seed }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    /// Uniform in -1...1.
    mutating func nextSigned() -> Float {
        Float(Double(next() % 2_000_001) / 1_000_000 - 1)
    }
}
