import SwiftUI

/// The first run, over the whole screen: the desert, live, with a card floating in the middle that
/// asks you to tilt the screen and then suggests calibrating. The card drops out of the way as soon
/// as the lid moves, so nothing covers the effect, and comes back once it's still.
struct OnboardingView: View {
    /// Called at the end, with the calibration to start, if one was chosen.
    var finish: (AppState.Request?) -> Void

    enum Step {
        case tilt, calibrate
    }

    @State private var step = Step.tilt
    /// Out of sight below the screen, while the lid moves. It starts there and rises into view.
    @State private var isAway = true
    private let sensor = LidSensor.shared

    /// How far the lid moves before the card gets out of the way, and how long it has to stay still
    /// for the card to come back.
    static let moveThreshold = 0.4
    static let settleTime = Duration.milliseconds(500)
    /// How far a tilt has to go to count as having seen the effect.
    static let tiltToContinue = 5.0

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ShowcaseView(mode: .demo)
                card
                    // Down past the bottom of the screen, a little smaller, as though dropping away.
                    .scaleEffect(isAway ? 0.94 : 1)
                    .offset(y: isAway ? geometry.size.height * 0.75 : 0)
                    .allowsHitTesting(!isAway)
            }
        }
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .task { await followLid() }
    }

    // MARK: The card

    private var card: some View {
        DuoCard(width: 500) {
            VStack(spacing: 0) {
                StepDots(done: step == .tilt ? 1 : 2, total: 2)
                    .padding(.bottom, 20)
                switch step {
                case .tilt: tilt
                case .calibrate: calibrate
                }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
        }
    }

    private var tilt: some View {
        VStack(spacing: 0) {
            Text("MACBOOK DUO")
                .font(.system(size: 11, weight: .semibold))
                .kerning(1.2)
                .foregroundStyle(.secondary)
            Text("The iPhone Duo effect, on your Mac.")
                .font(.system(size: 26, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            HStack(spacing: 12) {
                LidGlyph(sensor: sensor)
                    .frame(width: LidGlyph.size.width, height: LidGlyph.size.height)
                Text("Tilt your screen to see it")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.duo)
            }
            .padding(.top, 20)
            Button("Skip") { finish(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)
                .padding(.top, 22)
        }
    }

    private var calibrate: some View {
        VStack(spacing: 0) {
            Text("THAT'S THE DUO EFFECT")
                .font(.system(size: 11, weight: .semibold))
                .kerning(1.2)
                .foregroundStyle(Color.duo)
            Text("Calibrate for the best experience")
                .font(.system(size: 26, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            Text("The effect is drawn for where your eyes are. Your camera finds them in about 10 seconds, and nothing is recorded.")
                .font(.system(size: 13.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
            Button("Calibrate with Camera") { finish(.camera) }
                .buttonStyle(.primary)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 22)
            HStack(spacing: 8) {
                Button("Calibrate by Eye") { finish(.lineUp) }
                    .buttonStyle(.secondary)
                Button("Skip") { finish(nil) }
                    .buttonStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.top, 10)
        }
    }

    // MARK: Following the lid

    /// Sends the card away as soon as the lid moves and brings it back once the lid has been still
    /// for a moment. The first tilt that goes far enough moves on to calibrating, while it's away.
    private func followLid() async {
        let clock = ContinuousClock()
        var rest = sensor.reading
        var last = rest
        var lastMove = clock.now
        var farthest = 0.0
        while !Task.isCancelled {
            let now = clock.now
            let reading = sensor.reading
            if reading != last {
                last = reading
                lastMove = now
            }
            if isAway {
                farthest = max(farthest, abs(reading - rest))
                if now - lastMove >= Self.settleTime {
                    if step == .tilt, farthest >= Self.tiltToContinue { step = .calibrate }
                    rest = reading
                    farthest = 0
                    // Rises back with a little spring.
                    withAnimation(.spring(response: 0.55, dampingFraction: 0.78)) { isAway = false }
                }
            } else if abs(reading - rest) >= Self.moveThreshold {
                // Quick to go: gathering speed as it drops below the screen.
                withAnimation(.timingCurve(0.35, 0, 0.75, 0.2, duration: 0.38)) { isAway = true }
            }
            try? await Task.sleep(for: .milliseconds(16))
        }
    }
}

/// Puts the welcome over the whole built-in display, in place of the regular window, and takes it
/// down again at the end: to the regular window, or on to calibrating, still full screen.
@MainActor
enum Welcome {
    private static var isShowing = false

    /// From the regular window, whenever it shows the welcome or comes to the front while it's up.
    static func present(replacing regular: NSWindow) {
        // Just finished, the window may not have moved on from the welcome yet.
        guard !UserDefaults.standard.bool(forKey: Defaults.onboardingCompleted) else { return }
        guard !isShowing else { return EdgeToEdge.shared.bringForward(hiding: regular) }
        isShowing = true
        // The desert would be held twice over.
        if StillScreen.shared.isOn { StillScreen.shared.turnOff() }
        EdgeToEdge.shared.enter(OnboardingView(finish: finish), replacing: regular,
                                on: ThisMac.builtInScreen ?? regular.screen)
    }

    private static func finish(_ request: AppState.Request?) {
        isShowing = false
        UserDefaults.standard.set(true, forKey: Defaults.onboardingCompleted)
        if let request {
            EdgeToEdge.shared.enter(ShowcaseView(isEdgeToEdge: true))
            AppState.shared.request = request
        } else {
            EdgeToEdge.shared.exit()
        }
    }
}

/// In the regular window while the welcome is up, which it steps aside for.
struct WelcomeLauncher: View {
    var body: some View {
        Color.duoBackground
            .background(WindowReader { Welcome.present(replacing: $0) })
    }
}

/// Where Screen Recording stands, and the one step that moves it along: ask, open System Settings,
/// or try holding the screen once it's allowed.
struct ScreenPermissionView: View {
    private let permission = ScreenRecordingPermission.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 17))
                    .foregroundStyle(permission.isGranted ? Color.duo : .secondary)
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
            }
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                switch permission.state {
                case .notAsked:
                    Button("Allow Access") { permission.request() }
                        .buttonStyle(.primary)
                case .waiting:
                    Button("Open System Settings") { permission.openSystemSettings() }
                        .buttonStyle(.primary)
                    Button("Reopen MacBook Duo") { ScreenRecordingPermission.relaunch() }
                        .buttonStyle(.secondary)
                case .granted:
                    Button("Try It") { StillScreen.shared.turnOn() }
                        .buttonStyle(.secondary)
                }
            }
            .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.06)))
        .task {
            await permission.refresh()
            if permission.state == .waiting { permission.watch() }
        }
    }

    private var symbol: String {
        switch permission.state {
        case .notAsked: "rectangle.dashed"
        case .waiting: "hourglass"
        case .granted: "checkmark.circle.fill"
        }
    }

    private var title: String {
        switch permission.state {
        case .notAsked: "Screen Recording"
        case .waiting: "Waiting for permission"
        case .granted: "Screen Recording is on"
        }
    }

    private var detail: String {
        switch permission.state {
        case .notAsked:
            "macOS will ask for permission."
        case .waiting:
            "Turn on MacBook Duo in System Settings › Privacy & Security › Screen & System Audio Recording."
        case .granted:
            "Press ⌥⌘S from any app to turn Screen Effect on or off."
        }
    }
}
