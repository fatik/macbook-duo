import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@main
struct StraightApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        Window("Straight", id: "main") {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 640)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct ContentView: View {
    /// Whether this is the copy shown edge to edge over the whole display.
    private let isEdgeToEdge: Bool

    init(isEdgeToEdge: Bool = false) {
        self.isEdgeToEdge = isEdgeToEdge
    }

    @State private var sensor = LidSensor()
    @State private var calibrator = EyeCalibrator()
    @State private var placement: ScreenPlacement?
    /// The lid angle at which the card was put in place; it stays at that spot in space from then on.
    @State private var anchorAngle: Double?
    @AppStorage("mode") private var mode: CardMode = .facing
    @AppStorage("eyeDistance") private var eyeDistance = 55.0
    @AppStorage("eyeHeight") private var eyeHeight = 35.0
    @AppStorage("viewpoint") private var viewpoint: Viewpoint = .screen
    @AppStorage("viewSensitivity") private var sensitivity = 1.0
    /// 0 means the default for the screen.
    @AppStorage("viewDistance") private var viewDistance = 0.0
    @AppStorage("viewLookingDown") private var lookingDown = 0.0
    /// How much of the window the card may fill, in both directions.
    @AppStorage("cardSize") private var cardFill = 0.45
    @AppStorage("imagePath") private var imagePath = ""
    /// Whether the card covers the whole window instead of following the card width setting.
    @AppStorage("fillsWindow") private var fillsWindow = false
    private var blur = StoredEffect("blur", edge: .top)
    @State private var image: CGImage?
    /// The checkerboard as a picture, so it can go through the blur shader like a photo.
    @State private var checkerboard: CGImage?
    @State private var atlas: BlurAtlas?
    @State private var isChoosingImage = false
    @State private var isDropTargeted = false
    @State private var showsControls = true
    @State private var showsControlsHint = false

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            // The card takes the image's shape, or 3:2 for the checkerboard.
            let aspect = image.map { min(max(Double($0.width) / Double($0.height), 0.2), 5) } ?? 1.5
            let cardWidth = min(size.width * cardFill, size.height * cardFill * aspect)
            let cardSize = fillsWindow ? size : CGSize(width: cardWidth, height: cardWidth / aspect)

