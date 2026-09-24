import Foundation
import IOKit.hid
import Observation

/// Reads the MacBook hinge angle from Apple's built-in HID orientation sensor
/// (vendor 0x05AC, product 0x8104, usage page 0x20 "Sensor", usage 0x8A "Orientation").
@MainActor
@Observable
final class LidSensor {
    /// Eased angle in degrees, updated every frame so on-screen motion stays smooth between the
    /// sensor's updates.
    private(set) var angle: Double = 0
    private(set) var isAvailable = false

    @ObservationIgnored private var manager: IOHIDManager?
    @ObservationIgnored private var device: IOHIDDevice?
    @ObservationIgnored private var readsHundredths = false
    @ObservationIgnored private var target: Double = 0
    @ObservationIgnored private var timer: Timer?

    init() {
        connect()
        guard let reading = read() else { return }
        isAvailable = true
        target = reading
        angle = reading

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func connect() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching: [String: Any] = [
            kIOHIDVendorIDKey: 0x05AC,
            kIOHIDProductIDKey: 0x8104,
            kIOHIDPrimaryUsagePageKey: 0x20,
            kIOHIDPrimaryUsageKey: 0x8A,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess,
              let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>
        else { return }

        self.manager = manager
        device = devices.first {
            IOHIDDeviceOpen($0, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess
                && Self.value(ofReport: 1, from: $0) != nil
        }
        if let device { readsHundredths = Self.value(ofReport: 7, from: device) != nil }
    }

    /// The angle in degrees. Report 7 carries hundredths of a degree; report 1 only whole degrees,
    /// so it's the fallback for sensors without report 7.
    private func read() -> Double? {
        guard let device else { return nil }
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

    private func tick() {
        // The fine reading wobbles by a few hundredths at rest; ignoring that keeps a still lid still.
        if let reading = read(), abs(reading - target) >= 0.05 { target = reading }
        guard angle != target else { return }
        let next = angle + (target - angle) * 0.18
        angle = abs(target - next) < 0.01 ? target : next
    }
}
