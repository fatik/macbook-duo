import SwiftUI

extension Color {
    /// MacBook Duo's accent: the warm orange of the desert's sky at dusk.
    static let duo = Color(hex: 0xFF9A4A)
    /// The window's own background, behind cards and panels.
    static let duoBackground = Color(white: 0.045)
}

/// A panel for the welcome and the window's own messages, in the control panel's look: solid rather
/// than frosted and edged rather than shadowed, since it often sits over the moving card, where the
/// window server would redo either every frame.
struct DuoCard<Content: View>: View {
    var width: CGFloat? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .padding(24)
        .frame(width: width, alignment: .leading)
        .background(Color(white: 0.085).opacity(0.97), in: .rect(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(.white.opacity(0.1)))
        .padding(1)
        .background(Color.black.opacity(0.35), in: .rect(cornerRadius: 23))
        .environment(\.colorScheme, .dark)
    }
}

/// The one thing to do next: filled with the accent.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(Color.black.opacity(isEnabled ? 0.88 : 0.45))
            .padding(.horizontal, 18)
            .frame(minHeight: 34)
            .background(Color.duo.opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.35), in: .capsule)
            .contentShape(.capsule)
    }
}

/// Any other choice: a quiet capsule.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Capsule(configuration: configuration)
    }

    /// A view of its own, so it can keep whether the pointer is over it.
    private struct Capsule: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isEnabled ? .primary : .tertiary)
                .padding(.horizontal, 16)
                .frame(minHeight: 34)
                .background(Color.primary.opacity(configuration.isPressed ? 0.2 : isHovered ? 0.14 : 0.08),
                            in: SwiftUI.Capsule())
                .contentShape(SwiftUI.Capsule())
                .onHover { isHovered = $0 }
        }
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}

/// A choice among a few, with a symbol, a title and a line on what it means.
struct OptionRow: View {
    var symbol: String
    var title: String
    /// A word beside the title, like "Recommended".
    var badge: String? = nil
    var detail: String
    var isSelected: Bool
    var action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(isSelected ? Color.duo : .secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13.5, weight: .semibold))
                    HStack(spacing: 6) {
                        Text(detail)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let badge {
                            Text(badge.uppercased())
                                .font(.system(size: 9.5, weight: .bold))
                                .kerning(0.4)
                                .foregroundStyle(Color.duo)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.duo.opacity(0.16), in: .capsule)
                                .fixedSize()
                        }
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(isSelected ? Color.duo : Color.primary.opacity(0.25))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Color.primary.opacity(isSelected ? 0.09 : isHovered ? 0.06 : 0.035), in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isSelected ? Color.duo.opacity(0.6) : Color.primary.opacity(0.06)))
            .contentShape(.rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

/// A key or chord, drawn like a keycap.
struct KeyCap: View {
    var keys: String

    var body: some View {
        Text(keys)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .padding(.horizontal, 7)
            .frame(minWidth: 24, minHeight: 22)
            .background(Color.primary.opacity(0.12), in: .rect(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.08)))
            .fixedSize()
    }
}
