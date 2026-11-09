import Combine
import SwiftUI

/// The setup assistant: what Glasstap does, permissions, a hands-on practice that also trains
/// the pinch, done.
struct SetupView: View {
    enum Step: Int, CaseIterable {
        case welcome, permissions, practice, done
    }

    let model: AppModel
    @State private var step: Step

    init(model: AppModel, initialStep: Step = .welcome) {
        self.model = model
        _step = State(initialValue: initialStep)
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome: WelcomeStep()
                case .permissions: PermissionsStep(model: model)
                case .practice: PracticeStep(model: model)
                case .done: DoneStep(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(28)

            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
        }
        .frame(width: 680, height: 620)
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { item in
                    Circle()
                        .fill(item == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
            Spacer()
            if step != .welcome {
                Button("Back") { move(-1) }
            }
            switch step {
            case .permissions:
                Button("Continue") { move(1) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.permissions.allGranted(needsMicrophone: false))
            case .done:
                Button("Close") { finish(turnOn: false) }
                Button("Turn On Touch Mode") { finish(turnOn: true) }
                    .keyboardShortcut(.defaultAction)
            default:
                Button("Continue") { move(1) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func move(_ delta: Int) {
        if let next = Step(rawValue: step.rawValue + delta) {
            withAnimation(.easeInOut(duration: 0.2)) { step = next }
        }
    }

    private func finish(turnOn: Bool) {
        model.settings.hasCompletedSetup = true
        model.windows.closeSetup()
        if turnOn {
            Task { await model.activate() }
        }
    }
}

// MARK: - Steps

private struct StepHeader: View {
    let symbol: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 32))
                .foregroundStyle(.tint)
                .frame(width: 44)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.title.bold())
                Text(subtitle)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 8)
    }
}

private struct WelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(
                symbol: "hand.pinch.fill",
                title: "Welcome to Glasstap",
                subtitle: "Control your Mac with your hand in the air. The built-in camera does the tracking. No extra hardware."
            )
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 20, alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)],
                alignment: .leading,
                spacing: 14
            ) {
                ForEach(GestureGuide.items) { GestureRow(item: $0) }
            }
        }
    }
}

private struct PermissionsStep: View {
    let model: AppModel
    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private var permissions: Permissions { model.permissions }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(
                symbol: "lock.shield.fill",
                title: "Two permissions",
                subtitle: "Glasstap needs to see your hand and to click for you. The camera only runs while touch mode is on, and nothing is recorded or leaves your Mac."
            )
            VStack(spacing: 0) {
                PermissionRow(
                    symbol: "camera.fill", title: "Camera",
                    detail: "Follows your hand.",
                    status: .init(permissions.camera)
                ) { Task { await permissions.requestCamera() } }
                Divider()
                PermissionRow(
                    symbol: "accessibility", title: "Accessibility",
                    detail: "Lets Glasstap move the pointer, click, scroll and switch Spaces. Turn on Glasstap in the list that opens.",
                    status: permissions.accessibility ? .granted : .needed
                ) { permissions.requestAccessibility() }
                Divider()
                PermissionRow(
                    symbol: "mic.fill", title: "Microphone (optional)",
                    detail: "Only for tapping the glass to click, which is off unless you turn it on in Settings.",
                    status: .init(permissions.microphone),
                    optional: true
                ) { Task { await permissions.requestMicrophone() } }
            }
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
        }
        .onAppear { permissions.refresh() }
        .onReceive(refresh) { _ in permissions.refresh() }
    }
}

