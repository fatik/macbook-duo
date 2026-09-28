import SwiftUI

/// A picture for lining the card up by eye: a grid of squares, a rectangle and a circle, which look
/// square and round only when the card is drawn for where your eyes really are.
struct CalibrationTarget: View {
    var body: some View {
        Canvas { context, size in
            let unit = size.height / 8
            let line = max(size.height / 260, 1.5)
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(red: 0.07, green: 0.08, blue: 0.1)))

            // Squares, centered, to judge the perspective by.
            var grid = Path()
            let columns = Int((size.width / unit).rounded(.up)) + 1
            let left = size.width / 2 - Double(columns / 2) * unit
            for column in 0...columns {
                let x = left + Double(column) * unit
                grid.move(to: CGPoint(x: x, y: 0))
                grid.addLine(to: CGPoint(x: x, y: size.height))
            }
            for row in 0...8 {
                grid.move(to: CGPoint(x: 0, y: Double(row) * unit))
                grid.addLine(to: CGPoint(x: size.width, y: Double(row) * unit))
            }
            context.stroke(grid, with: .color(.white.opacity(0.13)), lineWidth: line)

            // A rectangle inset from the edges, and a circle in the upper middle, clear of the guide.
            let inset = CGRect(origin: .zero, size: size).insetBy(dx: unit * 0.5, dy: unit * 0.5)
            context.stroke(Path(roundedRect: inset, cornerRadius: unit * 0.15), with: .color(.white.opacity(0.9)),
                           lineWidth: line * 2.5)
            let center = CGPoint(x: size.width / 2, y: unit * 3.25)
            let radius = unit * 2.25
            context.stroke(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                  width: radius * 2, height: radius * 2)),
                           with: .color(Color(red: 0.35, green: 0.78, blue: 1)), lineWidth: line * 3)
            var cross = Path()
            cross.move(to: CGPoint(x: center.x - radius, y: center.y))
            cross.addLine(to: CGPoint(x: center.x + radius, y: center.y))
            cross.move(to: CGPoint(x: center.x, y: center.y - radius))
            cross.addLine(to: CGPoint(x: center.x, y: center.y + radius))
            context.stroke(cross, with: .color(.white.opacity(0.5)), lineWidth: line * 1.5)
        }
    }

    /// The target as a picture of `aspect` (width over height), `longSide` pixels long.
    @MainActor
    static func render(aspect: Double, longSide: Double) -> CGImage? {
        let size = aspect >= 1 ? CGSize(width: longSide, height: longSide / aspect)
                               : CGSize(width: longSide * aspect, height: longSide)
        let renderer = ImageRenderer(content: CalibrationTarget().frame(width: size.width, height: size.height))
        renderer.scale = 1
        return renderer.cgImage
    }
}

/// Lining the card up by eye, in the middle of the screen where you're looking: where to move the
/// lid and when that's far enough, then whether the target looks right, with the two nudges to fix it.
struct LineUpGuide: View {
    var lineUp: EyeLineUp
    var sensor: LidSensor
    var save: () -> Void
    var finish: () -> Void
    var cancel: () -> Void

