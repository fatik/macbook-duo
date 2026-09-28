import AppKit
import Foundation
import IOKit.hid
import Observation
import os

/// Reads the MacBook hinge angle from Apple's built-in HID orientation sensor
/// (vendor 0x05AC, product 0x8104, usage page 0x20 "Sensor", usage 0x8A "Orientation").
@MainActor
@Observable
final class LidSensor {
    /// Eased angle in degrees, updated on every screen refresh so on-screen motion stays smooth
    /// between the sensor's updates.
    private(set) var angle: Double = 0
    private(set) var isAvailable = false
    /// Screen updates per second while the lid is moving, or nil while it's still.
    private(set) var framesPerSecond: Int?

    /// The latest reading, without easing, for when timing matters more than smoothness.
    var reading: Double { latest.withLock { $0 } }

    @ObservationIgnored private let latest = OSAllocatedUnfairLock(initialState: 0.0)
    @ObservationIgnored private var poller: SensorPoller?
    @ObservationIgnored private var ticker: FrameTicker?
    @ObservationIgnored private var displayLink: CADisplayLink?
    @ObservationIgnored private var lastFrame: CFTimeInterval = 0
    @ObservationIgnored private var lastMotion: CFTimeInterval = 0
    @ObservationIgnored private var countStart: CFTimeInterval = 0
    @ObservationIgnored private var frameCount = 0

    init() {
        guard let poller = SensorPoller(), let first = poller.read() else { return }
        isAvailable = true
        angle = first
        latest.withLock { $0 = first }

        // The fine reading wobbles by a few hundredths at rest; ignoring that keeps a still lid still.
        poller.start { [latest] reading in
            latest.withLock { if abs(reading - $0) >= 0.05 { $0 = reading } }
        }
        self.poller = poller

        let ticker = FrameTicker { [weak self] link in self?.frame(link) }
        let link = NSScreen.main?.displayLink(target: ticker, selector: #selector(FrameTicker.frame(_:)))
        link?.add(to: .main, forMode: .common)
        self.ticker = ticker
        displayLink = link
    }

    private func frame(_ link: CADisplayLink) {
        advance(to: link.timestamp)
    }

    /// Eases the angle toward the latest reading for the screen refresh at `now`. Something drawing
    /// on its own display link can call this first so it draws the angle for that very refresh;
    /// calling it again for the same refresh does nothing.
    func advance(to now: CFTimeInterval) {
        guard now > lastFrame else { return }
        let elapsed = lastFrame == 0 ? 1.0 / 60 : min(now - lastFrame, 0.1)
        lastFrame = now
        countFrames(at: now)

        let target = reading
        guard angle != target else { return }
        lastMotion = now
        // Eases about 90% of the way in a fifth of a second, however long frames take.
        let next = angle + (target - angle) * (1 - exp(-elapsed / 0.085))
        angle = abs(target - next) < 0.01 ? target : next
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

/// Reads the sensor on its own queue. Each read takes most of a millisecond, which would otherwise
/// come out of every frame on the main thread.
///
/// It reads once per screen refresh while the lid moves, and a third as often once it has been
/// still for a second, since each read costs CPU time.
private final class SensorPoller: @unchecked Sendable {
    private let manager: IOHIDManager
    private let device: IOHIDDevice
    private let readsHundredths: Bool
    private let queue = DispatchQueue(label: "LidSensor", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var settled: Double?
    private var lastMovement = DispatchTime.now()
    private var isFast = true

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
              let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              let device = devices.first(where: {
                  IOHIDDeviceOpen($0, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
                      && Self.value(ofReport: 1, from: $0) != nil
              })
        else { return nil }

        self.manager = manager
        self.device = device
        readsHundredths = Self.value(ofReport: 7, from: device) != nil
    }

    func start(_ onReading: @escaping @Sendable (Double) -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in
            guard let self, let reading = read() else { return }
            pace(after: reading)
            onReading(reading)
        }
        self.timer = timer
        schedule(fast: true)
        timer.resume()
    }

    private func pace(after reading: Double) {
        // Movement beyond the sensor's resting wobble.
        if settled.map({ abs(reading - $0) >= 0.1 }) ?? true {
            settled = reading
            lastMovement = .now()
            if !isFast { schedule(fast: true) }
        } else if isFast, DispatchTime.now() > lastMovement + .seconds(1) {
            schedule(fast: false)
        }
    }

    private func schedule(fast: Bool) {
        isFast = fast
        timer?.schedule(deadline: .now(), repeating: .milliseconds(fast ? 16 : 50), leeway: .milliseconds(2))
    }

    /// The angle in degrees. Report 7 carries hundredths of a degree; report 1 only whole degrees,
    /// so it's the fallback for sensors without report 7.
    func read() -> Double? {
        if readsHundredths {
            return Self.value(ofReport: 7, from: device).flatMap { $0 <= 36000 ? Double($0) / 100 : nil }
        }
        return Self.value(ofReport: 1, from: device).map(Double.init)
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
