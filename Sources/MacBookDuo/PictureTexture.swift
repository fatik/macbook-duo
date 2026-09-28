import CoreImage
import Metal

/// The GPU everything is drawn with.
enum GPU {
    static let device: MTLDevice = MTLCreateSystemDefaultDevice()!
}

/// A picture as a texture for the card's shader (`CardScene.metal`), no bigger than it's drawn.
/// Blurring is done each frame on the picture of the screen, so only the sharp picture is kept.
struct PictureTexture {
    let texture: MTLTexture
    let pixelSize: CGSize
    /// Where the picture sits in the texture, in pixels from its top-left: all of it.
    let tiles: [CGRect]
    /// The picture's width over its height.
    let aspect: Double
    /// Which picture this was made from.
    let source: ObjectIdentifier

    /// The GPU context pictures are resized with; safe to share between threads.
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// Makes the texture no longer than `longSide` pixels, first trimming the picture's middle to
    /// `aspect` (width over height) if given, since nothing outside it is shown. Runs off the main
    /// thread, including handing the texture to the GPU.
    static func make(from source: CGImage, longSide: Double, aspect: Double? = nil) async -> PictureTexture? {
        let packed = await Task.detached(priority: .userInitiated) {
            pack(source, longSide: longSide, aspect: aspect)
        }.value
        guard let packed else { return nil }
        let size = CGSize(width: packed.texture.width, height: packed.texture.height)
        return PictureTexture(texture: packed.texture, pixelSize: size, tiles: [CGRect(origin: .zero, size: size)],
                              aspect: size.width / size.height, source: ObjectIdentifier(source))
    }

    private struct Packed: @unchecked Sendable {
        var texture: MTLTexture
    }

    private static func pack(_ source: CGImage, longSide: Double, aspect: Double?) -> Packed? {
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
        guard let image = context.createCGImage(sharp, from: sharp.extent), let texture = upload(image) else { return nil }
        return Packed(texture: texture)
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
