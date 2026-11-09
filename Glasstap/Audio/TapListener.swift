import AVFoundation
import CoreAudio
import QuartzCore

/// Runs the built-in microphone and a `TapDetector` on the real-time audio thread.
///
/// It uses an `AVAudioSinkNode`, which hands over each hardware buffer (~10 ms) as it
/// arrives. A regular `installTap` delivers 100 ms chunks, which would add that much lag to
/// every click.
final class TapListener {
    struct Levels: Sendable {
        var peakDB: Float = -120
        var floorDB: Float = -120
    }

    enum ListenerError: LocalizedError {
        case noMicrophone
        case couldNotSelectMicrophone(OSStatus)

        var errorDescription: String? {
            switch self {
            case .noMicrophone: "No microphone input is available."
            case .couldNotSelectMicrophone(let status): "Couldn't switch to the built-in microphone (error \(status))."
            }
        }
    }

    /// Called on the main queue for each confirmed tap or rejected sustained sound.
    var onOutcome: ((TapDetector.Outcome) -> Void)?
    private(set) var isRunning = false
    private(set) var deviceName = "Not started"

    private var engine: AVAudioEngine?
    private let shared = LockedValue(Shared())

    private struct Shared {
        var parameters = TapDetector.Parameters()
        var version = 0
        var levels = Levels()
    }

    /// Latest meter reading, updated about 20 times a second while running.
    var levels: Levels { shared.withLock { $0.levels } }

    func update(parameters: TapDetector.Parameters) {
        shared.withLock {
            $0.parameters = parameters
            $0.version += 1
        }
    }

    func start(parameters: TapDetector.Parameters) throws {
        guard !isRunning else { return }
        update(parameters: parameters)

        let engine = AVAudioEngine()
        let input = engine.inputNode

        // Always the MacBook's own mic, even with AirPods or an iPhone connected: the tap
        // travels through the laptop's body, and only the built-in mic hears it.
        if let mic = AudioDevices.builtInMicrophone() {
            try mic.select(on: input)
            deviceName = mic.name
        } else {
            deviceName = "Default input"
        }

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw ListenerError.noMicrophone }

        let sink = makeSink(sampleRate: format.sampleRate)
        engine.attach(sink)
        engine.connect(input, to: sink, format: format)
        engine.prepare()
        try engine.start()

        self.engine = engine
        isRunning = true
    }

    func stop() {
        engine?.stop()
        engine = nil
        isRunning = false
        shared.withLock { $0.levels = Levels() }
    }

    private func makeSink(sampleRate: Double) -> AVAudioSinkNode {
        // Everything the render block touches is created up front; the block itself only
        // does arithmetic, a try-lock, and (rarely) one dispatch to main.
        var detector = TapDetector(sampleRate: sampleRate, parameters: shared.withLock { $0.parameters })
        var seenVersion = shared.withLock { $0.version }
        var meterPeak: Float = 0
        var meterSamples = 0
        let meterWindow = Int(sampleRate * 0.05)
        let secondsPerTick = HostClock.secondsPerTick
        let shared = self.shared

        return AVAudioSinkNode { [weak self] timestamp, frameCount, bufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
            guard let buffer = buffers.first, let data = buffer.mData, buffer.mNumberChannels == 1 else { return noErr }
            let count = Int(frameCount)
            let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count)

            let stamp = timestamp.pointee
            let startTime = stamp.mFlags.contains(.hostTimeValid)
                ? Double(stamp.mHostTime) * secondsPerTick
                : CACurrentMediaTime() - Double(count) / sampleRate

            shared.withLockIfAvailable { state in
                if state.version != seenVersion {
                    detector.parameters = state.parameters
                    seenVersion = state.version
                }
            }

            for sample in samples { meterPeak = max(meterPeak, abs(sample)) }
            meterSamples += count

            let outcome = detector.process(samples, startTime: startTime)

            if meterSamples >= meterWindow {
                let levels = Levels(peakDB: TapDetector.decibels(amplitude: meterPeak), floorDB: detector.floorDB)
                shared.withLockIfAvailable { $0.levels = levels }
                meterPeak = 0
                meterSamples = 0
            }

            if let outcome {
                DispatchQueue.main.async { self?.onOutcome?(outcome) }
            }
            return noErr
        }
    }
}

enum HostClock {
    /// Converts `mach_absolute_time` ticks (and `AudioTimeStamp.mHostTime`) to seconds on the
    /// same clock as `CACurrentMediaTime()`.
    static let secondsPerTick: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()
}
