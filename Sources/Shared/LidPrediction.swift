import Foundation

/// When to read the lid sensor, and what time to give each value.
///
/// The sensor's fine angle changes on its own steady clock, about every 99.5 ms. Reading every 16 ms
/// sees a new value up to 16 ms late, and only knows it appeared some time since the read before.
/// This reads every `step` only from `early` before the next value is due until it arrives (or until
/// `late` after it was due): each value is caught within about 1.5 ms and stamped within ±0.75 ms of
/// when it appeared, for about 38 reads a second while the lid moves (27 while it's still) instead of
/// 62. A window that closes without a change means the sensor repeated its value, and says so.
struct PhaseLock {
    struct Sample: Sendable {
        /// When the value appeared, on the CACurrentMediaTime clock.
        var stamp: Double
        var value: Double
        /// The sensor ticked without its value changing.
        var repeated: Bool
    }

    var step = 0.0015
    /// The spacing of reads in a window once the lid has been still for `restAfter` seconds.
    var restStep = 0.004
    var restAfter = 1.0
    var early = 0.003
    var late = 0.004
    /// The spacing of reads while looking for the sensor's clock: `acquireStep` at first, then
    /// `acquireSlowStep` after 0.3 s, then 50 ms after 2 s (a rock-steady still lid).
    var acquireStep = 0.004
    var acquireSlowStep = 0.016
    var period = 0.0995

    private var due: Double?
    private var end = 0.0
    private var widen = 0.0
    private var empties = 0
    private var currentStep = 0.0015
    private var last: Double?
    private var previousRead: Double?
    private var settled = 0.0
    private var movedAt = 0.0
    private var acquiringSince = 0.0

    /// Takes one read, by when it started and the value it got, and returns when to read next and
    /// the sample that read completed, if it did.
    mutating func read(at time: Double, value: Double) -> (next: Double, sample: Sample?) {
        guard let last else {
            self.last = value
            settled = value
            movedAt = time
            acquiringSince = time
            return (time + acquireStep, nil)
        }
        let changed = value != last
        if changed {
            self.last = value
            if abs(value - settled) >= 0.1 { settled = value; movedAt = time }
        }
        guard let due else {
            // Not locked: read every so often until the value changes.
            let waited = time - acquiringSince
            let spacing = waited < 0.3 ? acquireStep : waited < 2 ? acquireSlowStep : 0.05
            guard changed else { previousRead = time; return (time + spacing, nil) }
            let stamp = previousRead == nil ? time : time - spacing / 2
            self.due = stamp + period
            widen = spacing
            empties = 0
            return (openWindow(after: time + spacing), Sample(stamp: stamp, value: value, repeated: false))
        }
        if changed {
            guard let previousRead else {
                // Already there at the window's first read: the lock slipped. Keep the value, find the clock again.
                let stamp = time - currentStep / 2
                unlock(at: time)
                return (time + acquireStep, Sample(stamp: stamp, value: value, repeated: false))
            }
            let stamp = (previousRead + time) / 2
            let error = stamp - due
            period += 0.05 * error
            self.due = due + 0.25 * error + period
            widen = 0
            empties = 0
            return (openWindow(after: time + currentStep), Sample(stamp: stamp, value: value, repeated: false))
        }
        previousRead = time
        if time < end { return (time + currentStep, nil) }
        // The window closed without a change: the sensor repeated its value.
        let sample = Sample(stamp: due, value: value, repeated: true)
        empties += 1
        widen = min(widen + 0.001, 0.012)
        self.due = due + period
        if empties >= 10 {
            // A second of identical values: find the sensor's clock again.
            unlock(at: time)
            return (time + acquireStep, sample)
        }
        return (openWindow(after: time + currentStep), sample)
    }

    /// The first read of the window around the next due time.
    private mutating func openWindow(after time: Double) -> Double {
        guard let due else { return time }
        end = due + late + widen
        previousRead = nil
        let start = max(time, due - early - widen)
        currentStep = start - movedAt > restAfter ? restStep : step
        return start
    }

    private mutating func unlock(at time: Double) {
        due = nil
        widen = 0
        empties = 0
        previousRead = time
        acquiringSince = time
    }
}

