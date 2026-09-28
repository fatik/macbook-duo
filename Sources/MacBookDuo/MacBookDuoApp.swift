import SwiftUI

/// MacBook Duo: it follows the lid angle sensor in a MacBook's hinge and redraws what's on the screen
/// so it looks held still in space while the lid moves. Its window shows that on a picture, with every
/// control; its menu bar item and ⌥⌘S do it to the whole screen, from any app.
@main
struct MacBookDuoApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    init() {
        Defaults.migrateFromStraight()
        Defaults.register()
    }

    var body: some Scene {
        Window("MacBook Duo", id: "main") {
            MainView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1000, height: 640)
        .commands { DuoCommands() }

        Settings {
            SettingsView()
        }

        MenuBarExtra {
            MenuBarMenu()
        } label: {
            MenuBarLabel()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Opened at login, it starts quietly, in the menu bar only.
        let event = NSAppleEventManager.shared().currentAppleEvent
        let atLogin = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        MainActor.assumeIsolated {
            // Again now the screens are known: a model missing from the table goes by its display's size.
            LidGeometry.reload()
            AppState.applyDockPreference()
            LidSensor.shared.predictsMotion = UserDefaults.standard.bool(forKey: Defaults.predictsMotion)
            LidSensor.shared.sensorDelay = UserDefaults.standard.double(forKey: Defaults.motionLead) / 1000
            StillScreen.shared.installHotKey()
        }
        MainActor.assumeIsolated { AppState.shared.launchedAtLogin = atLogin }
        Task { @MainActor in
            // Opened any other way, its window comes up, whatever macOS remembered from last time.
            try? await Task.sleep(for: .milliseconds(500))
            if !atLogin, !NSApp.windows.contains(where: { $0.canBecomeMain && $0.isVisible }) {
                AppState.shared.showMainWindow()
            }
            try? await Task.sleep(for: .seconds(1))
            AppState.shared.restIfUnfollowed()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated { ScreenRecordingPermission.shared.reopenIfQuitToApply() }
        return .terminateNow
    }

    /// Closing the window leaves MacBook Duo in the menu bar, with ⌥⌘S still working.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Clicking the Dock icon with no window open brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            MainActor.assumeIsolated { AppState.shared.showMainWindow() }
        }
        return true
    }
}

/// The menu bar's menus: Screen Effect and calibrating, and no new windows, since there's one.
struct DuoCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About MacBook Duo") { AboutPanel.show() }
        }
        CommandGroup(replacing: .newItem) {}
        CommandMenu("Effect") {
            Toggle("Screen Effect", isOn: Binding(get: { StillScreen.shared.isOn },
                                                  set: { _ in StillScreen.shared.toggle() }))
            Divider()
            Button("Calibrate with Camera…") { AppState.shared.showMainWindow(.camera) }
            Button("Calibrate by Eye…") { AppState.shared.showMainWindow(.lineUp) }
        }
        CommandGroup(replacing: .help) {
            Button("Show Welcome") {
                UserDefaults.standard.set(false, forKey: Defaults.onboardingCompleted)
                AppState.shared.showMainWindow()
            }
        }
    }
}
