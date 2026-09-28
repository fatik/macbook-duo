import AppKit
import Foundation
import IOKit.hid
import Observation
import os
import QuartzCore

/// Reads the MacBook hinge angle from Apple's built-in HID orientation sensor
/// (vendor 0x05AC, product 0x8104, usage page 0x20 "Sensor", usage 0x8A "Orientation").
@MainActor
@Observable
final class LidSensor {
    /// The one the app shares, so the sensor is read once however many views follow it.
    static let shared = LidSensor()

    /// The angle to draw for the current screen refresh: eased toward the latest reading, or where the
    /// lid will be when that frame reaches the glass if `predictsMotion`. At rest it's exactly the
    /// latest reading.
    private(set) var angle: Double = 0
    private(set) var isAvailable = false
    /// Screen updates per second while the lid is moving, or nil while it's still.
    private(set) var framesPerSecond: Int?

    /// The latest reading, without prediction, for when the lid is known to be still.
    var reading: Double { inbox.withLock { $0.reading } }

    /// Whether the angle is predicted to when each frame reaches the glass, rather than eased toward
    /// the latest reading. Prediction lags less while the lid moves, but between the sensor's ten
    /// readings a second it has to guess, and when the lid stops or turns it overshoots and springs
    /// back, which looks like jelly; easing never overshoots, so it's the default.
    var predictsMotion = false

    /// How long the sensor takes to report an angle, in seconds, for predicting.
    var sensorDelay: Double {
        get { predictor.lead }
        set { predictor.lead = newValue }
    }

    private struct Inbox {
        var reading = 0.0
        var samples: [PhaseLock.Sample] = []
    }

    @ObservationIgnored private let inbox = OSAllocatedUnfairLock(initialState: Inbox())
    @ObservationIgnored private var predictor = AnglePredictor()
    @ObservationIgnored private var poller: SensorPoller?
    @ObservationIgnored private var ticker: FrameTicker?
    @ObservationIgnored private var displayLink: CADisplayLink?
    @ObservationIgnored private var lastFrame: CFTimeInterval = 0
    @ObservationIgnored private var lastMotion: CFTimeInterval = 0
    @ObservationIgnored private var countStart: CFTimeInterval = 0
    @ObservationIgnored private var frameCount = 0
    @ObservationIgnored private var isActive = true

    init() {
        connect()
    }

    /// Looks for the sensor and starts reading it, if it isn't already: at launch, and again whenever
    /// someone asks to check after it wasn't found.
    func connect() {
        guard !isAvailable, let poller = SensorPoller(), let first = poller.read() else { return }
        isAvailable = true
        angle = first
        predictor.add(stamp: CACurrentMediaTime(), value: first)
        inbox.withLock { $0.reading = first }

        poller.start { [inbox] sample in
            inbox.withLock {
                // The predictor only needs the last few, if frames stop coming for a while.
                if $0.samples.count >= 8 { $0.samples.removeFirst() }
                $0.samples.append(sample)
                // The fine reading wobbles by a few hundredths at rest; ignoring that keeps it still.
                if abs(sample.value - $0.reading) >= 0.05 { $0.reading = sample.value }
            }
        }
        self.poller = poller

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                          queue: .main) { [weak poller] _ in poller?.wake() }

        let ticker = FrameTicker { [weak self] link in self?.frame(link) }
        let link = NSScreen.main?.displayLink(target: ticker, selector: #selector(FrameTicker.frame(_:)))
        link?.add(to: .main, forMode: .common)
        self.ticker = ticker
        displayLink = link
    }

    private func frame(_ link: CADisplayLink) {
        advance(to: link.timestamp)
    }

    /// Stops reading the sensor while nothing follows the lid, and starts again when something does:
    /// each read costs a little CPU, twenty-odd times a second even with the lid still.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        displayLink?.isPaused = !active
        if active { poller?.resume() } else { poller?.suspend() }
    }

    /// Updates the angle for the screen refresh with display-link timestamp `now`. Something drawing on
    /// its own display link can call this first so it draws the angle for that very refresh; calling it
    /// again for the same refresh does nothing.
    func advance(to now: CFTimeInterval) {
        guard now > lastFrame else { return }
        let elapsed = lastFrame == 0 ? 1.0 / 60 : min(now - lastFrame, 0.1)
        lastFrame = now
        countFrames(at: now)
        // The predictor follows every sample either way, so switching to it needs no warming up.
        let samples = inbox.withLock { inbox in
            defer { inbox.samples.removeAll(keepingCapacity: true) }
            return inbox.samples
        }
        for sample in samples { predictor.add(stamp: sample.stamp, value: sample.value) }
        let next: Double
        if predictsMotion {
            next = predictor.angle(at: now)
        } else {
            // Eases about 90% of the way to the latest reading in a fifth of a second, however long
            // frames take.
            let target = reading
            let eased = angle + (target - angle) * (1 - exp(-elapsed / 0.085))
            next = abs(target - eased) < 0.01 ? target : eased
        }
        guard next != angle else { return }
        angle = next
        lastMotion = now
    }

    private func countFrames(at now: CFTimeInterval) {
        frameCount += 1
        guard now - countStart >= 1 else { return }
        let rate = now - lastMotion < 0.5 ? Int((Double(frameCount) / (now - countStart)).rounded()) : nil
        if rate != framesPerSecond { framesPerSecond = rate }
        frameCount = 0
        countStart = now
    }
}

