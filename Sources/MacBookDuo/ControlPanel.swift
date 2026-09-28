import SwiftUI

/// What the card shows.
enum PictureSource {
    case checkerboard, desert, image
}

/// What the panel's buttons do; the window carries them out.
struct PanelActions {
    var recenter: () -> Void
    var fillWindow: () -> Void
    var chooseImage: () -> Void
    var showCheckerboard: () -> Void
    var showDesert: () -> Void
    var calibrateWithCamera: () -> Void
    var toggleEdgeToEdge: () -> Void
    var hide: () -> Void
    var startLineUp: () -> Void
    var saveLineUp: () -> Void
    var finishLineUp: () -> Void
    var cancelLineUp: () -> Void
}

/// The floating settings panel. It edits the stored settings directly; the window reads the same ones.
///
/// A header that's always there shows the lid and holds the actions used most (re-center, full
/// screen, hide). Below it, four tabs: what's shown and how big, the Desert scene's own settings,
/// how it's blurred and dimmed, and whom it's drawn for.
struct ControlPanel: View {
    var setup: CardScene
    var sensor: LidSensor
    /// The card's real-world width in centimeters.
    var cardWidth: Double
    var source: PictureSource
    var image: CGImage?
    var checkerboard: CGImage?
    var canCalibrate: Bool
    var calibrator: EyeCalibrator
    /// The viewing distance `Viewpoint.screen` assumes unless it's been changed, in centimeters.
    var defaultViewingDistance: Double
    var isEdgeToEdge: Bool
    var lineUp: EyeLineUp
    var actions: PanelActions

    enum Tab: String, CaseIterable {
        case picture, scene, look, viewer

        var title: String {
            switch self {
            case .picture: "Picture"
            case .scene: "Scene"
            case .look: "Look"
            case .viewer: "Calibration"
            }
        }

        var symbol: String {
            switch self {
            case .picture: "photo.on.rectangle.angled"
            case .scene: "mountain.2"
            case .look: "camera.filters"
            case .viewer: "eye"
            }
        }
    }

    @AppStorage("panelTab") private var tab: Tab = .picture
    @AppStorage("cardSize") private var cardFill = 0.45
    @AppStorage("fillsWindow") private var fillsWindow = false
    @AppStorage("backgroundColor") private var backgroundColor = 0x000000
    @AppStorage("cornerRadius") private var cornerRadius = ControlPanel.defaultCornerRadius
    @AppStorage("parallax") private var parallax = 0.6
    @AppStorage("parallaxDirection") private var parallaxDirection: LidDirection = .either
    @AppStorage("parallaxMotion") private var parallaxMotion: ParallaxMotion = .toward
    @AppStorage("showsClock") private var showsClock = true
    @AppStorage("clockWeight") private var clockWeight = ClockStyle.phone.weight
    @AppStorage("clockWidth") private var clockWidth = ClockStyle.phone.width
    @AppStorage("clockStretch") private var clockStretch = ClockStyle.phone.stretch
    @AppStorage("clockOpacity") private var clockOpacity = 1.0
    @AppStorage("clockBlend") private var clockBlend: ClockBlend = .normal
    @AppStorage("clockDepth") private var clockDepth = 0.0
    @AppStorage("clockBlur") private var clockBlur = 0.0
    @AppStorage("eyeDistance") private var eyeDistance = 55.0
    @AppStorage("eyeHeight") private var eyeHeight = 35.0
    @AppStorage("viewpoint") private var viewpoint: Viewpoint = .screen
    @AppStorage("viewDistance") private var viewDistance = 0.0
    @AppStorage("viewLookingDown") private var lookingDown = Defaults.typicalLookingDown
    private var blur = StoredEffect.blur()
    private var dim = StoredEffect.dim()

    @State private var showsClockMotion = false
    @State private var showsMoreBlur = false
    @State private var showsMoreDim = false