    /// The lid angle, read ten times a second rather than in `body`, so the guide isn't redrawn every frame.
    @State private var lidAngle: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                LidGlyph(sensor: sensor, target: lineUp.target, tolerance: EyeLineUp.tolerance, lineWidth: 4)
                    .frame(width: 76, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(direction.text)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(direction.isReady ? Color.green : .primary)
                    Text(stepCaption)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                StepDots(done: min(lineUp.samples.count + 1, 3), total: 3)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Adjust until the circle looks round and the squares look square.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.primary.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                NudgeRow(title: "Lean", value: Binding(get: { lineUp.lean }, set: { lineUp.lean = $0 }),
                         reach: EyeLineUp.reach.lean, low: "Toward you", high: "Away",
                         shown: lineUp.lean.formatted(.number.precision(.fractionLength(1))) + "°")
                NudgeRow(title: "Height", value: Binding(get: { lineUp.lift }, set: { lineUp.lift = $0 }),
                         reach: EyeLineUp.reach.lift, low: "Lower", high: "Higher",
                         shown: lineUp.lift.formatted(.number.precision(.fractionLength(1))) + " cm")
            }
            .padding(12)
            .background(Color.white.opacity(0.045), in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.05)))
            // Worth adjusting only once the lid is where it should be.
            .opacity(direction.isReady || lineUp.isComplete ? 1 : 0.55)

            if let note = lineUp.note {
                Label(note, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let fit = lineUp.fit {
                Label(fit.summary, systemImage: "checkmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button("Cancel", action: cancel)
                    .buttonStyle(.secondary)
                Spacer()
                if lineUp.lean != 0 || lineUp.lift != 0 {
                    Button("Reset") {
                        lineUp.lean = 0
                        lineUp.lift = 0
                    }
                    .buttonStyle(.secondary)
                }
                if lineUp.isComplete {
                    Button("Save Another", action: save)
                        .buttonStyle(.secondary)
                        .disabled(!canSave)
                    Button("Done", action: finish)
                        .buttonStyle(.primary)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Looks Good", action: save)
                        .buttonStyle(.primary)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSave)
                }
            }
            .controlSize(.large)
        }
        .padding(18)
        .frame(width: 480)
        .background(Color(white: 0.105).opacity(0.97), in: .rect(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.1)))
        .padding(1)
        .background(Color.black.opacity(0.35), in: .rect(cornerRadius: 21))
        .environment(\.colorScheme, .dark)
        .task {
            while !Task.isCancelled {
                let angle = sensor.angle
                if lidAngle.map({ abs($0 - angle) >= 0.1 }) ?? true { lidAngle = angle }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private var canSave: Bool {
        lidAngle.map(lineUp.isNew) ?? false
    }

    /// What to do with the lid now.
    private var direction: (text: String, isReady: Bool) {
        guard let lidAngle else { return (" ", false) }
        guard let target = lineUp.target else {
            return lineUp.isNew(lidAngle)
                ? ("Add another angle, or finish", true)
                : ("Move the lid to another angle", false)
        }
        let away = target - lidAngle
        if abs(away) <= EyeLineUp.tolerance { return ("That's it. Leave the lid here.", true) }
        let degrees = Int(abs(away).rounded())
        return (away < 0 ? "Close the lid \(degrees)° more" : "Open the lid \(degrees)° more", false)
    }

    private var stepCaption: String {
        let started = "Started at \(Int(lineUp.anchor.rounded()))°"
        switch lineUp.samples.count {
        case 0: return "\(started) · first angle, about \(Int((lineUp.target ?? 0).rounded()))°"
        case 1: return "Saved \(Int(lineUp.samples[0].lidAngle.rounded()))° · second angle, about "
            + "\(Int((lineUp.target ?? 0).rounded()))°"
        default: return "Saved " + lineUp.samples.map { "\(Int($0.lidAngle.rounded()))°" }.joined(separator: ", ")
        }
    }
}

/// A nudge slider with what each end does, and its value. It moves the value slowly near the middle
/// and faster toward the ends, so the small nudges that finish a line-up stay as fine as ever while
/// the large ones a far-off starting eye needs are still in reach.
private struct NudgeRow: View {
    var title: String
    @Binding var value: Double
    /// How far the value goes either way.
    var reach: Double
    var low: String
    var high: String
    var shown: String

    init(title: String, value: Binding<Double>, reach: Double, low: String, high: String, shown: String) {
        self.title = title
        _value = value
        self.reach = reach
        self.low = low
        self.high = high
        self.shown = shown
    }

    /// Where the slider sits, from -1 to 1: the value grows with its square.
    private var position: Binding<Double> {
        Binding(get: { (abs(value) / reach).squareRoot() * (value < 0 ? -1 : 1) },
                set: { value = $0 * abs($0) * reach })
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .frame(width: 50, alignment: .leading)
            Text(low)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 66, alignment: .trailing)
            Slider(value: position, in: -1...1)
                .controlSize(.small)
            Text(high)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .leading)
            Text(shown)
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
    }
}
