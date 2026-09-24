import AVFoundation
import Observation
import Vision

/// Works out where the viewer's eyes are from the built-in camera while they tilt the lid.
///
/// In each frame it measures how far the eyes sit above the camera's line of sight, in centimeters,
/// using the gap between the pupils as a ruler. The camera turns with the lid through angles the lid
/// sensor knows exactly, so a still head seen from a range of lid angles pins down where the eyes
/// are, without needing to know anything about the camera's lens.
@MainActor
@Observable
final class EyeCalibrator {
    enum Phase: Equatable {
        case idle
        case measuring(progress: Double, seesFace: Bool)
        case finished(distance: Double, height: Double)
        case failed(String)
    }

    private(set) var phase: Phase = .idle

    /// How far the lid has to move during a measurement, in degrees.
    static let sweep = 15.0

    var isMeasuring: Bool {
        if case .measuring = phase { true } else { false }
    }

    @ObservationIgnored private var session: AVCaptureSession?
    @ObservationIgnored private var reader: FrameReader?
    @ObservationIgnored private var samples: [Sample] = []
    @ObservationIgnored private var lastFace = Date.distantPast
    @ObservationIgnored private var deadline = Date.distantFuture
    @ObservationIgnored private var cameraFromHinge = 0.0
    @ObservationIgnored private var lidAngle: () -> Double = { 0 }
    @ObservationIgnored private var onResult: (_ distance: Double, _ height: Double) -> Void = { _, _ in }

    /// Starts measuring. `onResult` gets the eye's distance in front of the hinge and height above
    /// it, in centimeters.
    func start(cameraFromHinge: Double, lidAngle: @escaping () -> Double,
               onResult: @escaping (_ distance: Double, _ height: Double) -> Void) {
        guard !isMeasuring else { return }
        self.cameraFromHinge = cameraFromHinge
        self.lidAngle = lidAngle
        self.onResult = onResult
        samples = []
        lastFace = .distantPast
        deadline = Date().addingTimeInterval(40)
        phase = .measuring(progress: 0, seesFace: false)
        Task { await openCamera() }
    }

    func cancel() {
        stopCamera()
        phase = .idle
    }

