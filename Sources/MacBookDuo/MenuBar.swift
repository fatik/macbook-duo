import SwiftUI

/// The menu bar item's menu: Screen Effect, and the way back to everything else.
struct MenuBarMenu: View {
    private let still = StillScreen.shared
    private let app = AppState.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Toggle("Screen Effect", isOn: Binding(get: { still.isOn }, set: { _ in still.toggle() }))
            .keyboardShortcut("s", modifiers: [.command, .option])
        if let problem = still.problem {
            Text(problem)
        }
        Divider()
        Button("Open MacBook Duo") { show() }
        Menu("Calibrate") {
            Button("With Camera…") { show(.camera) }
            Button("By Eye…") { show(.lineUp) }
        }
        Button("Settings…") {
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")
        Divider()
        Button("About MacBook Duo") { AboutPanel.show() }
        Button("Quit MacBook Duo") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func show(_ request: AppState.Request? = nil) {
        if app.openMainWindow == nil { app.openMainWindow = { [openWindow] in openWindow(id: "main") } }
        // Calibrating needs the picture, not the whole screen held.
        if request != nil, still.isOn { still.turnOff() }
        app.showMainWindow(request)
    }
}

/// The menu bar item's icon. It's there from launch, so it hands over the way to open the main window
/// before any window has appeared.
struct MenuBarLabel: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: MenuBarIcon.image)
            .onAppear {
                if AppState.shared.openMainWindow == nil {
                    AppState.shared.openMainWindow = { [openWindow] in openWindow(id: "main") }
                }
            }
    }
}

/// The app icon's mark at menu bar size: one panel facing you, its twin turned away. A template, so
/// macOS colors it for the menu bar.
enum MenuBarIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 16), flipped: true) { _ in
            NSColor.black.set()
            NSBezierPath(roundedRect: NSRect(x: 3, y: 1.5, width: 6.2, height: 13), xRadius: 1.4, yRadius: 1.4).fill()
            let twin = NSBezierPath()
            twin.move(to: NSPoint(x: 9.8, y: 1.5))
            twin.line(to: NSPoint(x: 15.2, y: 3.3))
            twin.line(to: NSPoint(x: 15.2, y: 12.7))
            twin.line(to: NSPoint(x: 9.8, y: 14.5))
            twin.close()
            NSColor.black.withAlphaComponent(0.45).set()
            twin.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "MacBook Duo"
        return image
    }()
}
