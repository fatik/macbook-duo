import AppKit
import ScreenCaptureKit
import ServiceManagement

/// Screen Recording, which holding the whole screen still needs: macOS only lets an app see what's on
/// the screen once the person using it has said so in System Settings.
///
/// The journey: explain why, ask (macOS shows its own prompt the first time), and if that prompt was
/// dismissed or turned down, open the right pane of System Settings and watch for the switch to be
/// turned on. macOS sometimes only applies it once the app is reopened, so reopening is offered too.
@MainActor
@Observable
final class ScreenRecordingPermission {
    static let shared = ScreenRecordingPermission()

    enum State: Equatable {
        /// Never asked: asking shows macOS's own prompt.
        case notAsked
        /// Asked, but not allowed yet: only System Settings can allow it now.
        case waiting
        case granted
    }

    private(set) var state: State
    /// Whether someone was sent to allow it during this launch, so macOS may quit the app to apply it.
    @ObservationIgnored private var isAllowing = false
    @ObservationIgnored private var watcher: Task<Void, Never>?
    @ObservationIgnored private static let askedKey = "screenRecordingAsked"

    private init() {
        state = CGPreflightScreenCaptureAccess() ? .granted
            : UserDefaults.standard.bool(forKey: Self.askedKey) ? .waiting : .notAsked
    }

    var isGranted: Bool { state == .granted }

    /// Asks for it: macOS's prompt the first time, System Settings after that.
    func request() {
        if CGPreflightScreenCaptureAccess() {
            state = .granted
            return
        }
        isAllowing = true
        if state == .notAsked {
            UserDefaults.standard.set(true, forKey: Self.askedKey)
            // Shows macOS's prompt, which itself offers to open System Settings.
            _ = CGRequestScreenCaptureAccess()
            state = .waiting
        } else {
            openSystemSettings()
        }
        watch()
    }

    func openSystemSettings() {
        isAllowing = true
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        watch()
    }

    /// Looks again every second while someone is on their way to allow it, for up to five minutes.
    func watch() {
        guard watcher == nil, state != .granted else { return }
        watcher = Task { [weak self] in
            for tick in 0..<300 {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                await self.refresh(thoroughly: tick.isMultiple(of: 3))
                if self.state == .granted { break }
            }
            self?.watcher = nil
        }
    }

    /// Checks again. The quick check can lag behind System Settings within one launch, so now and
    /// then a "no" is double-checked by asking for what's on screen, which sees the new setting.
    func refresh(thoroughly: Bool = true) async {
        if CGPreflightScreenCaptureAccess() {
            state = .granted
            return
        }
        guard thoroughly, state == .waiting else { return }
        if (try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)) != nil {
            state = .granted
        }
    }

    /// Quits and opens again, so a permission granted meanwhile applies.
    static func relaunch() {
        reopenAfterQuitting()
        NSApp.terminate(nil)
    }

    /// Once Screen Recording is switched on, macOS offers to quit the app and reopen it, but it doesn't
    /// always reopen it. When the app is being quit from outside while someone is allowing it, it
    /// comes back by itself. Quitting it from its own menu or the Dock, or logging out, doesn't.
    func reopenIfQuitToApply() {
        guard isAllowing, let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == kCoreEventClass, event.eventID == kAEQuitApplication,
              // Logging out, restarting or shutting down gives a reason.
              event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) == nil
        else { return }
        let sender = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value
        let senderApp = sender.flatMap { NSRunningApplication(processIdentifier: pid_t($0)) }
        guard senderApp?.bundleIdentifier != "com.apple.dock" else { return }
        Self.reopenAfterQuitting()
    }

    /// Opens the app again a moment after this copy has gone.
    private static func reopenAfterQuitting() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while /bin/kill -0 $1 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
                          Bundle.main.bundlePath, String(ProcessInfo.processInfo.processIdentifier)]
        try? task.run()
    }
}

/// Opening at login, through macOS's own login items, where the person can also see and change it.
@MainActor
enum LaunchAtLogin {
    static var isOn: Bool { SMAppService.mainApp.status == .enabled }

    /// Turns it on or off, returning whether it's on afterwards. macOS may ask for approval in System
    /// Settings, in which case it isn't on yet.
    @discardableResult
    static func set(_ on: Bool) -> Bool {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            if on, SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        }
        return isOn
    }
}
