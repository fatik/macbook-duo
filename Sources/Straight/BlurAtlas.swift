import CoreImage
import Metal

/// The GPU everything is drawn with.
enum GPU {
    static let device: MTLDevice = MTLCreateSystemDefaultDevice()!
}

/// A picture and progressively blurrier copies of it, packed into one texture so a single shader
/// pass (`CardScene.metal`) can pick how blurred each pixel should be. Blurring happens once, when
/// the atlas is made; each frame only chooses between copies.
struct BlurAtlas {
    let texture: MTLTexture
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
    /// if not given. Runs off the main thread, including handing the texture to the GPU.
    static func make(from source: CGImage, longSide: Double, aspect: Double? = nil,
                     blurPerWidth: Double? = nil) async -> BlurAtlas? {
        let packed = await Task.detached(priority: .userInitiated) {
            pack(source, longSide: longSide, aspect: aspect, blurPerWidth: blurPerWidth)
        }.value
        guard let packed else { return nil }
        return BlurAtlas(texture: packed.texture,
                         pixelSize: CGSize(width: packed.texture.width, height: packed.texture.height),
                         tiles: packed.tiles,
                         aspect: packed.tiles[0].width / packed.tiles[0].height,
                         source: ObjectIdentifier(source))
    }

    private struct Packed: @unchecked Sendable {
        var texture: MTLTexture
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
        guard let image = context.createCGImage(atlas, from: CGRect(x: 0, y: 0, width: width, height: height)),
              let texture = upload(image)
        else { return nil }
        return Packed(texture: texture, tiles: tiles)
    }

    /// The picture as a texture: sRGB, with premultiplied alpha, top row first.
    private static func upload(_ image: CGImage) -> MTLTexture? {
        let width = image.width, height = image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let bitmap = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        bitmap.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width,
                                                                  height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let pixels = bitmap.data, let texture = GPU.device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                        withBytes: pixels, bytesPerRow: bitmap.bytesPerRow)
        return texture
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
