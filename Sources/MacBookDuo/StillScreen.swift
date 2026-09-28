import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Holding the whole screen still while the lid moves: the built-in display's real picture, captured
/// live and drawn back over itself the way the card is, held where the screen was when the lid
/// started moving. Once the lid settles, it eases back onto the real screen and steps aside, until the
/// lid moves again. It runs over everything and lets clicks through to what's really underneath; it's
/// turned on and off from MacBook Duo's window, its menu bar item or ⌥⌘S from anywhere.
@MainActor
@Observable
final class StillScreen {
    static let shared = StillScreen()

    private(set) var isOn = false
    /// Whether the screen is being held right now, rather than showing as it really is.
    private(set) var isHolding = false
    /// Why it couldn't start, or stopped, if it did.
    private(set) var problem: String?

    private enum Phase {
        /// The real screen shows, with the lid resting at `angle` since `since`.
        case resting(angle: Double, since: CFTimeInterval)
        /// The screen is held where it was with the lid at `anchor`.
        case holding(anchor: Double)
        /// Easing back from where it was held with the lid at `from` to where the lid is now, over
        /// `duration` seconds from `start`.
        case returning(from: Double, start: CFTimeInterval, duration: Double)
    }

    /// How many degrees the lid moves from rest before the screen is held. Less than a typing bump
    /// would be caught too, but holding it then barely shows.
    static let wakeAngle = 0.25
    /// How many seconds the lid stays still before the screen eases back.
    static var settleTime: Double { UserDefaults.standard.double(forKey: Defaults.holdSettleTime) }
    /// Frames a second captured while the lid rests: enough that the picture is barely behind when the
    /// lid moves, without capturing the whole screen at full speed all the time.
    static let restingRate = 15

    @ObservationIgnored private var phase = Phase.resting(angle: 0, since: 0)
    /// The last time the lid moved, and where to.
    @ObservationIgnored private var motion = (angle: 0.0, time: CFTimeInterval(0))
    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var view: CardMetalView?
    @ObservationIgnored private var ticker: FrameTicker?
    @ObservationIgnored private var link: CADisplayLink?
    /// Frames a second captured while the screen is held: as often as the display refreshes.
    @ObservationIgnored private var fullRate = 60
    @ObservationIgnored private let mirror = ScreenMirror()
    @ObservationIgnored let sensor = LidSensor.shared
    @ObservationIgnored private var hotKey: GlobalHotKey?
    /// Turned off for sleep, a locked screen or a display change, to come back on after.
    @ObservationIgnored private var resumes = false

