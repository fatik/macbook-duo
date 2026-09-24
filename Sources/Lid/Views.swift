import SwiftUI

/// Full-window color for the current lid angle, with the angle and a hinge diagram on top.
struct LidColorView: View {
    var angle: Double
    var palette: Palette

    var body: some View {
        let background = palette.color(at: angle)

        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)

            ZStack {
                background.color.ignoresSafeArea()

                VStack(spacing: side * 0.04) {
                    HingeView(angle: angle)
                        .frame(width: side * 0.36, height: side * 0.27)

                    Text("\(Int(angle.rounded()))°")
                        .font(.system(size: side * 0.26, weight: .semibold, design: .rounded))
                        .monospacedDigit()

                    Text("LID ANGLE")
                        .font(.system(size: 13, weight: .medium))
                        .tracking(2)
                        .opacity(0.6)
                }

                VStack {
                    Spacer()
                    Text("\(palette.name) · click to change")
                        .font(.system(size: 12))
                        .opacity(0.5)
                        .padding(.bottom, 20)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .foregroundStyle(background.foreground.color)
        .animation(.easeInOut(duration: 0.3), value: background.isLight)
    }
}

struct UnavailableView: View {
    var body: some View {
        ZStack {
            Color(white: 0.09).ignoresSafeArea()
            VStack(spacing: 8) {
                Text("No lid angle sensor found")
                    .font(.title2.weight(.semibold))
                Text("This Mac doesn't expose Apple's hinge sensor.")
                    .opacity(0.6)
            }
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding()
        }
    }
}

/// Side view of the laptop: the base lies flat and the lid swings up from the hinge.
struct HingeView: View {
    var angle: Double

    var body: some View {
        Canvas { context, size in
            let hinge = CGPoint(x: size.width * 0.42, y: size.height * 0.86)
            let length = size.width * 0.5
            let clamped = min(max(angle, 0), 180)

            func point(_ degrees: Double, _ radius: Double) -> CGPoint {
                let rad = degrees * .pi / 180
                return CGPoint(x: hinge.x + cos(rad) * radius, y: hinge.y - sin(rad) * radius)
            }

            var arc = Path()
            arc.move(to: point(0, length * 0.32))
            for step in 1...48 { arc.addLine(to: point(clamped * Double(step) / 48, length * 0.32)) }

            var base = Path()
            base.move(to: hinge)
            base.addLine(to: point(0, length))

            var lid = Path()
            lid.move(to: hinge)
            lid.addLine(to: point(clamped, length))

            var faint = context
            faint.opacity = 0.45
            faint.stroke(arc, with: .foreground, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [0.1, 5]))
            context.stroke(base, with: .foreground, style: StrokeStyle(lineWidth: 7, lineCap: .round))
            context.stroke(lid, with: .foreground, style: StrokeStyle(lineWidth: 4, lineCap: .round))
        }
    }
}
