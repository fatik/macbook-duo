import SwiftUI

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
    @State private var sensor = LidSensor()
    @State private var placement: ScreenPlacement?
    /// The lid angle at which the card was put in place; it stays at that spot in space from then on.
    @State private var anchorAngle: Double?
    @AppStorage("mode") private var mode: CardMode = .facing
    @AppStorage("eyeDistance") private var eyeDistance = 55.0
    @AppStorage("eyeHeight") private var eyeHeight = 35.0

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let cardWidth = min(size.width * 0.42, size.height * 0.5)
            let cardSize = CGSize(width: cardWidth, height: cardWidth * 2 / 3)

            ZStack {
                Color(red: 0.055, green: 0.06, blue: 0.08)
                DotGrid()
                PlacementReader { placement = $0 }

                if let placement, sensor.isAvailable {
                    let rig = Rig(lidAngle: sensor.angle, eyeDistance: eyeDistance, eyeHeight: eyeHeight,
                                  placement: placement)
                    let cardFrame = CGRect(x: placement.frame.minX + (size.width - cardSize.width) / 2,
                                           y: placement.frame.minY + (size.height - cardSize.height) / 2,
                                           width: cardSize.width, height: cardSize.height)

                    let anchor = anchorAngle ?? sensor.angle
                    let pose = rig.cardPose(frame: cardFrame, mode: mode, anchorAngle: anchor)
                    // The card is drawn at its laid-out size and then warped, so render it bigger
                    // when it's stretched to keep it sharp.
                    let sharpness = pose.map { pose in
                        let box = pose.boundingBox
                        let stretch = max(box.width / cardSize.width, box.height / cardSize.height)
                        return min(max((stretch - 0.1).rounded(.up), 1), 4)
                    } ?? 1
                    let renderFrame = cardFrame.insetBy(dx: -cardSize.width * (sharpness - 1) / 2,
                                                        dy: -cardSize.height * (sharpness - 1) / 2)
                    let transform = pose?.transform(from: renderFrame)

                    // Hidden rather than drawn uncorrected when the lid is too far closed to draw it.
                    Color.clear.overlay {
                        CheckerCard(lineWidth: 4 * sharpness)
                            .frame(width: renderFrame.width, height: renderFrame.height)
                            .projectionEffect(transform ?? ProjectionTransform())
                            .opacity(transform == nil ? 0 : 1)
                    }

                    VStack {
                        Spacer()
                        ControlPanel(mode: $mode, eyeDistance: $eyeDistance, eyeHeight: $eyeHeight,
                                     status: status(rig: rig, pose: pose, placement: placement, anchor: anchor),
                                     recenter: { anchorAngle = sensor.angle })
                    }
                    .padding(16)
                } else if !sensor.isAvailable {
                    Text("No lid angle sensor found")
                        .font(.title2.weight(.semibold))
                }
            }
        }
        .ignoresSafeArea()
        .onAppear { anchorAngle = sensor.angle }
        .preferredColorScheme(.dark)
        .frame(minWidth: 520, minHeight: 480)
    }

    private func status(rig: Rig, pose: CardPose?, placement: ScreenPlacement, anchor: Double) -> String {
        guard placement.isBuiltIn else { return "Move this window to the built-in display" }
        let lid = "Lid \(rig.lidAngle.formatted(.number.precision(.fractionLength(1))))°"
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

struct ControlPanel: View {
    @Binding var mode: CardMode
    @Binding var eyeDistance: Double
    @Binding var eyeHeight: Double
    var status: String
    var recenter: () -> Void

    var body: some View {
        VStack(spacing: 12) {
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
                    Text("Eye distance").gridColumnAlignment(.leading)
                    Slider(value: $eyeDistance, in: 25...100)
                    Text("\(Int(eyeDistance)) cm").monospacedDigit().gridColumnAlignment(.trailing)
                }
                GridRow {
                    Text("Eye height")
                    Slider(value: $eyeHeight, in: 0...70)
                    Text("\(Int(eyeHeight)) cm").monospacedDigit()
                }
            }
            .font(.callout)

            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(14)
        .frame(width: 440)
        .background(.regularMaterial, in: .rect(cornerRadius: 14))
    }
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

/// Faint dots that sit flat on the screen, so the card's correction reads against them.
struct DotGrid: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 28
            var dots = Path()
            for x in stride(from: spacing / 2, to: size.width, by: spacing) {
                for y in stride(from: spacing / 2, to: size.height, by: spacing) {
                    dots.addEllipse(in: CGRect(x: x - 1.25, y: y - 1.25, width: 2.5, height: 2.5))
                }
            }
            context.fill(dots, with: .color(.white.opacity(0.14)))
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}
