import SwiftUI
import simd

/// How the card should appear to be held in space.
enum CardMode: String, CaseIterable {
    /// Square to your line of sight, so it looks undistorted at any lid angle.
    case facing
    /// Standing vertically on the desk, like a physical card propped behind the keyboard.
    case upright
    /// Drawn flat on the screen with no correction, for comparison.
    case flat

    var label: String {
        switch self {
        case .facing: "Facing you"
        case .upright: "Upright"
        case .flat: "Flat"
        }
    }
}

/// Physical model of the laptop and the viewer's eye, in centimeters.
///
/// World axes: x runs along the hinge to the right, y points up from the desk, z points toward
/// the viewer. The hinge is the x-axis, so the base lies in the y = 0 plane.
struct Rig {
    var lidAngle: Double
    var eyeDistance: Double
    var eyeHeight: Double
    var placement: ScreenPlacement

    /// Distance from the hinge axis to the bottom edge of the lit display area.
    static let hingeToDisplay = 1.2

    var eye: SIMD3<Double> { [0, eyeHeight, eyeDistance] }

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
        return SIMD3(x, 0, 0) + up * screenUp
    }

    /// Where the line from the eye through `point` crosses the display, in display points.
    func display(fromWorld point: SIMD3<Double>) -> CGPoint? {
        let ray = point - eye
        let denominator = dot(screenNormal, ray)
        guard abs(denominator) > 1e-9 else { return nil }
        let t = -dot(screenNormal, eye) / denominator
        guard t > 0 else { return nil }

        let hit = eye + t * ray
        let k = placement.cmPerPoint
        return CGPoint(x: hit.x / k + placement.displaySize.width / 2,
                       y: placement.displaySize.height - (dot(hit, screenUp) - Self.hingeToDisplay) / k)
    }

    /// The card's up direction in the world. Its right direction is always along the hinge.
    func cardUp(at center: SIMD3<Double>, mode: CardMode) -> SIMD3<Double> {
        switch mode {
        case .flat:
            return screenUp
        case .upright:
            return [0, 1, 0]
        case .facing:
            let toEye = normalize(SIMD3(0, eye.y - center.y, eye.z - center.z))
            return [0, toEye.z, -toEye.y]
        }
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
    /// A flat card just sits in `frame`. The others hang still at the spot in space where the screen
    /// held `frame`'s center when the lid was at `anchorAngle`. Every corner is traced from the eye,
    /// so as the lid moves the card is drawn smaller when the screen comes closer, larger when it
    /// moves away, and shifted to stay on the same line of sight, even if that's out of view.
    func cardPose(frame: CGRect, mode: CardMode, anchorAngle: Double) -> CardPose? {
        let frameCenter = CGPoint(x: frame.midX, y: frame.midY)
        guard mode != .flat else {
            return pose(center: world(fromDisplay: frameCenter), size: frame.size, mode: mode, scale: 1)
        }

        var anchorRig = self
        anchorRig.lidAngle = anchorAngle
        let anchor = anchorRig.world(fromDisplay: frameCenter)

        // How big the card's middle is drawn: its line of sight meets the screen nearer or farther
        // than the card itself.
        guard let seen = display(fromWorld: anchor) else { return nil }
        let scale = length(world(fromDisplay: seen) - eye) / length(anchor - eye)

        guard let pose = pose(center: anchor, size: frame.size, mode: mode, scale: scale) else { return nil }
        let box = pose.boundingBox
        guard box.width <= frame.width * 8, box.height <= frame.height * 8 else { return nil }
        return pose
    }

    /// Traces the corners of a card centered at `center` in the world onto the display.
    private func pose(center: SIMD3<Double>, size: CGSize, mode: CardMode, scale: Double) -> CardPose? {
        let k = placement.cmPerPoint
        let direction = cardUp(at: center, mode: mode)
        let up = direction * (size.height / 2 * k)
        let right = SIMD3<Double>(size.width / 2 * k, 0, 0)

        let top = center + up, bottom = center - up
        let corners: [SIMD3<Double>] = [top - right, top + right, bottom + right, bottom - right]
        let projected = corners.compactMap(display(fromWorld:))
        guard projected.count == 4 else { return nil }
        return CardPose(corners: projected, up: direction, scale: scale)
    }
}

/// Where the card is drawn for one frame.
struct CardPose {
    /// Corners on the display in points: top-left, top-right, bottom-right, bottom-left.
    var corners: [CGPoint]
    /// The card's up direction in the world.
    var up: SIMD3<Double>
    /// How big the card's middle is drawn relative to its laid-out size.
    var scale: Double

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
