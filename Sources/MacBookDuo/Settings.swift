import SwiftUI

/// MacBook Duo's settings, from the everyday (opening at login, the Dock) to the Advanced tab's
/// geometry and timing, for anyone who wants to tune the illusion itself. How the picture looks
/// lives in the main window's controls, where its effect can be seen.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            HoldScreenSettings()
                .tabItem { Label("Screen Effect", systemImage: "rectangle.on.rectangle") }
            ViewerSettings()
                .tabItem { Label("Calibration", systemImage: "eye") }
            AdvancedSettings()
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 540)
    }
}

private struct GeneralSettings: View {
    @AppStorage(Defaults.showsInDock) private var showsInDock = true
    @AppStorage(Defaults.globalShortcut) private var globalShortcut = true
    @AppStorage(Defaults.onboardingCompleted) private var onboardingCompleted = true
    @State private var launchesAtLogin = LaunchAtLogin.isOn

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: Binding(
                    get: { launchesAtLogin },
                    set: { launchesAtLogin = LaunchAtLogin.set($0) }))
                Toggle("Show in Dock", isOn: $showsInDock)
                    .onChange(of: showsInDock) { AppState.applyDockPreference() }
            } footer: {
                Text("MacBook Duo always stays in the menu bar.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle(isOn: $globalShortcut) {
                    HStack(spacing: 8) {
                        Text("Screen Effect shortcut")
                        KeyCap(keys: "⌥⌘S")
                    }
                }
                .onChange(of: globalShortcut) { StillScreen.shared.installHotKey() }
            } header: {
                Text("Shortcut")
            } footer: {
                Text("Works from any app. Turn it off if another app uses ⌥⌘S.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Show Welcome") {
                    onboardingCompleted = false
                    AppState.shared.showMainWindow()
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct HoldScreenSettings: View {
    @AppStorage(Defaults.holdSettleTime) private var settleTime = 0.5

    var body: some View {
        Form {
            Section("Screen Recording") {
                ScreenPermissionView()
            }
            Section {
                LabeledContent("Settle back after") {
                    HStack {
                        Slider(value: $settleTime, in: 0.2...2, step: 0.1)
                            .frame(width: 180)
                        Text(settleTime.formatted(.number.precision(.fractionLength(1))) + " s")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
            } footer: {
                Text("How long after you stop tilting. Blur and corners follow the Look controls.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ViewerSettings: View {
    @AppStorage("viewpoint") private var viewpoint: Viewpoint = .screen
    @AppStorage("eyeDistance") private var eyeDistance = 55.0
    @AppStorage("eyeHeight") private var eyeHeight = 35.0

    var body: some View {
        Form {
            Section {
                LabeledContent("Using") {
                    Text(viewpoint == .screen ? "Typical position" : "Your calibration")
                }
                if viewpoint == .eyes {
                    LabeledContent("Your eyes") {
                        Text("\(Int(eyeDistance.rounded())) cm away, \(Int(eyeHeight.rounded())) cm up")
                            .monospacedDigit()
                    }
                }
            }
            Section {
                Button("Calibrate with Camera…") { AppState.shared.showMainWindow(.camera) }
                Button("Calibrate by Eye…") { AppState.shared.showMainWindow(.lineUp) }
                Button("Use Typical Position") { viewpoint = .screen }
                    .disabled(viewpoint == .screen)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AdvancedSettings: View {
    @AppStorage(Defaults.predictsMotion) private var predictsMotion = false
    @AppStorage(Defaults.motionLead) private var motionLead = 30.0
    @State private var geometry = LidGeometry.current
    @State private var angle: Double?
    @State private var confirmsReset = false

    var body: some View {
        Form {
            Section {
                Toggle("Predict lid motion", isOn: $predictsMotion)
                    .onChange(of: predictsMotion) { LidSensor.shared.predictsMotion = predictsMotion }
                LabeledContent("Sensor delay") {
                    HStack {
                        Slider(value: $motionLead, in: 0...80, step: 5)
                            .frame(width: 180)
                        Text("\(Int(motionLead)) ms")
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                .disabled(!predictsMotion)
                .onChange(of: motionLead) { LidSensor.shared.sensorDelay = motionLead / 1000 }
            } header: {
                Text("Motion")
            } footer: {
                Text("Less lag while tilting, but it can overshoot when you stop.")
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("This Mac") {
                    Text("\(geometry.family) · \(ThisMac.modelIdentifier)")
                }
                millimeters("Display above hinge", value: geometry.hingeToDisplay * 10, range: 5...35,
                            key: Defaults.hingeToDisplayOverride)
                millimeters("Display behind hinge", value: geometry.glassBehindHinge * 10, range: -5...12,
                            key: Defaults.glassBehindHingeOverride)
                Button("Reset to This Mac's Values") {
                    UserDefaults.standard.removeObject(forKey: Defaults.hingeToDisplayOverride)
                    UserDefaults.standard.removeObject(forKey: Defaults.glassBehindHingeOverride)
                    reload()
                }
            } header: {
                Text("Lid")
            } footer: {
                Text("Set for your model. Change only if you've measured your MacBook.")
                    .foregroundStyle(.secondary)
            }

            Section("Sensor") {
                LabeledContent("Lid angle") {
                    Text(angle.map { $0.formatted(.number.precision(.fractionLength(2))) + "°" } ?? "–")
                        .monospacedDigit()
                }
                LabeledContent("Updates") {
                    Text("10 per second")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button("Reset All Settings…", role: .destructive) { confirmsReset = true }
            } footer: {
                Text("Also clears your calibration.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { AppState.shared.follow() }
        .onDisappear { AppState.shared.unfollow() }
        .task {
            while !Task.isCancelled {
                angle = LidSensor.shared.reading
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        .confirmationDialog("Reset all settings?", isPresented: $confirmsReset) {
            Button("Reset", role: .destructive) {
                Defaults.resetAll()
                reload()
                motionLead = UserDefaults.standard.double(forKey: Defaults.motionLead)
                AppState.shared.showMainWindow()
            }
        } message: {
            Text("This also clears your calibration.")
        }
    }

    /// A length in millimeters that overrides this Mac's value once changed.
    private func millimeters(_ title: String, value: Double, range: ClosedRange<Double>, key: String) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: Binding(get: { value }, set: {
                    UserDefaults.standard.set(($0 * 2).rounded() / 2, forKey: key)
                    reload()
                }), in: range)
                .frame(width: 180)
                Text(value.formatted(.number.precision(.fractionLength(1))) + " mm")
                    .monospacedDigit()
                    .frame(width: 56, alignment: .trailing)
            }
        }
    }

    private func reload() {
        LidGeometry.reload()
        geometry = LidGeometry.current
    }
}
