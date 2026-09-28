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

        // Holding the real screen still runs from here.
        MenuBarExtra("Straight", systemImage: "laptopcomputer") {
            StillScreenMenu()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { StillScreen.shared.installHotKey() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        MainActor.assumeIsolated { !StillScreen.shared.isOn }
    }
}

struct ContentView: View {
    /// Whether this is the copy shown edge to edge over the whole display.
    private let isEdgeToEdge: Bool

    init(isEdgeToEdge: Bool = false) {
        self.isEdgeToEdge = isEdgeToEdge
    }

    @State private var sensor = LidSensor()
    @State private var calibrator = EyeCalibrator()
    @State private var lineUp = EyeLineUp()
    /// The calibration target's texture, shown on the card while lining it up by eye.
    @State private var lineUpTarget: PictureTexture?
    @State private var placement: ScreenPlacement?
    /// The lid angle at which the card was put in place; it stays at that spot in space from then on.
    @State private var anchorAngle: Double?
    @AppStorage("eyeDistance") private var eyeDistance = 55.0
    @AppStorage("eyeHeight") private var eyeHeight = 35.0
    @AppStorage("viewpoint") private var viewpoint: Viewpoint = .screen
    /// 0 means the default for the screen.
    @AppStorage("viewDistance") private var viewDistance = 0.0
    @AppStorage("viewLookingDown") private var lookingDown = 0.0
    /// How much of the window the card may fill, in both directions.
    @AppStorage("cardSize") private var cardFill = 0.45
    @AppStorage("imagePath") private var imagePath = ""
    /// The card's corner radius in millimeters, to match the screen's own rounded corners.
    @AppStorage("cornerRadius") private var cornerRadius = ControlPanel.defaultCornerRadius
    /// Whether the card covers the whole window instead of following the card width setting.
    @AppStorage("fillsWindow") private var fillsWindow = false
    /// The color around the card, as 0xRRGGBB.
    @AppStorage("backgroundColor") private var backgroundColor = 0x000000
    private var blur = StoredEffect.blur()
    private var dim = StoredEffect.dim()
    @State private var image: CGImage?
    /// The checkerboard as a picture, so it can go through the blur shader like a photo.
    @State private var checkerboard: CGImage?
    @State private var atlas: PictureTexture?
    /// A layered picture with parallax, shown instead of the image or checkerboard.
    @AppStorage("scene") private var sceneName = ""
    @State private var scene: ParallaxScene?
    @State private var sceneAtlases: [PictureTexture] = []
    /// How strongly the scene's layers come toward you as the lid moves, from 0 to 1.
    @AppStorage("parallax") private var parallax = 0.6
    @AppStorage("parallaxDirection") private var parallaxDirection: LidDirection = .either
    @AppStorage("parallaxMotion") private var parallaxMotion: ParallaxMotion = .toward
    @AppStorage("showsClock") private var showsClock = true
    @AppStorage("clockWeight") private var clockWeight = ClockStyle.phone.weight
    @AppStorage("clockWidth") private var clockWidth = ClockStyle.phone.width
    @AppStorage("clockStretch") private var clockStretch = ClockStyle.phone.stretch
    @AppStorage("clockOpacity") private var clockOpacity = 1.0
    @AppStorage("clockBlend") private var clockBlend: ClockBlend = .normal
    /// How near the clock is, for parallax, from 0 (stays put) to 1 (moves with the nearest layer).
    @AppStorage("clockDepth") private var clockDepth = 0.0
    /// How strongly the clock blurs where the scene does, from 0 (stays sharp) to 1.
    @AppStorage("clockBlur") private var clockBlur = 0.0
    @State private var clockAtlas: PictureTexture?
    @State private var isChoosingImage = false
    @State private var isDropTargeted = false
    @State private var showsControls = true
    @State private var showsControlsHint = false

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            // The card takes the image's shape, or 3:2 for the checkerboard and scenes.
            let aspect = scene != nil ? ParallaxScene.aspect
                : image.map { min(max(Double($0.width) / Double($0.height), 0.2), 5) } ?? 1.5
            let cardWidth = min(size.width * cardFill, size.height * cardFill * aspect)
            let cardSize = fillsWindow ? size : CGSize(width: cardWidth, height: cardWidth / aspect)

