import SwiftUI

/// A color in OKLab, a perceptual space where blending two colors looks even
/// instead of passing through the muddy midpoints plain RGB mixing gives.
struct OKLab {
    var l: Double, a: Double, b: Double

    init(l: Double, a: Double, b: Double) {
        self.l = l; self.a = a; self.b = b
    }

    init(hex: UInt32) {
        func linear(_ c: UInt32) -> Double {
            let v = Double(c & 0xFF) / 255
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let r = linear(hex >> 16), g = linear(hex >> 8), bl = linear(hex)
        let lc = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * bl)
        let mc = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * bl)
        let sc = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * bl)
        l = 0.2104542553 * lc + 0.7936177850 * mc - 0.0040720468 * sc
        a = 1.9779984951 * lc - 2.4285922050 * mc + 0.4505937099 * sc
        b = 0.0259040371 * lc + 0.7827717662 * mc - 0.8086757660 * sc
    }

    static func lch(l: Double, c: Double, h: Double) -> OKLab {
        let rad = h * .pi / 180
        return OKLab(l: l, a: c * cos(rad), b: c * sin(rad))
    }

    var chroma: Double { (a * a + b * b).squareRoot() }
    var hue: Double { atan2(b, a) * 180 / .pi }

    func mix(_ other: OKLab, _ t: Double) -> OKLab {
        OKLab(l: l + (other.l - l) * t, a: a + (other.a - a) * t, b: b + (other.b - b) * t)
    }

    var color: Color {
        let lc = pow(l + 0.3963377774 * a + 0.2158037573 * b, 3)
        let mc = pow(l - 0.1055613458 * a - 0.0638541728 * b, 3)
        let sc = pow(l - 0.0894841775 * a - 1.2914855480 * b, 3)
        func encode(_ v: Double) -> Double {
            let c = min(max(v, 0), 1)
            return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
        }
        return Color(.sRGB,
                     red: encode(4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc),
                     green: encode(-1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc),
                     blue: encode(-0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc))
    }

    var isLight: Bool { l > 0.68 }

    /// A text color that reads on this background, tinted with its hue.
    var foreground: OKLab {
        .lch(l: isLight ? 0.24 : 0.98, c: min(chroma, isLight ? 0.06 : 0.02), h: hue)
    }
}

enum Palette: String, CaseIterable {
    case dawn, spectrum

    /// Most MacBooks open to roughly 135°; beyond that the palette holds its last color.
    static let fullyOpen = 135.0

    var name: String {
        switch self {
        case .dawn: "Dawn"
        case .spectrum: "Spectrum"
        }
    }

    var next: Palette {
        let all = Palette.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    func color(at angle: Double) -> OKLab {
        let t = min(max(angle / Self.fullyOpen, 0), 1)
        switch self {
        case .dawn:
            // Night when closed, sunrise as it opens, full sun when wide open.
            let stops = Self.dawnStops
            guard let upper = stops.firstIndex(where: { $0.at >= t }), upper > 0 else { return stops[0].color }
            let lo = stops[upper - 1], hi = stops[upper]
            return lo.color.mix(hi.color, (t - lo.at) / (hi.at - lo.at))
        case .spectrum:
            // Sweep 300° of hue so closed and open never land on the same color.
            return .lch(l: 0.74, c: 0.13, h: 20 + t * 300)
        }
    }

    private static let dawnStops: [(at: Double, color: OKLab)] = [
        (0.00, OKLab(hex: 0x070A1A)),
        (0.19, OKLab(hex: 0x1B1B4D)),
        (0.37, OKLab(hex: 0x4B2A7B)),
        (0.56, OKLab(hex: 0xA03D83)),
        (0.70, OKLab(hex: 0xE85D5D)),
        (0.83, OKLab(hex: 0xFF9446)),
        (0.93, OKLab(hex: 0xFFC75A)),
        (1.00, OKLab(hex: 0xFFE9A8)),
    ]
}