    private init() {
        // If capturing ends (Stop Sharing, say), there's no picture to hold the screen with.
        mirror.onStop = { [weak self] in
            guard let self, window != nil else { return }
            turnOff()
            problem = "Screen Effect turned off because screen recording stopped."
        }
        // The capture doesn't survive sleep or a locked screen, and a sleeping screen needs nothing
        // held: it's off meanwhile and comes back on after.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.pause() }
            }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resume() }
            }
        }
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
        }
        distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    /// ⌥⌘S turns holding the screen on and off from anywhere, even with nothing of MacBook Duo's in view,
    /// unless it's been turned off in Settings. Called again whenever that changes.
    func installHotKey() {
        guard UserDefaults.standard.bool(forKey: Defaults.globalShortcut) else {
            hotKey = nil
            return
        }
        guard hotKey == nil else { return }
        hotKey = GlobalHotKey(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(cmdKey | optionKey)) { [weak self] in
            self?.toggle()
        }
    }

    func toggle() {
        isOn ? turnOff() : turnOn()
    }

    func turnOn() {
        guard window == nil else { return }
        guard let screen = ThisMac.builtInScreen,
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else {
            problem = "Open your MacBook's lid to use Screen Effect."
            return
        }
        // Asking comes with an explanation first, never out of the blue.
        guard ScreenRecordingPermission.shared.state != .notAsked else {
            AppState.shared.showMainWindow(.screenPermission)
            return
        }
        problem = nil
        isOn = true
        AppState.shared.follow()
        // A picture held edge to edge would be held twice over.
        EdgeToEdge.shared.exit()

        let view = CardMetalView(drawsItself: false)
        view.sensor = sensor
        view.seeThroughWhenEmpty = true
        view.colorSpace = CGColorSpace(name: CGColorSpace.displayP3)
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        window.backgroundColor = .clear
        window.isOpaque = false
        // Clicks go through to what's really there, and this menu stays reachable underneath.
        window.ignoresMouseEvents = true
        window.hasShadow = false
        // Over the menu bar and the Dock too, on every space.
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.setFrame(screen.frame, display: true)
        window.orderFrontRegardless()
        self.window = window
        self.view = view
        view.scene = scene(on: screen)
        let now = CACurrentMediaTime()
        motion = (sensor.angle, now)
        rest(at: sensor.angle, now: now)
        let fullRate = max(screen.maximumFramesPerSecond, 60)
        self.fullRate = fullRate

        let ticker = FrameTicker { [weak self] link in self?.step(at: link.timestamp) }
        let link = screen.displayLink(target: ticker, selector: #selector(FrameTicker.frame(_:)))
        link.add(to: .main, forMode: .common)
        self.ticker = ticker
        self.link = link

        Task {
            do {
                try await mirror.start(displayID: displayID, scale: screen.backingScaleFactor,
                                       rate: fullRate, excluding: window.windowNumber)
            } catch let failure as ScreenMirror.Failure {
                turnOff()
                problem = failure.localizedDescription
                return
            } catch {
                turnOff()
                problem = "Screen Effect needs Screen Recording permission."
                AppState.shared.showMainWindow(.screenPermission)
                return
            }
            guard self.window === window else { return }
            if case .resting = phase { mirror.setRate(Self.restingRate) }
            while mirror.latest == nil, self.window === window {
                try? await Task.sleep(for: .milliseconds(20))
            }
            // Should the picture ever go, whatever the reason, stop.
            while self.window === window {
                try? await Task.sleep(for: .milliseconds(500))
                if self.window === window, mirror.latest == nil {
                    turnOff()
                    problem = "Screen Effect turned off because screen recording stopped."
                }
            }
        }
    }

    func turnOff() {
        resumes = false
        guard window != nil else { return }
        link?.invalidate()
        link = nil
        ticker = nil
        window?.orderOut(nil)
        window = nil
        view = nil
        mirror.stop()
        isOn = false
        isHolding = false
        AppState.shared.unfollow()
    }

    /// Off for now, to come back on by itself.
    private func pause() {
        guard isOn else { return }
        turnOff()
        resumes = true
    }

    private func resume() {
        guard resumes else { return }
        resumes = false
        // The display takes a moment to be itself again after waking.
        Task {
            try? await Task.sleep(for: .seconds(1))
            turnOn()
        }
    }

    /// A display was added, removed or changed resolution: the capture and the window are sized for
    /// the old one, so they start over, or stop if the built-in display went away.
    private func screensChanged() {
        guard isOn, let window else { return }
        guard let screen = ThisMac.builtInScreen else {
            turnOff()
            problem = "Screen Effect turned off because your MacBook's display went off."
            return
        }
        guard screen.frame != window.frame || screen.backingScaleFactor != window.backingScaleFactor else { return }
        turnOff()
        turnOn()
    }

    /// The screen's picture over the whole display, for the viewpoint set in the Viewer tab and looking
    /// as set in the Look tab.
    private func scene(on screen: NSScreen) -> CardScene? {
        guard let placement = ScreenPlacement(of: screen.frame, on: screen) else { return nil }
        let defaults = UserDefaults.standard
        func setting(_ key: String, _ standard: Double) -> Double { defaults.object(forKey: key) as? Double ?? standard }
        // The blur and dimming set in the Look tab, gone by the time the screen is back in place, so
        // handing back to the real screen doesn't show.
        var blur = StoredEffect.blur().current, dim = StoredEffect.dim().current
        blur.lidReaction = 1
        dim.lidReaction = 1
        return CardScene(placement: placement, windowSize: screen.frame.size, cardSize: screen.frame.size,
                         anchorAngle: sensor.angle,
                         viewpoint: defaults.string(forKey: "viewpoint").flatMap(Viewpoint.init) ?? .screen,
                         eyeDistance: setting("eyeDistance", 55), eyeHeight: setting("eyeHeight", 35),
                         viewDistance: setting("viewDistance", 0), lookingDown: setting("viewLookingDown", 10),
                         fillsWindow: true, cornerRadius: setting("cornerRadius", LidGeometry.current.cornerRadius),
                         background: RGBColor(hex: 0), blur: blur, dim: dim, content: .nothing)
    }

    /// On every screen refresh: follows the lid, and draws.
    private func step(at now: CFTimeInterval) {
        guard let view else { return }
        sensor.advance(to: now)
        let angle = sensor.angle
        if abs(angle - motion.angle) >= 0.1 { motion = (angle, now) }

        switch phase {
        case .resting(let rest, let since):
            if abs(angle - rest) >= Self.wakeAngle, mirror.latest != nil {
                hold(at: rest)
            } else if now - since > 0.1, window?.alphaValue != 0 {
                // It has drawn nothing by now, so the window can step aside entirely.
                window?.alphaValue = 0
            }
        case .holding(let anchor):
            if now - motion.time >= Self.settleTime {
                // Farther to go takes a little longer, but never long.
                phase = .returning(from: anchor, start: now, duration: min(0.35 + abs(angle - anchor) * 0.012, 0.8))
            }
        case .returning(let from, let start, let duration):
            let progress = min((now - start) / duration, 1)
            let eased = progress < 0.5 ? 4 * pow(progress, 3) : 1 - pow(2 - 2 * progress, 3) / 2
            let anchor = from + (angle - from) * eased
            if motion.time > start {
                // Moving again: hold it from wherever it had got to.
                hold(at: anchor)
            } else if progress == 1 {
                rest(at: angle, now: now)
            } else {
                view.scene?.anchorAngle = anchor
            }
        }
        view.update(at: now)
    }

    private func hold(at anchor: Double) {
        if case .resting = phase, let screen = window?.screen {
            // Picks up any change to the viewpoint since last time.
            view?.scene = scene(on: screen)
            window?.alphaValue = 1
            mirror.setRate(fullRate)
            isHolding = true
        }
        phase = .holding(anchor: anchor)
        view?.scene?.anchorAngle = anchor
        view?.scene?.content = .live(mirror)
    }

    /// Back on the real screen: the held picture now matches it exactly, so drawing nothing instead
    /// doesn't show.
    private func rest(at angle: Double, now: CFTimeInterval) {
        phase = .resting(angle: angle, since: now)
        view?.scene?.anchorAngle = angle
        view?.scene?.content = .nothing
        mirror.setRate(Self.restingRate)
        if isHolding { isHolding = false }
    }
}

/// A keyboard shortcut that works whatever app is in front. Carbon's hot keys need no permission.
@MainActor
private final class GlobalHotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { hotKey.action() }
            return noErr
        }, 1, &pressed, me, &handler)
        // 'MDUO', for MacBook Duo.
        let id = EventHotKeyID(signature: OSType(0x4D44_554F), id: 1)
        guard installed == noErr,
              RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKey) == noErr
        else { return nil }
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}
