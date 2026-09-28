import SwiftUI
import simd

/// Where the card is drawn for: a viewpoint worked out from the screen itself, or the viewer's
/// actual eye position.
enum Viewpoint: String, CaseIterable {
    case screen, eyes

    var label: String {
        switch self {
        case .screen: "From the screen"
        case .eyes: "Your eyes"
        }
    }
}

/// Physical model of the laptop and the viewer's eye, in centimeters.
///
/// World axes: x runs along the hinge to the right, y points up from the desk, z points toward
/// the viewer. The hinge's axis is the x-axis; it sits inside the back of the base, so the base's
/// top lies just above the y = 0 plane.
struct Rig {
    var lidAngle: Double
    var eyeDistance: Double
    var eyeHeight: Double
    var placement: ScreenPlacement

    /// Distance up the lid from the hinge's axis to the bottom edge of the lit display area, and how
    /// far the display's glass lies behind the axis, away from the viewer: the lid's lower end swings
    /// down behind the base, around an axis inside it. Measured from Apple's dimension drawing of the
    /// 13-inch M4 MacBook Air, to about a millimeter.
    static let hingeToDisplay = 1.66
    static let glassBehindHinge = 0.4

    var eye: SIMD3<Double> { [0, eyeHeight, eyeDistance] }

    /// How far from the screen `Viewpoint.screen` assumes the viewer is by default, in screen diagonals.
    static let viewingDiagonals = 1.6

    /// The default viewing distance for `Viewpoint.screen`, in centimeters.
    static func defaultViewingDistance(for placement: ScreenPlacement) -> Double {
        let k = placement.cmPerPoint
        let width = placement.displaySize.width * k, height = placement.displaySize.height * k
        return viewingDiagonals * (width * width + height * height).squareRoot()
    }

    /// The viewpoint that needs nothing but the screen: at `anchorAngle` the screen faced the viewer,
    /// as people tend to set a laptop's lid, from `distance` centimeters in front of its middle and
    /// `lookingDown` degrees above square-on. Returns the eye's distance in front of the hinge and
    /// height above it.
    static func screenViewpoint(anchorAngle: Double, placement: ScreenPlacement,
                                distance: Double, lookingDown: Double) -> (distance: Double, height: Double) {
        let middle = hingeToDisplay + placement.displaySize.height * placement.cmPerPoint / 2
        let t = anchorAngle * .pi / 180, tip = lookingDown * .pi / 180
        // From the screen's middle, out along its normal, tipped up toward the screen's top.
        let outward = (height: -cos(t) * cos(tip) + sin(t) * sin(tip), ahead: sin(t) * cos(tip) + cos(t) * sin(tip))
        return (distance: middle * cos(t) - glassBehindHinge * sin(t) + distance * outward.ahead,
                height: middle * sin(t) + glassBehindHinge * cos(t) + distance * outward.height)
    }

    /// Distance from the hinge up the lid to the camera: centered in the notch, or just above the
    /// display on Macs without one.
    var cameraFromHinge: Double {
        let k = placement.cmPerPoint
        let belowTop = placement.notchHeight > 0 ? placement.notchHeight / 2 * k : -0.5
        return Self.hingeToDisplay + placement.displaySize.height * k - belowTop
    }

    private var radians: Double { lidAngle * .pi / 180 }
    /// Unit vector pointing up the screen, from the hinge toward its top edge.
    var screenUp: SIMD3<Double> { [0, sin(radians), cos(radians)] }
    /// Unit vector pointing out of the screen, toward the viewer.
    var screenNormal: SIMD3<Double> { [0, -cos(radians), sin(radians)] }

    /// A point on the display, in points from its top-left corner, placed in the world.
    func world(fromDisplay point: CGPoint) -> SIMD3<Double> {
        let k = placement.cmPerPoint
        let x = (point.x - placement.displaySize.width / 2) * k
        let up = Self.hingeToDisplay + (placement.displaySize.height - point.y) * k
        return SIMD3(x, 0, 0) + up * screenUp - Self.glassBehindHinge * screenNormal
    }

    /// Where the line from the eye through `point` crosses the display, in display points.
    func display(fromWorld point: SIMD3<Double>) -> CGPoint? {
        let ray = point - eye
        let denominator = dot(screenNormal, ray)
        guard abs(denominator) > 1e-9 else { return nil }
        let t = (-Self.glassBehindHinge - dot(screenNormal, eye)) / denominator
        guard t > 0 else { return nil }

        let hit = eye + t * ray
        let k = placement.cmPerPoint
        return CGPoint(x: hit.x / k + placement.displaySize.width / 2,
                       y: placement.displaySize.height - (dot(hit, screenUp) - Self.hingeToDisplay) / k)
    }


