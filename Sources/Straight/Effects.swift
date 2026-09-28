import SwiftUI

/// What the blur follows: a fade in from one edge of the card, or all of them, or the card's real
/// depth, strongest where it's farthest from the screen.
enum EffectEdge: String, CaseIterable {
    case top, bottom, left, right, around, depth

    var label: String {
        switch self {
        case .top: "Top edge"
        case .bottom: "Bottom edge"
        case .left: "Left edge"
        case .right: "Right edge"
        case .around: "All edges"
        case .depth: "Depth (3D)"
        }
    }
}

/// Which lid movement makes an edge fade reach further into the card.
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

/// Which parts depth blur applies to: those farther away than where the eye is focused, nearer, or both.
enum DepthSide: String, CaseIterable {
    case farther, nearer, either

    var label: String {
        switch self {
        case .farther: "Farther away"
        case .nearer: "Closer"
        case .either: "Both"
        }
    }
}

extension LidDirection {
    /// How far the lid has moved from `anchor` to `angle` this way, from 0 to 1 at `full` degrees.
    func travel(from anchor: Double, to angle: Double, full: Double = 45) -> Double {
        let moved = switch self {
        case .opening: angle - anchor
        case .closing: anchor - angle
        case .either: abs(angle - anchor)
        }
        return min(max(moved / full, 0), 1)
    }
}

/// Settings for the blur or the dimming, kept in user defaults under keys starting with `prefix`.
struct StoredEffect: DynamicProperty {
    /// 0 is off, 1 is the strongest.
    @AppStorage var strength: Double
    /// The furthest in from the edge the effect reaches, as a fraction of the way across (up to
    /// `longestReach`), or for depth effects how far away it's full, as a share of `fullDepthAtMost`.
    @AppStorage var spread: Double
    @AppStorage var edge: EffectEdge
    /// How much the lid drives the reach: 0 keeps it at `spread`, 1 means no reach at the anchor
    /// angle, growing to `spread` once the lid has moved `fullReachAfter` degrees in `lidDirection`.
    @AppStorage var lidReaction: Double
    @AppStorage var lidDirection: LidDirection
    /// Which side of the focus a depth effect applies to.
    @AppStorage var depthSide: DepthSide

    static let fullReachAfter = 45.0
    /// An edge fade eases out toward its end, so it can reach past the far edge to still show there.
    static let longestReach = 2.0
    /// For depth effects, how far from the screen `spread` of 1 takes to reach full strength.
    static let fullDepthAtMost = 20.0

    init(_ prefix: String, edge: EffectEdge, lidReaction: Double = 0) {
        _strength = AppStorage(wrappedValue: 0, prefix + "Strength")
        _spread = AppStorage(wrappedValue: 0.5, prefix + "Spread")
        _edge = AppStorage(wrappedValue: edge, prefix + "Edge")
        _lidReaction = AppStorage(wrappedValue: lidReaction, prefix + "LidReaction")
        _lidDirection = AppStorage(wrappedValue: .either, prefix + "LidDirection")
        _depthSide = AppStorage(wrappedValue: .farther, prefix + "DepthSide")
    }

    /// The blur's settings.
    static func blur() -> StoredEffect { StoredEffect("blur", edge: .top) }
    /// The dimming's settings: by default it comes down from the top as the lid moves.
    static func dim() -> StoredEffect { StoredEffect("dim", edge: .top, lidReaction: 1) }

    /// The settings as they are now, to work out frames with.
    var current: Effect {
        Effect(strength: strength, spread: spread, edge: edge, lidReaction: lidReaction,
               lidDirection: lidDirection, depthSide: depthSide)
    }

    /// For depth effects, how far from the screen in centimeters it takes to reach full strength.
    var fullDepth: Double { current.fullDepth }
}

/// A blur or dimming's settings at one moment.
struct Effect {
    var strength: Double
    var spread: Double
    var edge: EffectEdge
    var lidReaction: Double
    var lidDirection: LidDirection
    var depthSide: DepthSide

    var fullDepth: Double { min(spread, 1) * StoredEffect.fullDepthAtMost }

    /// Where the effect is at this lid angle.
    ///
    /// An edge fade keeps the same length (`spread`) and slides in from the edge as the lid moves, so
    /// a little movement gives a faint trace and more a stronger, deeper one. A depth effect follows
    /// how out of focus each part of the card is instead, which the lid changes by itself.
    /// `fromPartInView` makes an edge fade come in from the edge of the part of the card in view: the
    /// card's own edge while it's in the window, the window's once the card runs past it. That's for a
    /// card filling the window, whose edges move off-screen as the lid moves one way and into the
    /// window the other.
    func shape(lidAngle: Double, anchorAngle: Double, fromPartInView: Bool) -> EffectShape {
        guard strength > 0 else { return .none }
        if edge == .depth {
            return .depth(full: fullDepth, side: depthSide)
        }
        let travel = lidDirection.travel(from: anchorAngle, to: lidAngle, full: StoredEffect.fullReachAfter)
        let ramp = EffectRamp(front: spread * (1 - lidReaction * (1 - travel)), width: spread)
        return fromPartInView ? .partInViewEdge(edge, ramp) : .cardEdge(edge, ramp)
    }
}

/// Where a blur or dimming is for one frame.
enum EffectShape {
    case none
    /// Grows with how out of focus each part of the card is, seen from the eye focused on the screen:
    /// full once it's `full` centimeters farther away (or nearer) than the screen, at the viewing
    /// distance.
    case depth(full: Double, side: DepthSide)
    /// Fades in from an edge of the card.
    case cardEdge(EffectEdge, EffectRamp)
    /// Fades in from an edge of the part of the card in view: the card's own edge where it's in the
    /// window, the window's where the card runs past it.
    case partInViewEdge(EffectEdge, EffectRamp)
}

/// How far an edge fade reaches, as fractions of the way across: none past `front`, easing up to
/// full `width` closer to the edge.
struct EffectRamp {
    var front: Double
    var width: Double
}
