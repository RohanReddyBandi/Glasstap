import AppKit
import SwiftUI

/// Opens Glasstap's windows. It's a menu bar app with no Dock icon, so windows are managed
/// directly instead of through SwiftUI window scenes, which don't come forward reliably in
/// that setup.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    private weak var model: AppModel?
    private var windows: [String: NSWindow] = [:]

    func attach(_ model: AppModel) {
        self.model = model
    }

    func showSetup(step: SetupView.Step = .welcome) {
        guard let model else { return }
        // Reopening at a specific step rebuilds the window so it starts there.
        if step != .welcome, let existing = windows["setup"] {
            existing.close()
        }
        show(id: "setup", title: "Glasstap Setup") { SetupView(model: model, initialStep: step) }
    }

    func closeSetup() {
        windows["setup"]?.close()
    }

    func showSettings() {
        guard let model else { return }
        show(id: "settings", title: "Glasstap Settings") { SettingsView(model: model) }
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

    /// Windows are rebuilt each time they open, so camera previews stop drawing when their
    /// window closes instead of running hidden.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let id = window.identifier?.rawValue else { return }
        windows[id] = nil
        DispatchQueue.main.async { window.contentViewController = nil }
    }
}