/// Turns the sensor's timestamped samples into the angle to draw for a frame: where the lid will be
/// when that frame lights the glass, reached without jumps. At rest it's exactly the held reading.
struct AnglePredictor {
    /// How long the sensor takes to report an angle: a value stamped s is the lid's angle at s - lead.
    var lead = 0.030
    /// From a display-link timestamp to that frame lighting the glass.
    var glass = 0.045
    /// Aims this much short of the glass: a little less lead overshoots less where the lid stops.
    var aimShort = 0.010
    /// How quickly the drawn angle closes on the prediction, per second (critically damped).
    var omega = 50.0
    /// Steps smaller than this, in degrees, are the sensor's resting wobble.
    var rest = 0.05
    /// How much of the change in speed to carry forward while the lid speeds up, and while it slows.
    var speedingUpGain = 0.25
    var slowingGain = 1.0
    /// The furthest ahead of a sample to extrapolate, in seconds.
    var maxAhead = 0.25
    /// With nothing new this long after a sample, the value is taken to have repeated.
    var stale = 0.13
    var period = 0.0995

    private var taus: [Double] = []
    private var values: [Double] = []
    private var held: Double?
    /// The sensor's resting wobble, learned as it goes: an average of the small steps that turn back
    /// on the one before, which the lid itself only does at the end of a swing. Some sensors wobble by
    /// a tenth of a degree at rest, and steps within that mustn't be taken for motion.
    private var wobble = 0.0
    private var lastStep = 0.0
    /// The prediction: angle + rate h + curve h² at h seconds after tau, for h up to `until`.
    private var target = (tau: 0.0, angle: 0.0, rate: 0.0, curve: 0.0, until: 0.0)
    private var drawn: Double?
    private var drawnRate = 0.0
    private var lastTime = 0.0
    private var lastStamp: Double?

    mutating func add(stamp: Double, value: Double) {
        if let previous = values.last {
            let step = value - previous
            if step * lastStep < 0, abs(step) < 0.5 { wobble += (abs(step) - wobble) * 0.1 }
            wobble *= 0.999
            if step != 0 { lastStep = step }
        }
        let rest = max(self.rest, 2.5 * wobble)
        lastStamp = stamp
        taus.append(stamp - lead)
        values.append(value)
        if taus.count > 3 { taus.removeFirst(); values.removeFirst() }
        if held.map({ abs(value - $0) >= rest }) ?? true { held = value }
        let n = taus.count
        let tau = taus[n - 1], angle = values[n - 1]
        guard n >= 2, abs(angle - values[n - 2]) >= rest, tau - taus[n - 2] <= 0.25 else {
            target = (tau, held ?? angle, 0, 0, 0)
            return
        }
        // The latest step's rate, moved to the latest sample by the change in rate over the last two
        // steps (the slope there of the parabola through the last three samples).
        let step = (angle - values[n - 2]) / (tau - taus[n - 2])
        var rate = step, curve = 0.0, until = maxAhead
        if n == 3, taus[1] - taus[0] <= 0.25 {
            let change = 2 * (step - (values[1] - values[0]) / (taus[1] - taus[0])) / (tau - taus[0])
            rate = step + change * (tau - taus[1]) / 2
            if rate * step <= 0 { rate = 0 }
            let slowing = change * rate < 0
            curve = (slowing ? slowingGain : speedingUpGain) * change / 2
            // Slowing down, it predicts a stop, never a turn back.
            if slowing, curve != 0 { until = min(until, -rate / (2 * curve)) }
        }
        target = (tau, angle, rate, curve, until)
    }

    /// The angle to draw for the frame with display-link timestamp `time`.
    mutating func angle(at time: Double) -> Double {
        if let lastStamp, time - lastStamp > stale, let value = values.last {
            add(stamp: lastStamp + period, value: value)
        }
        let t = time + glass - aimShort
        let ahead = t - target.tau
        let h = min(max(ahead, 0), target.until)
        let goal = target.angle + target.rate * h + target.curve * h * h
        let goalRate = ahead > 0 && ahead < target.until ? target.rate + 2 * target.curve * h : 0
        guard let drawn else {
            self.drawn = goal
            drawnRate = 0
            lastTime = t
            return goal
        }
        let dt = min(t - lastTime, 0.1)
        lastTime = t
        // Critically damped approach to the goal's line, solved exactly over the frame.
        let e0 = drawn - (goal - goalRate * dt), r0 = drawnRate - goalRate
        let k = exp(-omega * dt)
        let e = (e0 + (r0 + omega * e0) * dt) * k
        let r = (r0 - omega * (r0 + omega * e0) * dt) * k
        if goalRate == 0, abs(e) < 0.005, abs(r) < 0.1 {
            self.drawn = goal
            drawnRate = 0
        } else {
            self.drawn = goal + e
            drawnRate = goalRate + r
        }
        return self.drawn ?? goal
    }
}
