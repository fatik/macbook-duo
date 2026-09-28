import AppKit
import SwiftUI

/// Shows the experiment on the whole display, including the strips beside the camera notch that
/// macOS's own full screen leaves black: the picture, or the welcome.
///
/// It opens a borderless window over the display's full frame and hides the menu bar and Dock while
/// it's up. The regular window steps aside until it closes again.
@MainActor
@Observable
final class EdgeToEdge {
    static let shared = EdgeToEdge()

    /// Whether the full-screen window is up.
    private(set) var isActive = false

    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private weak var regularWindow: NSWindow?

    func toggle() {
        window == nil ? enter() : exit()
    }

    /// The picture, on the display the regular window is on.
    func enter() {
        enter(ShowcaseView(isEdgeToEdge: true))
    }

    /// Shows `content` over the whole of `screen` (or the regular window's), in place of the regular
    /// window. Already up, it shows `content` instead of what it had.
    func enter(_ content: some View, replacing regular: NSWindow? = nil, on screen: NSScreen? = nil) {
        if let window {
            window.contentView = NSHostingView(rootView: content)
            bringForward(hiding: regular)
            return
        }
        let regular = regular ?? NSApp.keyWindow ?? NSApp.mainWindow
        guard let screen = screen ?? regular?.screen ?? NSScreen.main else { return }

        let window = KeyableWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: content)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.setFrame(screen.frame, display: true)

        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        window.makeKeyAndOrderFront(nil)
        regular?.orderOut(nil)
        self.window = window
        regularWindow = regular
        isActive = true
    }

    /// Brings the full-screen window back in front, as when the app is asked for its window while
    /// it's up, keeping the regular one out of the way.
    func bringForward(hiding regular: NSWindow? = nil) {
        guard let window else { return }
        if let regular {
            regularWindow = regular
            regular.orderOut(nil)
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func exit() {
        guard let window else { return }
        NSApp.presentationOptions = []
        // Bring the regular window back before closing this one, so the app never looks like its
        // last window closed.
        if let regularWindow {
            regularWindow.makeKeyAndOrderFront(nil)
        } else {
            AppState.shared.openMainWindow?()
        }
        window.close()
        self.window = nil
        isActive = false
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

/// Tells `found` which window it's in once it's in one, and again whenever that window comes to the
/// front.
struct WindowReader: NSViewRepresentable {
    var found: (NSWindow) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.found = found
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.found = found
    }

    final class ReaderView: NSView {
        var found: ((NSWindow) -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            // Once the window has finished coming up.
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                found?(window)
            }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window,
                                                              queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let window = self.window else { return }
                    self.found?(window)
                }
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
