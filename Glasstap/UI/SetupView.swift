import Combine
import SwiftUI

/// The setup assistant: what Glasstap does, permissions, a camera check, calibration, done.
struct SetupView: View {
    enum Step: Int, CaseIterable {
        case welcome, permissions, camera, calibrate, done
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
                case .camera: CameraStep(model: model)
                case .calibrate: CalibrateStep(model: model)
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
        .frame(width: 660, height: 600)
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
            case .calibrate:
                if model.settings.calibration == nil {
                    Button("Skip for Now") { move(1) }
                }
                Button("Continue") { move(1) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.settings.calibration == nil)
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
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(
                symbol: "hand.pinch.fill",
                title: "Welcome to Glasstap",
                subtitle: "Control your Mac by pointing at the screen. The built-in camera follows your hand. No extra hardware needed."
            )
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 20, alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)], alignment: .leading, spacing: 18) {
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
                    detail: "Follows your hand so Glasstap knows where you're pointing.",
                    status: .init(permissions.camera)
                ) { Task { await permissions.requestCamera() } }
                Divider()
                PermissionRow(
                    symbol: "accessibility", title: "Accessibility",
                    detail: "Lets Glasstap click, scroll and switch Spaces for you. Turn on Glasstap in the list that opens.",
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

private struct CameraStep: View {
    let model: AppModel
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StepHeader(
                symbol: "camera.viewfinder",
                title: "Check the camera",
                subtitle: "Raise a hand in front of the screen. When dots appear on your fingers, Glasstap can see you."
            )
            HStack(alignment: .top, spacing: 20) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(.black)
                    if model.isCameraRunning {
                        CameraDebugView(session: model.tracker.session, frame: model.debug.latestFrame)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    } else if let error {
                        Text(error).foregroundStyle(.secondary).padding()
                    }
                }
                .aspectRatio(model.tracker.aspectRatio, contentMode: .fit)
                .frame(width: 340)

                VStack(alignment: .leading, spacing: 14) {
                    Label(
                        model.debug.handVisible ? "Found your hand" : "Looking for your hand…",
                        systemImage: model.debug.handVisible ? "checkmark.circle.fill" : "hand.raised"
                    )
                    .font(.headline)
                    .foregroundStyle(model.debug.handVisible ? .green : .primary)
                    Tip(symbol: "ruler", text: "Sit about an arm's length from the screen.")
                    Tip(symbol: "sun.max", text: "Light in front of you works best. A bright window behind you makes your hand hard to see.")
                    Tip(symbol: "hand.raised", text: "Hold your palm toward the screen with your fingers relaxed.")
                }
            }
        }
        .onAppear(perform: start)
        .onDisappear { model.stopCamera(for: .setup) }
    }

    private func start() {
        Task {
            await model.permissions.requestMediaAccessIfNeeded(includingMicrophone: false)
            guard model.permissions.camera == .granted else {
                error = "Camera access is off. Go back and allow it."
                return
            }
            do {
                try model.startCamera(for: .setup)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

private struct CalibrateStep: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(
                symbol: "scope",
                title: "Calibrate",
                subtitle: "Teach Glasstap where your hand is when you point at each part of the screen. It takes about a minute: nine dots, one pinch each."
            )
            if let profile = model.settings.calibration {
                CalibrationStatus(profile: profile)
            }
            HStack {
                Button(model.settings.calibration == nil ? "Start Calibration" : "Calibrate Again") {
                    model.calibration.begin()
                }
                .controlSize(.large)
                .keyboardShortcut(model.settings.calibration == nil ? .defaultAction : nil)
            }
            Text("Calibration fills the screen. Press Esc to stop at any time.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
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
            Text("Change gestures, sensitivity and the shortcut in Settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
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

private struct Tip: View {
    let symbol: String
    let text: String

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary)
        }
        .font(.callout)
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