            ZStack {
                PlacementReader { placement = $0 }

                if let placement, sensor.isAvailable {
                    // Everything but the lid angle: the renderer and the status line follow the lid
                    // on their own, so this view isn't rebuilt every frame.
                    let setup = cardScene(placement: placement, windowSize: size, cardSize: cardSize)
                    let source = image ?? checkerboard

                    CardRendererView(scene: setup, sensor: sensor)
                    // The picture only needs to be about as big as the card is drawn; a bigger one
                    // would shimmer when shrunk. Remade only when that size changes by a fifth or so.
                    // A photo filling the window is trimmed to the window's shape first, since the
                    // rest never shows.
                    .task(id: AtlasRequest(source: source, longSide: max(cardSize.width, cardSize.height) * 3,
                                           aspect: fillsWindow && image != nil ? size.width / size.height : nil)) {
                        guard let source else { return }
                        // A different picture shouldn't show the last one while its own is made.
                        if atlas?.source != ObjectIdentifier(source) { atlas = nil }
                        let request = AtlasRequest(source: source, longSide: max(cardSize.width, cardSize.height) * 3,
                                                   aspect: fillsWindow && image != nil ? size.width / size.height : nil)
                        if let made = await PictureTexture.make(from: source, longSide: min(request.longSide, 3456),
                                                           aspect: request.aspect) {
                            atlas = made
                        }
                    }
                    // Each layer of a scene gets its own texture; the sky is trimmed to the card's shape.
                    .task(id: scene.map { SceneAtlasRequest(scene: $0.name,
                                                            longSide: AtlasRequest.bucket(max(cardSize.width, cardSize.height) * 3),
                                                            aspect: (Double(cardSize.width / cardSize.height) * 100).rounded() / 100) }) {
                        guard let scene else { return sceneAtlases = [] }
                        let longSide = min(AtlasRequest.bucket(max(cardSize.width, cardSize.height) * 3), 3456)
                        var made: [PictureTexture] = []
                        let cardAspect = Double(cardSize.width / cardSize.height)
                        for layer in scene.layers {
                            var fills = true
                            if case .band = layer.placement { fills = false }
                            guard let atlas = await PictureTexture.make(from: layer.image, longSide: longSide,
                                                                        aspect: fills ? cardAspect : nil)
                            else { return }
                            made.append(atlas)
                        }
                        sceneAtlases = made
                    }
                    // Lining up by eye shows a target the card's shape instead of the picture.
                    .task(id: lineUp.isActive ? (Double(cardSize.width / cardSize.height) * 100).rounded() : nil) {
                        guard lineUp.isActive else { return lineUpTarget = nil }
                        let longSide = min(AtlasRequest.bucket(max(cardSize.width, cardSize.height) * 2), 3456)
                        guard let picture = CalibrationTarget.render(aspect: Double(cardSize.width / cardSize.height),
                                                                     longSide: longSide)
                        else { return }
                        lineUpTarget = await PictureTexture.make(from: picture, longSide: longSide)
                    }
                    // The clock is redrawn as a picture whenever its style or the card changes, and
                    // again at the start of every minute.
                    .task(id: scene != nil && showsClock ? ClockRequest(
                        style: ClockStyle(weight: clockWeight, width: clockWidth, stretch: clockStretch),
                        longSide: AtlasRequest.bucket(max(cardSize.width, cardSize.height) * 3),
                        aspect: (Double(cardSize.width / cardSize.height) * 100).rounded() / 100) : nil) {
                        guard scene != nil, showsClock else { return clockAtlas = nil }
                        let longSide = min(AtlasRequest.bucket(max(cardSize.width, cardSize.height) * 3), 3456)
                        let aspect = Double(cardSize.width / cardSize.height)
                        let pixels = aspect >= 1 ? CGSize(width: longSide, height: longSide / aspect)
                                                 : CGSize(width: longSide * aspect, height: longSide)
                        let style = ClockStyle(weight: clockWeight, width: clockWidth, stretch: clockStretch)
                        while !Task.isCancelled {
                            let now = Date()
                            if let picture = ParallaxScene.renderClock(at: now, pixelSize: pixels, style: style),
                               let made = await PictureTexture.make(from: picture, longSide: longSide) {
                                clockAtlas = made
                            }
                            let nextMinute = (now.timeIntervalSince1970 / 60).rounded(.down) * 60 + 60.05
                            try? await Task.sleep(for: .seconds(nextMinute - Date().timeIntervalSince1970))
                        }
                    }

                    if lineUp.isActive {
                        // Where you're looking while lining up, below the target's circle.
                        LineUpGuide(lineUp: lineUp, sensor: sensor, save: { saveLineUp(setup) },
                                    finish: { lineUp.end() }, cancel: cancelLineUp)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            .padding(.bottom, 40)
                            .transition(.opacity)
                    } else if showsControls {
                        ControlPanel(
                            setup: setup,
                            sensor: sensor,
                            cardWidth: cardSize.width * placement.cmPerPoint,
                            source: scene != nil ? .desert : image != nil ? .image : .checkerboard,
                            image: image,
                            checkerboard: checkerboard,
                            canCalibrate: placement.isBuiltIn,
                            calibrator: calibrator,
                            defaultViewingDistance: Rig.defaultViewingDistance(for: placement),
                            isEdgeToEdge: isEdgeToEdge,
                            lineUp: lineUp,
                            actions: panelActions(setup))
                        // In the corner, clear of the middle of the picture.
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(20)
                        .transition(.opacity.combined(with: .offset(x: 24)))
                    } else if showsControlsHint {
                        HStack(spacing: 6) {
                            Text("Press")
                            Text("X")
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .frame(minWidth: 20, minHeight: 20)
                                .background(Color.white.opacity(0.14), in: .rect(cornerRadius: 5))
                            Text("for controls")
                        }
                        .font(.system(size: 12.5))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color(white: 0.105).opacity(0.97), in: .capsule)
                        .overlay(Capsule().strokeBorder(.white.opacity(0.08)))
                        .environment(\.colorScheme, .dark)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(20)
                        .transition(.opacity)
                    }
                } else {
                    RGBColor(hex: backgroundColor).color
                    if !sensor.isAvailable {
                        Text("No lid angle sensor found")
                            .font(.title2.weight(.semibold))
                    }
                }