    /// macOS doesn't say how round the screen's corners are, so this is an estimate for recent
    /// MacBooks, in millimeters; the slider is there to match it by eye.
    static let defaultCornerRadius = 3.0
    static let width: CGFloat = 372

    init(setup: CardScene, sensor: LidSensor, cardWidth: Double, source: PictureSource, image: CGImage?,
         checkerboard: CGImage?, canCalibrate: Bool, calibrator: EyeCalibrator, defaultViewingDistance: Double,
         isEdgeToEdge: Bool, lineUp: EyeLineUp, actions: PanelActions) {
        self.setup = setup
        self.sensor = sensor
        self.cardWidth = cardWidth
        self.source = source
        self.image = image
        self.checkerboard = checkerboard
        self.canCalibrate = canCalibrate
        self.calibrator = calibrator
        self.defaultViewingDistance = defaultViewingDistance
        self.isEdgeToEdge = isEdgeToEdge
        self.lineUp = lineUp
        self.actions = actions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            TabBar(selection: $tab)
            Group {
                switch tab {
                case .picture: pictureTab
                case .scene: sceneTab
                case .look: lookTab
                case .viewer: viewerTab
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12.5))
        .padding(14)
        .frame(width: Self.width)
        // Solid rather than frosted glass, and edged rather than shadowed: the window server would redo
        // either every frame over the moving card, and a shadow alone costs more than the card.
        .background(Color(white: 0.105).opacity(0.97), in: .rect(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.white.opacity(0.1)))
        .padding(1)
        .background(Color.black.opacity(0.35), in: .rect(cornerRadius: 19))
        .environment(\.colorScheme, .dark)
    }

    // MARK: Header

    private var header: some View {
        LiveReadout(scene: setup, sensor: sensor) {
            PillButton(symbol: "scope", title: "Re-center", help: "Re-center the picture (R)",
                       action: actions.recenter)
                .disabled(lineUp.isActive)
            RoundButton(symbol: isEdgeToEdge ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                        help: isEdgeToEdge ? "Exit Full Screen (F)" : "Full Screen (F)",
                        action: actions.toggleEdgeToEdge)
            RoundButton(symbol: "xmark", help: "Hide controls (X)", action: actions.hide)
        }
        .padding(.horizontal, 2)
    }

    // MARK: Picture

    private var pictureTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            PanelSection("Show") {
                HStack(spacing: 10) {
                    PictureTile(title: "Checkerboard", thumbnail: checkerboard.flatMap(Thumbnails.of),
                                isSelected: source == .checkerboard, action: actions.showCheckerboard)
                        .help("A test pattern: when the effect is right, the squares look square.")
                    PictureTile(title: "Desert", thumbnail: Thumbnails.desert, isSelected: source == .desert,
                                action: actions.showDesert)
                        .help("A layered desert scene, with a clock.")
                    PictureTile(title: image == nil ? "Your Image" : "Change…",
                                thumbnail: image.flatMap(Thumbnails.of), placeholder: "plus",
                                isSelected: source == .image, action: actions.chooseImage)
                        .help("Choose a picture, or drop one on the window.")
                }
                .padding(10)
            }


            PanelSection("Size") {
                PanelRow("Fill the window") {
                    Toggle("Fill the window", isOn: Binding(get: { fillsWindow },
                                                            set: { $0 ? actions.fillWindow() : (fillsWindow = false) }))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                }
                .help("Fill the window with the picture.")
                RowDivider()
                // Dragging the width takes the card back out of filling the window.
                SliderRow("Width", value: Binding(get: { cardFill }, set: { cardFill = $0; fillsWindow = false }),
                          in: 0.1...2.5, shown: cardWidth.formatted(.number.precision(.fractionLength(1))) + " cm")
            }

