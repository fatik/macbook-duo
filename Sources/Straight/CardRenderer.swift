import AppKit
import Metal
import QuartzCore
import SwiftUI

/// One picture drawn on the card: its blurred copies, where it sits, and how it mixes with the
/// layers behind it.
struct CardLayer {
    var atlas: BlurAtlas
    /// Where the picture sits on the card, in fractions of the card's size.
    var rect: CGRect
    /// How strongly it blurs where the blur is full.
    var blur: Double
    var opacity: Double = 1
    var blend: ClockBlend = .normal

    /// Where a picture of `aspect` goes to fill a card of `cardAspect`, its middle cropped to fit.
    static func filling(aspect: Double, cardAspect: Double) -> CGRect {
        if aspect > cardAspect {
            let shown = cardAspect / aspect
            return CGRect(x: -(1 - shown) / 2 / shown, y: 0, width: 1 / shown, height: 1)
        }
        let shown = aspect / cardAspect
        return CGRect(x: 0, y: -(1 - shown) / 2 / shown, width: 1, height: 1 / shown)
    }
}

/// Everything the shader needs for one frame, packed in the order `CardScene.metal` reads it.
struct CardFrame {
    var values: [Float]
    var textures: [MTLTexture]

    static let maxLayers = 6

    /// `toWindow` takes a card position (0 to 1 across it) to the window, in points.
    init?(toWindow: ProjectionTransform, windowSize: CGSize, cardSize: CGSize, cornerRadius: Double,
          blurStrength: Double, blur: EffectShape, dimStrength: Double, dim: EffectShape,
          background: RGBColor, layers: [CardLayer]) {
        guard var toCard = toWindow.inverted() else { return nil }
        // Keep the card's own side of its horizon positive.
        let middle = CGPoint(x: 0.5, y: 0.5).applying(toWindow)
        if middle.x * toCard.m13 + middle.y * toCard.m23 + toCard.m33 < 0 { toCard = toCard.negated() }

        let layers = layers.prefix(Self.maxLayers)
        var values = [Float](repeating: 0, count: 36)
        for (index, m) in [toCard.m11, toCard.m12, toCard.m13, toCard.m21, toCard.m22, toCard.m23,
                           toCard.m31, toCard.m32, toCard.m33].enumerated() {
            values[index] = Float(m)
        }
        values[9] = Float(windowSize.width)
        values[10] = Float(windowSize.height)
        values[11] = 1
        values[12] = Float(cardSize.width)
        values[13] = Float(cardSize.height)
        values[14] = Float(cornerRadius)
        values[15] = Float(blurStrength)

        func pack(_ shape: EffectShape, at slot: Int) {
            func setEdge(_ edge: EffectEdge, _ ramp: EffectRamp) {
                values[slot + 1] = Float(EffectEdge.allCases.firstIndex(of: edge) ?? 0)
                values[slot + 2] = Float(ramp.front)
                values[slot + 3] = Float(max(ramp.width, 0.0001))
            }
            switch shape {
            case .none:
                values[slot] = 0
            case .depth(let top, let bottom, let full, let side):
                values[slot] = 1
                values[16] = Float(top)
                values[17] = Float(bottom)
                values[slot + 4] = Float(max(full, 0.0001))
                values[slot + 5] = switch side {
                case .nearer: -1
                case .either: 0
                case .farther: 1
                }
            case .cardEdge(let edge, let ramp):
                values[slot] = 2
                setEdge(edge, ramp)
            case .windowEdge(let edge, let ramp):
                values[slot] = 3
                setEdge(edge, ramp)
            }
        }
        pack(blur, at: 18)
        pack(dim, at: 24)
        values[30] = Float(dimStrength)
        values[31] = Float(layers.count)
        values[32] = Float(background.red)
        values[33] = Float(background.green)
        values[34] = Float(background.blue)

        for layer in layers {
            var packed = [Float](repeating: 0, count: 48)
            let rect = layer.rect
            packed[0] = Float(1 / rect.width)
            packed[1] = Float(1 / rect.height)
            packed[2] = Float(-rect.minX / rect.width)
            packed[3] = Float(-rect.minY / rect.height)
            packed[4] = Float(layer.blur)
            packed[5] = Float(layer.opacity)
            packed[6] = Float(ClockBlend.allCases.firstIndex(of: layer.blend) ?? 0)
            packed[7] = Float(BlurAtlas.levels)
            packed[8] = Float(layer.atlas.pixelSize.width)
            packed[9] = Float(layer.atlas.pixelSize.height)
            for (index, tile) in layer.atlas.tiles.prefix(BlurAtlas.levels + 1).enumerated() {
                packed.replaceSubrange(10 + index * 4 ..< 14 + index * 4,
                                       with: [Float(tile.minX), Float(tile.minY), Float(tile.width), Float(tile.height)])
            }
            values += packed
        }
        self.values = values
        textures = layers.map(\.atlas.texture)
    }

    func isSame(as other: CardFrame?) -> Bool {
        guard let other, values == other.values, textures.count == other.textures.count else { return false }
        return zip(textures, other.textures).allSatisfy { $0 === $1 }
    }
}

