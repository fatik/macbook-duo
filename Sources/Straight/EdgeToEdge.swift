import AppKit
import SwiftUI

/// Shows the experiment on the whole display, including the strips beside the camera notch that
/// macOS's own full screen leaves black.
///
/// It opens a borderless window over the display's full frame and hides the menu bar and Dock while
/// it's up. The regular window steps aside until it closes again.
@MainActor
final class EdgeToEdge {
    static let shared = EdgeToEdge()

    private var window: NSWindow?
    private weak var regularWindow: NSWindow?

    func toggle() {
        window == nil ? enter() : exit()
    }

    func enter() {
        guard window == nil,
              let regular = NSApp.keyWindow ?? NSApp.mainWindow,
              let screen = regular.screen ?? NSScreen.main
        else { return }

        let window = KeyableWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: ContentView(isEdgeToEdge: true))
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.setFrame(screen.frame, display: true)

        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        window.makeKeyAndOrderFront(nil)
        regular.orderOut(nil)
        self.window = window
        regularWindow = regular
    }

    func exit() {
        guard let window else { return }
        NSApp.presentationOptions = []
        // Bring the regular window back before closing this one, so the app never looks like its
        // last window closed.
        regularWindow?.makeKeyAndOrderFront(nil)
        window.close()
        self.window = nil
    }
}

/// Borderless windows can't take keyboard focus by default, which the controls and shortcuts need.
private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // While in front, sit above the menu bar's layer: with the menu bar hidden, macOS still paints
    // the strips beside the notch black at that layer. Drop back to normal whenever another window
    // (an open panel, say) or another app takes over, so nothing gets stuck behind this one.
    override func becomeKey() {
        super.becomeKey()
        level = .mainMenu + 1
    }

    override func resignKey() {
        super.resignKey()
        level = .normal
    }
}