            ZStack {
                PlacementReader { placement = $0 }

                if let placement, sensor.isAvailable {
                    let anchor = anchorAngle ?? sensor.angle
                    let defaultDistance = Rig.defaultViewingDistance(for: placement)
                    let eye = viewpoint == .screen
                        ? Rig.screenViewpoint(anchorAngle: anchor, placement: placement,
                                              distance: viewDistance > 0 ? viewDistance : defaultDistance,
                                              lookingDown: lookingDown)
                        : (distance: eyeDistance, height: eyeHeight)
                    // Sensitivity scales how much the lid's movement since the anchor counts.
                    let rig = Rig(lidAngle: anchor + sensitivity * (sensor.angle - anchor),
                                  eyeDistance: eye.distance, eyeHeight: eye.height, placement: placement)
                    let cardFrame = CGRect(x: placement.frame.minX + (size.width - cardSize.width) / 2,
                                           y: placement.frame.minY + (size.height - cardSize.height) / 2,
                                           width: cardSize.width, height: cardSize.height)

                    let pose = rig.cardPose(frame: cardFrame, mode: mode, anchorAngle: anchor)

                    // The card is drawn at its laid-out size and then warped, so render it bigger when
                    // it's stretched to keep it sharp.
                    let stretch = pose.map { max($0.boundingBox.width / cardSize.width,
                                                 $0.boundingBox.height / cardSize.height) } ?? 1
                    let sharpness = min(min(max((stretch - 0.1).rounded(.up), 1), 4), 2400 / max(cardSize.width, cardSize.height))
                    let rendered = { (frame: CGRect) -> CGRect in
                        frame.insetBy(dx: -frame.width * (sharpness - 1) / 2, dy: -frame.height * (sharpness - 1) / 2)
                    }
                    let source = image ?? checkerboard

                    Color.black

                    // Hidden rather than drawn uncorrected when the lid is too far closed to draw it.
                    Color.clear.overlay {
                        if let atlas, let pose {
                            // The shader draws past the card on every side, so the blur can spread
                            // beyond its edges, and that bigger area is held in space the same way.
                            let margin = blurMargin(cardSize: cardSize, strength: blur.strength,
                                                    shape: blur.shape(lidAngle: sensor.angle, anchorAngle: anchor,
                                                                      pose: pose, window: nil))
                            let area = cardFrame.insetBy(dx: -margin.width, dy: -margin.height)
                            let renderFrame = rendered(area)
                            if let transform = rig.cardPose(frame: area, mode: mode, anchorAngle: anchor)?
                                .transform(from: renderFrame) {
                                // Filling the window pushes the card's own edges off-screen as the lid
                                // moves, so edge fades come in from the window's edges instead.
                                let toWindow = transform.translatedAfter(x: renderFrame.minX - placement.frame.minX,
                                                                         y: renderFrame.minY - placement.frame.minY)
                                let shape = blur.shape(lidAngle: sensor.angle, anchorAngle: anchor, pose: pose,
                                                       window: fillsWindow ? (toWindow, size) : nil)
                                BlurredCard(atlas: atlas, values: blurShaderValues(
                                    strength: blur.strength, dim: blur.dim, shape: shape, atlas: atlas,
                                    cardSize: cardSize, margin: margin, crops: fillsWindow && image != nil))
                                .frame(width: renderFrame.width, height: renderFrame.height)
                                .projectionEffect(transform)
                            }
                        } else if let source, let transform = pose?.transform(from: rendered(cardFrame)) {
                            // Until the blur's copies are ready.
                            Image(decorative: source, scale: 1)
                                .resizable()
                                .frame(width: rendered(cardFrame).width, height: rendered(cardFrame).height)
                                .projectionEffect(transform)
                        }
                    }
                    // The sharp copy only needs to be about as big as the card is drawn; a bigger one
                    // would shimmer when shrunk. Remade only when that size changes by a fifth or so.
                    // A photo filling the window is trimmed to the window's shape first, since the
                    // rest never shows.
                    .task(id: AtlasRequest(source: source, longSide: max(cardSize.width, cardSize.height) * 3,
                                           aspect: fillsWindow && image != nil ? size.width / size.height : nil)) {
                        guard let source else { return }
                        // A different picture shouldn't show the last one's copies while its own are made.
                        if atlas?.source != ObjectIdentifier(source) { atlas = nil }
                        let request = AtlasRequest(source: source, longSide: max(cardSize.width, cardSize.height) * 3,
                                                   aspect: fillsWindow && image != nil ? size.width / size.height : nil)
                        if let made = await BlurAtlas.make(from: source, longSide: min(request.longSide, 3456),
                                                           aspect: request.aspect) {
                            atlas = made
                        }
                    }

                    if showsControls {
                        VStack {
                            Spacer()
                            ControlPanel(
                                cardWidth: cardSize.width * placement.cmPerPoint,
                                hasImage: image != nil,
                                canCalibrate: placement.isBuiltIn,
                                calibrator: calibrator,
                                defaultViewingDistance: defaultDistance,
                                status: status(rig: rig, pose: pose, placement: placement, anchor: anchor),
                                recenter: { anchorAngle = sensor.angle },
                                fillWindow: {
                                    fillsWindow = true
                                    mode = .asPlaced
                                    anchorAngle = sensor.angle
                                },
                                chooseImage: { isChoosingImage = true },
                                clearImage: { image = nil; imagePath = "" },
                                calibrate: { calibrate(cameraFromHinge: rig.cameraFromHinge) },
                                isEdgeToEdge: isEdgeToEdge,
                                toggleEdgeToEdge: { EdgeToEdge.shared.toggle() },
                                hide: toggleControls)
                        }
                        .padding(16)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    } else if showsControlsHint {
                        VStack {
                            Spacer()
                            Text("Press X to show controls")
                                .font(.callout)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(Color(white: 0.12).opacity(0.94), in: .capsule)
                        }
                        .padding(24)
                        .transition(.opacity)
                    }
                } else {
                    Color.black
                    if !sensor.isAvailable {
                        Text("No lid angle sensor found")
                            .font(.title2.weight(.semibold))
                    }
                }

                // Invisible, but give the window its X, F and Esc shortcuts.
                Group {
                    Button("Toggle Controls", action: toggleControls)
                        .keyboardShortcut("x", modifiers: [])
                    Button("Toggle Full Screen") { EdgeToEdge.shared.toggle() }
                        .keyboardShortcut("f", modifiers: [])
                    if isEdgeToEdge {
                        Button("Exit Full Screen") { EdgeToEdge.shared.exit() }
                            .keyboardShortcut(.escape, modifiers: [])
                    }
                }
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(.white.opacity(0.8), style: StrokeStyle(lineWidth: 3, dash: [10, 8]))
                        .padding(12)
                        .overlay(Text("Drop to use this image").font(.title3.weight(.semibold)))
                }
            }
        }
        .ignoresSafeArea()
        .onAppear {
            anchorAngle = sensor.angle
            checkerboard = renderCheckerboard()
            if !imagePath.isEmpty, !useImage(at: URL(fileURLWithPath: imagePath)) { imagePath = "" }
        }
        .task(id: showsControls) {
            // After hiding the controls, say how to get them back, then get out of the way.
            showsControlsHint = !showsControls
            guard !showsControls else { return }
            try? await Task.sleep(for: .seconds(2))
            withAnimation(.easeOut(duration: 0.4)) { showsControlsHint = false }
        }
        .fileImporter(isPresented: $isChoosingImage, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result { useImage(at: url) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            urls.first.map { useImage(at: $0) } ?? false
        } isTargeted: { isDropTargeted = $0 }
        .preferredColorScheme(.dark)
        .frame(minWidth: 520, minHeight: 480)
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) { showsControls.toggle() }
    }

    private func calibrate(cameraFromHinge: Double) {
        calibrator.start(cameraFromHinge: cameraFromHinge, lidAngle: { [sensor] in sensor.reading }) { distance, height in
            withAnimation(.easeInOut(duration: 0.4)) {
                eyeDistance = distance
                eyeHeight = height
            }
        }
    }

    @discardableResult
    private func useImage(at url: URL) -> Bool {
        guard let loaded = loadCardImage(at: url) else { return false }
        image = loaded
        imagePath = url.path
        return true
    }

    private func status(rig: Rig, pose: CardPose?, placement: ScreenPlacement, anchor: Double) -> String {
        guard placement.isBuiltIn else { return "Move this window to the built-in display" }
        let fps = sensor.framesPerSecond.map { " · \($0) fps" } ?? ""
        let lid = "Lid \(sensor.angle.formatted(.number.precision(.fractionLength(1))))°\(fps)"
        guard mode != .flat else { return "\(lid) · no correction" }
        guard let pose else { return "\(lid) · too far closed to draw the card from your eye position" }
        let lean = rig.lean(of: pose.up)
        let tilt = abs(lean) < 0.5 ? "in line with the screen"
            : "tilted \(Int(abs(lean).rounded()))° \(lean > 0 ? "back" : "forward")"
        let held = "held where it was at \(anchor.formatted(.number.precision(.fractionLength(1))))°"
        guard pose.boundingBox.intersects(placement.frame) else { return "\(lid) · card \(held), now out of view" }
        return "\(lid) · card \(held), \(tilt), drawn at \(Int((pose.scale * 100).rounded()))% size"
    }
}