    private func openCamera() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { return fail(Self.noAccess) }
        default:
            return fail(Self.noAccess)
        }
        guard isMeasuring else { return }

        let cameras = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera],
                                                       mediaType: .video, position: .unspecified).devices
        guard let camera = cameras.first, let input = try? AVCaptureDeviceInput(device: camera) else {
            return fail("Couldn't find the built-in camera.")
        }

        // Center Stage crops and pans the picture to follow you, which would throw the measurement off.
        AVCaptureDevice.centerStageControlMode = .app
        AVCaptureDevice.isCenterStageEnabled = false

        let session = AVCaptureSession()
        if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        let reader = FrameReader { [weak self] height in
            Task { @MainActor in self?.record(height) }
        }
        output.setSampleBufferDelegate(reader, queue: reader.queue)
        guard session.canAddInput(input), session.canAddOutput(output) else {
            return fail("Couldn't start the camera.")
        }
        session.addInput(input)
        session.addOutput(output)

        self.session = session
        self.reader = reader
        let handle = SessionHandle(session: session)
        reader.queue.async { handle.session.startRunning() }
    }

    private func record(_ height: Double?) {
        guard isMeasuring else { return }
        let now = Date()
        if let height {
            lastFace = now
            samples.append(Sample(angle: lidAngle(), height: height))
        }

        let angles = samples.map(\.angle)
        let covered = (angles.max() ?? 0) - (angles.min() ?? 0)
        if covered >= Self.sweep, samples.count >= 40 { return finish() }
        guard now < deadline else {
            return fail(samples.isEmpty
                ? "Couldn't see your face. Make sure the camera can see you, then try again."
                : "The screen didn't move far enough. Tilt it about \(Int(Self.sweep))° back and forth while measuring.")
        }
        phase = .measuring(progress: min(covered / Self.sweep, 1), seesFace: now.timeIntervalSince(lastFace) < 0.5)
    }

    private func finish() {
        stopCamera()
        guard let fit = Self.fit(samples, cameraFromHinge: cameraFromHinge) else {
            return fail("Couldn't work out where your eyes are. Try again.")
        }
        guard fit.rms < 1.5 else {
            return fail("Your head moved while measuring. Try again, keeping it still while you tilt the screen.")
        }
        guard Self.distanceRange.contains(fit.distance), Self.heightRange.contains(fit.height) else {
            return fail("That measurement looks off. Sit where you normally do and try again.")
        }
        onResult(fit.distance, fit.height)
        phase = .finished(distance: fit.distance, height: fit.height)
    }

    private func fail(_ message: String) {
        stopCamera()
        phase = .failed(message)
    }

    private func stopCamera() {
        if let session, let reader {
            let handle = SessionHandle(session: session)
            reader.queue.async { handle.session.stopRunning() }
        }
        if session != nil { AVCaptureDevice.centerStageControlMode = .user }
        session = nil
        reader = nil
    }

    /// Eye positions the sliders can show, in centimeters.
    static let distanceRange = 20.0...120.0
    static let heightRange = -10.0...80.0

    private static let noAccess =
        "Camera access is off for Straight. Turn it on in System Settings › Privacy & Security › Camera, then try again."

    struct Sample {
        /// Lid angle in degrees.
        var angle: Double
        /// How far the eyes were above the camera's line of sight, in centimeters.
        var height: Double
    }

    /// Least-squares eye position for a set of samples.
    ///
    /// At lid angle θ, the lid's up direction is (sin θ, cos θ) in (height, distance) and the camera
    /// sits `cameraFromHinge` up it, so eyes seen `h` above the camera's line of sight satisfy
    /// eye · up(θ) = h + cameraFromHinge.
    nonisolated static func fit(_ samples: [Sample], cameraFromHinge: Double)
        -> (distance: Double, height: Double, rms: Double)? {
        var syy = 0.0, syz = 0.0, szz = 0.0, by = 0.0, bz = 0.0
        for sample in samples {
            let t = sample.angle * .pi / 180
            let (uy, uz) = (sin(t), cos(t))
            let b = sample.height + cameraFromHinge
            syy += uy * uy; syz += uy * uz; szz += uz * uz
            by += uy * b; bz += uz * b
        }
        let determinant = syy * szz - syz * syz
        guard samples.count >= 2, abs(determinant) > 1e-9 else { return nil }

        let height = (by * szz - bz * syz) / determinant
        let distance = (syy * bz - syz * by) / determinant
        let squares = samples.map { sample -> Double in
            let t = sample.angle * .pi / 180
            let miss = height * sin(t) + distance * cos(t) - (sample.height + cameraFromHinge)
            return miss * miss
        }
        return (distance, height, (squares.reduce(0, +) / Double(samples.count)).squareRoot())
    }
}

/// Lets the capture session start and stop off the main thread, as AVFoundation recommends. The
/// session is only touched there after it's fully set up.
private struct SessionHandle: @unchecked Sendable {
    let session: AVCaptureSession
}

/// Receives camera frames off the main thread and reports how far the eyes are above the camera's
/// line of sight in each, in centimeters, or nil when it can't find them.
private final class FrameReader: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    /// The typical gap between an adult's pupils, used as a ruler.
    static let pupilDistance = 6.3

    let queue = DispatchQueue(label: "Straight.camera")
    private let report: @Sendable (Double?) -> Void
    private let request = VNDetectFaceLandmarksRequest()

    init(report: @escaping @Sendable (Double?) -> Void) {
        self.report = report
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let size = CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels))
        try? VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up).perform([request])

        let face = request.results?.max { $0.boundingBox.width < $1.boundingBox.width }
        guard let left = face?.landmarks?.leftPupil?.pointsInImage(imageSize: size).first,
              let right = face?.landmarks?.rightPupil?.pointsInImage(imageSize: size).first
        else { return report(nil) }

        let gap = hypot(left.x - right.x, left.y - right.y)
        guard gap > 4 else { return report(nil) }
        // Vision measures from the bottom-left, so y grows upward, the same way as up the lid.
        let aboveCenter = (left.y + right.y) / 2 - size.height / 2
        report(aboveCenter / gap * Self.pupilDistance)
    }
}