    /// How far a card with this up direction leans back relative to the screen, in degrees
    /// (negative leans forward).
    func lean(of up: SIMD3<Double>) -> Double {
        func lean(_ v: SIMD3<Double>) -> Double { atan2(-v.z, v.y) * 180 / .pi }
        return lean(up) - lean(screenUp)
    }

    /// Where to draw a card laid out in `frame` (display points), or nil when the screen is so close
    /// to edge-on from the eye that the card can't sensibly be drawn.
    ///
    /// The card is held still in space just where the screen held `frame` when the lid was at
    /// `anchorAngle`, tilted as the screen was then, so at that angle it sits exactly on the screen.
    /// Every corner is traced from the eye, so as the lid moves the card is drawn smaller when the
    /// screen comes closer, larger when it moves away, and shifted to stay on the same line of sight,
    /// even if that's out of view.
    func cardPose(frame: CGRect, anchorAngle: Double) -> CardPose? {
        var anchorRig = self
        anchorRig.lidAngle = anchorAngle
        let center = anchorRig.world(fromDisplay: CGPoint(x: frame.midX, y: frame.midY))
        let up = anchorRig.screenUp

        // How big the card's middle is drawn: its line of sight meets the screen nearer or farther
        // than the card itself.
        guard let seen = display(fromWorld: center) else { return nil }
        let scale = length(world(fromDisplay: seen) - eye) / length(center - eye)

        guard let pose = pose(center: center, up: up, size: frame.size, scale: scale) else { return nil }
        let box = pose.boundingBox
        guard box.width <= frame.width * 8, box.height <= frame.height * 8 else { return nil }
        return pose
    }

    /// Traces the corners of a card centered at `center` in the world onto the display.
    private func pose(center: SIMD3<Double>, up direction: SIMD3<Double>, size: CGSize, scale: Double) -> CardPose? {
        let k = placement.cmPerPoint
        let up = direction * (size.height / 2 * k)
        let right = SIMD3<Double>(size.width / 2 * k, 0, 0)

        let top = center + up, bottom = center - up
        let corners: [SIMD3<Double>] = [top - right, top + right, bottom + right, bottom - right]
        let projected = corners.compactMap(display(fromWorld:))
        guard projected.count == 4 else { return nil }
        // The eye is focused on the screen's glass.
        return CardPose(corners: projected, world: corners, up: direction, scale: scale, focusNormal: screenNormal)
    }
}

/// Where the card is drawn for one frame.
struct CardPose {
    /// Corners on the display in points: top-left, top-right, bottom-right, bottom-left.
    var corners: [CGPoint]
    /// The same corners in the world, in centimeters.
    var world: [SIMD3<Double>]
    /// The card's up direction in the world.
    var up: SIMD3<Double>
    /// How big the card's middle is drawn relative to its laid-out size.
    var scale: Double
    /// The plane the eye is focused on, the screen's glass, faces this way.
    var focusNormal: SIMD3<Double>

    var boundingBox: CGRect {
        let xs = corners.map(\.x), ys = corners.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// The transform that draws a view laid out in `frame` (display points) onto these corners.
    func transform(from frame: CGRect) -> ProjectionTransform? {
        ProjectionTransform(mapping: frame.size, to: corners.map { CGPoint(x: $0.x - frame.minX, y: $0.y - frame.minY) })
    }
}

extension ProjectionTransform {
    /// The perspective transform that maps a `size` rectangle's corners (top-left, top-right,
    /// bottom-right, bottom-left) onto the four points in `quad`.
    init?(mapping size: CGSize, to quad: [CGPoint]) {
        let (p0, p1, p2, p3) = (quad[0], quad[1], quad[2], quad[3])
        let dx1 = p1.x - p2.x, dx2 = p3.x - p2.x, dx3 = p0.x - p1.x + p2.x - p3.x
        let dy1 = p1.y - p2.y, dy2 = p3.y - p2.y, dy3 = p0.y - p1.y + p2.y - p3.y
        let determinant = dx1 * dy2 - dx2 * dy1
        guard abs(determinant) > 1e-9 else { return nil }

        // Unit square to quad, then scaled so it takes the view's own coordinates.
        let g = (dx3 * dy2 - dx2 * dy3) / determinant
        let h = (dx1 * dy3 - dx3 * dy1) / determinant
        self.init()
        m11 = (p1.x - p0.x + g * p1.x) / size.width
        m21 = (p3.x - p0.x + h * p3.x) / size.height
        m31 = p0.x
        m12 = (p1.y - p0.y + g * p1.y) / size.width
        m22 = (p3.y - p0.y + h * p3.y) / size.height
        m32 = p0.y
        m13 = g / size.width
        m23 = h / size.height
        m33 = 1

        let values = [m11, m12, m13, m21, m22, m23, m31, m32]
        guard values.allSatisfy(\.isFinite) else { return nil }
    }
}
