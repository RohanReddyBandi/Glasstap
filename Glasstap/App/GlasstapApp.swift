import SwiftUI

@main
struct GlasstapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenu(model: appDelegate.model)
        } label: {
            MenuBarLabel(model: appDelegate.model)
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.launch()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.deactivate(announce: false)
    }
}

struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        Image(systemName: model.isActive ? "hand.tap.fill" : "hand.tap")
            .accessibilityLabel(model.isActive ? "Glasstap, touch mode on" : "Glasstap")
    }
}

struct MenuBarMenu: View {
    let model: AppModel

    var body: some View {
        Button(model.isActive ? "Turn Touch Mode Off" : "Turn Touch Mode On") {
            model.toggle()
        }
        Text("Shortcut: \(model.settings.toggleHotKey.displayString)")

        Divider()

        Toggle("Show Cursor Dot", isOn: Binding(
            get: { model.settings.showCursor },
            set: { model.settings.showCursor = $0; model.settingsChanged() }
        ))
        Button("Camera & Mic Debug…") { model.windows.showDebug() }
        Button("Permissions…") { model.windows.showOnboarding() }

        Divider()

        Button("Quit Glasstap") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
