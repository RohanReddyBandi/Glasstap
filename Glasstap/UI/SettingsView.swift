import Carbon.HIToolbox
import SwiftUI

struct SettingsView: View {
    let model: AppModel

    var body: some View {
        TabView {
            GeneralTab(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
            GesturesTab(model: model)
                .tabItem { Label("Gestures", systemImage: "hand.pinch") }
            TappingTab(model: model)
                .tabItem { Label("Tapping", systemImage: "waveform") }
            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 580, height: 560)
    }
}

extension AppModel {
    /// A binding to a setting that pushes the change into the running pipeline.
    func binding<Value>(_ keyPath: ReferenceWritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { self.settings[keyPath: keyPath] = $0; self.applySettings() }
        )
    }

    func gestureBinding<Value>(_ keyPath: WritableKeyPath<GestureSettings, Value>) -> Binding<Value> {
        Binding(
            get: { self.settings.gestures[keyPath: keyPath] },
            set: { self.settings.gestures[keyPath: keyPath] = $0; self.applySettings() }
        )
    }
}

// MARK: - General

private struct GeneralTab: View {
    let model: AppModel
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Touch mode") {
                LabeledContent("Turn on and off") { ShortcutRecorder(model: model) }
                Toggle("Show the cursor ring", isOn: model.binding(\.showCursor))
                Toggle(isOn: model.binding(\.movePointer)) {
                    Text("Move the pointer with my hand")
                    Text("Buttons light up as you point at them. The trackpad still works: touch it and your hand lets go of the pointer for a second.")
                }
                LabeledContent("Smoothing") {
                    HStack {
                        Text("Quick").font(.caption).foregroundStyle(.secondary)
                        Slider(value: model.binding(\.smoothing), in: 0...1)
                        Text("Steady").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Calibration") {
                if let profile = model.settings.calibration {
                    CalibrationStatus(profile: profile)
                } else {
                    Label("Not calibrated yet. The cursor will be rough until you are.", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                }
                HStack {
                    Button(model.settings.calibration == nil ? "Calibrate…" : "Recalibrate…") { model.calibration.begin() }
                    Button("Run Setup Assistant…") { model.windows.showSetup() }
                }
                Text("Recalibrate if you change how you sit or move the lid.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("App") {
                Toggle("Open Glasstap at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            try LaunchAtLogin.set(enabled)
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = LaunchAtLogin.isEnabled
                        }
                    }
                if LaunchAtLogin.needsApproval {
                    Text("Allow Glasstap in System Settings → General → Login Items.").font(.caption).foregroundStyle(.orange)
                }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                Toggle("Check for updates automatically", isOn: model.binding(\.autoCheckForUpdates))
                Button(model.updates.isChecking ? "Checking…" : "Check Now") {
                    Task { await model.updates.check(userInitiated: true, settings: model.settings) }
                }
                .disabled(model.updates.isChecking)
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = LaunchAtLogin.isEnabled }
    }
}

// MARK: - Gestures

private struct GesturesTab: View {
    let model: AppModel

