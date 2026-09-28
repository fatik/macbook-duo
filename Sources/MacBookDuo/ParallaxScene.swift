import AppKit
import SwiftUI

/// A picture built from layers at different depths that come toward you at different speeds as the
/// lid moves, the way a layered lock-screen wallpaper does. The clock sits between the layers and
/// stays put.
struct ParallaxScene {
    struct Layer {
        var image: CGImage
        /// How near the layer is, from 0 (far away, barely moves) to 1 (nearest, moves the most).
        var depth: Double
        var placement: Placement
    }

    enum Placement {
        /// Covering the whole card.
        case fill
        /// Centered across `width` of the card's width (1 is exactly as wide), with its bottom edge
        /// `bottom` of the way down.
        case band(bottom: Double, width: Double)
    }

    var name: String
    /// Far to near.
    var layers: [Layer]
    /// The clock goes in front of the layers before this index and behind the rest.
    var clockBefore: Int

    /// The card's width over its height when showing a scene.
    static let aspect = 1.5
    /// Where layers grow from as they come closer, as a fraction of the card's height: the horizon.
    static let horizon = 0.45
    /// How much the nearest layer grows at full parallax, once the lid has moved 45°.
    static let closestZoom = 0.5

    /// The built-in desert: sky, mountains and sand, far to near.
    static func desert() -> ParallaxScene? {
        guard let folder = Bundle.main.resourceURL?.appending(path: "Scene"),
              let sky = loadCardImage(at: folder.appending(path: "sky.png")),
              let mountains = loadCardImage(at: folder.appending(path: "mountains.png")),
              let sand = loadCardImage(at: folder.appending(path: "sand.png"))
        else { return nil }
        return ParallaxScene(name: "desert", layers: [
            Layer(image: sky, depth: 0.12, placement: .fill),
            Layer(image: mountains, depth: 0.5, placement: .band(bottom: 0.8, width: 1.2)),
            Layer(image: sand, depth: 1, placement: .band(bottom: 1.08, width: 1)),
        ], clockBefore: 1)
    }

    /// Where `layer` sits on a card of `cardAspect`, in fractions of the card's size, grown by
    /// `closer` times its depth toward the horizon's middle.
    static func rect(for layer: Layer, cardAspect: Double, closer: Double) -> CGRect {
        var rect = CGRect(x: 0, y: 0, width: 1, height: 1)
        if case .band(let bottom, let width) = layer.placement {
            let height = width * cardAspect * Double(layer.image.height) / Double(layer.image.width)
            rect = CGRect(x: (1 - width) / 2, y: bottom - height, width: width, height: height)
        }
        return grown(rect, by: closer * layer.depth)
    }

    /// `rect` grown by `amount` (0 leaves it as it is) toward the horizon's middle, the way the
    /// scene's layers come closer.
    static func grown(_ rect: CGRect, by amount: Double) -> CGRect {
        let zoom = 1 + amount
        let focus = CGPoint(x: 0.5, y: horizon)
        return CGRect(x: focus.x + (rect.minX - focus.x) * zoom, y: focus.y + (rect.minY - focus.y) * zoom,
                      width: rect.width * zoom, height: rect.height * zoom)
    }
}

/// Which way a scene's layers move as the lid moves.
enum ParallaxMotion: String, CaseIterable {
    /// They come closer, from the picture as it is, the nearest fastest.
    case toward
    /// They start as close as they come and move back to the picture as it is, the nearest fastest.
    case away

    var label: String {
        switch self {
        case .toward: "Toward you"
        case .away: "Away from you"
        }
    }
}

/// How a scene's layers move with the lid.
struct Parallax {
    /// From 0 (they don't) to 1.
    var strength: Double
    /// Which lid movement moves them.
    var direction: LidDirection
    var motion: ParallaxMotion

    /// How much closer than normal the nearest layer is at this lid angle, for a card anchored at
    /// `anchor`; the others are closer by that times their depth.
    func closer(anchor: Double, lidAngle: Double) -> Double {
        let travel = direction.travel(from: anchor, to: lidAngle)
        // Moving away is moving closer played backward, so the layers never shrink past the card's
        // edges, where the pictures end.
        return strength * ParallaxScene.closestZoom * (motion == .toward ? travel : 1 - travel)
    }
}

/// How the clock is drawn, using SF Pro's variable axes.
struct ClockStyle: Equatable {
    /// SF Pro's weight axis, from 1 (hairline) to 1000 (black).
    var weight: Double
    /// SF Pro's width axis, from 30 (very compressed) to 150 (very expanded).
    var width: Double
    /// How much taller than normal the numerals are drawn.
    var stretch: Double