            PanelSection("Frame") {
                SliderRow("Corners", value: $cornerRadius, in: 0...10,
                          shown: cornerRadius.formatted(.number.precision(.fractionLength(1))) + " mm",
                          help: "Rounds the top corners to match your screen's.")
                RowDivider()
                PanelRow("Background") {
                    SwatchPicker(selection: $backgroundColor)
                }
            }
        }
    }

    // MARK: Scene

    @ViewBuilder
    private var sceneTab: some View {
        if source == .desert {
            VStack(alignment: .leading, spacing: 14) {
                    PanelSection("Parallax") {
                        SliderRow("Strength", value: $parallax, shown: percent(parallax),
                                  help: "How much the layers move as you tilt.")
                        RowDivider()
                        PanelRow("Direction") {
                            Picker("Direction", selection: $parallaxMotion) {
                                ForEach(ParallaxMotion.allCases, id: \.self) { Text($0.shortLabel).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .fixedSize()
                        }
                        .help("Toward you: the layers come closer as you tilt. Away: they start close and move back.")
                        RowDivider()
                        MenuRow("Moves when", selection: $parallaxDirection, options: LidDirection.allCases, label: \.label)
                            .help("Which way of tilting moves the layers.")
                    }

                    PanelSection("Clock", accessory: {
                        Toggle("Show the date and time", isOn: $showsClock)
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                            .labelsHidden()
                    }) {
                        if showsClock {
                            SliderRow("Width", value: $clockWidth, in: 30...150, shown: "\(Int(clockWidth.rounded()))",
                                      help: "30 is condensed, 150 is expanded.")
                            RowDivider()
                            SliderRow("Weight", value: $clockWeight, in: 100...900, shown: "\(Int(clockWeight.rounded()))",
                                      help: "100 is thin, 900 is heavy.")
                            RowDivider()
                            SliderRow("Height", value: $clockStretch, in: 1...2.2,
                                      shown: clockStretch.formatted(.number.precision(.fractionLength(1))) + "×",
                                      help: "Makes the numbers taller.")
                            RowDivider()
                            SliderRow("Opacity", value: $clockOpacity, shown: percent(clockOpacity))
                            RowDivider()
                            MenuRow("Blend", selection: $clockBlend, options: ClockBlend.allCases, label: \.label)
                                .help("How the clock blends with the sky.")
                            RowDivider()
                            DisclosureRow("Motion", isExpanded: $showsClockMotion)
                            if showsClockMotion {
                                RowDivider()
                                SliderRow("Depth", value: $clockDepth, shown: clockDepth < 0.005 ? "Fixed" : percent(clockDepth),
                                          help: "How much the clock moves with the layers.")
                                RowDivider()
                                SliderRow("Blur", value: $clockBlur, shown: clockBlur < 0.005 ? "Sharp" : percent(clockBlur),
                                          help: "How much the clock blurs with the scene.")
                            }
                        } else {
                            Text("The date and time, like a lock screen.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                        }
                    }
            }
        } else {
            PanelSection("Desert") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Sky, mountains and sand that move at different speeds, with a clock.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Show the Desert", action: actions.showDesert)
                }
                .padding(12)
            }
        }
    }

    // MARK: Look

    private var lookTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            effectSection("Blur", blur, verb: "Blurs", isExpanded: $showsMoreBlur)
            effectSection("Dim", dim, verb: "Dims", isExpanded: $showsMoreDim)
        }
    }

    private func effectSection(_ title: String, _ effect: StoredEffect, verb: String,
                               isExpanded: Binding<Bool>) -> some View {
        PanelSection(title) {
            SliderRow("Strength", value: effect.$strength, shown: effect.strength < 0.005 ? "Off" : percent(effect.strength),
                      help: verb == "Dims" ? "How dark it gets." : "How blurry it gets.")
            RowDivider()
            MenuRow("Follows", selection: effect.$edge, options: EffectEdge.allCases, label: \.label)
                .help("Depth goes by distance from the screen. An edge fades in from that side.")
            RowDivider()
            if effect.edge == .depth {
                SliderRow("Full at", value: effect.$spread, in: 0.05...1, shown: "\(Int(effect.fullDepth.rounded())) cm",
                          help: "How far from the screen it reaches full strength.")
            } else {
                SliderRow("Reach", value: effect.$spread, in: 0.05...StoredEffect.longestReach, shown: percent(effect.spread),
                          help: "How far in from the edge it goes.")
            }
            RowDivider()
            DisclosureRow("More", isExpanded: isExpanded)
            if isExpanded.wrappedValue {
                RowDivider()
                if effect.edge == .depth {
                    MenuRow("\(verb)", selection: effect.$depthSide, options: DepthSide.allCases, label: \.label)
                        .help("Farther than the screen, nearer, or both.")
                } else {
                    SliderRow("Lid reaction", value: effect.$lidReaction, shown: percent(effect.lidReaction),
                              help: "How much tilting brings it in. At 100%, there's none until you tilt.")
                    RowDivider()
                    MenuRow("Grows when", selection: effect.$lidDirection, options: LidDirection.allCases, label: \.label)
                        .disabled(effect.lidReaction == 0)
                }
            }
        }
    }

    // MARK: Viewer

    private var viewerTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            PanelSection("Using", accessory: {
                if viewpoint == .screen {
                    Button("Reset") {
                        viewDistance = 0
                        lookingDown = Defaults.typicalLookingDown
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                    .disabled(viewDistance == 0 && lookingDown == Defaults.typicalLookingDown)
                    .help("Back to the typical position.")
                }
            }) {
                Picker("Viewpoint", selection: $viewpoint) {
                    ForEach(Viewpoint.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .frame(maxWidth: .infinity)
                .padding(12)
                RowDivider()
                if viewpoint == .screen {
                    SliderRow("Distance", value: Binding(get: { viewDistance > 0 ? viewDistance : defaultViewingDistance },
                                                         set: { viewDistance = $0 }),
                              in: 25...120,
                              shown: "\(Int((viewDistance > 0 ? viewDistance : defaultViewingDistance).rounded())) cm",
                              help: "How far your eyes are from the screen.")
                    RowDivider()
                    SliderRow("Looking down", value: $lookingDown, in: -20...45, shown: "\(Int(lookingDown.rounded()))°",
                              help: "How far above the screen's center you look from.")
                } else {
                    SliderRow("Eye distance", value: $eyeDistance, in: EyeCalibrator.distanceRange,
                              shown: "\(Int(eyeDistance.rounded())) cm",
                              help: "How far your eyes are in front of the hinge.")
                    RowDivider()
                    SliderRow("Eye height", value: $eyeHeight, in: EyeCalibrator.heightRange,
                              shown: "\(Int(eyeHeight.rounded())) cm",
                              help: "How high your eyes are above the hinge.")
                }
            }

            PanelSection("Calibrate") {
                CalibrationRow(symbol: "camera", title: "Calibrate with Camera", detail: cameraMessage,
                               button: calibrator.isMeasuring ? "Stop" : "Start",
                               action: calibrator.isMeasuring ? calibrator.cancel : actions.calibrateWithCamera)
                    .disabled(!canCalibrate && !calibrator.isMeasuring)
                if case .measuring(let progress, _) = calibrator.phase {
                    ProgressView(value: progress)
                        .controlSize(.small)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                }
                RowDivider()
                CalibrationRow(symbol: "hand.draw", title: "Calibrate by Eye",
                               detail: lineUp.fit.map(\.summary) ?? "Line up a target at two angles.",
                               button: "Start", action: actions.startLineUp)
            }
        }
    }

    private var cameraMessage: String {
        switch calibrator.phase {
        case .idle:
            canCalibrate ? "Takes about 10 seconds." : "Needs your MacBook's screen."
        case .measuring(_, let seesFace):
            seesFace ? "Keep your head still and slowly tilt." : "Finding your face…"
        case .finished(let distance, let height):
            "Your eyes: \(Int(distance.rounded())) cm away, \(Int(height.rounded())) cm up."
        case .failed(let message):
            message
        }
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

extension ParallaxMotion {
    var shortLabel: String {
        switch self {
        case .toward: "Toward you"
        case .away: "Away"
        }
    }
}

// MARK: - Building blocks

/// A titled group of rows on a slightly lighter card.
struct PanelSection<Content: View, Accessory: View>: View {
    var title: String
    var accessory: Accessory
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title.uppercased())
                    .font(.system(size: 10.5, weight: .semibold))
                    .kerning(0.6)
                    .foregroundStyle(.secondary)
                Spacer()
                accessory
            }
            .padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .background(Color.white.opacity(0.045), in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.05)))
        }
    }
}

