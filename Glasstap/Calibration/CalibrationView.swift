import SwiftUI

/// The full-screen calibration and practice UI.
struct CalibrationView: View {
    let controller: CalibrationController
    let model: AppModel

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                Color.black.opacity(0.9)

                switch controller.phase {
                case .intro:
                    IntroPanel(controller: controller)
                case .capturing:
                    capturing(in: size)
                case .result(let outcome):
                    ResultPanel(controller: controller, outcome: outcome)
                case .practice:
                    practice(in: size)
                }

                CameraCorner(model: model, handVisible: controller.handVisible)
                    .frame(width: 260)
                    .position(x: size.width - 162, y: 160)
            }
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .animation(.easeInOut(duration: 0.25), value: controller.phase)
    }

    // MARK: Capture

    @ViewBuilder
    private func capturing(in size: CGSize) -> some View {
        let done = controller.session.samples.count
        ForEach(0..<done, id: \.self) { index in
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(.green.opacity(0.7))
                .position(Self.point(CalibrationSession.targets[index], in: size))
        }
        if let target = controller.session.currentTarget {
            CalibrationTarget(progress: controller.pinchProgress)
                .id(done)
                .transition(.scale.combined(with: .opacity))
                .position(Self.point(target, in: size))
        }
        InstructionBar(
            title: controller.handVisible ? "Hold your hand in front of the dot and pinch" : "Raise your hand so the camera can see it",
            detail: "\(done + 1) of \(CalibrationSession.targets.count)",
            progress: Double(done) / Double(CalibrationSession.targets.count)
        ) {
            if done > 0 {
                Button("Redo Last Dot") { controller.undoLast() }
            }
            Button("Cancel") { controller.cancel() }
        }
        .position(x: size.width / 2, y: size.height - 90)
    }

    // MARK: Practice

    @ViewBuilder
    private func practice(in size: CGSize) -> some View {
        let diameter = CalibrationController.practiceRadius * size.width * 2
        if let target = controller.practiceTarget {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.25))
                Circle().strokeBorder(Color.accentColor, lineWidth: 3)
                Text("Pinch here").font(.headline).foregroundStyle(.white)
            }
            .frame(width: diameter, height: diameter)
            .id(controller.captureCount)
            .transition(.scale.combined(with: .opacity))
            .position(Self.point(target, in: size))

            InstructionBar(
                title: "Point at the circle and pinch",
                detail: "\(controller.practiceHits) of \(CalibrationController.practiceGoal) hit\(controller.practiceMisses > 0 ? " · \(controller.practiceMisses) missed" : "")",
                progress: Double(controller.practiceHits) / Double(CalibrationController.practiceGoal)
            ) {
                Button("Recalibrate") { controller.startCapture() }
                Button("Done") { controller.finish() }
                    .keyboardShortcut(.defaultAction)
            }
            .position(x: size.width / 2, y: size.height - 90)
        } else {
            PracticeDonePanel(controller: controller)
        }

        if let cursor = controller.cursor {
            PinchRing(progress: controller.pinchProgress, pinched: controller.isPinched)
                .position(Self.point(cursor, in: size))
                .animation(.linear(duration: 1.0 / 30.0), value: cursor)
        }
    }

    /// Normalized screen point (origin bottom-left) to view coordinates (origin top-left).
    static func point(_ p: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: p.x * size.width, y: (1 - p.y) * size.height)
    }
}

// MARK: - Pieces

/// A calibration dot. The outer ring pulses to draw the eye; the white ring closes in as
/// the fingers pinch.
private struct CalibrationTarget: View {
    let progress: Double
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.accentColor.opacity(0.5), lineWidth: 2)
                .frame(width: 96, height: 96)
                .scaleEffect(pulse ? 1.2 : 0.7)
                .opacity(pulse ? 0 : 1)
            Circle()
                .stroke(Color.white, lineWidth: 3)
                .frame(width: 56, height: 56)
                .scaleEffect(1 - 0.5 * progress)
                .animation(.easeOut(duration: 0.1), value: progress)
            Circle()
                .fill(Color.accentColor)
                .frame(width: 16, height: 16)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

/// The practice cursor: same look as the touch-mode ring.
private struct PinchRing: View {
    let progress: Double
    let pinched: Bool

