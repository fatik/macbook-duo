import SwiftUI

/// Where a gradient effect is strongest: one edge of the card, or all of them.
enum EffectEdge: String, CaseIterable {
    case top, bottom, left, right, around

    var label: String {
        switch self {
        case .top: "Top"
        case .bottom: "Bottom"
        case .left: "Left"
        case .right: "Right"
        case .around: "All edges"
        }
    }

    /// A gradient laid out by distance from this edge: location 0 is at the edge and 1 is as far in
    /// as the card goes (the far side, or the middle for `.around`).
    func style(_ stops: [Gradient.Stop]) -> AnyShapeStyle {
        switch self {
        case .around:
            let inward = stops.reversed().map { Gradient.Stop(color: $0.color, location: 1 - $0.location) }
            return AnyShapeStyle(EllipticalGradient(stops: inward, center: .center,
                                                    startRadiusFraction: 0, endRadiusFraction: 0.5))
        case .top: return AnyShapeStyle(LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom))
        case .bottom: return AnyShapeStyle(LinearGradient(stops: stops, startPoint: .bottom, endPoint: .top))
        case .left: return AnyShapeStyle(LinearGradient(stops: stops, startPoint: .leading, endPoint: .trailing))
        case .right: return AnyShapeStyle(LinearGradient(stops: stops, startPoint: .trailing, endPoint: .leading))
        }
    }
}

/// Which lid movement makes an effect reach further into the card.
enum LidDirection: String, CaseIterable {
    case opening, closing, either

    var label: String {
        switch self {
        case .opening: "Opened more"
        case .closing: "Closed more"
        case .either: "Moved either way"
        }
    }
}

/// Settings for a blur or darkening that is strongest at an edge of the card and fades toward the
/// middle, kept in user defaults under keys starting with `prefix`.
struct StoredEffect: DynamicProperty {
    /// 0 is off, 1 is the strongest.
    @AppStorage var strength: Double
    /// The furthest in from the edge the effect reaches, as a fraction of the way across.
    @AppStorage var spread: Double
    @AppStorage var edge: EffectEdge
    /// How much the lid drives the reach: 0 keeps it at `spread`, 1 means no reach at the anchor
    /// angle, growing to `spread` once the lid has moved `fullReachAfter` degrees in `lidDirection`.
    @AppStorage var lidReaction: Double
    @AppStorage var lidDirection: LidDirection

    static let fullReachAfter = 45.0

    init(_ prefix: String, edge: EffectEdge) {
        _strength = AppStorage(wrappedValue: 0, prefix + "Strength")
        _spread = AppStorage(wrappedValue: 0.5, prefix + "Spread")
        _edge = AppStorage(wrappedValue: edge, prefix + "Edge")
        _lidReaction = AppStorage(wrappedValue: 0, prefix + "LidReaction")
        _lidDirection = AppStorage(wrappedValue: .either, prefix + "LidDirection")
    }

    /// Where the effect sits at this lid angle. Its fade keeps the same length (`spread`) and slides
    /// in from the edge as the lid moves, so a little movement gives a faint trace and more movement
    /// a stronger, deeper one.
    func ramp(lidAngle: Double, anchorAngle: Double) -> EffectRamp {
        let moved = switch lidDirection {
        case .opening: lidAngle - anchorAngle
        case .closing: anchorAngle - lidAngle
        case .either: abs(lidAngle - anchorAngle)
        }
        let travel = min(max(moved / Self.fullReachAfter, 0), 1)
        return EffectRamp(front: spread * (1 - lidReaction * (1 - travel)), width: spread)
    }
}

/// How much of an effect there is at each distance from its edge, as fractions of the way across:
/// none past `front`, easing up to full `width` closer to the edge.
struct EffectRamp {
    var front: Double
    var width: Double

    /// The effect's amount, from 0 to 1, at distance `d` from the edge.
    func amount(at d: Double) -> Double {
        let x = min(max((front - d) / width, 0), 1)
        // Smootherstep: flat at both ends, so the fade has no visible start or finish.
        return x * x * x * (x * (6 * x - 15) + 10)
    }

