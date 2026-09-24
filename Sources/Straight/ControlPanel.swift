import SwiftUI

/// The floating settings panel. It edits the stored settings directly; the window reads the same ones.
struct ControlPanel: View {
    /// The card's real-world width in centimeters.
    var cardWidth: Double
    var hasImage: Bool
    var canCalibrate: Bool
    var calibrator: EyeCalibrator
    /// The viewing distance `Viewpoint.screen` assumes unless it's been changed, in centimeters.
    var defaultViewingDistance: Double
    var status: String
    var recenter: () -> Void
    var fillWindow: () -> Void
    var chooseImage: () -> Void
    var clearImage: () -> Void
    var hasScene: Bool
    var useScene: () -> Void
    var calibrate: () -> Void
    var isEdgeToEdge: Bool
    var toggleEdgeToEdge: () -> Void
    var hide: () -> Void

    enum Tab: String, CaseIterable {
        case card = "Card", scene = "Scene", effects = "Effects", viewer = "Viewer"
    }

    @AppStorage("panelTab") private var tab: Tab = .card
    @AppStorage("mode") private var mode: CardMode = .facing
    @AppStorage("cardSize") private var cardFill = 0.45
    @AppStorage("fillsWindow") private var fillsWindow = false
    @AppStorage("cornerRadius") private var cornerRadius = ControlPanel.defaultCornerRadius
    @AppStorage("parallax") private var parallax = 0.6
    @AppStorage("parallaxDirection") private var parallaxDirection: LidDirection = .either
    @AppStorage("showsClock") private var showsClock = true
    @AppStorage("clockWeight") private var clockWeight = ClockStyle.phone.weight
    @AppStorage("clockWidth") private var clockWidth = ClockStyle.phone.width
    @AppStorage("clockStretch") private var clockStretch = ClockStyle.phone.stretch
    @AppStorage("clockOpacity") private var clockOpacity = 1.0
    @AppStorage("clockBlend") private var clockBlend: ClockBlend = .normal

    /// macOS doesn't say how round the screen's corners are, so this is an estimate for recent
    /// MacBooks, in millimeters; the slider is there to match it by eye.
    static let defaultCornerRadius = 3.0
    @AppStorage("eyeDistance") private var eyeDistance = 55.0
    @AppStorage("eyeHeight") private var eyeHeight = 35.0
    @AppStorage("viewpoint") private var viewpoint: Viewpoint = .screen
    @AppStorage("viewSensitivity") private var sensitivity = 1.0
    @AppStorage("viewDistance") private var viewDistance = 0.0
    @AppStorage("viewLookingDown") private var lookingDown = 0.0
    private var blur = StoredEffect("blur", edge: .top)

