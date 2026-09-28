import SwiftUI

/// The first run: the Duo effect, shown live on the desert as the lid moves; Screen Effect, with the
/// Screen Recording it needs; calibrating to the viewer's eyes; and where everything is afterwards.
struct OnboardingView: View {
    /// Called at the end, with the calibration to start, if one was chosen.
    var finish: (AppState.Request?) -> Void

    enum Step: Int, CaseIterable {
        case welcome, screen, fit, ready
    }

    enum Fit {
        case typical, lineUp, camera
    }

    /// Kept, so reopening the app to apply Screen Recording picks up where it left off.
    @AppStorage("onboardingStep") private var step = Step.welcome
    @State private var fit = Fit.camera
    @State private var launchesAtLogin = LaunchAtLogin.isOn
    private let still = StillScreen.shared
    private let app = AppState.shared

    var body: some View {
        HStack(spacing: 0) {
            demo
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            panel
                .frame(width: 430)
                .frame(maxHeight: .infinity)
                .background(Color(white: 0.075))
                .overlay(alignment: .leading) { Color.white.opacity(0.06).frame(width: 1) }
        }
        .background(Color.duoBackground)
        .environment(\.colorScheme, .dark)
        // Asked to hold the screen before the welcome is done: this is where that's explained.
        .onChange(of: app.request, initial: true) { _, request in
            guard request == .screenPermission else { return }
            app.request = nil
            withAnimation(.easeInOut(duration: 0.25)) { step = .screen }
        }
    }

    // MARK: The live demo

    private var demo: some View {
        ZStack(alignment: .bottom) {
            if still.isOn {
                // The desert would be held twice over; the whole screen is the demo now.
                VStack(spacing: 10) {
                    Image(systemName: "rectangle.inset.filled.and.person.filled")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(Color.duo)
                    Text("Screen Effect is on")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Tilt your screen to see it. ⌥⌘S turns it off.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ShowcaseView(mode: .demo)
                LiveChip()
                    .padding(.bottom, 22)
            }
        }
    }

    // MARK: The story

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepDots(done: step.rawValue + 1, total: Step.allCases.count)
                .padding(.bottom, 26)
            Group {
                switch step {
                case .welcome: welcome
                case .screen: screen
                case .fit: fitStep
                case .ready: ready
                }
            }
            .transition(.opacity.combined(with: .offset(y: 6)))
            .frame(maxHeight: .infinity, alignment: .top)
            buttons
        }
        .padding(34)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("WELCOME TO")
                .font(.system(size: 11, weight: .semibold))
                .kerning(1.2)
                .foregroundStyle(.secondary)
            Text("MacBook Duo")
                .font(.system(size: 34, weight: .bold))
            Text("The iPhone Duo effect, on your Mac.")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color.duo)
            Text("Tilt your screen. The picture stays put, like it's floating in front of it.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TiltCheck()
                .padding(.top, 6)
            Label("Tip: close one eye. It's even better.", systemImage: "eye")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 13.5))
    }

    private var screen: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your whole screen, too")
                .font(.system(size: 26, weight: .bold))
            Text("Turn on Screen Effect and everything on your screen gets the Duo effect as you tilt. It settles back when you stop.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("It needs Screen Recording permission. Nothing is recorded, and nothing leaves your Mac.")
                .font(.system(size: 12.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            ScreenPermissionView()
                .padding(.top, 4)
        }
        .font(.system(size: 13.5))
    }

    private var fitStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Tune it to you")
                .font(.system(size: 26, weight: .bold))
            Text("The effect is drawn for where your eyes are.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 8) {
                OptionRow(symbol: "camera", title: "Calibrate with Camera", badge: "Recommended",
                          detail: "Takes about 10 seconds.",
                          isSelected: fit == .camera) { fit = .camera }
                OptionRow(symbol: "hand.draw", title: "Calibrate by Eye",
                          detail: "Line up a target at two angles.",
                          isSelected: fit == .lineUp) { fit = .lineUp }
                OptionRow(symbol: "person.fill", title: "Skip for Now",
                          detail: "Use a typical viewing position.",
                          isSelected: fit == .typical) { fit = .typical }
            }
            .padding(.top, 2)
        }
        .font(.system(size: 13.5))
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("You're all set")
                .font(.system(size: 26, weight: .bold))
            VStack(alignment: .leading, spacing: 12) {
                ShortcutRow(keys: "⌥⌘S", text: "Screen Effect, from any app")
                ShortcutRow(symbol: "menubar.rectangle", text: "MacBook Duo lives in the menu bar")
                ShortcutRow(keys: "X", text: "All controls")
                ShortcutRow(keys: "R", text: "Re-center the picture")
            }
            Toggle("Open at login", isOn: Binding(
                get: { launchesAtLogin },
                set: { launchesAtLogin = LaunchAtLogin.set($0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .padding(.top, 6)
        }
        .font(.system(size: 13.5))
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            if step != .welcome {
                Button("Back") { go(-1) }
                    .buttonStyle(.secondary)
            }
            Spacer()
            if step == .screen, !ScreenRecordingPermission.shared.isGranted {
                // Allowing it is the step's own button; this only moves on without it.
                Button("Not Now") { go(1) }
                    .buttonStyle(.secondary)
                    .keyboardShortcut(.defaultAction)
            } else {
                nextButton
            }
        }
    }

    private var nextButton: some View {
        Button(nextTitle) {
            if step == .ready {
                let request: AppState.Request? = switch fit {
                case .typical: nil
                case .lineUp: .lineUp
                case .camera: .camera
                }
                step = .welcome
                finish(request)
            } else {
                go(1)
            }
        }
        .buttonStyle(.primary)
        .keyboardShortcut(.defaultAction)
    }

    private var nextTitle: String {
        switch step {
        case .ready: fit == .typical ? "Get Started" : "Calibrate"
        default: "Continue"
        }
    }

    private func go(_ by: Int) {
        guard let next = Step(rawValue: step.rawValue + by) else { return }
        withAnimation(.easeInOut(duration: 0.25)) { step = next }
    }
}

