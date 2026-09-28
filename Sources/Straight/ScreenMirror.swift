import CoreMedia
import CoreVideo
import Metal
import os
import ScreenCaptureKit

/// The built-in display's picture, captured live as it changes, as a texture for the card's shader.
/// The window it's drawn back into is left out, so it doesn't capture itself.
final class ScreenMirror: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    enum Failure: LocalizedError {
        case noDisplay, noOwnWindow
        var errorDescription: String? {
            switch self {
            case .noDisplay: "Couldn't find the built-in display to capture."
            case .noOwnWindow: "Couldn't leave Straight's own window out of the capture."
            }
        }
    }

    /// A frame, kept with the Core Video texture it comes from so its memory stays alive.
    private struct Frame: @unchecked Sendable {
        var picture: PictureTexture
        var keep: CVMetalTexture
        var count: Int
    }

    private let latestFrame = OSAllocatedUnfairLock<Frame?>(initialState: nil)
    private let queue = DispatchQueue(label: "ScreenMirror", qos: .userInteractive)
    private var stream: SCStream?
    private var configuration: SCStreamConfiguration?
    private var textureCache: CVMetalTextureCache?
    private var frameCount = 0

    /// Called, on the main thread, when capturing stops by itself: someone chose Stop Sharing, or it
    /// failed.
    var onStop: (@MainActor () -> Void)?

    /// The screen as it last looked, and how many frames have come in, which changes with every new one.
    var latest: (picture: PictureTexture, count: Int)? { latestFrame.withLock { $0.map { ($0.picture, $0.count) } } }

    override init() {
        super.init()
        CVMetalTextureCacheCreate(nil, nil, GPU.device, nil, &textureCache)
    }

    /// Starts capturing `displayID` at `scale` pixels per point, up to `rate` frames a second, leaving
    /// out the window numbered `excluded`. Throws if Screen Recording isn't allowed, or that window
    /// can't be left out.
    func start(displayID: CGDirectDisplayID, scale: CGFloat, rate: Int, excluding excluded: Int) async throws {
        // All windows, not just those showing: the one left out is see-through while the lid rests, and
        // then it isn't listed as on screen. Capturing it would draw the screen back into itself.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw Failure.noDisplay }
        let own = content.windows.filter { Int($0.windowID) == excluded }
        guard !own.isEmpty else { throw Failure.noOwnWindow }
        let filter = SCContentFilter(display: display, excludingWindows: own)

        let configuration = SCStreamConfiguration()
        configuration.width = Int(CGFloat(display.width) * scale)
        configuration.height = Int(CGFloat(display.height) * scale)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(rate))
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        // Wide enough for the built-in display's colors, so drawn back they match what's really there.
        configuration.colorSpaceName = CGColorSpace.displayP3
        // The real cursor stays on top, where clicks land; a copy in the picture would drift from it.
        configuration.showsCursor = false
        configuration.queueDepth = 4

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        self.configuration = configuration
    }

    /// Captures up to `rate` frames a second from now on.
    func setRate(_ rate: Int) {
        guard let stream, let configuration,
              configuration.minimumFrameInterval != CMTime(value: 1, timescale: CMTimeScale(rate)) else { return }
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(rate))
        stream.updateConfiguration(configuration) { _ in }
    }

    func stop() {
        let stream = self.stream
        self.stream = nil
        configuration = nil
        Task { try? await stream?.stopCapture() }
        latestFrame.withLock { $0 = nil }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, let pixels = sampleBuffer.imageBuffer, let textureCache else { return }
        // Frames arrive only when something changed; idle ones carry no picture.
        let info = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]]
        guard let raw = info?.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }

        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        var made: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pixels, nil, .bgra8Unorm, width, height, 0, &made)
        guard let made, let texture = CVMetalTextureGetTexture(made) else { return }
        frameCount += 1
        let size = CGSize(width: width, height: height)
        let picture = PictureTexture(texture: texture, pixelSize: size, tiles: [CGRect(origin: .zero, size: size)],
                                     aspect: size.width / size.height, source: ObjectIdentifier(self))
        let frame = Frame(picture: picture, keep: made, count: frameCount)
        latestFrame.withLock { $0 = frame }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        latestFrame.withLock { $0 = nil }
        let onStop = self.onStop
        DispatchQueue.main.async { MainActor.assumeIsolated { onStop?() } }
    }
}
