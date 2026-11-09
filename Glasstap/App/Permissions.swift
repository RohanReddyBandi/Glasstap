import AppKit
import ApplicationServices
import AVFoundation
import Observation

/// Camera, microphone and Accessibility status, plus ways to ask for each.
@MainActor
@Observable
final class Permissions {
    enum Status {
        case granted, denied, notDetermined
    }

    enum Pane: String {
        case camera = "Privacy_Camera"
        case microphone = "Privacy_Microphone"
        case accessibility = "Privacy_Accessibility"
    }

    private(set) var camera: Status = .notDetermined
    private(set) var microphone: Status = .notDetermined
    private(set) var accessibility = false
    @ObservationIgnored private var didPromptAccessibility = false

    var allGranted: Bool {
        camera == .granted && microphone == .granted && accessibility
    }

    func refresh() {
        camera = Self.status(for: .video)
        microphone = Self.status(for: .audio)
        accessibility = AXIsProcessTrusted()
    }

    /// Shows the system camera/mic prompts for anything not yet asked.
    func requestMediaAccessIfNeeded() async {
        refresh()
        if camera == .notDetermined { _ = await AVCaptureDevice.requestAccess(for: .video) }
        if microphone == .notDetermined { _ = await AVCaptureDevice.requestAccess(for: .audio) }
        refresh()
    }

    func requestCamera() async {
        if camera == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        } else {
            Self.open(.camera)
        }
        refresh()
    }

    func requestMicrophone() async {
        if microphone == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        } else {
            Self.open(.microphone)
        }
        refresh()
    }

    /// The first time, shows the system's Accessibility prompt (which also adds Glasstap to
    /// the list in System Settings). After that, opens the settings pane directly.
    func requestAccessibility() {
        if didPromptAccessibility {
            Self.open(.accessibility)
        } else {
            didPromptAccessibility = true
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        refresh()
    }

    static func open(_ pane: Pane) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") else { return }
        NSWorkspace.shared.open(url)
    }

    private static func status(for type: AVMediaType) -> Status {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }
}