/// Says whether the lid has been moved yet, and cheers when it has: the one thing to try first.
private struct TiltCheck: View {
    private let sensor = LidSensor.shared
    @State private var start: Double?
    @State private var angle: Double?
    @State private var moved = false

    var body: some View {
        HStack(spacing: 12) {
            LidGlyph(sensor: sensor)
                .frame(width: LidGlyph.size.width, height: LidGlyph.size.height)
            VStack(alignment: .leading, spacing: 2) {
                Text(moved ? "That's the Duo effect." : "Tilt your screen")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(moved ? Color.duo : .primary)
                Text(angle.map { "Lid at " + $0.formatted(.number.precision(.fractionLength(0))) + "°" } ?? " ")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if moved {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.duo)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color.white.opacity(0.045), in: .rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.06)))
        // Read ten times a second rather than in body, so the page isn't redrawn every frame.
        .task {
            while !Task.isCancelled {
                let now = sensor.angle
                if start == nil { start = now }
                if angle.map({ abs($0 - now) >= 0.5 }) ?? true { angle = now }
                if !moved, let start, abs(now - start) >= 8 {
                    withAnimation(.spring(duration: 0.4)) { moved = true }
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}

/// "Live" over the demo, with the lid's little side view, so it's clear the picture answers the lid.
private struct LiveChip: View {
    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.duo)
                .frame(width: 7, height: 7)
            Text("Live")
                .font(.system(size: 12, weight: .medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color(white: 0.1).opacity(0.95), in: .capsule)
        .overlay(Capsule().strokeBorder(.white.opacity(0.1)))
    }
}

/// One thing to remember, with its key or symbol.
private struct ShortcutRow: View {
    var keys: String? = nil
    var symbol: String? = nil
    var text: String

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let keys {
                    KeyCap(keys: keys)
                } else if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 15))
                        .foregroundStyle(Color.duo)
                }
            }
            .frame(width: 54, alignment: .leading)
            Text(text)
        }
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