extension PanelSection where Accessory == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(title, accessory: { EmptyView() }, content: content)
    }
}

/// A few colors to pick from with one click, the chosen one ringed.
struct SwatchPicker: View {
    @Binding var selection: Int

    static let colors: [(name: String, hex: Int)] = [
        ("Black", 0x000000), ("Graphite", 0x1C1C1E), ("Gray", 0x636366), ("White", 0xF2F2F2),
        ("Night", 0x141B2D), ("Dusk", 0x3A2140), ("Sand", 0xC49A74),
    ]

    var body: some View {
        HStack(spacing: 7) {
            ForEach(Self.colors, id: \.hex) { color in
                Button { selection = color.hex } label: {
                    Circle()
                        .fill(Color(hex: UInt32(color.hex)))
                        .overlay(Circle().strokeBorder(.white.opacity(0.18)))
                        .frame(width: 18, height: 18)
                        .padding(3)
                        .overlay(Circle().strokeBorder(Color.duo, lineWidth: 2).opacity(selection == color.hex ? 1 : 0))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(color.name)
                .accessibilityLabel(color.name)
                .accessibilityAddTraits(selection == color.hex ? .isSelected : [])
            }
        }
    }
}

/// A label on the left and a control on the right.
struct PanelRow<Control: View>: View {
    var title: String
    @ViewBuilder var control: Control

