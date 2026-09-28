import SwiftUI
import simd

/// How the card is set up, everything but the lid angle, so each frame can be worked out from the
/// angle alone, away from SwiftUI.
struct CardScene {
    var placement: ScreenPlacement
    /// The window's size in points.
    var windowSize: CGSize
    var cardSize: CGSize
    /// The lid angle the card was put in place at, or nil to use the current one.
    var anchorAngle: Double?
    var viewpoint: Viewpoint
    var eyeDistance: Double
    var eyeHeight: Double
    /// 0 means the default for the screen.
    var viewDistance: Double
    var lookingDown: Double
    var fillsWindow: Bool
    /// The card's corner radius in millimeters.
    var cornerRadius: Double
    /// The color around the card.
    var background: RGBColor
    /// A nudge while lining the card up by eye.
    var adjustment: CardAdjustment? = nil
    var blur: Effect
    var dim: Effect
    var content: Content

    enum Content {
        case nothing
        /// A single picture; `crops` trims its middle to the card's shape.
        case picture(PictureTexture, crops: Bool)
        /// The screen itself, as it looks right now.
        case live(ScreenMirror)
        /// A layered scene, with its layers' textures in the same order.
        case layers(ParallaxScene, [PictureTexture], clock: Clock?, parallax: Parallax)
    }

    /// The date and time drawn between a scene's layers.
    struct Clock {
        var atlas: PictureTexture
        /// How much it comes closer with the parallax, from 0 (stays put) to 1 (like the nearest layer).
        var depth: Double
        var blur: Double
        var opacity: Double
        var blend: ClockBlend
    }

    /// Where the card is laid out, in display points.
    var cardFrame: CGRect {
        CGRect(x: placement.frame.minX + (windowSize.width - cardSize.width) / 2,
               y: placement.frame.minY + (windowSize.height - cardSize.height) / 2,
               width: cardSize.width, height: cardSize.height)
    }

    /// The laptop and the viewer at this lid angle, and the angle the card was anchored at.
    func rig(lidAngle: Double) -> (rig: Rig, anchor: Double) {
        let anchor = anchorAngle ?? lidAngle
        let eye = viewpoint == .screen
            ? Rig.screenViewpoint(anchorAngle: anchor, placement: placement,
                                  distance: viewDistance > 0 ? viewDistance : Rig.defaultViewingDistance(for: placement),
                                  lookingDown: lookingDown)
            : (distance: eyeDistance, height: eyeHeight)
        var modelled = lidAngle
        var eyeHeight = eye.height
        if let adjustment {
            // Leaning the card back is drawing it for a lid a little further closed. Drawing it from a
            // little higher up moves it up when the lid is closed past where it started, and down when
            // it's opened past, so the lift works either way.
            modelled -= adjustment.lean
            eyeHeight += adjustment.lift * (lidAngle < anchor ? 1 : -1)
        }
        let rig = Rig(lidAngle: modelled, eyeDistance: eye.distance, eyeHeight: eyeHeight, placement: placement)
        return (rig, anchor)
    }

    func pose(lidAngle: Double) -> CardPose? {
        let (rig, anchor) = rig(lidAngle: lidAngle)
        return pose(rig, anchor: anchor)
    }

    private func pose(_ rig: Rig, anchor: Double) -> CardPose? {
        rig.cardPose(frame: cardFrame, anchorAngle: anchor)
    }