    var body: some View {
        let size = pinched ? 16 : 34 - 18 * progress
        ZStack {
            Circle().fill(pinched ? Color.accentColor : Color.white.opacity(0.14 + 0.3 * progress))
            Circle().strokeBorder(Color.white.opacity(0.92), lineWidth: 2)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.35), radius: 4)
        .animation(.easeOut(duration: 0.09), value: progress)
        .allowsHitTesting(false)
    }
}

private struct IntroPanel: View {
    let controller: CalibrationController

    var body: some View {
        Panel {
            Image(systemName: "hand.pinch.fill")
                .font(.system(size: 52))
                .foregroundStyle(.tint)
            Text("Let's line up your hand with the screen")
                .font(.system(size: 28, weight: .bold))
                .multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 12) {
                Step(number: 1, text: "Sit the way you normally do, about an arm's length from the screen.")
                Step(number: 2, text: "A dot appears. Hold your hand in front of it, the way you'd reach for it.")
                Step(number: 3, text: "Pinch your thumb and index finger together to lock it in. There are 9 dots.")
            }
            Text("Keep your hand where the camera can see it. The preview in the corner shows you.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button("Cancel") { controller.cancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Start") { controller.startCapture() }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            Text("or pinch to start").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ResultPanel: View {
    let controller: CalibrationController
    let outcome: CalibrationController.Outcome

    var body: some View {
        Panel {
            switch outcome {
            case .success(let profile):
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.green)
                Text("You're calibrated").font(.system(size: 28, weight: .bold))
                Text(summary(profile))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button("Redo") { controller.startCapture() }
                    Button("Done") { controller.finish() }
                    Button("Try It Out") { controller.startPractice() }
                        .keyboardShortcut(.defaultAction)
                }
                .controlSize(.large)
                Text("or pinch to try it out").font(.caption).foregroundStyle(.secondary)
            case .failure(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.orange)
                Text("That didn't line up").font(.system(size: 28, weight: .bold))
                Text(message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Button("Cancel") { controller.cancel() }
                    Button("Try Again") { controller.startCapture() }
                        .keyboardShortcut(.defaultAction)
                }
                .controlSize(.large)
                Text("or pinch to try again").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func summary(_ profile: CalibrationProfile) -> String {
        let points = Int((profile.rmsError * controller.screenSize.width).rounded())
        let tip: String
        switch profile.quality {
        case .great: tip = "Buttons and links should be easy to hit."
        case .good: tip = "Good for most buttons. Redo it if small targets are hard to hit."
        case .rough: tip = "Small targets will be hard to hit. Redo it, holding still for a moment before each pinch."
        }
        return "Accuracy: \(profile.quality.rawValue). On average the dots were about \(points) points off. \(tip)"
    }
}

private struct PracticeDonePanel: View {
    let controller: CalibrationController

    var body: some View {
        Panel {
            Image(systemName: "star.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(.yellow)
            Text("Nice aim").font(.system(size: 28, weight: .bold))
            Text("You hit all \(CalibrationController.practiceGoal) targets\(controller.practiceMisses > 0 ? " (with \(controller.practiceMisses) misses along the way)" : ""). You're ready to use touch mode.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button("Practice Again") { controller.startPractice() }
                Button("Done") { controller.finish() }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
    }
}

private struct InstructionBar<Buttons: View>: View {
    let title: String
    let detail: String
    let progress: Double
    @ViewBuilder let buttons: () -> Buttons

    var body: some View {
        VStack(spacing: 10) {
            Text(title).font(.title3.weight(.semibold))
            HStack(spacing: 12) {
                ProgressView(value: progress).frame(width: 220)
                Text(detail).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) { buttons() }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

private struct Panel<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 18) { content() }
            .padding(36)
            .frame(width: 560)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }
}

private struct Step: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.callout.bold())
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.accentColor))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Small live camera view with the tracked hand drawn on it, plus a status line.
struct CameraCorner: View {
    let model: AppModel
    let handVisible: Bool

    var body: some View {
        VStack(spacing: 8) {
            CameraDebugView(session: model.tracker.session, frame: model.debug.latestFrame)
                .aspectRatio(model.tracker.aspectRatio, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.2)))
            Label(handVisible ? "Hand found" : "No hand in view", systemImage: handVisible ? "hand.raised.fill" : "hand.raised.slash")
                .font(.callout.weight(.medium))
                .foregroundStyle(handVisible ? .green : .orange)
        }
    }
}
