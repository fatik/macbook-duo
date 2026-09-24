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
    /// How much of the window the card may fill, in both directions.
    @AppStorage("cardSize") private var cardFill = 0.45
    @AppStorage("imagePath") private var imagePath = ""
    /// Whether the card covers the whole window instead of following the card width setting.
    @AppStorage("fillsWindow") private var fillsWindow = false
    private var blur = StoredEffect("blur", edge: .top)
    private var darkness = StoredEffect("darkness", edge: .bottom)
    @State private var image: CGImage?
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
                    let rig = Rig(lidAngle: sensor.angle, eyeDistance: eyeDistance, eyeHeight: eyeHeight,
                                  placement: placement)
                    let cardFrame = CGRect(x: placement.frame.minX + (size.width - cardSize.width) / 2,
                                           y: placement.frame.minY + (size.height - cardSize.height) / 2,
                                           width: cardSize.width, height: cardSize.height)

                    let anchor = anchorAngle ?? sensor.angle
                    let pose = rig.cardPose(frame: cardFrame, mode: mode, anchorAngle: anchor)

                    // The lid slides each effect in from its edge. Full blur, in points, is up to an
                    // eighth of the card's shorter side. A card filling the window has its own edges
                    // pushed off-screen as the lid moves, so there the effects come in from the
                    // window's edges instead.
                    let blurRamp = blur.ramp(lidAngle: sensor.angle, anchorAngle: anchor)
                    let blurRadius = blurRamp.peak > 0.002 ? blur.strength * min(cardSize.width, cardSize.height) / 8 : 0
                    let shadeRamp = darkness.ramp(lidAngle: sensor.angle, anchorAngle: anchor)
                    let shade = shadeRamp.peak > 0.002 ? darkness.strength : 0
                    let effectsOnCard = !fillsWindow

                    // The card is drawn at its laid-out size and then warped, so render it bigger when
                    // it's stretched to keep it sharp, within what the GPU handles comfortably. Every
                    // blur layer needs its own copy, so there's less room with blur on.
                    let stretch = pose.map { max($0.boundingBox.width / cardSize.width,
                                                 $0.boundingBox.height / cardSize.height) } ?? 1
                    let largest = (blurRadius > 0.25 ? 1800 : 2400) / max(cardSize.width, cardSize.height)
                    let sharpness = min(min(max((stretch - 0.1).rounded(.up), 1), 4), largest)
                    let renderFrame = cardFrame.insetBy(dx: -cardSize.width * (sharpness - 1) / 2,
                                                        dy: -cardSize.height * (sharpness - 1) / 2)
                    let transform = pose?.transform(from: renderFrame)

                    // Hidden rather than drawn uncorrected when the lid is too far closed to draw it.
                    let card = Color.clear.overlay {
                        ProgressiveBlur(radius: effectsOnCard ? blurRadius * sharpness : 0, ramp: blurRamp,
                                        edge: blur.edge, isOpaque: image.map(isOpaque) ?? true) {
                            if let image {
                                // Filling the window crops the image to the window's shape.
                                Image(decorative: image, scale: 1)
                                    .resizable()
                                    .interpolation(.high)
                                    .aspectRatio(contentMode: fillsWindow ? .fill : .fit)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .clipped()
                            } else {
                                CheckerCard(lineWidth: 4 * sharpness)
                            }
                        }
                        .overlay {
                            if effectsOnCard, shade > 0.005 {
                                EdgeDarkness(opacity: shade, ramp: shadeRamp, edge: darkness.edge)
                            }
                        }
                        .frame(width: renderFrame.width, height: renderFrame.height)
                        .projectionEffect(transform ?? ProjectionTransform())
                        .opacity(transform == nil ? 0 : 1)
                    }

                    if effectsOnCard {
                        Backdrop()
                        card
                    } else {
                        ProgressiveBlur(radius: blurRadius, ramp: blurRamp, edge: blur.edge, isOpaque: true) {
                            ZStack {
                                Backdrop()
                                card
                            }
                        }
                        .overlay {
                            if shade > 0.005 {
                                EdgeDarkness(opacity: shade, ramp: shadeRamp, edge: darkness.edge)
                            }
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
                                .background(.regularMaterial, in: .capsule)
                        }
                        .padding(24)
                        .transition(.opacity)
                    }
                } else {
                    Backdrop()
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

    private func isOpaque(_ image: CGImage) -> Bool {
        [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
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
        let lid = "Lid \(rig.lidAngle.formatted(.number.precision(.fractionLength(1))))°\(fps)"
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

/// The window's dark background and its dot grid.
struct Backdrop: View {
    var body: some View {
        ZStack {
            Color(red: 0.055, green: 0.06, blue: 0.08)
            DotGrid()
        }
    }
}

/// Faint dots that sit flat on the screen, so the card's correction reads against them. Drawn as one
/// repeating tile, which is far cheaper than thousands of separate dots.
struct DotGrid: View {
    var body: some View {
        Image(nsImage: dotTile)
            .resizable(resizingMode: .tile)
    }
}

/// One 28-point cell of the dot grid, with its dot in the middle.
@MainActor private let dotTile = NSImage(size: NSSize(width: 28, height: 28), flipped: false) { rect in
    NSColor.white.withAlphaComponent(0.14).setFill()
    NSBezierPath(ovalIn: NSRect(x: rect.midX - 1.25, y: rect.midY - 1.25, width: 2.5, height: 2.5)).fill()
    return true
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}
