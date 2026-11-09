import AVFoundation
import SwiftUI

/// Shows what Glasstap sees and hears: the camera with tracked hand joints drawn on top, the
/// mic level against the tap threshold, and a log of every tap and why it did or didn't
/// click. This is the main tool for judging tracking quality on a given Mac.
struct DebugView: View {
    let model: AppModel
    @State private var threshold: Float = TapDetector.Parameters().minPeakDB

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            camera
            stats
            Divider()
            microphone
            Divider()
            log
        }
        .padding(16)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 760, idealHeight: 820)
        .onAppear { threshold = model.settings.tapThresholdDB }
    }

    @ViewBuilder private var camera: some View {
        if model.isCameraRunning {
            CameraDebugView(session: model.tracker.session, frame: model.debug.latestFrame)
                .aspectRatio(model.tracker.aspectRatio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .bottomLeading) {
                    Text(model.tracker.summary)
                        .font(.caption)
                        .padding(6)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(.white)
                        .padding(8)
                }
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.6))
                VStack(spacing: 10) {
                    Image(systemName: "video.slash").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("Touch mode is off, so the camera is off too.")
                        .foregroundStyle(.secondary)
                    Button("Turn On Touch Mode") { model.toggle() }
                }
            }
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
        }
    }

    private var stats: some View {
        let hand = model.debug.latestUpdate?.primary
        let on = model.isCameraRunning
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 24) {
                stat("Camera", on ? String(format: "%.0f fps", model.debug.cameraFPS) : "–")
                stat("Hand model", on ? String(format: "%.0f ms/frame", model.debug.visionMilliseconds) : "–")
                stat("Hands", on ? "\(model.debug.latestFrame?.hands.count ?? 0)" : "–")
                stat("Gesture", model.isActive ? model.debug.gestureState : "–")
            }
            HStack(spacing: 24) {
                stat("Cursor", hand.map { String(format: "%.0f%% across, %.0f%% up", $0.sample.screen.x * 100, $0.sample.screen.y * 100) } ?? "–")
                stat("Pinch gap", hand?.metrics.indexPinch.map {
                    String(format: "%.2f (press < %.2f)", $0, model.pinchThresholds.down)
                } ?? "–")
                stat("Hand", hand.map { $0.metrics.isOpenPalm ? "open (paused)" : "steering, \($0.metrics.extendedFingers) fingers out" } ?? "–")
                stat("Pointing", model.settings.pointerMode == .trackpad ? "Trackpad" : "Touchscreen")
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .monospaced))
        }
    }

    private var microphone: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Microphone").font(.headline)
                Spacer()
                Text(model.listener.isRunning ? model.listener.deviceName : "Off (tap-to-click is off)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            TimelineView(.periodic(from: .now, by: 1.0 / 20.0)) { _ in
                LevelMeter(levels: model.listener.levels, threshold: threshold, active: model.listener.isRunning)
            }
            .frame(height: 22)
            HStack {
                Text("Tap threshold")
                Slider(value: $threshold, in: AppSettings.tapThresholdRange)
                Text(threshold.dBText)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 60, alignment: .trailing)
            }
            Text("Taps louder than the red line count. Lower it if gentle taps are missed, raise it if clicks happen on their own.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .onChange(of: threshold) { _, newValue in
            model.settings.tapThresholdDB = newValue
            model.applySettings()
        }
    }

    private var log: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Events").font(.headline)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(model.debug.entries) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: entry.kind.symbol)
                                .foregroundStyle(entry.kind.color)
                                .frame(width: 14)
                            Text(entry.date, format: .dateTime.hour().minute().second())
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(entry.text).font(.callout).textSelection(.enabled)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 140)
        }
    }
}

private extension DebugStore.Entry.Kind {
    var symbol: String {
        switch self {
        case .info: "info.circle"
        case .click: "cursorarrow.click"
        case .rejected: "xmark.circle"
        case .warning: "exclamationmark.triangle"
        }
    }

