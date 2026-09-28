import AppKit
import SwiftUI

/// What the windows share: a way to bring up the main window from anywhere (the Dock, the menu bar,
/// the global shortcut, Settings), and what it should do once it's up.
@MainActor
@Observable
final class AppState {
    static let shared = AppState()

    /// Something for the main window to do next.
    enum Request: Equatable {
        /// Explain Screen Recording and ask for it.
        case screenPermission
        /// Start calibrating: by eye, or with the camera.
        case lineUp, camera
    }

    var request: Request?

    /// Opens the main window, or brings it forward if it's open. SwiftUI only hands this out to its
    /// views, so the first one to appear leaves it here.
    @ObservationIgnored var openMainWindow: (() -> Void)?

    /// Opened at login, when the window stays closed until asked for.
    @ObservationIgnored var launchedAtLogin = false

    /// How many things follow the lid right now: the main window, the whole screen being held,
    /// Settings' sensor readout. With none, the sensor rests.
    @ObservationIgnored private var followers = 0

    func follow() {
        followers += 1
        LidSensor.shared.setActive(true)
    }

    func unfollow() {
        followers = max(followers - 1, 0)
        if followers == 0 { LidSensor.shared.setActive(false) }
    }

    /// Rests the sensor if nothing has started following the lid since launch, as when opened at login.
    func restIfUnfollowed() {
        if followers == 0 { LidSensor.shared.setActive(false) }
    }

    func showMainWindow(_ request: Request? = nil) {
        if let request { self.request = request }
        NSApp.activate()
        openMainWindow?()
    }

    /// Whether MacBook Duo has an icon in the Dock as well as in the menu bar.
    static func applyDockPreference() {
        let shows = UserDefaults.standard.bool(forKey: Defaults.showsInDock)
        NSApp.setActivationPolicy(shows ? .regular : .accessory)
    }
}