    /// The most there is anywhere, which is right at the edge.
    var peak: Double { amount(at: 0) }

    /// Gradient stops that follow `color(amount)` inward from the edge, sampled finely across the
    /// stretch where the amount changes so the gradient doesn't band.
    func stops(_ color: (Double) -> Color) -> [Gradient.Stop] {
        let start = min(max(front - width, 0), 1), end = min(max(front, 0), 1)
        let samples = 32
        var locations: [Double] = [0]
        for step in 0...samples {
            locations.append(start + (end - start) * Double(step) / Double(samples))
        }
        locations.append(1)
        return locations.map { Gradient.Stop(color: color(amount(at: $0)), location: $0) }
    }
}

/// Blurs `content` more and more toward `edge`, following `ramp`: `radius` where the ramp is full,
/// none where it's empty. Built from a stack of increasingly blurred copies, each fading in as the
/// ramp rises past its level, so the blur grows smoothly instead of in steps. Each copy is drawn at
/// a fraction of full resolution, since blur hides the lost detail anyway.
struct ProgressiveBlur<Content: View>: View {
    var radius: CGFloat
    var ramp: EffectRamp
    var edge: EffectEdge
    /// Whether the content fills its frame, so blurring shouldn't soften its outline.
    var isOpaque: Bool
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                content.frame(width: size.width, height: size.height)
                if radius > 0.25 {
                    ForEach(blurLevels.indices, id: \.self) { index in
                        let level = blurLevels[index]
                        let below = index == 0 ? 0 : blurLevels[index - 1]
                        // Copies whose level the ramp never reaches would be invisible anyway.
                        if ramp.peak > below {
                            blurred(by: radius * level, size: size) { amount in
                                min(max((amount - below) / (level - below), 0), 1)
                            }
                        }
                    }
                }
            }
        }
    }

    /// A copy blurred by `radius` points and shown where `visibility(amount)` says, drawn shrunk and
    /// scaled back up: at a quarter of the size each way it's a sixteenth of the pixels to draw,
    /// blur and mask, and the blur hides the difference.
    private func blurred(by radius: CGFloat, size: CGSize, visibility: @escaping (Double) -> Double) -> some View {
        let shrink = downscale(forBlur: radius)
        // Whole points, or the rounding shows up as a sliver along the edge once scaled back up.
        let small = CGSize(width: (size.width / shrink).rounded(.up), height: (size.height / shrink).rounded(.up))
        let scale = CGSize(width: small.width / size.width, height: small.height / size.height)
        return content
            .frame(width: size.width, height: size.height)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: small.width, height: small.height, alignment: .topLeading)
            // Flattened, so layered content (a card with an outline, or a warped card over the
            // backdrop) blurs as one picture instead of as stacked copies.
            .drawingGroup()
            .blur(radius: radius * scale.width, opaque: isOpaque)
            // Masked while still small: the mask is a smooth gradient, so it loses nothing.
            .mask { Rectangle().fill(edge.style(ramp.stops { .black.opacity(visibility($0)) })) }
            .scaleEffect(CGSize(width: 1 / scale.width, height: 1 / scale.height), anchor: .topLeading)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

/// How much to shrink a copy before blurring it: as much as possible while the blur still spans a
/// couple of points at the smaller size, which keeps scaling it back up invisible.
private func downscale(forBlur radius: CGFloat) -> CGFloat {
    switch radius {
    case ..<2: 1
    case ..<6: 2
    case ..<12: 4
    default: 8
    }
}

/// Each blurred copy's share of the full blur. They bunch up at the low end, where a little blur is
/// most noticeable.
private let blurLevels = (1...8).map { pow(Double($0) / 8, 2) }

/// Black that follows `ramp`: `opacity` strong where it's full, fading smoothly to nothing.
struct EdgeDarkness: View {
    var opacity: Double
    var ramp: EffectRamp
    var edge: EffectEdge

    var body: some View {
        Rectangle()
            .fill(edge.style(ramp.stops { .black.opacity(opacity * $0) }))
            .allowsHitTesting(false)
    }
}
