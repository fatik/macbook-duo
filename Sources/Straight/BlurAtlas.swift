import CoreImage
import SwiftUI

/// A picture and progressively blurrier copies of it, packed into one texture so a single shader
/// pass (`CardBlur.metal`) can pick how blurred each pixel should be. Blurring happens once, when
/// the atlas is made; each frame only chooses between copies.
struct BlurAtlas {
    let image: Image
    let pixelSize: CGSize
    /// Where each copy sits, in pixels from the atlas's top-left: the sharp picture first, then
    /// copies blurred by an eighth of the picture's shorter side times `(level / levels)²`.
    let tiles: [CGRect]
    /// The picture's width over its height.
    let aspect: Double
    /// Which picture this was made from.
    let source: ObjectIdentifier

    static let levels = 8

    /// The GPU context the copies are blurred with; safe to share between threads.
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// Makes the atlas with the sharp copy no longer than `longSide` pixels, first trimming the
    /// picture's middle to `aspect` (width over height) if given, since nothing outside it is shown.
    /// The strongest blur is `blurPerWidth` of the picture's width, or an eighth of its shorter side
    /// if not given. Runs off the main thread.
    static func make(from source: CGImage, longSide: Double, aspect: Double? = nil,
                     blurPerWidth: Double? = nil) async -> BlurAtlas? {
        let packed = await Task.detached(priority: .userInitiated) {
            pack(source, longSide: longSide, aspect: aspect, blurPerWidth: blurPerWidth)
        }.value
        guard let packed else { return nil }
        return BlurAtlas(image: Image(decorative: packed.image, scale: 1),
                         pixelSize: CGSize(width: packed.image.width, height: packed.image.height),
                         tiles: packed.tiles,
                         aspect: packed.tiles[0].width / packed.tiles[0].height,
                         source: ObjectIdentifier(source))
    }

    private struct Packed: @unchecked Sendable {
        var image: CGImage
        var tiles: [CGRect]
    }

    private static func pack(_ source: CGImage, longSide: Double, aspect: Double?, blurPerWidth: Double?) -> Packed? {
        var original = CIImage(cgImage: source)
        if let aspect {
            let extent = original.extent
            let trimmed = extent.width / extent.height > aspect
                ? extent.insetBy(dx: (extent.width - extent.height * aspect) / 2, dy: 0)
                : extent.insetBy(dx: 0, dy: (extent.height - extent.width / aspect) / 2)
            original = original.cropped(to: trimmed.integral)
        }
        let scale = min(1, longSide / max(original.extent.width, original.extent.height))
        let sharp = wholePixels(resize(original, by: scale))
        let maxBlur = blurPerWidth.map { sharp.extent.width * $0 } ?? min(sharp.extent.width, sharp.extent.height) / 8

        // Blurrier copies can be much smaller: blur hides the missing detail, as long as it still
        // spans a few pixels at the smaller size. Each is blurred with its edges extended outward,
        // so its borders stay solid; the shader softens the card's outline itself.
        var copies = [sharp]
        for level in 1...levels {
            let radius = maxBlur * pow(Double(level) / Double(levels), 2)
            let shrink = min(0.5, max(1.0 / 8, 3 / radius))
            let small = wholePixels(resize(sharp, by: shrink))
            copies.append(small.clampedToExtent().applyingGaussianBlur(sigma: radius * shrink).cropped(to: small.extent))
        }

        // The sharp copy on top, the blurred ones in a row beneath, with gaps so filtering never
        // bleeds between them.
        let gap = 4.0
        var tiles = [CGRect(origin: .zero, size: copies[0].extent.size)]
        var x = 0.0
        for copy in copies.dropFirst() {
            tiles.append(CGRect(origin: CGPoint(x: x, y: tiles[0].height + gap), size: copy.extent.size))
            x += copy.extent.width + gap
        }
        let width = max(tiles[0].width, x)
        let height = tiles[0].height + gap + (tiles.dropFirst().map(\.height).max() ?? 0)

        // Core Image measures from the bottom-left, so flip each tile's position.
        var atlas = CIImage.empty()
        for (copy, tile) in zip(copies, tiles) {
            let placed = copy.transformed(by: CGAffineTransform(translationX: tile.minX - copy.extent.minX,
                                                                y: height - tile.maxY - copy.extent.minY))
            atlas = placed.composited(over: atlas)
        }
        guard let image = context.createCGImage(atlas, from: CGRect(x: 0, y: 0, width: width, height: height)) else {
            return nil
        }
        return Packed(image: image, tiles: tiles)
    }

    private static func resize(_ image: CIImage, by scale: Double) -> CIImage {
        guard scale < 1 else { return image }
        return image.applyingFilter("CILanczosScaleTransform",
                                    parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
    }

    /// Trims a fraction of a pixel off, and moves the image to the origin.
    private static func wholePixels(_ image: CIImage) -> CIImage {
        let extent = image.extent
        let trimmed = image.cropped(to: CGRect(x: extent.minX, y: extent.minY,
                                               width: extent.width.rounded(.down), height: extent.height.rounded(.down)))
        return trimmed.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
    }
}

/// Black wherever the card doesn't cover, softened like its outline: drawn over a stack of layers on
/// the black background, it shapes the whole stack at once.
struct CardOutside: View {
    var values: [Float]

