import AppKit
import SwiftUI

/// Where a view sits on its physical display, which the projection needs in real units.
struct ScreenPlacement: Equatable {
    /// The view's frame in points, measured from its display's top-left corner.
    var frame: CGRect
    var displaySize: CGSize
    var cmPerPoint: Double
    var isBuiltIn: Bool
    /// Height of the camera notch in points, or 0 on displays without one.
    var notchHeight: CGFloat
}

/// Reports the placement of the space it fills whenever the window moves, resizes or changes display.
struct PlacementReader: NSViewRepresentable {
    var onChange: (ScreenPlacement) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onChange = onChange
    }

    final class ReaderView: NSView {
        var onChange: ((ScreenPlacement) -> Void)?
        private var last: ScreenPlacement?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let window else { return }
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(windowChanged), name: name, object: window)
            }
            report()
        }

        override func layout() {
            super.layout()
            report()
        }

        @objc private func windowChanged(_ notification: Notification) {
            report()
        }

        private func report() {
            guard let window, let screen = window.screen,
                  let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            else { return }

            let rect = window.convertToScreen(convert(bounds, to: nil))
            let placement = ScreenPlacement(
                frame: CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY,
                              width: rect.width, height: rect.height),
                displaySize: screen.frame.size,
                cmPerPoint: CGDisplayScreenSize(id).width / 10 / screen.frame.width,
                isBuiltIn: CGDisplayIsBuiltin(id) != 0,
                notchHeight: screen.safeAreaInsets.top)
            guard placement != last else { return }
            last = placement

            // Deliver outside the current layout pass so SwiftUI can update state freely.
            DispatchQueue.main.async { [onChange] in onChange?(placement) }
        }
    }
}