    var body: some View {
        Form {
            Section("Gestures") {
                ForEach(GestureGuide.items) { item in
                    Toggle(isOn: model.gestureBinding(item.setting)) { GestureRow(item: item) }
                }
            }
            Section("Feel") {
                LabeledContent("Pinch sensitivity") {
                    HStack {
                        Text("Fingers touching").font(.caption).foregroundStyle(.secondary)
                        Slider(value: model.gestureBinding(\.pinchSensitivity), in: 0...1)
                        Text("Fingers close").font(.caption).foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Scroll speed") {
                    HStack {
                        Slider(value: model.gestureBinding(\.scrollSpeed), in: 0.5...3)
                        Text(String(format: "%.1f×", model.settings.gestures.scrollSpeed))
                            .font(.callout.monospacedDigit())
                            .frame(width: 40, alignment: .trailing)
                    }
                }
                Toggle("Reverse scroll direction", isOn: model.binding(\.reverseScroll))
            }
            Section {
                Text("Zoom presses ⌘+ and ⌘−, because macOS doesn't let apps fake a real trackpad pinch. Swipes use Mission Control's Control-arrow shortcuts. If swipes do nothing, turn those shortcuts on in System Settings → Keyboard → Keyboard Shortcuts → Mission Control.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Tapping

private struct TappingTab: View {
    let model: AppModel
    @State private var tuning = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { model.settings.tapToClick },
                    set: { enabled in Task { await model.setTapToClick(enabled) } }
                )) {
                    Text("Also click when I tap the screen")
                    Text("Uses the microphone to hear your fingertip hit the glass, and clicks where the cursor ring is. Pinching is more reliable; this is for when you'd rather touch.")
                }
            }
            Section("Sensitivity") {
                LabeledContent("Tap threshold") {
                    HStack {
                        Text("Gentle").font(.caption).foregroundStyle(.secondary)
                        Slider(
                            value: model.binding(\.tapThresholdDB),
                            in: AppSettings.tapThresholdRange.lowerBound...AppSettings.tapThresholdRange.upperBound
                        )
                        Text("Firm").font(.caption).foregroundStyle(.secondary)
                        Text(model.settings.tapThresholdDB.dBText)
                            .font(.callout.monospacedDigit())
                            .frame(width: 52, alignment: .trailing)
                    }
                }
                HStack {
                    Button("Tune to My Taps…") { tuning = true }
                    Button("Reset") {
                        model.settings.resetTapTuning()
                        model.applySettings()
                    }
                }
                Text("Tuning listens to five of your taps and sets the threshold just under the softest one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!model.settings.tapToClick)
            Section {
                Text("Taps right next to a key press or trackpad click are ignored. Sharp sounds such as drum hits can still click while your hand is in view.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $tuning) { TapTuningView(model: model) }
    }
}

private struct TapTuningView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var taps: [TapDetector.Event] = []
    @State private var error: String?

    private static let goal = 5

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "hand.tap.fill")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            Text("Tap the screen \(Self.goal) times").font(.title3.bold())
            Text("Use a fingertip, about as hard as you normally would. Anywhere on the display is fine.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                ForEach(0..<Self.goal, id: \.self) { index in
                    Circle()
                        .fill(index < taps.count ? Color.green : Color.secondary.opacity(0.3))
                        .frame(width: 16, height: 16)
                }
            }
            .animation(.spring(duration: 0.25), value: taps.count)
            if let last = taps.last {
                Text("Last tap: \(last.peakDB.dBText)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let error {
                Text(error).foregroundStyle(.red).multilineTextAlignment(.center)
            }
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.applyTapTuning(taps)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(taps.count < Self.goal)
            }
        }
        .padding(28)
        .frame(width: 400)
        .task { await start() }
        .onDisappear { model.endTapMeasurement() }
    }

    private func start() async {
        await model.permissions.requestMediaAccessIfNeeded(includingMicrophone: true)
        guard model.permissions.microphone == .granted else {
            error = "Glasstap needs microphone access for this. Allow it in System Settings → Privacy & Security → Microphone."
            return
        }
        do {
            try model.beginTapMeasurement { event in
                if taps.count < Self.goal { taps.append(event) }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - About

private struct AboutTab: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "hand.pinch.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Glasstap").font(.largeTitle.bold())
            Text("Version \(UpdateChecker.currentVersion)").foregroundStyle(.secondary)
            Text("Turns your MacBook's screen into a touchscreen you don't have to touch, using only the built-in camera.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            HStack(spacing: 16) {
                Link("GitHub", destination: URL(string: "https://github.com/\(UpdateChecker.repository)")!)
                Link("Releases", destination: UpdateChecker.releasesPage)
                Link("License (MIT)", destination: URL(string: "https://github.com/\(UpdateChecker.repository)/blob/main/LICENSE")!)
            }
            Text("© 2026 Rohan Reddy Bandi").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - Shortcut recorder

/// Click, then press the new shortcut. Esc cancels. The shortcut needs ⌘, ⌥ or ⌃.
struct ShortcutRecorder: View {
    let model: AppModel
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Button(recording ? "Press a shortcut…" : model.settings.toggleHotKey.displayString) {
                recording ? stop() : start()
            }
            .frame(minWidth: 120)
            if !recording, model.settings.toggleHotKey != .defaultToggle {
                Button("Reset") {
                    model.settings.toggleHotKey = .defaultToggle
                    model.registerHotKey()
                }
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        model.suspendHotKey()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if Int(event.keyCode) == kVK_Escape {
                stop()
                return nil
            }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard !flags.intersection([.command, .option, .control]).isEmpty else {
                NSSound.beep()
                return nil
            }
            model.settings.toggleHotKey = KeyCombo(keyCode: UInt32(event.keyCode), carbonModifiers: Self.carbonFlags(flags))
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording {
            recording = false
            model.registerHotKey()
        }
    }

    private static func carbonFlags(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }
}