    var color: Color {
        switch self {
        case .info: .secondary
        case .click: .green
        case .rejected: .orange
        case .warning: .yellow
        }
    }
}

/// Camera preview with the detected hand joints drawn over it, mirrored so it reads like a
/// mirror. The ring between the knuckles is what the cursor follows; the yellow line is the pinch.
struct CameraDebugView: View {
    let session: AVCaptureSession
    let frame: HandFrame?

    var body: some View {
        ZStack {
            CameraPreview(session: session)
            Canvas { context, size in
                guard let frame else { return }
                for hand in frame.hands {
                    var bones = Path()
                    for (a, b) in HandJoint.bones {
                        guard let p = hand.joints[a], let q = hand.joints[b] else { continue }
                        bones.move(to: Self.viewPoint(p, in: size))
                        bones.addLine(to: Self.viewPoint(q, in: size))
                    }
                    context.stroke(bones, with: .color(.white.opacity(0.8)), lineWidth: 2)
                    for (joint, point) in hand.joints {
                        let isTip = joint == .thumbTip || joint == .indexTip
                        let r: CGFloat = isTip ? 5 : 3.5
                        let c = Self.viewPoint(point, in: size)
                        let dot = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                        context.fill(dot, with: .color(isTip ? .yellow : .white))
                    }
                    // The pinch: thumb tip to index tip.
                    if let thumb = hand.joints[.thumbTip], let index = hand.joints[.indexTip] {
                        var pinch = Path()
                        pinch.move(to: Self.viewPoint(thumb, in: size))
                        pinch.addLine(to: Self.viewPoint(index, in: size))
                        context.stroke(pinch, with: .color(.yellow), style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                    }
                    // The cursor anchor: between the index and middle knuckles.
                    if let anchor = hand.anchor {
                        let c = Self.viewPoint(anchor, in: size)
                        let r: CGFloat = 8
                        context.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                                       with: .color(.accentColor), lineWidth: 3)
                    }
                }
            }
        }
        .scaleEffect(x: -1, y: 1)
    }

    /// Vision's normalized coordinates (origin bottom-left) to view coordinates.
    private static func viewPoint(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: point.x * size.width, y: (1 - point.y) * size.height)
    }
}

/// `AVCaptureVideoPreviewLayer` in SwiftUI. Mirroring is turned off here; the parent view
/// mirrors the preview and the joint overlay together.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        return view
    }

    func updateNSView(_ view: PreviewView, context: Context) {
        view.configureMirroring()
    }

    final class PreviewView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            previewLayer.videoGravity = .resize
            layer = previewLayer
            wantsLayer = true
        }

        required init?(coder: NSCoder) { nil }

        func configureMirroring() {
            guard let connection = previewLayer.connection, connection.isVideoMirroringSupported else { return }
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }

        override func layout() {
            super.layout()
            configureMirroring()
        }
    }
}

/// Mic level bar from -80 to 0 dBFS, with the noise floor and tap threshold marked.
struct LevelMeter: View {
    let levels: TapListener.Levels
    let threshold: Float
    let active: Bool

    private static let range: ClosedRange<Float> = -80...0

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                if active {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(levels.peakDB >= threshold ? Color.green : Color.accentColor)
                        .frame(width: width * Self.fraction(levels.peakDB))
                    Rectangle()
                        .fill(.secondary)
                        .frame(width: 2)
                        .offset(x: width * Self.fraction(levels.floorDB))
                }
                Rectangle()
                    .fill(.red)
                    .frame(width: 2)
                    .offset(x: width * Self.fraction(threshold) - 1)
            }
        }
        .accessibilityLabel("Microphone level \(Int(levels.peakDB)) dB, threshold \(Int(threshold)) dB")
    }

    private static func fraction(_ db: Float) -> CGFloat {
        CGFloat((db.clamped(to: range) - range.lowerBound) / (range.upperBound - range.lowerBound))
    }
}
