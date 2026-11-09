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
        model.calibration.cancel()
    }
}

struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        Image(systemName: model.isActive ? "hand.pinch.fill" : "hand.pinch")
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
        if model.settings.calibration == nil {
            Text("Not calibrated yet")
        }

        Divider()

        Button(model.settings.calibration == nil ? "Calibrate…" : "Recalibrate…") {
            model.calibration.begin()
        }
        Button("Settings…") { model.windows.showSettings() }
            .keyboardShortcut(",")
        Button("Setup Assistant…") { model.windows.showSetup() }
        Button("Debug View…") { model.windows.showDebug() }
        Button("Check for Updates…") {
            Task { await model.updates.check(userInitiated: true, settings: model.settings) }
        }

        Divider()

        Button("Quit Glasstap") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
