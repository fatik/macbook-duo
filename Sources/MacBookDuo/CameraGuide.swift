import SwiftUI

/// Calibrating with the camera, step by step, in the middle of the window where you're looking: face
/// the screen while it finds you, then keep your head still and tilt the screen until it has seen
/// enough, then where it found your eyes, or what went wrong.
struct CameraGuide: View {
    var calibrator: EyeCalibrator
    var sensor: LidSensor
    var retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                LidGlyph(sensor: sensor, lineWidth: 4)
                    .frame(width: 76, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(isFinished ? Color.duo : .primary)
                    Text(caption)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                StepDots(done: step, total: 3)
            }

            if case .measuring(let progress, let seesFace) = calibrator.phase, seesFace {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: progress)
                        .tint(Color.duo)
                    Text("\(Int((progress * EyeCalibrator.sweep).rounded()))° of \(Int(EyeCalibrator.sweep))°")
                        .font(.system(size: 11.5))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                switch calibrator.phase {
                case .measuring, .idle:
                    Button("Cancel") { calibrator.cancel() }
                        .buttonStyle(.secondary)
                    Spacer()
                case .finished:
                    Spacer()
                    Button("Done") { calibrator.cancel() }
                        .buttonStyle(.primary)
                        .keyboardShortcut(.defaultAction)
                case .failed:
                    Button("Close") { calibrator.cancel() }
                        .buttonStyle(.secondary)
                    Spacer()
                    Button("Try Again", action: retry)
                        .buttonStyle(.primary)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.large)
        }
        .padding(18)
        .frame(width: 480)
        // Solid and edged like the Line Up guide, since it floats over the moving card.
        .background(Color(white: 0.105).opacity(0.97), in: .rect(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.1)))
        .padding(1)
        .background(Color.black.opacity(0.35), in: .rect(cornerRadius: 21))
        .environment(\.colorScheme, .dark)
    }

    private var isFinished: Bool {
        if case .finished = calibrator.phase { true } else { false }
    }

    private var step: Int {
        switch calibrator.phase {
        case .idle, .failed: 1
        case .measuring(_, let seesFace): seesFace ? 2 : 1
        case .finished: 3
        }
    }

    private var title: String {
        switch calibrator.phase {
        case .idle: "Starting the camera…"
        case .measuring(_, let seesFace): seesFace ? "Now slowly tilt your screen" : "Finding your face…"
        case .finished: "You're calibrated"
        case .failed: "Couldn't calibrate"
        }
    }

    private var caption: String {
        switch calibrator.phase {
        case .idle:
            " "
        case .measuring(_, let seesFace):
            seesFace
                ? "Keep your head still. Tilt back and forth, about \(Int(EyeCalibrator.sweep))° in all."
                : "Sit as usual and face the screen."
        case .finished(let distance, let height):
            "Your eyes: \(Int(distance.rounded())) cm away, \(Int(height.rounded())) cm up."
        case .failed(let message):
            message
        }
    }
}
