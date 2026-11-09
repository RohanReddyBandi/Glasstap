import AppKit
import SwiftUI

/// Opens Glasstap's few windows. It's a menu bar app with no Dock icon, so windows are
/// managed directly instead of through SwiftUI window scenes, which don't come forward
/// reliably in that setup.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    private weak var model: AppModel?
    private var windows: [String: NSWindow] = [:]

    func attach(_ model: AppModel) {
        self.model = model
    }

    func showOnboarding() {
        guard let model else { return }
        show(id: "onboarding", title: "Welcome to Glasstap") { OnboardingView(model: model) }
    }

    func closeOnboarding() {
        windows["onboarding"]?.close()
    }

    func showDebug() {
        guard let model else { return }
        show(id: "debug", title: "Glasstap Debug", resizable: true) { DebugView(model: model) }
    }

    func showAlert(_ title: String, _ message: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    private func show<Content: View>(
        id: String, title: String, resizable: Bool = false, @ViewBuilder content: () -> Content
    ) {
        let window: NSWindow
        if let existing = windows[id] {
            window = existing
        } else {
            var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
            if resizable { style.insert(.resizable) }
            let hosting = NSHostingController(rootView: content())
            window = NSWindow(contentViewController: hosting)
            window.styleMask = style
            window.title = title
            window.identifier = NSUserInterfaceItemIdentifier(id)
            window.isReleasedWhenClosed = false
            // Open on whatever Space the user is looking at, not the one Glasstap last used.
            window.collectionBehavior.insert(.moveToActiveSpace)
            window.delegate = self
            window.setContentSize(hosting.view.fittingSize)
            window.center()
            windows[id] = window
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // A menu bar app is often not the active app when it opens a window (macOS 14's
        // cooperative activation can decline), so make sure the window still comes forward.
        window.orderFrontRegardless()
    }

    /// Windows are rebuilt each time they open. That way the debug window's camera preview
    /// stops drawing when it's closed instead of running hidden.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let id = window.identifier?.rawValue else { return }
        windows[id] = nil
        DispatchQueue.main.async { window.contentViewController = nil }
    }
}