    var body: some View {
        GeometryReader { geometry in
            Rectangle()
                .colorEffect(ShaderLibrary.cardOutside(.float2(geometry.size), .floatArray(values)))
        }
        .allowsHitTesting(false)
    }
}

/// The card face drawn by the blur shader.
struct BlurredCard: View {
    var atlas: BlurAtlas
    var values: [Float]

    var body: some View {
        GeometryReader { geometry in
            Rectangle()
                .colorEffect(ShaderLibrary.cardBlur(.float2(geometry.size), .image(atlas.image), .floatArray(values)))
        }
    }
}

/// Where the blur (or the dimming) is for one frame.
enum BlurShape {
    case none
    /// Grows with how much farther away (or nearer) than the in-focus surface each part of the card
    /// is; `top` and `bottom` are those distances at the card's top and bottom edges.
    case depth(top: Double, bottom: Double, full: Double, side: DepthSide)
    /// Fades in from an edge of the card.
    case cardEdge(EffectEdge, EffectRamp)
    /// Fades in from an edge of the window. `toWindow` takes a point on the drawn card to the
    /// window's coordinates.
    case windowEdge(EffectEdge, EffectRamp, toWindow: ProjectionTransform, windowSize: CGSize)
}

/// How far past the card the view drawing it reaches, so its outline can soften and spill outward
/// as far as the strongest blur spreads.
func blurMargin(cardSize: CGSize, strength: Double, shape: BlurShape) -> CGSize {
    if case .none = shape { return .zero }
    let spill = 3 * strength * min(cardSize.width, cardSize.height) / 8 + 1
    return CGSize(width: spill, height: spill)
}

/// Packs the blur shader's settings in the order `CardBlur.metal` reads them. `cardAspect` is the
/// card's width over its height; a picture of a different shape is cropped to fill it, unless
/// `pictureRect` places it somewhere on the card instead (in fractions of the card's size).
/// `margin` is how far the view reaches past the card, from `blurMargin`. `cornerRadius` rounds the
/// card's outline, in the view's points, and `shapesEdge` says whether this picture is shaped by it
/// (a layer in a stack isn't; the stack is shaped once on top by `CardOutside`).
/// `dim` darkens the picture where `dimShape` says, separately from the blur.
func blurShaderValues(strength: Double, shape: BlurShape, dim: Double, dimShape: BlurShape, atlas: BlurAtlas,
                      cardSize: CGSize, margin: CGSize, crops: Bool, pictureRect: CGRect? = nil,
                      cornerRadius: Double = 0, shapesEdge: Bool = true) -> [Float] {
    let cardAspect = cardSize.width / cardSize.height
    var values = [Float](repeating: 0, count: 40)
    values[0] = Float(strength)

    /// Puts `shape` in the slots for its kind, edge, front, width, full depth and side. Where the
    /// card is (its depth and where it lands in the window) is the same for both shapes.
    func pack(_ shape: BlurShape, into slots: [Int]) {
        func setEdge(_ edge: EffectEdge, _ ramp: EffectRamp) {
            values[slots[1]] = Float(EffectEdge.allCases.firstIndex(of: edge) ?? 0)
            values[slots[2]] = Float(ramp.front)
            values[slots[3]] = Float(max(ramp.width, 0.0001))
        }
        switch shape {
        case .none:
            values[slots[0]] = 0
        case .depth(let top, let bottom, let full, let side):
            values[slots[0]] = 1
            values[5] = Float(top)
            values[6] = Float(bottom)
            values[slots[4]] = Float(max(full, 0.0001))
            values[slots[5]] = switch side {
            case .nearer: -1
            case .either: 0
            case .farther: 1
            }
        case .cardEdge(let edge, let ramp):
            values[slots[0]] = 2
            setEdge(edge, ramp)
        case .windowEdge(let edge, let ramp, let t, let windowSize):
            values[slots[0]] = 3
            setEdge(edge, ramp)
            for (index, m) in [t.m11, t.m12, t.m13, t.m21, t.m22, t.m23, t.m31, t.m32, t.m33].enumerated() {
                values[9 + index] = Float(m)
            }
            values[18] = Float(windowSize.width)
            values[19] = Float(windowSize.height)
        }
    }
    pack(shape, into: [1, 2, 3, 4, 7, 8])
    pack(dimShape, into: [32, 33, 34, 35, 36, 37])

    // Filling a card of another shape crops the picture's middle.
    var scale = CGSize(width: 1, height: 1)
    if crops {
        if atlas.aspect > cardAspect {
            scale.width = cardAspect / atlas.aspect
        } else {
            scale.height = atlas.aspect / cardAspect
        }
    }
    if let rect = pictureRect {
        values[20] = Float(1 / rect.width)
        values[21] = Float(1 / rect.height)
        values[22] = Float(-rect.minX / rect.width)
        values[23] = Float(-rect.minY / rect.height)
    } else {
        values[20] = Float(scale.width)
        values[21] = Float(scale.height)
        values[22] = Float((1 - scale.width) / 2)
        values[23] = Float((1 - scale.height) / 2)
    }

    values[24] = Float(BlurAtlas.levels)
    values[25] = Float(atlas.pixelSize.width)
    values[26] = Float(atlas.pixelSize.height)
    values[27] = Float(dim)
    values[28] = Float(margin.width / cardSize.width)
    values[29] = Float(margin.height / cardSize.height)
    values[30] = Float(cornerRadius)
    values[31] = shapesEdge ? 1 : 0
    for tile in atlas.tiles {
        values += [Float(tile.minX), Float(tile.minY), Float(tile.width), Float(tile.height)]
    }
    return values
}
