import SwiftUI

/// The main window: the welcome the first time, then the picture held still, or while the whole screen
/// is being held, what's going on and how to stop it. A Mac without a lid sensor gets told so.
struct MainView: View {
    @AppStorage(Defaults.onboardingCompleted) private var onboardingCompleted = false
    @Environment(\.openWindow) private var openWindow
    private let sensor = LidSensor.shared
    private let still = StillScreen.shared
    private let app = AppState.shared

    var body: some View {
        Group {
            if !sensor.isAvailable {
                NoSensorView()
            } else if !onboardingCompleted {
                OnboardingView { request in
                    onboardingCompleted = true
                    app.request = request
                }
            } else if still.isOn {
                // The picture would be held twice over: the whole screen already is.
                ScreenHeldView()
            } else {
                ShowcaseView()
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .background(Color.duoBackground)
        .preferredColorScheme(.dark)
        .onAppear {
            app.openMainWindow = { [openWindow] in openWindow(id: "main") }
            app.follow()
            // Opened at login, it starts quietly in the menu bar: the window SwiftUI opens goes again.
            if app.launchedAtLogin {
                app.launchedAtLogin = false
                DispatchQueue.main.async {
                    for window in NSApp.windows where window.canBecomeMain && window.isVisible { window.close() }
                }
            }
        }
        .onDisappear { app.unfollow() }
    }
}

/// For a Mac whose lid can't be followed: a desktop Mac has none, and some MacBooks don't report its
/// angle. Says which, and which Macs do.
struct NoSensorView: View {
    private let sensor = LidSensor.shared
    @State private var checked = false

    var body: some View {
        VStack(spacing: 18) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: ThisMac.hasBattery ? "laptopcomputer" : "desktopcomputer")
                    .font(.system(size: 64, weight: .ultraLight))
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(Color.duo)
                    .background(Circle().fill(Color.duoBackground).padding(2))
                    .offset(x: 10, y: 8)
            }
            .padding(.bottom, 4)
            Text(ThisMac.hasBattery ? "This Mac doesn't have a lid sensor" : "This Mac doesn't have a lid")
                .font(.system(size: 24, weight: .bold))
                .multilineTextAlignment(.center)
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
                .fixedSize(horizontal: false, vertical: true)
            Text(SupportedMacs.summary)
                .font(.system(size: 12.5))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Check Again") {
                    sensor.connect()
                    checked = true
                }
                .buttonStyle(.secondary)
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.primary)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 6)
            Text(checked ? "Still no lid sensor found (\(ThisMac.modelIdentifier))." : ThisMac.modelIdentifier)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var message: String {
        "MacBook Duo uses the lid angle sensor built into recent MacBooks."
    }
}

/// The main window while the whole screen is being held: live, and how to stop.
struct ScreenHeldView: View {
    private let still = StillScreen.shared
    private let sensor = LidSensor.shared
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 20) {
            LidGlyph(sensor: sensor, lineWidth: 4)
                .frame(width: LidGlyph.size.width * 2.2, height: LidGlyph.size.height * 2.2)
            VStack(spacing: 8) {
                Text("Screen Effect is on")
                    .font(.system(size: 26, weight: .bold))
                Text("Tilt your screen to see it. It settles back when you stop.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button("Settings…") {
                    NSApp.activate()
                    openSettings()
                }
                .buttonStyle(.secondary)
                Button("Turn Off") { still.turnOff() }
                    .buttonStyle(.primary)
                    .keyboardShortcut(.defaultAction)
            }
            HStack(spacing: 6) {
                KeyCap(keys: "⌥⌘S")
                Text("turns it on or off from any app")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 12.5))
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The standard About panel, with a line on what MacBook Duo does.
@MainActor
enum AboutPanel {
    static func show() {
        NSApp.activate()
        let credits = NSAttributedString(
            string: "The iPhone Duo effect, on your Mac.",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}
