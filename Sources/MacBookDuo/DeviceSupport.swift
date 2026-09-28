import AppKit
import IOKit.ps

/// What kind of Mac this is, as far as holding its screen still goes.
enum ThisMac {
    /// The model identifier, like "Mac16,12" for a 13-inch M4 MacBook Air.
    static let modelIdentifier: String = {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var bytes = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &bytes, &size, nil, 0)
        return String(cString: bytes)
    }()

    /// Whether it runs on a battery: only laptops do, so a Mac without one has no lid at all.
    static let hasBattery: Bool = {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }
        return sources.contains { source in
            let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
            return description?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }()

    /// The built-in display, or nil while the lid is closed with an external display in use.
    static var builtInScreen: NSScreen? {
        NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
                .map { CGDisplayIsBuiltin($0) != 0 } ?? false
        }
    }

    /// The built-in display's lit area in millimeters, as the display itself reports it.
    static var builtInDisplaySize: CGSize? {
        guard let id = builtInScreen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { return nil }
        return CGDisplayScreenSize(id)
    }
}

/// The shape of the lid around its display, which is what makes a picture held still come out right:
/// the display's glass turns around the hinge's axis, and how far it is from that axis sets how far
/// every point on it moves.
struct LidGeometry: Equatable {
    /// Distance up the lid from the hinge's axis to the bottom edge of the lit display area, in cm.
    var hingeToDisplay: Double
    /// How far the display's glass lies behind the hinge's axis, away from the viewer, in cm: the
    /// axis sits inside the back of the base, and the lid's lower end swings down behind it.
    var glassBehindHinge: Double
    /// The lit area's rounded top corners, in mm.
    var cornerRadius: Double
    /// Which MacBook these are for, and how sure they are.
    var family: String
    var isMeasured: Bool

    /// The geometry everything is drawn with: this Mac's, with any measured overrides applied.
    nonisolated(unsafe) static var current = LidGeometry.forThisMac()

    // Measured from Apple's dimension drawings and product images, to the lit pixels, which sit about
    // 0.8 mm under the glass: the 13-inch Air's to about a millimeter, the others to one or two.
    static let air13 = LidGeometry(hingeToDisplay: 1.66, glassBehindHinge: 0.40, cornerRadius: 4.1,
                                   family: "13-inch MacBook Air", isMeasured: true)
    static let air15 = LidGeometry(hingeToDisplay: 1.66, glassBehindHinge: 0.41, cornerRadius: 3.6,
                                   family: "15-inch MacBook Air", isMeasured: true)
    static let pro14 = LidGeometry(hingeToDisplay: 1.60, glassBehindHinge: 0.54, cornerRadius: 3.8,
                                   family: "14-inch MacBook Pro", isMeasured: true)
    static let pro16 = LidGeometry(hingeToDisplay: 1.62, glassBehindHinge: 0.56, cornerRadius: 3.7,
                                   family: "16-inch MacBook Pro", isMeasured: true)
    /// The 2019 16-inch Pro: its glass measured, its lit area's height on the lid estimated.
    static let pro16Intel = LidGeometry(hingeToDisplay: 1.62, glassBehindHinge: 0.49, cornerRadius: 0,
                                        family: "16-inch MacBook Pro (2019)", isMeasured: false)

    /// This Mac's geometry: by its model where it's known, else by the size of its display, else the
    /// 13-inch Air's, which every thin-lid MacBook is close to; then any overrides from Advanced.
    static func forThisMac() -> LidGeometry {
        var geometry = known(ThisMac.modelIdentifier, width: ThisMac.builtInDisplaySize.map { Double($0.width) }) ?? air13
        let defaults = UserDefaults.standard
        if let millimeters = defaults.object(forKey: Defaults.hingeToDisplayOverride) as? Double {
            geometry.hingeToDisplay = millimeters / 10
        }
        if let millimeters = defaults.object(forKey: Defaults.glassBehindHingeOverride) as? Double {
            geometry.glassBehindHinge = millimeters / 10
        }
        return geometry
    }

    /// Reads the overrides again after they change.
    static func reload() {
        current = forThisMac()
    }

    /// By model identifier, and the display's width in millimeters to tell the sizes apart: MacBooks
    /// with a lid sensor are MacBook Airs from 2022 or 14- and 16-inch MacBook Pros from 2021, and
    /// the 16-inch Pro from 2019.
    private static func known(_ model: String, width: Double?) -> LidGeometry? {
        if SupportedMacs.intel16.contains(model) { return pro16Intel }
        let isAir = SupportedMacs.airs.contains(model) || model.hasPrefix("MacBookAir")
        let isPro = SupportedMacs.pros.contains(model) || model.hasPrefix("MacBookPro")
        guard let width else { return isAir ? air13 : isPro ? pro14 : nil }
        switch (isAir, isPro) {
        case (true, _): return width < 310 ? air13 : air15
        case (_, true): return width < 325 ? pro14 : pro16
        // A model newer than this list: its display's width says which it's most like.
        default:
            switch width {
            case ..<296: return air13
            case ..<315: return pro14
            case ..<338: return air15
            default: return pro16
            }
        }
    }
}

/// Which Macs have a lid MacBook Duo can follow, by model identifier. Apple added the sensor with the
/// 16-inch MacBook Pro (2019), and every 14- and 16-inch MacBook Pro since 2021 and every MacBook Air
/// since the M2 has one; no 13-inch MacBook Pro, earlier Air, 12-inch MacBook, MacBook Neo or desktop
/// Mac does.
enum SupportedMacs {
    static let intel16: Set = ["MacBookPro16,1", "MacBookPro16,4"]
    static let pros: Set = [
        "MacBookPro18,1", "MacBookPro18,2", "MacBookPro18,3", "MacBookPro18,4",
        "Mac14,5", "Mac14,6", "Mac14,9", "Mac14,10",
        "Mac15,3", "Mac15,6", "Mac15,7", "Mac15,8", "Mac15,9", "Mac15,10", "Mac15,11",
        "Mac16,1", "Mac16,5", "Mac16,6", "Mac16,7", "Mac16,8",
        "Mac17,2", "Mac17,6", "Mac17,7", "Mac17,8", "Mac17,9",
    ]
    static let airs: Set = ["Mac14,2", "Mac14,15", "Mac15,12", "Mac15,13", "Mac16,12", "Mac16,13", "Mac17,3", "Mac17,4"]

    /// For anyone whose Mac doesn't have one.
    static let summary = "Works with MacBook Air (M2 and later), 14- and 16-inch MacBook Pro (2021 and later), and 16-inch MacBook Pro (2019)."
}