    init(cardWidth: Double, hasImage: Bool, canCalibrate: Bool, calibrator: EyeCalibrator,
         defaultViewingDistance: Double, status: String,
         recenter: @escaping () -> Void, fillWindow: @escaping () -> Void,
         chooseImage: @escaping () -> Void, clearImage: @escaping () -> Void,
         hasScene: Bool, useScene: @escaping () -> Void,
         calibrate: @escaping () -> Void, isEdgeToEdge: Bool, toggleEdgeToEdge: @escaping () -> Void,
         hide: @escaping () -> Void) {
        self.cardWidth = cardWidth
        self.hasImage = hasImage
        self.canCalibrate = canCalibrate
        self.calibrator = calibrator
        self.defaultViewingDistance = defaultViewingDistance
        self.status = status
        self.recenter = recenter
        self.fillWindow = fillWindow
        self.chooseImage = chooseImage
        self.clearImage = clearImage
        self.hasScene = hasScene
        self.useScene = useScene
        self.calibrate = calibrate
        self.isEdgeToEdge = isEdgeToEdge
        self.toggleEdgeToEdge = toggleEdgeToEdge
        self.hide = hide
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Section", selection: $tab) {
                    ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Spacer()

                Button(action: toggleEdgeToEdge) {
                    Image(systemName: isEdgeToEdge
                          ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.body.weight(.semibold))
                        .frame(width: 24, height: 24)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .help(isEdgeToEdge ? "Leave full screen (F or Esc)" : "Full screen, edge to edge (F)")
                .accessibilityLabel(isEdgeToEdge ? "Leave full screen" : "Full screen")

                Button(action: hide) {
                    Image(systemName: "xmark")
                        .font(.body.weight(.semibold))
                        .frame(width: 24, height: 24)
                        .contentShape(.rect)
                }
                .buttonStyle(.borderless)
                .help("Hide controls (X)")
                .accessibilityLabel("Hide controls")
            }

            switch tab {
            case .card: cardControls
            case .scene: sceneControls
            case .effects: effectControls
            case .viewer: viewerControls
            }

            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(14)
        .frame(width: 440)
        // Solid rather than frosted glass: frosting would re-blur the moving card behind it every frame.
        .background(Color(white: 0.12).opacity(0.94), in: .rect(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.08)))
    }

    private var cardControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Card", selection: $mode) {
                    ForEach(CardMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Button("Re-center", action: recenter)
                    .disabled(mode == .flat)
            }

            Grid(horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("Card width").gridColumnAlignment(.leading)
                    // Dragging the width takes the card back out of filling the window.
                    Slider(value: Binding(get: { cardFill }, set: { cardFill = $0; fillsWindow = false }),
                           in: 0.1...2.5)
                    valueLabel("\(cardWidth.formatted(.number.precision(.fractionLength(1)))) cm")
                }
                GridRow {
                    Text("Corners")
                    Slider(value: $cornerRadius, in: 0...10)
                    valueLabel("\(cornerRadius.formatted(.number.precision(.fractionLength(1)))) mm")
                }
                .help("Rounds the card's corners. To match your screen's own: Fill Window at your usual angle, "
                      + "then adjust until the card's top corners sit exactly in the screen's rounded corners.")
            }
            .font(.callout)

            Button("Fill Window", action: fillWindow)
                .help("Stretch the card over the whole window, held in place from the current lid angle.")

            HStack {
                Button(hasImage ? "Change Image…" : "Choose Image…", action: chooseImage)
                    .help("Or drop an image on the window.")
                Button("Desert Scene", action: useScene)
                    .disabled(hasScene)
                    .help("A layered picture: sand, mountains and sky come toward you at different speeds as "
                          + "the lid moves, while the clock stays put.")
                if hasImage || hasScene {
                    Button("Checkerboard", action: clearImage)
                }
            }
        }
    }

    private var sceneControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !hasScene {
                HStack {
                    Button("Desert Scene", action: useScene)
                    Text("A layered picture whose layers come toward you as the lid moves.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    GridRow {
                        Text("Parallax")
                        Slider(value: $parallax)
                        valueLabel(percent(parallax))
                    }
                    .help("How strongly the layers come toward you as the lid moves: the sand most, the "
                          + "mountains less, the sky barely.")
                    GridRow {
                        Text("Comes closer")
                        Picker("Comes closer", selection: $parallaxDirection) {
                            ForEach(LidDirection.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .fixedSize()
                        .gridCellColumns(2)
                    }

                    Divider().padding(.vertical, 4)

                    GridRow {
                        Text("Clock").font(.headline)
                        Toggle("Show the date and time", isOn: $showsClock)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                            .gridCellColumns(2)
                            .gridCellAnchor(.trailing)
                    }
                    if showsClock {
                        GridRow {
                            Text("Width")
                            Slider(value: $clockWidth, in: 30...150)
                            valueLabel("\(Int(clockWidth.rounded()))")
                        }
                        .help("SF Pro's width axis: 30 is very compressed, 100 normal, 150 very expanded.")
                        GridRow {
                            Text("Weight")
                            Slider(value: $clockWeight, in: 100...900)
                            valueLabel("\(Int(clockWeight.rounded()))")
                        }
                        .help("SF Pro's weight axis: 100 is thin, 400 regular, 900 heavy.")
                        GridRow {
                            Text("Height")
                            Slider(value: $clockStretch, in: 1...2.2)
                            valueLabel("\(clockStretch.formatted(.number.precision(.fractionLength(1))))×")
                        }
                        .help("Stretches the numerals taller, like a lock screen's clock.")
                        GridRow {
                            Text("Opacity")
                            Slider(value: $clockOpacity)
                            valueLabel(percent(clockOpacity))
                        }
                        GridRow {
                            Text("Blend")
                            Picker("Blend", selection: $clockBlend) {
                                ForEach(ClockBlend.allCases, id: \.self) { Text($0.label).tag($0) }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .fixedSize()
                            .gridCellColumns(2)
                        }
                        .help("How the clock mixes with the picture behind it. Plus Lighter and Screen let the "
                              + "sky's color show through, like frosted glass.")
                    }
                }
                .font(.callout)
            }
        }
    }

    private var effectControls: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
            effectRows("Blur", blur)
        }
        .font(.callout)
    }

    @ViewBuilder
    private func effectRows(_ title: String, _ effect: StoredEffect) -> some View {
        GridRow {
            Text(title).font(.headline)
            Picker("Based on", selection: effect.$edge) {
                ForEach(EffectEdge.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .gridCellColumns(2)
            .gridCellAnchor(.trailing)
        }
        GridRow {
            Text("Strength")
            Slider(value: effect.$strength)
            valueLabel(percent(effect.strength))
        }
        GridRow {
            Text("Dim")
            Slider(value: effect.$dim)
            valueLabel(percent(effect.dim))
        }
        .help("How much the blurred parts also darken, most where the blur is strongest. "
              + "At 100% they go black where the blur is full.")

        if effect.edge == .depth {
            // Depth already moves with the lid, so there's no lid reaction to set.
            GridRow {
                Text("Full at")
                Slider(value: effect.$spread, in: 0.05...1)
                valueLabel("\(Int(effect.fullDepth.rounded())) cm")
            }
            .help("How much farther away (or nearer) than the screen a part has to be to get the full blur. "
                  + "What's in focus stays sharp.")
            GridRow {
                Text("Blurs")
                Picker("Blurs", selection: effect.$depthSide) {
                    ForEach(DepthSide.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .gridCellColumns(2)
            }
        } else {
            GridRow {
                Text("Reach")
                Slider(value: effect.$spread, in: 0.05...1)
                valueLabel(percent(effect.spread))
            }
            .help("How far in from the edge it goes, at most.")
            GridRow {
                Text("Lid reaction")
                Slider(value: effect.$lidReaction)
                valueLabel(percent(effect.lidReaction))
            }
            .help("How much the lid slides the effect in. At 0% it stays put. At 100% there's none at the anchored "
                  + "angle, and it slides in from the edge as the lid moves, all the way after "
                  + "\(Int(StoredEffect.fullReachAfter))°.")
            GridRow {
                Text("Grows when")
                Picker("Grows when", selection: effect.$lidDirection) {
                    ForEach(LidDirection.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .gridCellColumns(2)
                .disabled(effect.lidReaction == 0)
            }
        }
    }

    private var viewerControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Viewpoint", selection: $viewpoint) {
                    ForEach(Viewpoint.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Button("Reset") {
                    sensitivity = 1
                    viewDistance = 0
                    lookingDown = 0
                }
                .disabled(sensitivity == 1 && viewDistance == 0 && lookingDown == 0)
            }

            Grid(horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("Sensitivity").gridColumnAlignment(.leading)
                    Slider(value: $sensitivity, in: 0.25...2)
                    valueLabel(percent(sensitivity))
                }
                .help("How much the lid's movement counts. Raise it if the picture doesn't move enough to stay "
                      + "put as you tilt the lid, lower it if it moves too much.")
                if viewpoint == .screen {
                    GridRow {
                        Text("Distance")
                        Slider(value: Binding(get: { viewDistance > 0 ? viewDistance : defaultViewingDistance },
                                              set: { viewDistance = $0 }),
                               in: 25...120)
                        valueLabel("\(Int((viewDistance > 0 ? viewDistance : defaultViewingDistance).rounded())) cm")
                    }
                    .help("How far your eyes are from the screen. Closer makes its far edge's size change more "
                          + "as the lid moves.")
                }
                if viewpoint == .screen {
                    GridRow {
                        Text("Looking down")
                        Slider(value: $lookingDown, in: -20...45)
                        valueLabel("\(Int(lookingDown.rounded()))°")
                    }
                    .help("How far above square-on you look at the screen from, at the anchored angle. Tune it if "
                          + "closing the lid and opening it don't feel equally right.")
                }
            }
            .font(.callout)

            if viewpoint == .eyes {
                eyeControls
            } else {
                Text("Worked out from the screen's size and the lid angle, as if the screen faced you when the "
                     + "card was anchored. Re-center at the angle you like.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var eyeControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("Eye distance").gridColumnAlignment(.leading)
                    Slider(value: $eyeDistance, in: EyeCalibrator.distanceRange)
                    valueLabel("\(Int(eyeDistance.rounded())) cm")
                }
                GridRow {
                    Text("Eye height")
                    Slider(value: $eyeHeight, in: EyeCalibrator.heightRange)
                    valueLabel("\(Int(eyeHeight.rounded())) cm")
                }
            }
            .font(.callout)

            HStack(alignment: .firstTextBaseline) {
                if calibrator.isMeasuring {
                    Button("Cancel", action: calibrator.cancel)
                } else {
                    Button("Calibrate with Camera", action: calibrate)
                        .disabled(!canCalibrate)
                }
                Text(calibrationMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if case .measuring(let progress, _) = calibrator.phase {
                ProgressView(value: progress)
            }
        }
    }

    private var calibrationMessage: String {
        switch calibrator.phase {
        case .idle:
            canCalibrate
                ? "Measures where your eyes are while you tilt the screen."
                : "Move this window to the built-in display to calibrate."
        case .measuring(_, let seesFace):
            seesFace
                ? "Keep your head still and slowly tilt the screen back and forth."
                : "Looking for your face…"
        case .finished(let distance, let height):
            "Your eyes are \(Int(distance.rounded())) cm in front of the hinge and \(Int(height.rounded())) cm above it."
        case .failed(let message):
            message
        }
    }

    private func valueLabel(_ text: String) -> some View {
        Text(text)
            .monospacedDigit()
            .frame(minWidth: 52, alignment: .trailing)
            .gridColumnAlignment(.trailing)
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}
