import Combine
import SwiftUI

/// First-run window: what Glasstap does, and the three permissions it needs.
struct OnboardingView: View {
    let model: AppModel
    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var permissions: Permissions { model.permissions }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "hand.tap.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.tint)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Glasstap").font(.title2.bold())
                    Text("Point at your screen and tap the glass to click. The camera follows your hand, and the microphone hears the tap. A click only happens when both agree.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(spacing: 0) {
                PermissionRow(
                    symbol: "camera.fill",
                    title: "Camera",
                    detail: "Follows your hand so Glasstap knows where you're pointing.",
                    status: .init(permissions.camera)
                ) { Task { await permissions.requestCamera() } }
                Divider()
                PermissionRow(
                    symbol: "mic.fill",
                    title: "Microphone",
                    detail: "Hears your fingertip tap the screen.",
                    status: .init(permissions.microphone)
                ) { Task { await permissions.requestMicrophone() } }
                Divider()
                PermissionRow(
                    symbol: "accessibility",
                    title: "Accessibility",
                    detail: "Lets Glasstap click and scroll for you. Turn Glasstap on in the list that opens.",
                    status: permissions.accessibility ? .granted : .needed
                ) { permissions.requestAccessibility() }
            }
            .padding(.horizontal, 14)
            .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))

            Label("The camera and microphone only run while touch mode is on. Nothing is recorded or leaves your Mac.", systemImage: "lock.fill")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("Turn touch mode on and off with **\(model.settings.toggleHotKey.displayString)**, or from the menu bar.")
                    .font(.callout)
                Spacer()
                Button("Done") {
                    model.settings.hasCompletedOnboarding = true
                    model.windows.closeOnboarding()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!permissions.allGranted)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear { permissions.refresh() }
        .onReceive(refresh) { _ in permissions.refresh() }
    }
}

private struct PermissionRow: View {
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
                    .labelStyle(.titleAndIcon)
            case .needed:
                Button("Allow…", action: action)
            case .denied:
                Button("Open Settings…", action: action)
            }
        }
        .padding(.vertical, 12)
    }
}