/// What the blur atlas is made from, roughly how big, and what shape it's trimmed to. Sizes are
/// grouped into steps of about a fifth, so small changes to the card don't remake it.
struct AtlasRequest: Equatable {
    var source: ObjectIdentifier?
    var longSide: Double
    var aspect: Double?

    init(source: CGImage?, longSide: Double, aspect: Double?) {
        self.source = source.map(ObjectIdentifier.init)
        self.longSide = Self.bucket(longSide)
        self.aspect = aspect.map { ($0 * 100).rounded() / 100 }
    }

    static func bucket(_ longSide: Double) -> Double {
        pow(2, (log2(max(longSide, 64)) * 4).rounded() / 4)
    }
}

extension ProjectionTransform {
    /// This transform followed by a move of (`x`, `y`).
    func translatedAfter(x: Double, y: Double) -> ProjectionTransform {
        var moved = self
        moved.m11 += m13 * x; moved.m21 += m23 * x; moved.m31 += m33 * x
        moved.m12 += m13 * y; moved.m22 += m23 * y; moved.m32 += m33 * y
        return moved
    }
}

/// The checkerboard as a 3:2 picture, big enough to stay crisp on a full-screen card.
@MainActor
private func renderCheckerboard() -> CGImage? {
    let renderer = ImageRenderer(content: CheckerCard(lineWidth: 10).frame(width: 2400, height: 1600))
    renderer.scale = 1
    return renderer.cgImage
}

/// Loads an image upright (following its orientation tag) and no bigger than the card is ever drawn.
func loadCardImage(at url: URL) -> CGImage? {
    let options = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: 4096,
    ] as CFDictionary
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options),
          image.width > 0, image.height > 0
    else { return nil }
    return image
}

/// A checkerboard with an inscribed circle: when the illusion works, the squares look square
/// and the circle looks round.
struct CheckerCard: View {
    var lineWidth: CGFloat = 4

    var body: some View {
        Canvas { context, size in
            let columns = 6, rows = 4
            let cell = CGSize(width: size.width / CGFloat(columns), height: size.height / CGFloat(rows))
            for row in 0..<rows {
                for column in 0..<columns {
                    let rect = CGRect(x: CGFloat(column) * cell.width, y: CGFloat(row) * cell.height,
                                      width: cell.width, height: cell.height)
                    let isEven = (row + column).isMultiple(of: 2)
                    context.fill(Path(rect), with: .color(isEven ? Color(hex: 0xFF9446) : Color(hex: 0xFFC75A)))
                }
            }

            let radius = cell.height * 1.5
            let circle = CGRect(x: size.width / 2 - radius, y: size.height / 2 - radius,
                                width: radius * 2, height: radius * 2)
            context.stroke(Path(ellipseIn: circle), with: .color(.white), lineWidth: lineWidth)
        }
        .overlay(Rectangle().strokeBorder(.white, lineWidth: lineWidth))
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}