    /// What to draw at this lid angle, or nil for nothing: the lid too far closed to draw the card
    /// sensibly, or its pictures not ready yet.
    func frame(lidAngle: Double) -> CardFrame? {
        let (rig, anchor) = rig(lidAngle: lidAngle)
        guard let pose = pose(rig, anchor: anchor)
        else { return nil }
        let corners = pose.corners.map { CGPoint(x: $0.x - placement.frame.minX, y: $0.y - placement.frame.minY) }
        guard let toWindow = ProjectionTransform(mapping: CGSize(width: 1, height: 1), to: corners) else { return nil }

        let cardAspect = cardSize.width / cardSize.height
        var layers: [CardLayer] = []
        // A live screen's frames can come in the same texture, so each one is told apart by its count.
        var liveFrame: Int?
        switch content {
        case .nothing:
            return nil
        case .live(let mirror):
            guard let latest = mirror.latest else { return nil }
            layers = [CardLayer(atlas: latest.picture, rect: CGRect(x: 0, y: 0, width: 1, height: 1), blur: blur.strength)]
            liveFrame = latest.count
        case .picture(let atlas, let crops):
            let rect = crops ? CardLayer.filling(aspect: atlas.aspect, cardAspect: cardAspect)
                             : CGRect(x: 0, y: 0, width: 1, height: 1)
            layers = [CardLayer(atlas: atlas, rect: rect, blur: blur.strength)]
        case .layers(let scene, let atlases, let clock, let parallax):
            guard atlases.count == scene.layers.count else { return nil }
            // The layers move toward you, or away, as the lid moves from where the card was
            // anchored, the nearest fastest.
            let closer = parallax.closer(anchor: anchor, lidAngle: rig.lidAngle)
            for (index, layer) in scene.layers.enumerated() {
                if index == scene.clockBefore, let clock {
                    let rect = ParallaxScene.grown(CGRect(x: 0, y: 0, width: 1, height: 1), by: closer * clock.depth)
                    layers.append(CardLayer(atlas: clock.atlas, rect: rect, blur: clock.blur,
                                            opacity: clock.opacity, blend: clock.blend))
                }
                layers.append(CardLayer(atlas: atlases[index],
                                        rect: ParallaxScene.rect(for: layer, cardAspect: cardAspect, closer: closer),
                                        blur: blur.strength))
            }
        }

        // Filling the window, the card's edges move off-screen as the lid moves one way and into the
        // window the other, so edge fades come in from the edges of whatever part of it is in view.
        // Depth effects are measured at the distance the screen's middle was from the eye when the
        // card was anchored.
        var anchorRig = rig
        anchorRig.lidAngle = anchor
        let middle = anchorRig.world(fromDisplay: CGPoint(x: placement.frame.minX + windowSize.width / 2,
                                                          y: placement.frame.minY + windowSize.height / 2))
        // Measured from the point on the glass nearest the hinge's axis, so the plane in focus runs
        // through where the positions start.
        let onGlass = -Rig.glassBehindHinge * pose.focusNormal
        let focus = FocusGeometry(eye: rig.eye - onGlass, corner: pose.world[0] - onGlass,
                                  across: pose.world[1] - pose.world[0], down: pose.world[3] - pose.world[0],
                                  focusNormal: pose.focusNormal, reference: simd_length(middle - rig.eye))
        var frame = CardFrame(toWindow: toWindow, windowSize: windowSize, cardSize: cardSize,
                              cornerRadius: cornerRadius / 10 / placement.cmPerPoint,
                              blurStrength: blur.strength,
                              blur: blur.shape(lidAngle: lidAngle, anchorAngle: anchor, fromPartInView: fillsWindow),
                              dimStrength: dim.strength,
                              dim: dim.shape(lidAngle: lidAngle, anchorAngle: anchor, fromPartInView: fillsWindow),
                              focus: focus, background: background, layers: layers)
        if let liveFrame {
            frame?.values[16] = Float(liveFrame % 1_000_000)
            // Drawn back exactly over itself, the screen's edges must cover the edge pixels fully.
            frame?.values[17] = 1
        }
        return frame
    }

    /// A few words on where the card is at this lid angle.
    func summary(lidAngle: Double) -> String {
        guard placement.isBuiltIn else { return "Move to the built-in display" }
        let (rig, anchor) = rig(lidAngle: lidAngle)
        if adjustment != nil { return "Lining up · moved \(Int(abs(lidAngle - anchor).rounded()))°" }
        guard let pose = pose(rig, anchor: anchor)
        else { return "Too far closed to draw" }
        let held = "Held at \(Int(anchor.rounded()))°"
        guard pose.boundingBox.intersects(placement.frame) else { return "\(held) · out of view" }
        let lean = rig.lean(of: pose.up)
        let tilt = abs(lean) < 0.5 ? "in line" : "\(Int(abs(lean).rounded()))° \(lean > 0 ? "back" : "forward")"
        return "\(held) · \(tilt)"
    }
}

/// A color as sRGB components from 0 to 1, stored in settings as 0xRRGGBB.
struct RGBColor: Equatable {
    var red: Double
    var green: Double
    var blue: Double

    init(hex: Int) {
        red = Double(hex >> 16 & 0xFF) / 255
        green = Double(hex >> 8 & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
    }

    /// The nearest sRGB color to `color`.
    init(_ color: Color) {
        let srgb = NSColor(color).usingColorSpace(.sRGB)
        red = Double(srgb?.redComponent ?? 0)
        green = Double(srgb?.greenComponent ?? 0)
        blue = Double(srgb?.blueComponent ?? 0)
    }

    var hex: Int {
        func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return byte(red) << 16 | byte(green) << 8 | byte(blue)
    }

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }
}

/// The lid angle, large, beside a little side view of the lid, with a line under it on where the
/// card is and the frame rate, and `accessory` on the right. It reads the lid ten times a second on
/// its own, rather than in `body`, so neither it nor the rest of the panel is redrawn every frame.
struct LiveReadout<Accessory: View>: View {
    var scene: CardScene
    var sensor: LidSensor
    @ViewBuilder var accessory: Accessory

    /// The angle last shown.
    @State private var lidAngle: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                LidGlyph(sensor: sensor)
                    .frame(width: LidGlyph.size.width, height: LidGlyph.size.height)
                Text(lidAngle.map { $0.formatted(.number.precision(.fractionLength(1))) + "°" } ?? "–")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .help("The lid's angle")
                Spacer(minLength: 4)
                accessory
            }
            Text(caption)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .task {
            while !Task.isCancelled {
                let angle = sensor.angle
                if lidAngle.map({ abs($0 - angle) >= 0.05 }) ?? true { lidAngle = angle }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private var caption: String {
        guard let lidAngle else { return " " }
        return scene.summary(lidAngle: lidAngle) + (sensor.framesPerSecond.map { " · \($0) fps" } ?? "")
    }
}
