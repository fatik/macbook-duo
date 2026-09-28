import SwiftUI

/// Calibrating by eye. The card is anchored at one lid angle; then at two or more other angles the
/// viewer nudges it until it looks straight. The eye position that would have drawn it just there at
/// every one of those angles becomes the viewpoint.
@MainActor
@Observable
final class EyeLineUp {
    /// Where the card was drawn when it looked straight.
    struct Sample {
        var lidAngle: Double
        /// The card's corners on the display, in points: top-left, top-right, bottom-right, bottom-left.
        var corners: [CGPoint]
    }

    struct Fit {
        var eyeDistance: Double
        var eyeHeight: Double
        /// How far, on average, the fitted drawing's corners are from where they were lined up, in points.
        var error: Double

        var summary: String {
            "Eyes \(Int(eyeDistance.rounded())) cm out and \(Int(eyeHeight.rounded())) cm up, within "
                + "\(error.formatted(.number.precision(.fractionLength(1)))) pt of your line-ups."
        }
    }

    /// The settings from before lining up began, put back if it's cancelled.
    struct Previous {
        var viewpoint: Viewpoint
        var eyeDistance: Double
        var eyeHeight: Double
    }

    private(set) var isActive = false
    /// The lid angle the card was anchored at.
    private(set) var anchor = 0.0
    private(set) var samples: [Sample] = []
    private(set) var fit: Fit?
    private(set) var previous: Previous?
    /// A note about the last thing that went wrong, if anything did.
    var note: String?

    /// How far the card is nudged at the angle being lined up: degrees leaned back, and how many
    /// centimeters the eye is moved to lift it.
    var lean = 0.0
    var lift = 0.0

    /// The fewest degrees between lined-up angles, and from the anchor, for them to say anything new.
    static let spacing = 10.0
    /// How far from where it started the lid is sent for each angle, and how near that is near enough.
    static let step = 20.0
    static let tolerance = 5.0
    /// The range a lid comfortably opens to.
    static let angles = 40.0...130.0

    /// Two angles are enough to find the eye; more only refine it.
    var isComplete: Bool { samples.count >= 2 }

    /// The lid angle to line up at next, if there's one to suggest: first closed a little from where
    /// it started, then opened past it, since angles on both sides pin the viewpoint down best.
    var target: Double? {
        let closed = anchor - Self.step, opened = anchor + Self.step
        switch samples.count {
        case 0:
            return Self.angles.contains(closed) ? closed : opened
        case 1:
            if samples[0].lidAngle < anchor {
                return Self.angles.contains(opened) ? opened : anchor - 2 * Self.step
            }
            return Self.angles.contains(closed) ? closed : anchor + 2 * Self.step
        default:
            return nil
        }
    }

    var adjustment: CardAdjustment? { isActive ? CardAdjustment(lean: lean, lift: lift) : nil }

    func start(at angle: Double, previous: Previous) {
        isActive = true
        anchor = angle
        samples = []
        fit = nil
        note = nil
        lean = 0
        lift = 0
        self.previous = previous
    }

    /// Whether `angle` is far enough from the anchor and the angles already lined up.
    func isNew(_ angle: Double) -> Bool {
        ([anchor] + samples.map(\.lidAngle)).allSatisfy { abs($0 - angle) >= Self.spacing }
    }

    /// Keeps `sample` and the fit made with it; the fit now draws the card there, so the nudge starts
    /// over.
    func add(_ sample: Sample, fit: Fit) {
        samples.append(sample)
        self.fit = fit
        note = nil
        lean = 0
        lift = 0
    }

    func end() {
        isActive = false
        lean = 0
        lift = 0
        note = nil
    }
}

/// A nudge to the viewpoint the card is drawn for, while lining it up by eye. It changes the same
/// things the fit finds, so whatever lines the card up can be matched exactly.
struct CardAdjustment: Equatable {
    /// Degrees of extra counter-tilt: positive leans the card back.
    var lean: Double
    /// Centimeters higher (or lower) the eye is taken to be; positive moves the card up.
    var lift: Double
}

extension CardScene {
    /// The believable range of the fitted eye position: distance and height in centimeters.
    static let lineUpLimits = (distance: 30.0...120.0, height: -10.0...70.0)

    /// How far the fit may wander from `typical` (a viewpoint worked out from the screen) before
    /// that costs as much as missing every lined-up corner by 20 points.
    static let lineUpSpread = (distance: 20.0, height: 15.0)