extension ProjectionTransform {
    func inverted() -> ProjectionTransform? {
        let determinant = m11 * (m22 * m33 - m23 * m32) - m12 * (m21 * m33 - m23 * m31) + m13 * (m21 * m32 - m22 * m31)
        guard abs(determinant) > 1e-12 else { return nil }
        var inverse = ProjectionTransform()
        inverse.m11 = (m22 * m33 - m23 * m32) / determinant
        inverse.m12 = (m13 * m32 - m12 * m33) / determinant
        inverse.m13 = (m12 * m23 - m13 * m22) / determinant
        inverse.m21 = (m23 * m31 - m21 * m33) / determinant
        inverse.m22 = (m11 * m33 - m13 * m31) / determinant
        inverse.m23 = (m13 * m21 - m11 * m23) / determinant
        inverse.m31 = (m21 * m32 - m22 * m31) / determinant
        inverse.m32 = (m12 * m31 - m11 * m32) / determinant
        inverse.m33 = (m11 * m22 - m12 * m21) / determinant
        return inverse
    }

    /// The same projection with every entry negated, which leaves the points it maps unchanged.
    func negated() -> ProjectionTransform {
        var negated = ProjectionTransform()
        negated.m11 = -m11; negated.m12 = -m12; negated.m13 = -m13
        negated.m21 = -m21; negated.m22 = -m22; negated.m23 = -m23
        negated.m31 = -m31; negated.m32 = -m32; negated.m33 = -m33
        return negated
    }
}

extension CGPoint {
    /// This point, in a row vector, through a projection.
    func applying(_ t: ProjectionTransform) -> CGPoint {
        let w = x * t.m13 + y * t.m23 + t.m33
        return CGPoint(x: (x * t.m11 + y * t.m21 + t.m31) / w, y: (x * t.m12 + y * t.m22 + t.m32) / w)
    }
}

/// Draws the card with Metal, on every screen refresh while something changes: `scene` worked out
/// for the lid's current angle. Drawing skips SwiftUI entirely, so moving the lid doesn't rebuild
/// any views.
struct CardRendererView: NSViewRepresentable {
    var scene: CardScene
    var sensor: LidSensor

    func makeNSView(context: Context) -> CardMetalView {
        let view = CardMetalView()
        view.sensor = sensor
        view.scene = scene
        return view
    }

    func updateNSView(_ view: CardMetalView, context: Context) {
        view.sensor = sensor
        view.scene = scene
    }
}

final class CardMetalView: NSView {
    var scene: CardScene?
    var sensor: LidSensor?

    private var link: CADisplayLink?
    private var drawn: CardFrame?
    /// The background drawn with no card, or nil if the card was drawn.
    private var drewOnly: RGBColor?
    private var drawnSize: CGSize = .zero
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    private static let queue = GPU.device.makeCommandQueue()
    private static let pipeline: MTLRenderPipelineState? = {
        guard let library = try? GPU.device.makeDefaultLibrary(bundle: .main) else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "cardVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "cardFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        return try? GPU.device.makeRenderPipelineState(descriptor: descriptor)
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func makeBackingLayer() -> CALayer {
        let layer = CAMetalLayer()
        layer.device = GPU.device
        layer.pixelFormat = .bgra8Unorm
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.isOpaque = true
        layer.framebufferOnly = true
        return layer
    }

    override var isOpaque: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The display link holds on to its target, so it only runs while the view is in a window.
        link?.invalidate()
        link = nil
        guard window != nil else { return }
        let link = displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let sensor, let scene, let window, window.occlusionState.contains(.visible) else { return }
        sensor.advance(to: link.timestamp)

        let scale = window.backingScaleFactor
        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        guard size.width >= 1, size.height >= 1 else { return }
        var frame = scene.frame(lidAngle: sensor.angle)
        frame?.values[11] = Float(scale)

        // Nothing to do while nothing moves.
        if size == drawnSize, frame == nil ? drewOnly == scene.background : frame!.isSame(as: drawn) { return }
        if metalLayer.drawableSize != size {
            metalLayer.drawableSize = size
            metalLayer.contentsScale = scale
        }
        guard draw(frame, background: scene.background) else { return }
        drawn = frame
        drewOnly = frame == nil ? scene.background : nil
        drawnSize = size
    }

    private func draw(_ frame: CardFrame?, background: RGBColor) -> Bool {
        guard let drawable = metalLayer.nextDrawable(), let commands = Self.queue?.makeCommandBuffer() else { return false }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: background.red, green: background.green,
                                                            blue: background.blue, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return false }
        if let frame, let pipeline = Self.pipeline, let first = frame.textures.first {
            encoder.setRenderPipelineState(pipeline)
            frame.values.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
            // Every slot gets a texture, even ones past the layers in use.
            let textures = frame.textures + Array(repeating: first, count: CardFrame.maxLayers - frame.textures.count)
            encoder.setFragmentTextures(textures, range: 0..<CardFrame.maxLayers)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
        return true
    }
}