private struct PracticeStep: View {
    let model: AppModel
    @State private var session = PracticeSession()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(
                symbol: "hand.point.up.left.fill",
                title: "Try it",
                subtitle: "Sit about an arm's length from the screen and hold up your hand. Each item lights up when Glasstap sees it. The pinches also teach Glasstap what your pinch looks like."
            )
            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12).fill(.black)
                        if model.isCameraRunning {
                            CameraDebugView(session: model.tracker.session, frame: model.debug.latestFrame)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        } else if let error = session.error {
                            Text(error).foregroundStyle(.secondary).padding()
                        }
                    }
                    .aspectRatio(model.tracker.aspectRatio, contentMode: .fit)
                    liveStatus
                }
                .frame(width: 300)

                VStack(alignment: .leading, spacing: 14) {
                    PracticeRow(
                        done: session.moved,
                        title: "Move your hand around",
                        detail: "Fingers relaxed. This is how you'll move the pointer."
                    )
                    PracticeRow(
                        done: session.pinchTrained,
                        title: "Pinch three times",
                        detail: pinchDetail
                    ) {
                        HStack(spacing: 6) {
                            ForEach(0..<PinchTrainer.pinchesNeeded, id: \.self) { index in
                                Circle()
                                    .fill(index < session.pinches ? Color.green : Color.secondary.opacity(0.3))
                                    .frame(width: 10, height: 10)
                            }
                        }
                        .animation(.spring(duration: 0.25), value: session.pinches)
                    }
                    PracticeRow(
                        done: session.openHand,
                        title: "Open your hand",
                        detail: "Spread your fingers toward the screen. That pauses the pointer, and it's the pose for swipes."
                    )
                    if session.pinchResult == .tooSimilar {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Your pinches and your open hand looked alike to the camera. Try touching your fingertips together more clearly, with your palm facing the screen.")
                                .font(.callout)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Try the Pinches Again") { session.retrainPinch() }
                        }
                    } else if session.pinchTrained {
                        Button("Redo the Pinches") { session.retrainPinch() }
                            .buttonStyle(.link)
                    }
                }
            }
        }
        .task { await session.start(model: model) }
        .onDisappear { session.stop() }
    }

    private var pinchDetail: String {
        if session.pinchTrained { return "Got it. Pinches are now tuned to your hand." }
        return "Tap your thumb and index fingertip together, then open them again."
    }

    private var liveStatus: some View {
        HStack(spacing: 6) {
            if !session.handVisible {
                Label("No hand in view", systemImage: "hand.raised.slash").foregroundStyle(.orange)
            } else if session.isOpenPalm {
                Label("Open hand: paused", systemImage: "hand.raised.fill").foregroundStyle(.secondary)
            } else {
                Label("Steering", systemImage: "hand.point.up.left.fill").foregroundStyle(.green)
            }
            Spacer()
            if let gap = session.pinchGap {
                Text(String(format: "pinch gap %.2f", gap))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout.weight(.medium))
    }
}

private struct PracticeRow<Extra: View>: View {
    let done: Bool
    let title: String
    let detail: String
    @ViewBuilder var extra: () -> Extra

    init(done: Bool, title: String, detail: String, @ViewBuilder extra: @escaping () -> Extra = { EmptyView() }) {
        self.done = done
        self.title = title
        self.detail = detail
        self.extra = extra
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 20))
                .foregroundStyle(done ? .green : .secondary)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                extra()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: done)
    }
}

private struct DoneStep: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(
                symbol: "checkmark.seal.fill",
                title: "You're all set",
                subtitle: "Turn touch mode on and off with \(model.settings.toggleHotKey.displayString), or from the hand icon in the menu bar."
            )
            VStack(alignment: .leading, spacing: 12) {
                ForEach(GestureGuide.items.prefix(4)) { GestureRow(item: $0) }
            }
            Text("Prefer pointing straight at things, like a touchscreen? Switch the pointing style in Settings and calibrate. You can also change pointer speed, gestures and the shortcut there.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Shared pieces

struct CalibrationStatus: View {
    let profile: CalibrationProfile

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("Calibrated · \(profile.quality.rawValue) accuracy").font(.headline)
                Text(profile.date, format: .dateTime.month().day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: profile.quality == .rough ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(profile.quality == .rough ? .orange : .green)
        }
    }
}

struct PermissionRow: View {
    enum RowStatus {
        case granted, needed, denied

        init(_ status: Permissions.Status) {
            switch status {
            case .granted: self = .granted
            case .notDetermined: self = .needed
            case .denied: self = .denied
            }
        }
    }

    let symbol: String
    let title: String
    let detail: String
    let status: RowStatus
    var optional = false
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .frame(width: 24)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            switch status {
            case .granted:
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .needed:
                Button(optional ? "Allow" : "Allow…", action: action)
            case .denied:
                Button("Open Settings…", action: action)
            }
        }
        .padding(.vertical, 12)
    }
}