    init(_ title: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
            Spacer(minLength: 8)
            control
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 34)
    }
}

/// A labeled slider with its value on the right.
struct SliderRow: View {
    var title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var shown: String
    var help: String?

    init(_ title: String, value: Binding<Double>, in range: ClosedRange<Double> = 0...1, shown: String,
         help: String? = nil) {
        self.title = title
        _value = value
        self.range = range
        self.shown = shown
        self.help = help
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .frame(width: 92, alignment: .leading)
            Slider(value: $value, in: range)
                .controlSize(.small)
            Text(shown)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 50, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 34)
        .help(help ?? title)
    }
}

/// A label with a pop-up menu of choices on the right.
struct MenuRow<Option: Hashable>: View {
    var title: String
    @Binding var selection: Option
    var options: [Option]
    var label: (Option) -> String

    init(_ title: String, selection: Binding<Option>, options: [Option], label: @escaping (Option) -> String) {
        self.title = title
        _selection = selection
        self.options = options
        self.label = label
    }

    var body: some View {
        PanelRow(title) {
            Picker(title, selection: $selection) {
                ForEach(options, id: \.self) { Text(label($0)).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        }
    }
}

/// A row that shows or hides the rows after it.
struct DisclosureRow: View {
    var title: String
    @Binding var isExpanded: Bool

    init(_ title: String, isExpanded: Binding<Bool>) {
        self.title = title
        _isExpanded = isExpanded
    }

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
        } label: {
            HStack {
                Text(title)
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 30)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// A hairline between rows.
struct RowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.06))
            .frame(height: 1)
            .padding(.leading, 12)
    }
}

/// A way to calibrate: what it is and a button to start it.
struct CalibrationRow: View {
    var symbol: String
    var title: String
    var detail: String
    var button: String
    var action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Button(button, action: action)
                .controlSize(.small)
        }
        .padding(12)
    }
}

