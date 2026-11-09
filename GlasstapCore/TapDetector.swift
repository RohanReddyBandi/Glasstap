import Foundation

/// Finds the sound of a fingertip hitting the display glass in a stream of microphone samples.
///
/// A tap is a short, sharp transient: the level jumps within a millisecond or two, lands well
/// above the room's noise floor, and dies away within a few tens of milliseconds. Speech and
/// music can start sharply too, but they keep sounding, so a candidate is only confirmed once
/// it has decayed. That check is also where the detection latency comes from
/// (`decayWindow`, 30 ms by default).
///
/// Typing makes the same kind of click. That's filtered elsewhere, by ignoring taps that
/// happen right next to a key press.
///
/// This is a plain value type that never allocates, so it can run on the real-time audio thread.
struct TapDetector {
    struct Parameters: Equatable, Sendable {
        /// Quietest tap that counts, as the peak level in dBFS. The sensitivity setting moves this.
        var minPeakDB: Float = -50
        /// How far above the running noise floor the onset must be.
        var minRiseDB: Float = 12
        /// How far the level must jump above the average of the previous ~10 ms. Separates
        /// clicks from swells, and from the cycle-to-cycle wobble of a hum or a voice.
        var minAttackDB: Float = 8
        /// How far the level must have fallen by the end of `decayWindow`.
        var minDecayDB: Float = 10
        /// How long after the onset the decay is checked.
        var decayWindow: Double = 0.030
        /// Dead time after a tap, so one tap's ringing can't count twice.
        var refractory: Double = 0.15
    }

    struct Event: Equatable, Sendable {
        /// Host-clock seconds at the onset.
        var time: Double
        var peakDB: Float
        var riseDB: Float
        var attackDB: Float
        var decayDB: Float
    }

    enum Outcome: Equatable, Sendable {
        case tap(Event)
        /// Sharp onset that kept sounding: most likely speech, music or something that rang on.
        case sustained(Event)
    }

    var parameters: Parameters
    let sampleRate: Double

    private let blockSize: Int
    private let blockDuration: Double
    private var highPass: OnePoleHighPass
    private var energySum: Float = 0
    private var blockPeak: Float = 0
    private var blockFill = 0
    /// Energies of the previous eight blocks (~10 ms), as a ring. A SIMD vector because it
    /// lives inline: no heap, safe on the audio thread.
    private var recentEnergies = SIMD8<Float>(repeating: 1e-12)
    private var recentIndex = 0
    private var floorEnergy: Float = 0
    private var hasFloor = false
    private var state = State.idle

    private enum State {
        case idle
        case candidate(Candidate)
        case refractory(until: Double)
    }

    private struct Candidate {
        var onset: Double
        var peakEnergy: Float
        var peakAmplitude: Float
        var riseDB: Float
        var attackDB: Float
        var tailEnergy: Float = 0
        var tailBlocks = 0
    }

    init(sampleRate: Double, parameters: Parameters = Parameters()) {
        self.sampleRate = sampleRate
        self.parameters = parameters
        // ≈1.33 ms blocks: 64 samples at 48 kHz.
        blockSize = max(16, Int((sampleRate / 750).rounded()))
        blockDuration = Double(blockSize) / sampleRate
        highPass = OnePoleHighPass(cutoff: 120, sampleRate: sampleRate)
    }

    /// The running noise floor, in dBFS.
    var floorDB: Float { hasFloor ? Self.decibels(energy: floorEnergy) : -120 }

    /// Feeds one buffer of mono samples that started at `startTime` (host-clock seconds).
    /// Returns a result when a candidate finishes inside this buffer.
    mutating func process(_ samples: UnsafeBufferPointer<Float>, startTime: Double) -> Outcome? {
        var outcome: Outcome?
        for index in samples.indices {
            let y = highPass.process(samples[index])
            energySum += y * y
            blockPeak = max(blockPeak, abs(y))
            blockFill += 1
            guard blockFill == blockSize else { continue }

            let blockStart = startTime + Double(index + 1 - blockSize) / sampleRate
            if let result = processBlock(energy: energySum / Float(blockSize), peak: blockPeak, start: blockStart) {
                outcome = result
            }
            energySum = 0
            blockPeak = 0
            blockFill = 0
        }
        return outcome
    }

    private mutating func processBlock(energy rawEnergy: Float, peak: Float, start time: Double) -> Outcome? {
        let energy = max(rawEnergy, 1e-12)
        defer {
            recentEnergies[recentIndex] = energy
            recentIndex = (recentIndex + 1) % 8
        }

        guard hasFloor else {
            floorEnergy = energy
            hasFloor = true
            return nil
        }

        switch state {
        case .refractory(let until):
            if time >= until { state = .idle }
            return nil

        case .candidate(var candidate):
            let elapsed = time - candidate.onset
            if elapsed < 0.004 {
                candidate.peakEnergy = max(candidate.peakEnergy, energy)
                candidate.peakAmplitude = max(candidate.peakAmplitude, peak)
            }
            if elapsed >= parameters.decayWindow - 0.006 {
                candidate.tailEnergy += energy
                candidate.tailBlocks += 1
            }
            guard elapsed + blockDuration >= parameters.decayWindow, candidate.tailBlocks > 0 else {
                state = .candidate(candidate)
                return nil
            }

            let tail = candidate.tailEnergy / Float(candidate.tailBlocks)
            let event = Event(
                time: candidate.onset,
                peakDB: Self.decibels(amplitude: candidate.peakAmplitude),
                riseDB: candidate.riseDB,
                attackDB: candidate.attackDB,
                decayDB: Self.decibels(energy: candidate.peakEnergy) - Self.decibels(energy: tail)
            )
            if event.peakDB < parameters.minPeakDB {
                state = .idle
                return nil
            }
            if event.decayDB < parameters.minDecayDB {
                state = .refractory(until: time + 0.05)
                return .sustained(event)
            }
            state = .refractory(until: candidate.onset + parameters.refractory)
            return .tap(event)

        case .idle:
            let level = Self.decibels(energy: energy)
            let rise = level - Self.decibels(energy: floorEnergy)
            let attack = level - Self.decibels(energy: recentEnergies.sum() / 8)
            if rise >= parameters.minRiseDB, attack >= parameters.minAttackDB {
                state = .candidate(Candidate(
                    onset: time, peakEnergy: energy, peakAmplitude: peak, riseDB: rise, attackDB: attack
                ))
                return nil
            }
            // Track the noise floor: follow drops quickly, rises slowly, so a burst of sound
            // doesn't drag the floor up with it.
            let timeConstant = energy < floorEnergy ? 0.15 : 2.0
            floorEnergy += (energy - floorEnergy) * Float(min(1, blockDuration / timeConstant))
            return nil
        }
    }

    static func decibels(energy: Float) -> Float { 10 * log10(max(energy, 1e-12)) }
    static func decibels(amplitude: Float) -> Float { 20 * log10(max(amplitude, 1e-6)) }
}

/// First-order high-pass filter. Removes rumble, hum and DC before tap detection.
struct OnePoleHighPass {
    private let coefficient: Float
    private var previousInput: Float = 0
    private var previousOutput: Float = 0

    init(cutoff: Double, sampleRate: Double) {
        let rc = 1 / (2 * Double.pi * cutoff)
        let dt = 1 / sampleRate
        coefficient = Float(rc / (rc + dt))
    }

    mutating func process(_ x: Float) -> Float {
        let y = coefficient * (previousOutput + x - previousInput)
        previousInput = x
        previousOutput = y
        return y
    }
}
