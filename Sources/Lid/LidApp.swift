import SwiftUI

@main
struct LidApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        Window("Lid", id: "main") {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 480, height: 520)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ContentView: View {
    @State private var sensor = LidSensor()
    @AppStorage("palette") private var palette: Palette = .dawn

    var body: some View {
        Group {
            if sensor.isAvailable {
                LidColorView(angle: sensor.angle, palette: palette)
            } else {
                UnavailableView()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.6)) { palette = palette.next }
        }
        .frame(minWidth: 320, minHeight: 360)
    }
}