    /// The eye position with which this card, anchored at `anchor`, would be drawn closest to where
    /// it was lined up in `samples`, or nil if only an unbelievable one fits.
    ///
    /// Hand-made line-ups are never quite consistent, so the fit stays near a typical viewpoint
    /// unless the line-ups clearly call for something else.
    func lineUpFit(_ samples: [EyeLineUp.Sample], anchor: Double,
                   typical: (distance: Double, height: Double)) -> EyeLineUp.Fit? {
        guard !samples.isEmpty else { return nil }
        let limits = Self.lineUpLimits, spread = Self.lineUpSpread
        func missed(_ p: [Double]) -> Double {
            guard limits.distance.contains(p[0]), limits.height.contains(p[1]) else { return .infinity }
            var scene = self
            scene.viewpoint = .eyes
            scene.eyeDistance = p[0]
            scene.eyeHeight = p[1]
            scene.anchorAngle = anchor
            scene.adjustment = nil
            var total = 0.0
            for sample in samples {
                guard let pose = scene.pose(lidAngle: sample.lidAngle) else { return .infinity }
                for (drawn, lined) in zip(pose.corners, sample.corners) {
                    total += (drawn.x - lined.x) * (drawn.x - lined.x) + (drawn.y - lined.y) * (drawn.y - lined.y)
                }
            }
            return total
        }
        let corners = Double(samples.count * 4)
        func cost(_ p: [Double]) -> Double {
            let away = pow((p[0] - typical.distance) / spread.distance, 2) + pow((p[1] - typical.height) / spread.height, 2)
            return missed(p) + corners * 20 * 20 * away
        }

        var best = [typical.distance, typical.height]
        guard cost(best).isFinite else { return nil }
        // Searching again from where the first search ended gets it out of any narrow valley.
        for steps in [[12.0, 12.0], [3.0, 3.0]] {
            best = lowestPoint(of: cost, from: best, steps: steps)
        }
        // Pressed against a limit, it's no longer a viewpoint that explains the line-ups.
        func nearEdge(_ value: Double, _ range: ClosedRange<Double>) -> Bool {
            value < range.lowerBound + 1 || value > range.upperBound - 1
        }
        guard !nearEdge(best[0], limits.distance), !nearEdge(best[1], limits.height) else { return nil }
        return EyeLineUp.Fit(eyeDistance: best[0], eyeHeight: best[1], error: (missed(best) / corners).squareRoot())
    }
}

/// Where `cost` is lowest, searched for from `start` by the Nelder–Mead method: a small simplex of
/// points that reflects, stretches and shrinks its way downhill. `steps` sizes the first simplex.
func lowestPoint(of cost: ([Double]) -> Double, from start: [Double], steps: [Double],
                 iterations: Int = 500) -> [Double] {
    let n = start.count
    var points = [start] + (0..<n).map { i -> [Double] in
        var point = start
        point[i] += steps[i]
        return point
    }
    var values = points.map(cost)

    for _ in 0..<iterations {
        let order = values.indices.sorted { values[$0] < values[$1] }
        points = order.map { points[$0] }
        values = order.map { values[$0] }
        if values[n].isFinite, values[n] - values[0] < 1e-7 { break }

        let centroid = (0..<n).map { i in points[0..<n].map { $0[i] }.reduce(0, +) / Double(n) }
        func along(_ t: Double) -> [Double] { (0..<n).map { centroid[$0] + t * (points[n][$0] - centroid[$0]) } }

        let reflected = along(-1), reflectedValue = cost(reflected)
        if reflectedValue < values[0] {
            let expanded = along(-2), expandedValue = cost(expanded)
            (points[n], values[n]) = expandedValue < reflectedValue ? (expanded, expandedValue) : (reflected, reflectedValue)
        } else if reflectedValue < values[n - 1] {
            (points[n], values[n]) = (reflected, reflectedValue)
        } else {
            let contracted = reflectedValue < values[n] ? along(-0.5) : along(0.5)
            let contractedValue = cost(contracted)
            if contractedValue < min(reflectedValue, values[n]) {
                (points[n], values[n]) = (contracted, contractedValue)
            } else {
                for i in 1...n {
                    points[i] = (0..<n).map { points[0][$0] + 0.5 * (points[i][$0] - points[0][$0]) }
                    values[i] = cost(points[i])
                }
            }
        }
    }
    return points[values.indices.min { values[$0] < values[$1] }!]
}