/// A picture the card can show, as a small tile.
struct PictureTile: View {
    var title: String
    var thumbnail: CGImage?
    var placeholder = "photo"
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Color.white.opacity(0.06)
                    if let thumbnail {
                        Image(decorative: thumbnail, scale: 2)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: placeholder)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(height: 64)
                .frame(maxWidth: .infinity)
                .clipShape(.rect(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(isSelected ? Color.accentColor : .white.opacity(0.1), lineWidth: isSelected ? 2 : 1))
                Text(title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The panel's tabs, as icons with labels.
struct TabBar: View {
    @Binding var selection: ControlPanel.Tab

    var body: some View {
        HStack(spacing: 3) {
            ForEach(ControlPanel.Tab.allCases, id: \.self) { tab in
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 14, weight: .medium))
                            .frame(height: 17)
                        Text(tab.title)
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .foregroundStyle(selection == tab ? Color.accentColor : .secondary)
                    .background(selection == tab ? Color.white.opacity(0.09) : .clear, in: .rect(cornerRadius: 9))
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Color.white.opacity(0.04), in: .rect(cornerRadius: 12))
    }
}

/// An icon and a label in a capsule, for the header's main action.
struct PillButton: View {
    var symbol: String
    var title: String
    var help: String
    var action: () -> Void
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 11.5, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(Color.white.opacity(isHovered && isEnabled ? 0.15 : 0.07), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? .primary : .tertiary)
        .onHover { isHovered = $0 }
        .help(help)
    }
}

/// A small round icon button, for the header.
struct RoundButton: View {
    var symbol: String
    var help: String
    var action: () -> Void
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .background(Color.white.opacity(isHovered && isEnabled ? 0.15 : 0.07), in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? .primary : .tertiary)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// How far through a few steps something is.
struct StepDots: View {
    var done: Int
    var total: Int

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<total, id: \.self) { step in
                Capsule()
                    .fill(step < done ? Color.duo : Color.white.opacity(0.18))
                    .frame(width: step == done - 1 ? 16 : 6, height: 6)
            }
        }
        .accessibilityLabel("Step \(done) of \(total)")
    }
}

/// Small pictures of what the card can show, made once each.
@MainActor
enum Thumbnails {
    /// Twice the size a tile draws them, for the Retina display.
    private static let size = CGSize(width: 212, height: 128)
    private static var made: [(source: CGImage, thumbnail: CGImage)] = []