/// Reads the sensor on its own queue, when PhaseLock says to: densely around each new value, not at all
/// in between. Each read takes about half a millisecond.
///
/// The timer is a strict one-shot with no leeway: measured here, it fires 0.03 ms late (0.1 at most),
/// where a plain sleep or timer wakes 0.4 ms late on short waits and 3-5 ms late on the ~90 ms wait
/// between windows, which would open windows after the value had already changed.
private final class SensorPoller: @unchecked Sendable {
    private let manager: IOHIDManager
    private var device: IOHIDDevice
    private var readsHundredths: Bool
    private let queue = DispatchQueue(label: "LidSensor", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var lock = PhaseLock()
    /// Reads in a row that failed: after a while, the device is looked for and opened again.
    private var failures = 0

    init?() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey: 0x05AC,
            kIOHIDProductIDKey: 0x8104,
            kIOHIDPrimaryUsagePageKey: 0x20,
            kIOHIDPrimaryUsageKey: 0x8A,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
              let device = Self.lidDevice(in: manager)
        else { return nil }

        self.manager = manager
        self.device = device
        readsHundredths = Self.value(ofReport: 7, from: device) != nil
    }

    /// The lid's sensor, opened. Some external displays report the same kind of sensor, always at 0,
    /// so the built-in one comes first.
    private static func lidDevice(in manager: IOHIDManager) -> IOHIDDevice? {
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return nil }
        func isBuiltIn(_ device: IOHIDDevice) -> Bool {
            IOHIDDeviceGetProperty(device, kIOHIDBuiltInKey as CFString) as? Bool == true
        }
        let builtInFirst = devices.sorted { isBuiltIn($0) && !isBuiltIn($1) }
        return builtInFirst.first {
            IOHIDDeviceOpen($0, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
                && value(ofReport: 1, from: $0) != nil
        }
    }

    /// Looks for the device again and opens it: after sleep, and whenever reads keep failing.
    private func reconnect() {
        guard let found = Self.lidDevice(in: manager) else { return }
        device = found
        readsHundredths = Self.value(ofReport: 7, from: found) != nil
        lock = makeLock()
    }

    /// After waking from sleep: the device may need opening again, and the sensor's clock finding
    /// afresh.
    func wake() {
        queue.async { [self] in
            reconnect()
            schedule(at: CACurrentMediaTime())
        }
    }

    /// Reading stops, and starts again later with the sensor's clock found afresh, since it will have
    /// drifted meanwhile.
    func suspend() {
        timer?.suspend()
    }

    func resume() {
        queue.async { [self] in
            lock = makeLock()
            schedule(at: CACurrentMediaTime())
        }
        timer?.resume()
    }

    private func makeLock() -> PhaseLock {
        var lock = PhaseLock()
        if !readsHundredths {
            // Whole degrees change too rarely to lock onto: this just reads every 16 ms.
            lock.step = 0.016; lock.restStep = 0.016; lock.acquireStep = 0.016; lock.acquireSlowStep = 0.016
        }
        return lock
    }

    func start(_ onSample: @escaping @Sendable (PhaseLock.Sample) -> Void) {
        lock = makeLock()
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let time = CACurrentMediaTime()
            guard let value = read() else {
                failures += 1
                if failures.isMultiple(of: 10) { reconnect() }
                return schedule(at: time + 0.1)
            }
            failures = 0
            let (next, sample) = lock.read(at: time, value: value)
            if let sample { onSample(sample) }
            schedule(at: next)
        }
        self.timer = timer
        schedule(at: CACurrentMediaTime())
        timer.resume()
    }

    private func schedule(at time: Double) {
        timer?.schedule(deadline: .now() + max(time - CACurrentMediaTime(), 0), leeway: .nanoseconds(0))
    }

    /// The angle in degrees. Report 7 carries hundredths of a degree; report 1 only whole degrees,
    /// so it's the fallback for sensors without report 7.
    func read() -> Double? {
        let angle = readsHundredths
            ? Self.value(ofReport: 7, from: device).flatMap { $0 <= 36000 ? Double($0) / 100 : nil }
            : Self.value(ofReport: 1, from: device).map(Double.init)
        // A closed lid can read a degree below 0, as 359: no lid opens that far.
        return angle.map { $0 > 300 ? 0 : $0 }
    }

    /// A report's payload (everything after the report ID byte) as a little-endian integer.
    private static func value(ofReport id: Int, from device: IOHIDDevice) -> Int? {
        var report = [UInt8](repeating: 0, count: 8)
        var length = report.count
        guard IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, CFIndex(id), &report, &length) == kIOReturnSuccess,
              length >= 3
        else { return nil }
        return report[1..<length].reversed().reduce(0) { $0 << 8 | Int($1) }
    }
}

/// Receives screen refreshes. CADisplayLink needs an Objective-C target to call.
final class FrameTicker: NSObject {
    private let onFrame: (CADisplayLink) -> Void

    init(_ onFrame: @escaping (CADisplayLink) -> Void) {
        self.onFrame = onFrame
    }

    @objc func frame(_ link: CADisplayLink) {
        onFrame(link)
    }
}
