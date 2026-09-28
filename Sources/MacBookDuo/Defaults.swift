import Foundation

/// The settings everyone starts with, chosen so the first launch already looks its best: the desert
/// at dusk filling the window, a blur that comes in from the top as soon as the lid moves,
/// and a viewpoint worked out from the screen, so nothing needs setting up first.
///
/// They're registered rather than written, so a setting nobody has changed keeps following them, and
/// every view that stores the same key agrees on its default.
enum Defaults {
    static let onboardingCompleted = "onboardingCompleted"
    static let showsInDock = "showsInDock"
    /// Whether ⌥⌘S holds the screen still from any app.
    static let globalShortcut = "globalShortcut"
    /// Seconds the lid stays still before a held screen eases back.
    static let holdSettleTime = "holdSettleTime"
    /// Whether the lid's motion is predicted rather than eased (see `LidSensor.predictsMotion`).
    static let predictsMotion = "predictsMotion"
    /// How long the lid sensor takes to report an angle, in milliseconds (see `AnglePredictor.lead`).
    static let motionLead = "motionLead"
    /// This Mac's hinge geometry, in millimeters, when someone has measured it better than the table.
    static let hingeToDisplayOverride = "hingeToDisplayOverride"
    static let glassBehindHingeOverride = "glassBehindHingeOverride"
    /// How far above square-on a viewer at a desk looks at the screen from, in degrees.
    static let typicalLookingDown = 10.0

    static func register() {
        UserDefaults.standard.register(defaults: [
            onboardingCompleted: false,
            showsInDock: true,
            globalShortcut: true,
            holdSettleTime: 0.5,
            predictsMotion: false,
            motionLead: 30.0,

            "scene": "desert",
            "cardSize": 0.55,
            "fillsWindow": true,
            "backgroundColor": 0x000000,
            "cornerRadius": LidGeometry.current.cornerRadius,
            "parallax": 0.6,
            "parallaxDirection": LidDirection.either.rawValue,
            "parallaxMotion": ParallaxMotion.toward.rawValue,

            // Until calibrated, the eye is where it usually is: square-on to the screen as it was set,
            // looking down at it a little, as from a desk.
            "viewpoint": Viewpoint.screen.rawValue,
            "viewDistance": 0.0,
            "viewLookingDown": typicalLookingDown,
            "eyeDistance": 55.0,
            "eyeHeight": 35.0,

            "blurStrength": 0.35,
            "blurSpread": 1.0,
            "blurEdge": EffectEdge.top.rawValue,
            "blurLidReaction": 1.0,
            "blurLidDirection": LidDirection.either.rawValue,
            "blurDepthSide": DepthSide.farther.rawValue,
            "dimStrength": 0.0,
            "dimSpread": 0.5,
            "dimEdge": EffectEdge.top.rawValue,
            "dimLidReaction": 1.0,
            "dimLidDirection": LidDirection.either.rawValue,
            "dimDepthSide": DepthSide.farther.rawValue,
        ])
    }

    /// Keeps a calibration made in Straight, this app's name before it was MacBook Duo, the first time
    /// MacBook Duo runs: where the viewer's eyes are is the one thing worth carrying over.
    static func migrateFromStraight() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "migratedFromStraight") == nil else { return }
        defaults.set(true, forKey: "migratedFromStraight")
        let old = "local.lid.straight" as CFString
        for key in ["viewpoint", "eyeDistance", "eyeHeight"] where defaults.object(forKey: key) == nil {
            if let value = CFPreferencesCopyAppValue(key as CFString, old) {
                defaults.set(value, forKey: key)
            }
        }
    }

    /// Everything back to how it came, calibration included; the welcome is shown again.
    static func resetAll() {
        guard let domain = Bundle.main.bundleIdentifier else { return }
        UserDefaults.standard.removePersistentDomain(forName: domain)
        UserDefaults.standard.set(true, forKey: "migratedFromStraight")
    }
}