                // Invisible, but give the window its X, F, R and Esc shortcuts.
                Group {
                    Button("Toggle Controls", action: toggleControls)
                        .keyboardShortcut("x", modifiers: [])
                    Button("Re-center") { if !lineUp.isActive { anchorAngle = sensor.angle } }
                        .keyboardShortcut("r", modifiers: [])
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
            if sceneName == "desert" { scene = ParallaxScene.desert() }
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

    /// The card's setup from the current settings, for `CardRendererView` to draw at each lid angle.
    /// What the panel's buttons do.
    private func panelActions(_ setup: CardScene) -> PanelActions {
        PanelActions(
            recenter: { anchorAngle = sensor.angle },
            fillWindow: {
                fillsWindow = true
                anchorAngle = sensor.angle
            },
            chooseImage: { isChoosingImage = true },
            showCheckerboard: {
                image = nil
                imagePath = ""
                scene = nil
                sceneName = ""
            },
            showDesert: {
                scene = ParallaxScene.desert()
                sceneName = scene?.name ?? ""
                image = nil
                imagePath = ""
            },
            calibrateWithCamera: {
                calibrate(cameraFromHinge: setup.rig(lidAngle: sensor.reading).rig.cameraFromHinge)
            },
            toggleEdgeToEdge: { EdgeToEdge.shared.toggle() },
            hide: toggleControls,
            startLineUp: { startLineUp(setup) },
            saveLineUp: { saveLineUp(setup) },
            finishLineUp: { lineUp.end() },
            cancelLineUp: cancelLineUp)
    }

    /// Where a typical viewer's eyes are for a card anchored at `anchor`: worked out from the screen.
    private func typicalEye(anchor: Double, placement: ScreenPlacement) -> (distance: Double, height: Double) {
        Rig.screenViewpoint(anchorAngle: anchor, placement: placement,
                            distance: viewDistance > 0 ? viewDistance : Rig.defaultViewingDistance(for: placement),
                            lookingDown: lookingDown)
    }

    /// Re-centers the card here and starts lining it up by eye, from a typical viewpoint: the one
    /// worked out from the screen.
    private func startLineUp(_ setup: CardScene) {
        let angle = sensor.angle
        let eye = typicalEye(anchor: angle, placement: setup.placement)
        lineUp.start(at: angle, previous: .init(viewpoint: viewpoint, eyeDistance: eyeDistance, eyeHeight: eyeHeight))
        anchorAngle = angle
        viewpoint = .eyes
        eyeDistance = eye.distance
        eyeHeight = eye.height
    }

    /// Keeps where the card is now as looking straight at this lid angle, and switches to the
    /// viewpoint that best explains every angle lined up so far.
    private func saveLineUp(_ setup: CardScene) {
        let angle = sensor.angle
        guard lineUp.isNew(angle) else {
            lineUp.note = "Move the lid at least \(Int(EyeLineUp.spacing))° from the angles already used first."
            return
        }
        guard let corners = setup.pose(lidAngle: angle)?.corners else {
            lineUp.note = "The card can't be drawn at this angle; open the lid a little."
            return
        }
        let sample = EyeLineUp.Sample(lidAngle: angle, corners: corners)
        guard let fit = setup.lineUpFit(lineUp.samples + [sample], anchor: lineUp.anchor,
                                        typical: typicalEye(anchor: lineUp.anchor, placement: setup.placement))
        else {
            lineUp.note = "No believable viewpoint draws the card like that, so this angle wasn't saved. Line it "
                + "up as a real card would sit: as the lid closes, its top should run off the top of the screen."
            return
        }
        lineUp.add(sample, fit: fit)
        eyeDistance = fit.eyeDistance
        eyeHeight = fit.eyeHeight
    }

    private func cancelLineUp() {
        if let previous = lineUp.previous {
            viewpoint = previous.viewpoint
            eyeDistance = previous.eyeDistance
            eyeHeight = previous.eyeHeight
        }
        lineUp.end()
    }

    private func cardScene(placement: ScreenPlacement, windowSize: CGSize, cardSize: CGSize) -> CardScene {
        var content: CardScene.Content
        if let scene, sceneAtlases.count == scene.layers.count {
            let clock = showsClock ? clockAtlas.map {
                CardScene.Clock(atlas: $0, depth: clockDepth, blur: clockBlur, opacity: clockOpacity, blend: clockBlend)
            } : nil
            content = .layers(scene, sceneAtlases, clock: clock,
                              parallax: Parallax(strength: parallax, direction: parallaxDirection, motion: parallaxMotion))
        } else if scene == nil, let atlas {
            content = .picture(atlas, crops: fillsWindow && image != nil)
        } else {
            content = .nothing
        }
        // Lining up shows the target plainly: no blur, dim or parallax to judge it through.
        var blurNow = blur.current, dimNow = dim.current
        if lineUp.isActive, let lineUpTarget {
            content = .picture(lineUpTarget, crops: false)
            blurNow.strength = 0
            dimNow.strength = 0
        }
        var scene = CardScene(placement: placement, windowSize: windowSize, cardSize: cardSize,
                              anchorAngle: anchorAngle, viewpoint: viewpoint, eyeDistance: eyeDistance,
                              eyeHeight: eyeHeight, viewDistance: viewDistance, lookingDown: lookingDown,
                              fillsWindow: fillsWindow, cornerRadius: cornerRadius,
                              background: RGBColor(hex: backgroundColor), blur: blurNow, dim: dimNow, content: content)
        scene.adjustment = lineUp.adjustment
        return scene
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
        scene = nil
        sceneName = ""
        imagePath = url.path
        return true
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
