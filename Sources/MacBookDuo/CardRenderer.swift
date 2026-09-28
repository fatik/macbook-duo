import AppKit
import Metal
import MetalPerformanceShaders
import QuartzCore
import SwiftUI

/// One picture drawn on the card, over the layers behind it: its texture and where it sits.
struct CardLayer {
    var atlas: PictureTexture
    /// Where the picture sits on the card, in fractions of the card's size.
    var rect: CGRect

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

/// Where the eye is and what it's focused on, for working out how out of focus each part of the card
/// is: all in the world, in centimeters, measured from a point on the screen's glass.
struct FocusGeometry {
    var eye: SIMD3<Double>
    /// The card's top-left corner, and the way to its top-right and bottom-left corners.
    var corner: SIMD3<Double>
    var across: SIMD3<Double>
    var down: SIMD3<Double>
    /// The plane the eye is focused on, the glass, runs through that point, facing this way.
    var focusNormal: SIMD3<Double>
    /// The viewing distance the depth effects' "full at" distances are measured at.
    var reference: Double
}

/// Everything the shader needs for one frame, packed in the order `CardScene.metal` reads it.
struct CardFrame {
    var values: [Float]
    var textures: [MTLTexture]

    static let maxLayers = 6

    /// `toWindow` takes a card position (0 to 1 across it) to the window, in points.
    init?(toWindow: ProjectionTransform, windowSize: CGSize, cardSize: CGSize, cornerRadius: Double,
          blurStrength: Double, blur: EffectShape, dimStrength: Double, dim: EffectShape,
          focus: FocusGeometry, background: RGBColor, layers: [CardLayer]) {
        guard var toCard = toWindow.inverted() else { return nil }
        // Keep the card's own side of its horizon positive.
        let middle = CGPoint(x: 0.5, y: 0.5).applying(toWindow)
        if middle.x * toCard.m13 + middle.y * toCard.m23 + toCard.m33 < 0 { toCard = toCard.negated() }

        let layers = layers.prefix(Self.maxLayers)
        var values = [Float](repeating: 0, count: 52)
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
            case .depth(let full, let side):
                values[slot] = 1
                values[slot + 4] = Float(max(full, 0.0001))
                values[slot + 5] = switch side {
                case .nearer: -1
                case .either: 0
                case .farther: 1
                }
            case .cardEdge(let edge, let ramp):
                values[slot] = 2
                setEdge(edge, ramp)
            case .partInViewEdge(let edge, let ramp):
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
        for (index, v) in [focus.eye, focus.corner, focus.across, focus.down, focus.focusNormal].enumerated() {
            values[36 + index * 3] = Float(v.x)
            values[37 + index * 3] = Float(v.y)
            values[38 + index * 3] = Float(v.z)
        }
        values[51] = Float(focus.reference)

        for layer in layers {
            let rect = layer.rect, tile = layer.atlas.tiles[0]
            values += [Float(1 / rect.width), Float(1 / rect.height),
                       Float(-rect.minX / rect.width), Float(-rect.minY / rect.height),
                       Float(layer.atlas.pixelSize.width), Float(layer.atlas.pixelSize.height),
                       Float(tile.minX), Float(tile.minY), Float(tile.width), Float(tile.height)]
        }
        self.values = values
        textures = layers.map(\.atlas.texture)
    }

    /// Whether anything is blurred, so the picture of the screen needs its blurred copies. An edge
    /// fade that hasn't come in yet blurs nothing.
    var blurs: Bool { values[18] != 0 && values[15] > 0 && (values[18] < 2 || values[20] > 0) }

    /// The most any part of the card is blurred, as a share of the full blur.
    var strongestBlur: Double { Double(min(max(values[15], 0), 1)) }

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

    /// Whether what's behind the window shows through, rather than the background, while there's no
    /// card to draw.
    var seeThroughWhenEmpty = false {
        didSet { metalLayer.isOpaque = !seeThroughWhenEmpty }
    }
    /// The color space the drawn colors are in.
    var colorSpace: CGColorSpace? {
        get { metalLayer.colorspace }
        set { metalLayer.colorspace = newValue }
    }

