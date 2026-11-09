import AVFoundation
import QuartzCore
import Vision

/// Runs the built-in camera and Apple's hand-pose model, and reports the hands it finds.
///
/// Frames are processed on a background queue; results are delivered on the main queue.
final class HandTracker: NSObject {
    enum TrackerError: LocalizedError {
        case noCamera
        case cannotUseCamera

        var errorDescription: String? {
            switch self {
            case .noCamera: "No built-in camera was found."
            case .cannotUseCamera: "The camera is in use by something else or couldn't be configured."
            }
        }
    }

    /// Frames are downscaled to this width. Detection then runs on a crop around the hand
    /// (see `HandRegionTracker`), so the extra pixels go to the hand itself.
    static let processingWidth = 1280

    let session = AVCaptureSession()
    /// Called on the main queue for every processed frame, with or without hands.
    var onFrame: ((HandFrame) -> Void)?

    /// Width / height of the processed frames. Set when the camera is first configured.
    private(set) var aspectRatio: CGFloat = 4.0 / 3.0
    /// Human-readable camera and format, for the debug view.
    private(set) var summary = "Not started"

    private let sessionQueue = DispatchQueue(label: "app.glasstap.camera.session")
    private let videoQueue = DispatchQueue(label: "app.glasstap.camera.frames", qos: .userInteractive)
    private var isConfigured = false
    /// Only touched on `videoQueue`.
    private var regions = HandRegionTracker(aspectRatio: 4.0 / 3.0)
    private let request: VNDetectHumanHandPoseRequest = {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
        return request
    }()

    func start() throws {
        if !isConfigured {
            try configure()
            isConfigured = true
        }
        sessionQueue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
        videoQueue.async { [weak self] in self?.regions.reset() }
    }

    private func configure() throws {
        guard let device = Self.builtInCamera() else { throw TrackerError.noCamera }

        // Center Stage crops in and pans to follow faces. Glasstap needs a fixed, uncropped
        // view, or calibration would drift every time the crop moved.
        AVCaptureDevice.centerStageControlMode = .app
        AVCaptureDevice.isCenterStageEnabled = false

        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        guard session.canAddInput(input) else { throw TrackerError.cannotUseCamera }
        session.addInput(input)

        if let format = Self.preferredFormat(for: device) {
            try device.lockForConfiguration()
            device.activeFormat = format
            // Lock the frame rate at the maximum so latency stays steady. The camera would
            // otherwise drop to 15 fps in dim light.
            if let range = format.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) {
                device.activeVideoMinFrameDuration = range.minFrameDuration
                device.activeVideoMaxFrameDuration = range.minFrameDuration
            }
            device.unlockForConfiguration()
        }

        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let width = min(Self.processingWidth, Int(dimensions.width))
        let height = Int((Double(width) * Double(dimensions.height) / Double(dimensions.width) / 2).rounded()) * 2
        aspectRatio = CGFloat(width) / CGFloat(height)
        regions = HandRegionTracker(aspectRatio: aspectRatio)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
        output.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(output) else { throw TrackerError.cannotUseCamera }
        session.addOutput(output)

        let fps = device.activeVideoMinFrameDuration.seconds > 0 ? Int((1 / device.activeVideoMinFrameDuration.seconds).rounded()) : 0
        summary = "\(device.localizedName), \(dimensions.width)×\(dimensions.height) → \(width)×\(height) @ \(fps) fps"
    }

    /// The MacBook's own camera. Continuity Camera (an iPhone) and external webcams are
    /// skipped: calibration assumes the camera is fixed to the top of the display.
    private static func builtInCamera() -> AVCaptureDevice? {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        ).devices.first
    }

    /// The tallest landscape format sees the most of the area below the camera, which is
    /// where a hand reaching for the screen shows up. On the 12 MP Center Stage camera that's
    /// the 4:3 1760×1328 mode; the 16:9 modes crop off the bottom of the view.
    private static func preferredFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        device.formats
            .filter { format in
                let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                return d.width > d.height && d.width <= 2100
            }
            .max { a, b in
                let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
                let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
                return (da.height, da.width) < (db.height, db.width)
            }
    }
}

extension HandTracker: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let captureTime = Self.hostSeconds(of: sampleBuffer)
        let started = CACurrentMediaTime()

        let region = regions.nextRegion()
        request.regionOfInterest = region ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        var detected: [HandPose] = []
        if (try? handler.perform([request])) != nil {
            detected = (request.results ?? []).compactMap { HandPose(observation: $0) }
        }
        let hands = regions.process(detected, detectedIn: region)

        let frame = HandFrame(
            time: captureTime,
            hands: hands,
            visionMilliseconds: (CACurrentMediaTime() - started) * 1000,
            aspectRatio: aspectRatio
        )
        DispatchQueue.main.async { [weak self] in self?.onFrame?(frame) }
    }

    /// Capture time on the host clock. AVFoundation stamps frames with the host clock on
    /// macOS; if that ever isn't true, fall back to "now".
    private static func hostSeconds(of buffer: CMSampleBuffer) -> Double {
        let now = CACurrentMediaTime()
        let stamp = CMSampleBufferGetPresentationTimeStamp(buffer)
        guard stamp.isValid else { return now }
        let seconds = stamp.seconds
        return abs(now - seconds) < 1 ? seconds : now
    }
}

extension HandPose {
    init?(observation: VNHumanHandPoseObservation, minimumConfidence: Float = 0.3) {
        guard let points = try? observation.recognizedPoints(.all) else { return nil }
        var joints: [HandJoint: CGPoint] = [:]
        for (name, point) in points where point.confidence >= minimumConfidence {
            if let joint = HandJoint(visionName: name) { joints[joint] = point.location }
        }
        guard !joints.isEmpty else { return nil }
        self.init(joints: joints, confidence: observation.confidence)
    }
}

extension HandJoint {
    init?(visionName name: VNHumanHandPoseObservation.JointName) {
        switch name {
        case .wrist: self = .wrist
        case .thumbCMC: self = .thumbCMC
        case .thumbMP: self = .thumbMP
        case .thumbIP: self = .thumbIP
        case .thumbTip: self = .thumbTip
        case .indexMCP: self = .indexMCP
        case .indexPIP: self = .indexPIP
        case .indexDIP: self = .indexDIP
        case .indexTip: self = .indexTip
        case .middleMCP: self = .middleMCP
        case .middlePIP: self = .middlePIP
        case .middleDIP: self = .middleDIP
        case .middleTip: self = .middleTip
        case .ringMCP: self = .ringMCP
        case .ringPIP: self = .ringPIP
        case .ringDIP: self = .ringDIP
        case .ringTip: self = .ringTip
        case .littleMCP: self = .littleMCP
        case .littlePIP: self = .littlePIP
        case .littleDIP: self = .littleDIP
        case .littleTip: self = .littleTip
        default: return nil
        }
    }
}
