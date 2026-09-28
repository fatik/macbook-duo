import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// The picture held still in space: the desert, the checkerboard or any image, on a card that stays put
/// while the lid moves, with a toolbar for the everyday and the full control panel for the rest.
struct ShowcaseView: View {
    enum Mode {
        /// Everything: the toolbar, the controls, calibrating, dropping in a picture.
        case full
        /// Just the desert, answering the lid, for the welcome.
        case demo
    }

    private let mode: Mode
    /// Whether this is the copy shown edge to edge over the whole display.
    private let isEdgeToEdge: Bool

    init(mode: Mode = .full, isEdgeToEdge: Bool = false) {
        self.mode = mode
        self.isEdgeToEdge = isEdgeToEdge
    }

    private let sensor = LidSensor.shared
    private let app = AppState.shared
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
    @AppStorage("viewLookingDown") private var lookingDown = Defaults.typicalLookingDown
    /// How much of the window the card may fill, in both directions.
    @AppStorage("cardSize") private var cardFill = 0.45
    @AppStorage("imagePath") private var imagePath = ""
    /// The card's corner radius in millimeters, to match the screen's own rounded corners.
    @AppStorage("cornerRadius") private var cornerRadius = ControlPanel.defaultCornerRadius
    /// Whether the card covers the whole window instead of following the card width setting.
    @AppStorage("fillsWindow") private var fillsWindow = true
    /// Whether the card covers the whole window: as set, or always for the welcome's demo.
    private var fills: Bool { mode == .demo || fillsWindow }
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
    /// The date and time, drawn between the scene's layers.
    @State private var clockAtlas: PictureTexture?
    @State private var isChoosingImage = false
    @State private var isDropTargeted = false
    @State private var showsControls = false
    @State private var asksForScreenRecording = false

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            // The card takes the image's shape, or 3:2 for the checkerboard and scenes.
            let aspect = scene != nil ? ParallaxScene.aspect
                : image.map { min(max(Double($0.width) / Double($0.height), 0.2), 5) } ?? 1.5
            let cardWidth = min(size.width * cardFill, size.height * cardFill * aspect)
            let cardSize = fills ? size : CGSize(width: cardWidth, height: cardWidth / aspect)

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
                                           aspect: fills && image != nil ? size.width / size.height : nil)) {
                        guard let source else { return }
                        // A different picture shouldn't show the last one while its own is made.
                        if atlas?.source != ObjectIdentifier(source) { atlas = nil }
                        let request = AtlasRequest(source: source, longSide: max(cardSize.width, cardSize.height) * 3,
                                                   aspect: fills && image != nil ? size.width / size.height : nil)
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
                    // The clock is redrawn as a picture whenever the card changes, and again at the
                    // start of every minute.
                    .task(id: scene != nil ? ClockRequest(
                        longSide: AtlasRequest.bucket(max(cardSize.width, cardSize.height) * 3),
                        aspect: (Double(cardSize.width / cardSize.height) * 100).rounded() / 100) : nil) {
                        guard scene != nil else { return clockAtlas = nil }
                        let longSide = min(AtlasRequest.bucket(max(cardSize.width, cardSize.height) * 3), 3456)
                        let aspect = Double(cardSize.width / cardSize.height)
                        let pixels = aspect >= 1 ? CGSize(width: longSide, height: longSide / aspect)
                                                 : CGSize(width: longSide * aspect, height: longSide)
                        while !Task.isCancelled {
                            let now = Date()
                            if let picture = ParallaxScene.renderClock(at: now, pixelSize: pixels),
                               let made = await PictureTexture.make(from: picture, longSide: longSide) {
                                clockAtlas = made
                            }
                            let nextMinute = (now.timeIntervalSince1970 / 60).rounded(.down) * 60 + 60.05
                            try? await Task.sleep(for: .seconds(nextMinute - Date().timeIntervalSince1970))
                        }
                    }

                    if mode == .demo {
                        // Nothing over the picture: the welcome says the rest.
                    } else if !placement.isBuiltIn {
                        DuoCard(width: 420) {
                            Label("Move this window to your MacBook's screen", systemImage: "macbook")
                                .font(.system(size: 15, weight: .semibold))
                            Text("The effect follows your MacBook's lid.")
                                .foregroundStyle(.secondary)
                                .padding(.top, 6)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if lineUp.isActive {
                        // Where you're looking while lining up, below the target's circle.
                        LineUpGuide(lineUp: lineUp, sensor: sensor, save: { saveLineUp(setup) },
                                    finish: { lineUp.end() }, cancel: cancelLineUp)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            .padding(.bottom, 40)
                            .transition(.opacity)
                    } else if calibrator.phase != .idle {
                        // Where you're looking while the camera measures, with each step to take.
                        CameraGuide(calibrator: calibrator, sensor: sensor) {
                            calibrate(cameraFromHinge: setup.rig(lidAngle: sensor.reading).rig.cameraFromHinge)
                        }
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
                    } else {
                        AutoHidingToolbar(isEdgeToEdge: isEdgeToEdge) { choosesCalibration in
                            ShowcaseToolbar(sensor: sensor, isEdgeToEdge: isEdgeToEdge,
                                            recenter: { anchorAngle = sensor.angle },
                                            fullScreen: { EdgeToEdge.shared.toggle() },
                                            lineUp: startLineUp,
                                            camera: { calibrate(cameraFromHinge: setup.rig(lidAngle: sensor.reading).rig.cameraFromHinge) },
                                            showControls: toggleControls,
                                            choosesCalibration: choosesCalibration)
                        }
                        .transition(.opacity)
                    }
                } else {
                    RGBColor(hex: backgroundColor).color
                }

                // Invisible, but give the window its X, F, R and Esc shortcuts.
                if mode == .full {
                    shortcuts
                }

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
            if mode == .demo || sceneName == "desert" { scene = ParallaxScene.desert() }
            if mode == .full, !imagePath.isEmpty, !useImage(at: URL(fileURLWithPath: imagePath)) { imagePath = "" }
        }
        // Asked for from the welcome, the menu bar or Settings, once the window knows where it is.
        .onChange(of: app.request, initial: true) { handleRequest() }
        .onChange(of: placement) { handleRequest() }
        .onChange(of: EdgeToEdge.shared.isActive) { handleRequest() }
        .sheet(isPresented: $asksForScreenRecording) {
            ScreenRecordingSheet()
        }
        .fileImporter(isPresented: $isChoosingImage, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result { useImage(at: url) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard mode == .full else { return false }
            return urls.first.map { useImage(at: $0) } ?? false
        } isTargeted: { isDropTargeted = mode == .full && $0 }
        .preferredColorScheme(.dark)
    }

    /// The window's single-key shortcuts: X for the controls, R to re-center, F for full screen.
    private var shortcuts: some View {
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
    }

    /// Handled by whichever copy is in view: the one full screen while that's up, else the window's.
    private func handleRequest() {
        guard mode == .full, isEdgeToEdge == EdgeToEdge.shared.isActive, let request = app.request, let placement
        else { return }
        app.request = nil
        switch request {
        case .lineUp:
            showsControls = false
            startLineUp()
        case .camera:
            let rig = Rig(lidAngle: sensor.reading, eyeDistance: eyeDistance, eyeHeight: eyeHeight, placement: placement)
            calibrate(cameraFromHinge: rig.cameraFromHinge)
        case .screenPermission:
            asksForScreenRecording = true
        }
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
            startLineUp: startLineUp,
            saveLineUp: { saveLineUp(setup) },
            finishLineUp: { lineUp.end() },
            cancelLineUp: cancelLineUp)
    }

    /// Re-centers the card here and starts lining it up by eye, from the eye saved now: the viewer's
    /// own, from the camera or an earlier line-up, or else where one usually is at a desk. The "From
    /// the screen" distance and looking-down settings aren't used; they only stand in for an eye, and
    /// are often left far from it.
    private func startLineUp() {
        let angle = sensor.angle
        lineUp.start(at: angle, from: (eyeDistance, eyeHeight),
                     previous: .init(viewpoint: viewpoint, eyeDistance: eyeDistance, eyeHeight: eyeHeight))
        anchorAngle = angle
        viewpoint = .eyes
        eyeDistance = lineUp.startingEye.distance
        eyeHeight = lineUp.startingEye.height
    }

    /// Keeps where the card is now as looking straight at this lid angle, and switches to the
    /// viewpoint that best explains every angle lined up so far.
    private func saveLineUp(_ setup: CardScene) {
        let angle = sensor.angle
        guard lineUp.isNew(angle) else {
            lineUp.note = "Move the lid at least \(Int(EyeLineUp.spacing))° further first."
            return
        }
        guard let corners = setup.pose(lidAngle: angle)?.corners else {
            lineUp.note = "Open the lid a little more."
            return
        }
        let sample = EyeLineUp.Sample(lidAngle: angle, corners: corners)
        guard let fit = setup.lineUpFit(lineUp.samples + [sample], anchor: lineUp.anchor, guess: lineUp.startingEye)
        else {
            lineUp.note = "That doesn't match a real viewing position. As the lid closes, the target's top "
                + "should run off the screen."
            return
        }
        // A first line-up that no eye quite draws took a big nudge, from a starting eye far off: the eye
        // it points to is only nearer the viewer's, so the card is drawn for that eye and the same angle
        // lined up again, now with a small nudge that moving the eye can match.
        if lineUp.samples.isEmpty, fit.error > EyeLineUp.firstSlack {
            eyeDistance = fit.eyeDistance
            eyeHeight = fit.eyeHeight
            lineUp.lean = 0
            lineUp.lift = 0
            lineUp.note = "Almost there. Line it up once more at this angle."
            return
        }
        // Once there are two angles, an eye that misses them by more than a steady hand does didn't
        // see them all, and saving it would spread that miss over every angle. A single angle can't
        // disagree with itself: what little it's missed by is only the nudges not being quite the
        // same as moving the eye.
        guard lineUp.samples.isEmpty || fit.error <= EyeLineUp.slack else {
            lineUp.note = "Those don't quite match. Close one eye, keep your head still, and try again."
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
            content = .layers(scene, sceneAtlases, clock: clockAtlas,
                              parallax: Parallax(strength: parallax, direction: parallaxDirection, motion: parallaxMotion))
        } else if scene == nil, let atlas {
            content = .picture(atlas, crops: fills && image != nil)
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
                              fillsWindow: fills, cornerRadius: cornerRadius,
                              background: RGBColor(hex: backgroundColor), blur: blurNow, dim: dimNow, content: content)
        scene.adjustment = lineUp.adjustment
        return scene
    }

    private func calibrate(cameraFromHinge: Double) {
        calibrator.start(cameraFromHinge: cameraFromHinge, lidAngle: { [sensor] in sensor.reading }) { distance, height in
            withAnimation(.easeInOut(duration: 0.4)) {
                viewpoint = .eyes
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

/// The everyday controls, floating under the picture: the lid's angle, re-centering, holding the whole
/// screen, calibrating, and the way to every control.
struct ShowcaseToolbar: View {
    var sensor: LidSensor
    var isEdgeToEdge: Bool
    var recenter: () -> Void
    var fullScreen: () -> Void
    var lineUp: () -> Void
    var camera: () -> Void
    var showControls: () -> Void
    @Binding var choosesCalibration: Bool

    @State private var angle: Double?

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 7) {
                LidGlyph(sensor: sensor)
                    .frame(width: LidGlyph.size.width, height: LidGlyph.size.height)
                Text(angle.map { $0.formatted(.number.precision(.fractionLength(0))) + "°" } ?? "–")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .frame(width: 36, alignment: .leading)
            }
            .padding(.leading, 8)
            .help("The lid's angle")
            PillButton(symbol: "scope", title: "Re-center", help: "Re-center the picture (R)", action: recenter)
            PillButton(symbol: "rectangle.on.rectangle", title: "Screen Effect",
                       help: "The effect on your whole screen (⌥⌘S)") { StillScreen.shared.turnOn() }
            HStack(spacing: 2) {
                PillButton(symbol: "camera", title: "Calibrate", help: "Calibrate with the camera", action: camera)
                RoundButton(symbol: "chevron.down", help: "More ways to calibrate") { choosesCalibration = true }
                    .popover(isPresented: $choosesCalibration, arrowEdge: .top) {
                        VStack(alignment: .leading, spacing: 8) {
                            OptionRow(symbol: "camera", title: "Calibrate with Camera", badge: "Recommended",
                                      detail: "Takes about 10 seconds.", isSelected: false) {
                                choosesCalibration = false
                                camera()
                            }
                            OptionRow(symbol: "hand.draw", title: "Calibrate by Eye",
                                      detail: "Line up a target at two angles.", isSelected: false) {
                                choosesCalibration = false
                                lineUp()
                            }
                        }
                        .padding(12)
                        .frame(width: 340)
                    }
            }
            PillButton(symbol: "slider.horizontal.3", title: "Controls", help: "All controls (X)", action: showControls)
            RoundButton(symbol: isEdgeToEdge ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                        help: isEdgeToEdge ? "Exit Full Screen (F)" : "Full Screen (F)",
                        action: fullScreen)
        }
        .padding(6)
        .font(.system(size: 12.5))
        // Solid and edged, not frosted or shadowed, like the control panel: it floats over the card.
        .background(Color(white: 0.105).opacity(0.97), in: .capsule)
        .overlay(Capsule().strokeBorder(.white.opacity(0.1)))
        .padding(1)
        .background(Color.black.opacity(0.35), in: .capsule)
        .environment(\.colorScheme, .dark)
        .task {
            while !Task.isCancelled {
                let now = sensor.angle
                if angle.map({ abs($0 - now) >= 0.5 }) ?? true { angle = now }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}

/// The toolbar, out of the way until it's wanted: it slides away after a few seconds without the
/// pointer moving, and comes back as soon as it moves. It's a view of its own, so following the
/// pointer redraws nothing else.
struct AutoHidingToolbar: View {
    var isEdgeToEdge: Bool
    var toolbar: (Binding<Bool>) -> ShowcaseToolbar

    @State private var isShown = true
    @State private var isHovered = false
    @State private var choosesCalibration = false
    /// When the pointer last moved, in a box, so moving it doesn't redraw anything by itself.
    @State private var lastMove = LastMove()

    private final class LastMove {
        var time = Date()
    }

    /// Seconds without the pointer moving before the toolbar goes.
    static let idle = 2.5

    var body: some View {
        ZStack(alignment: .bottom) {
            // Everywhere around it, only to notice the pointer moving.
            Color.clear
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    guard case .active = phase else { return }
                    lastMove.time = Date()
                    if !isShown { withAnimation(.easeOut(duration: 0.2)) { isShown = true } }
                }
            toolbar($choosesCalibration)
                .onHover { isHovered = $0 }
                .padding(.bottom, 20)
                .offset(y: isShown ? 0 : 90)
                .opacity(isShown ? 1 : 0)
                .allowsHitTesting(isShown)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                guard isShown, !isHovered, !choosesCalibration,
                      Date().timeIntervalSince(lastMove.time) > Self.idle
                else { continue }
                withAnimation(.easeInOut(duration: 0.35)) { isShown = false }
                // In full screen the pointer goes too, as in a video.
                if isEdgeToEdge { NSCursor.setHiddenUntilMouseMoves(true) }
            }
        }
    }
}

/// Asking for Screen Recording from the picture's window, when holding the screen was asked for
/// before it was allowed.
struct ScreenRecordingSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let permission = ScreenRecordingPermission.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Screen Effect")
                .font(.system(size: 22, weight: .bold))
            Text("The Duo effect on everything on your screen. It settles back when you stop tilting.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("It needs Screen Recording permission. Nothing is recorded, and nothing leaves your Mac.")
                .font(.system(size: 12.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            ScreenPermissionView()
            HStack {
                Spacer()
                Button(permission.isGranted ? "Done" : "Not Now") { dismiss() }
                    .buttonStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .font(.system(size: 13.5))
        .padding(26)
        .frame(width: 470)
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