    /// Whether it draws on its own display link while its window is visible. If not, its owner calls
    /// `update(at:)` on every screen refresh instead.
    private let drawsItself: Bool

    private static let queue = GPU.device.makeCommandQueue()
    private let scratch = CardPasses.Scratch()

    init(drawsItself: Bool = true) {
        self.drawsItself = drawsItself
        super.init(frame: .zero)
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

    override var isOpaque: Bool { !seeThroughWhenEmpty }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The display link holds on to its target, so it only runs while the view is in a window.
        link?.invalidate()
        link = nil
        guard window != nil, drawsItself else { return }
        let link = displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let window, window.occlusionState.contains(.visible) else { return }
        update(at: link.timestamp)
    }

    /// Draws the scene for the screen refresh at `timestamp`, if anything changed since it last drew.
    func update(at timestamp: CFTimeInterval) {
        guard let sensor, let scene, let window else { return }
        sensor.advance(to: timestamp)

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
        CardPasses.encode(frame, background: background, seeThrough: seeThroughWhenEmpty, into: drawable.texture,
                          commands: commands, scratch: scratch)
        commands.present(drawable)
        commands.commit()
        return true
    }
}

/// Draws a frame with the card's shaders into a texture: in one pass, or with blur by drawing the
/// screen's picture sharp, making progressively blurrier copies of it, and blending those.
enum CardPasses {
    /// How many blurred copies there are, each blurred by the full blur times (level / copies)^2.
    static let copies = 8

    private static let library = try? GPU.device.makeDefaultLibrary(bundle: .main)
    private static func pipeline(_ fragment: String, _ format: MTLPixelFormat) -> MTLRenderPipelineState? {
        guard let library else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "cardVertex")
        descriptor.fragmentFunction = library.makeFunction(name: fragment)
        descriptor.colorAttachments[0].pixelFormat = format
        return try? GPU.device.makeRenderPipelineState(descriptor: descriptor)
    }
    private static let direct = pipeline("cardFragment", .bgra8Unorm)
    private static let sharp = pipeline("cardFragment", .rgba16Float)
    private static let finish = pipeline("glassFinish", .bgra8Unorm)

    /// The screen's picture and its blurred copies, kept from frame to frame.
    final class Scratch {
        fileprivate var sharp: MTLTexture?
        fileprivate var copies: [MTLTexture] = []
        private var levels: [Int] = []
        fileprivate var blurs: [Int: MPSImageGaussianBlur] = [:]