    /// `image` shrunk to fill a tile.
    static func of(_ image: CGImage) -> CGImage? {
        if let known = made.first(where: { $0.source === image }) { return known.thumbnail }
        let scale = max(size.width / Double(image.width), size.height / Double(image.height))
        let drawn = CGSize(width: Double(image.width) * scale, height: Double(image.height) * scale)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2,
                                       width: drawn.width, height: drawn.height))
        guard let thumbnail = context.makeImage() else { return nil }
        // Keeping the source keeps its identity from being reused by another picture.
        made = Array((made + [(image, thumbnail)]).suffix(3))
        return thumbnail
    }

    /// The desert scene's layers at rest.
    static let desert: CGImage? = {
        guard let scene = ParallaxScene.desert() else { return nil }
        let preview = ZStack(alignment: .topLeading) {
            ForEach(scene.layers.indices, id: \.self) { index in
                let rect = ParallaxScene.rect(for: scene.layers[index], cardAspect: size.width / size.height, closer: 0)
                Image(decorative: scene.layers[index].image, scale: 1)
                    .resizable()
                    .frame(width: rect.width * size.width, height: rect.height * size.height)
                    .offset(x: rect.minX * size.width, y: rect.minY * size.height)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
        let renderer = ImageRenderer(content: preview)
        renderer.scale = 1
        return renderer.cgImage
    }()
}

/// The laptop from the side, two lines: the base lying flat and the lid at its angle, following it
/// every frame. With a `target`, a dashed line shows where to move the lid, and the lid turns
/// green within `tolerance` degrees of it. The lid is a layer that's turned, rather than a view
/// that's redrawn, so it moves smoothly without drawing the panel again.
struct LidGlyph: NSViewRepresentable {
    var sensor: LidSensor
    var target: Double? = nil
    var tolerance = 5.0
    var lineWidth: CGFloat = 2.5

    static let size = CGSize(width: 34, height: 26)

    func makeNSView(context: Context) -> GlyphView {
        let view = GlyphView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: GlyphView, context: Context) {
        view.sensor = sensor
        view.lineWidth = lineWidth
        view.tolerance = tolerance
        view.target = target
    }

    final class GlyphView: NSView {
        var sensor: LidSensor?
        var lineWidth: CGFloat = 2.5 { didSet { if lineWidth != oldValue { needsLayout = true } } }
        var tolerance = 5.0
        var target: Double? { didSet { if target != oldValue { shownAngle = nil; needsLayout = true } } }
        private let base = CAShapeLayer()
        private let lid = CAShapeLayer()
        private let aim = CAShapeLayer()
        private var link: CADisplayLink?
        private var shownAngle: Double?
        private var colors = (base: CGColor.black, lid: CGColor.black, onTarget: CGColor.black, aim: CGColor.black)

        override init(frame: NSRect) {
            super.init(frame: frame)
            // Hosting the layers itself, so AppKit never redraws anything here.
            layer = CALayer()
            wantsLayer = true
            for line in [aim, base, lid] {
                line.lineCap = .round
                line.fillColor = nil
                line.actions = ["transform": NSNull(), "strokeColor": NSNull(), "path": NSNull(),
                                "position": NSNull(), "hidden": NSNull()]
                layer?.addSublayer(line)
            }
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override var intrinsicContentSize: NSSize { LidGlyph.size }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// The hinge sits a little left of middle, so the lid has room to lean back past upright.
        override func layout() {
            super.layout()
            let hinge = CGPoint(x: bounds.width * 0.38, y: lineWidth / 2 + 2)
            let length = min(bounds.width * 0.56, bounds.height - lineWidth - 3)
            let flat = CGMutablePath()
            flat.move(to: hinge)
            flat.addLine(to: CGPoint(x: hinge.x + length, y: hinge.y))
            base.path = flat
            // The lid and the aim are drawn lying along the base from the hinge, then turned about it.
            let along = CGMutablePath()
            along.move(to: .zero)
            along.addLine(to: CGPoint(x: length, y: 0))
            for line in [lid, aim] {
                line.path = along
                line.position = hinge
                line.lineWidth = lineWidth
            }
            base.lineWidth = lineWidth
            aim.lineDashPattern = [NSNumber(value: Double(lineWidth) * 1.2), NSNumber(value: Double(lineWidth) * 1.6)]
            aim.isHidden = target == nil
            if let target { aim.setAffineTransform(CGAffineTransform(rotationAngle: target * .pi / 180)) }
            shownAngle = nil
            if let link { step(link) }
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            effectiveAppearance.performAsCurrentDrawingAppearance {
                colors = (NSColor.tertiaryLabelColor.cgColor, NSColor.labelColor.cgColor,
                          NSColor.systemGreen.cgColor, NSColor.controlAccentColor.cgColor)
            }
            base.strokeColor = colors.base
            aim.strokeColor = colors.aim
            shownAngle = nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            link?.invalidate()
            link = nil
            guard let window else { return }
            for line in [base, lid, aim] { line.contentsScale = window.backingScaleFactor }
            viewDidChangeEffectiveAppearance()
            let link = displayLink(target: self, selector: #selector(step(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
            step(link)
        }

        @objc private func step(_ link: CADisplayLink) {
            guard let angle = sensor?.angle, angle != shownAngle else { return }
            shownAngle = angle
            lid.setAffineTransform(CGAffineTransform(rotationAngle: angle * .pi / 180))
            let onTarget = target.map { abs($0 - angle) <= tolerance } ?? false
            lid.strokeColor = onTarget ? colors.onTarget : colors.lid
        }
    }
}