    /// Close to a phone's lock-screen clock: narrow, medium weight, at its natural height.
    static let phone = ClockStyle(weight: 480, width: 36, stretch: 1)
}

/// How the clock mixes with the picture behind it.
enum ClockBlend: String, CaseIterable {
    case normal, plusLighter, screen, softLight, overlay

    var label: String {
        switch self {
        case .normal: "Normal"
        case .plusLighter: "Plus Lighter"
        case .screen: "Screen"
        case .softLight: "Soft Light"
        case .overlay: "Overlay"
        }
    }

    var mode: BlendMode {
        switch self {
        case .normal: .normal
        case .plusLighter: .plusLighter
        case .screen: .screen
        case .softLight: .softLight
        case .overlay: .overlay
        }
    }
}

extension ParallaxScene {
    /// The date and time, lock-screen style, as a picture the card's size with a clear background,
    /// so it can sit between layers and dim with them.
    @MainActor
    static func renderClock(at date: Date, pixelSize: CGSize, style: ClockStyle) -> CGImage? {
        let renderer = ImageRenderer(content: ClockFace(date: date, style: style)
            .frame(width: pixelSize.width, height: pixelSize.height))
        renderer.scale = 1
        return renderer.cgImage
    }
}

/// The date just above the time, placed like a phone's lock screen on the frame it's given.
private struct ClockFace: View {
    var date: Date
    var style: ClockStyle

    /// Where the tops of the digits and of the date's letters sit, and how tall the digits are, as
    /// fractions of the frame's height.
    private static let timeTop = 0.12, dateTop = 0.068, digitHeight = 0.27, dateHeight = 0.026

    private static let dateText: DateFormatter = {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("EEE MMM d")
        return formatter
    }()

    private static let timeText: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm"
        return formatter
    }()

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            // Sized and placed by SF Pro's own measurements, so the digits and letters land exactly
            // where a lock screen puts them, whatever the width and weight.
            let timeFont = sfPro(size: 100, weight: style.weight, width: style.width)
            let timeSize = height * Self.digitHeight / (CTFontGetCapHeight(timeFont) / 100)
            let time = sfPro(size: timeSize, weight: style.weight, width: style.width)
            let dateFont = sfPro(size: 100, weight: 590, width: 100)
            let dateSize = height * Self.dateHeight / (CTFontGetCapHeight(dateFont) / 100)
            let dateLine = sfPro(size: dateSize, weight: 590, width: 100)

            ZStack(alignment: .top) {
                Text(Self.dateText.string(from: date).replacingOccurrences(of: ",", with: ""))
                    .font(Font(dateLine))
                    .foregroundStyle(.white.opacity(0.92))
                    .offset(y: height * Self.dateTop - (CTFontGetAscent(dateLine) - CTFontGetCapHeight(dateLine)))
                Text(Self.timeText.string(from: date))
                    .font(Font(time))
                    .monospacedDigit()
                    // Solid at the top, letting a little of the picture through toward the bottom.
                    .foregroundStyle(LinearGradient(colors: [.white, .white.opacity(0.78)],
                                                    startPoint: .top, endPoint: .bottom))
                    .scaleEffect(x: 1, y: style.stretch, anchor: .top)
                    .offset(y: height * Self.timeTop - (CTFontGetAscent(time) - CTFontGetCapHeight(time)))
            }
            .frame(width: geometry.size.width, height: height, alignment: .top)
        }
    }
}

/// The system font, SF Pro, at a point on its weight and width axes.
func sfPro(size: CGFloat, weight: Double, width: Double) -> CTFont {
    func tag(_ name: String) -> NSNumber {
        NSNumber(value: name.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
    }
    let base = NSFont.systemFont(ofSize: size) as CTFont
    let variations = [tag("wght"): NSNumber(value: weight), tag("wdth"): NSNumber(value: width),
                      tag("opsz"): NSNumber(value: min(max(Double(size), 17), 96))]
    let descriptor = CTFontDescriptorCreateCopyWithAttributes(
        CTFontCopyFontDescriptor(base), [kCTFontVariationAttribute: variations] as CFDictionary)
    return CTFontCreateWithFontDescriptor(descriptor, size, nil)
}

/// What the clock picture depends on, so it's only redrawn when this changes (and each minute).
struct ClockRequest: Equatable {
    var style: ClockStyle
    var longSide: Double
    var aspect: Double
}

/// What a scene's layers are made into, so their textures are only remade when this changes.
struct SceneAtlasRequest: Equatable {
    var scene: String
    var longSide: Double
    var aspect: Double
}