        /// The sharp picture, `width` by `height` pixels, with mipmaps to shrink it from, and a texture
        /// for each blurred copy at the mipmap level it's made from.
        fileprivate func textures(width: Int, height: Int, levels: [Int]) -> (sharp: MTLTexture, copies: [MTLTexture])? {
            if let sharp, sharp.width == width, sharp.height == height, levels == self.levels {
                return (sharp, copies)
            }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width,
                                                                      height: height, mipmapped: true)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            guard let made = GPU.device.makeTexture(descriptor: descriptor) else { return nil }
            copies = levels.compactMap { level in
                let copy = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                                                                    width: max(width >> level, 1),
                                                                    height: max(height >> level, 1), mipmapped: false)
                copy.usage = [.shaderRead, .shaderWrite]
                copy.storageMode = .private
                return GPU.device.makeTexture(descriptor: copy)
            }
            sharp = made
            self.levels = levels
            guard copies.count == levels.count else { return nil }
            return (made, copies)
        }

        /// A Gaussian blur of `sigma` pixels, kept for reuse.
        fileprivate func blur(sigma: Double) -> MPSImageGaussianBlur {
            let key = Int((sigma * 100).rounded())
            if let known = blurs[key] { return known }
            let made = MPSImageGaussianBlur(device: GPU.device, sigma: Float(max(sigma, 0.01)))
            made.edgeMode = .clamp
            blurs[key] = made
            return made
        }
    }

    /// Draws `frame` into `target` (bgra8Unorm), or just the background without one: or nothing at
    /// all, clear, if it's `seeThrough`.
    static func encode(_ frame: CardFrame?, background: RGBColor, seeThrough: Bool = false, into target: MTLTexture,
                       commands: MTLCommandBuffer, scratch: Scratch) {
        func pass(into texture: MTLTexture, _ draw: (MTLRenderCommandEncoder) -> Void) {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: background.red, green: background.green,
                                                                blue: background.blue, alpha: seeThrough ? 0 : 1)
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }
            draw(encoder)
            encoder.endEncoding()
        }
        guard var frame, let first = frame.textures.first, let direct else {
            pass(into: target) { _ in }
            return
        }
        // Every slot gets a texture, even ones past the layers in use.
        let textures = frame.textures + Array(repeating: first, count: CardFrame.maxLayers - frame.textures.count)
        func drawCard(_ encoder: MTLRenderCommandEncoder, _ pipeline: MTLRenderPipelineState, margin: Int = 0) {
            encoder.setRenderPipelineState(pipeline)
            frame.values.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
            var offset = SIMD2<Float>(repeating: Float(margin))
            encoder.setFragmentBytes(&offset, length: MemoryLayout.size(ofValue: offset), index: 1)
            encoder.setFragmentTextures(textures, range: 0..<CardFrame.maxLayers)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }

        // The full blur is an eighth of the card's shorter side, in pixels. Each copy is made from the
        // picture shrunk as far as its blur still spans a few pixels, which blur hides anyway.
        let pixelsPerPoint = Double(frame.values[11])
        let full = Double(min(frame.values[12], frame.values[13])) / 8 * pixelsPerPoint
        let sigmas = (1...copies).map { full * pow(Double($0) / Double(copies), 2) }
        let levels = sigmas.map { sigma -> Int in
            let points = sigma / pixelsPerPoint
            return points < 2 ? 0 : points < 6 ? 1 : points < 12 ? 2 : 3
        }
        // Past the window's edges the blur needs what's really there: the card carrying on, or the
        // background around it. Blurring just the window would stretch its edge pixels outward, and
        // anything crossing an edge, like the checkerboard's white border, would flare into a band
        // that flashes as it passes. So the sharp picture runs past the window all round, by three
        // times the widest blur in use, beyond which nothing shows through; and it's a multiple of 8
        // each way, so every shrunk copy lines up with it exactly.
        func multipleOf8(_ n: Int) -> Int { (n + 7) / 8 * 8 }
        let margin = multipleOf8(Int((3 * full * frame.strongestBlur).rounded(.up)))
        guard frame.blurs, let sharp, let finish,
              let scratched = scratch.textures(width: multipleOf8(target.width + 2 * margin),
                                               height: multipleOf8(target.height + 2 * margin), levels: levels)
        else {
            frame.values[35] = 0
            pass(into: target) { drawCard($0, direct) }
            return
        }
        frame.values[35] = 1
        pass(into: scratched.sharp) { drawCard($0, sharp, margin: margin) }
        if let blit = commands.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: scratched.sharp)
            blit.endEncoding()
        }
        for (index, copy) in scratched.copies.enumerated() {
            let level = levels[index]
            guard let shrunk = scratched.sharp.makeTextureView(pixelFormat: .rgba16Float, textureType: .type2D,
                                                               levels: level..<level + 1, slices: 0..<1)
            else { continue }
            scratch.blur(sigma: sigmas[index] / Double(1 << level))
                .encode(commandBuffer: commands, sourceTexture: shrunk, destinationTexture: copy)
        }
        pass(into: target) { encoder in
            encoder.setRenderPipelineState(finish)
            var offset = SIMD2<Float>(repeating: Float(margin))
            encoder.setFragmentBytes(&offset, length: MemoryLayout.size(ofValue: offset), index: 0)
            encoder.setFragmentTexture(scratched.sharp, index: 0)
            encoder.setFragmentTextures(scratched.copies, range: 1..<1 + scratched.copies.count)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
    }
}
