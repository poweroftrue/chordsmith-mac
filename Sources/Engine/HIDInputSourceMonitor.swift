import Carbon.HIToolbox
import Foundation
import IOKit.hid

public enum PhysicalInputSource: String, Sendable {
    case m4g
    case keyboard
    case unknown
}

struct HIDKeyboardDeviceIdentity: Equatable, Sendable {
    let product: String
    let manufacturer: String
    let vendorID: Int?
    let productID: Int?
    let locationID: Int?

    var isM4GHalf: Bool {
        let searchableName = "\(manufacturer) \(product)".lowercased()
        return searchableName.contains("charachorder") ||
            searchableName.contains("forge m4g") ||
            (vendorID == HIDInputSourceMonitor.m4gVendorID && productID == HIDInputSourceMonitor.m4gProductID)
    }
}

struct HIDKeySample: Equatable, Sendable {
    let timestampNanoseconds: UInt64
    let virtualKeyCode: CGKeyCode
    let source: PhysicalInputSource
}

struct HIDInputCorrelator: Sendable {
    private(set) var samples: [HIDKeySample] = []
    let matchingToleranceNanoseconds: UInt64
    let retentionNanoseconds: UInt64

    init(
        matchingToleranceNanoseconds: UInt64 = 40_000_000,
        retentionNanoseconds: UInt64 = 250_000_000
    ) {
        self.matchingToleranceNanoseconds = matchingToleranceNanoseconds
        self.retentionNanoseconds = retentionNanoseconds
    }

    mutating func record(_ sample: HIDKeySample) {
        if samples.last == sample {
            return
        }
        samples.append(sample)
        prune(relativeTo: sample.timestampNanoseconds)
    }

    mutating func source(for timestampNanoseconds: UInt64, virtualKeyCode: CGKeyCode) -> PhysicalInputSource {
        prune(relativeTo: timestampNanoseconds)

        let bestMatch = samples.indices
            .filter { samples[$0].virtualKeyCode == virtualKeyCode }
            .map { index in
                (index: index, distance: distance(samples[index].timestampNanoseconds, timestampNanoseconds))
            }
            .filter { $0.distance <= matchingToleranceNanoseconds }
            .min { lhs, rhs in
                if lhs.distance == rhs.distance {
                    return lhs.index < rhs.index
                }
                return lhs.distance < rhs.distance
            }

        guard let bestMatch else { return .unknown }
        return samples.remove(at: bestMatch.index).source
    }

    private mutating func prune(relativeTo timestampNanoseconds: UInt64) {
        let oldestAllowed = timestampNanoseconds > retentionNanoseconds
            ? timestampNanoseconds - retentionNanoseconds
            : 0
        samples.removeAll { $0.timestampNanoseconds < oldestAllowed }
    }

    private func distance(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        lhs >= rhs ? lhs - rhs : rhs - lhs
    }
}

public struct HIDInputMonitorStatus: Equatable, Sendable {
    public let isMonitoring: Bool
    /// Number of separately enumerated Master Forge digitizer halves, not the
    /// number of complete Master Forge keyboards.
    public let m4gHalfCount: Int
    public let errorCode: Int32?

    public var displayText: String {
        if !isMonitoring {
            if errorCode == Int32(kIOReturnNotPermitted) {
                return "Master Forge detection needs Input Monitoring permission"
            }
            return "Master Forge detection unavailable"
        }
        switch m4gHalfCount {
        case 0:
            return "No Master Forge HID halves detected"
        case 1:
            return "Physical Master Forge detection active (1 half)"
        case 2:
            return "Physical Master Forge detection active (both halves)"
        default:
            return "Physical Master Forge detection active (\(m4gHalfCount) HID halves)"
        }
    }
}

public final class HIDInputSourceMonitor: @unchecked Sendable {
    // The official firmware identifies m4g_s3 and m4gr_s3 as the left and
    // right Master Forge halves. Both currently expose this USB descriptor,
    // so both must feed one logical Master Forge attribution stream.
    static let m4gVendorID = 0x303A
    static let m4gProductID = 0x829A

    private let lock = NSLock()
    private let manager: IOHIDManager
    private var correlator = HIDInputCorrelator()
    private var monitoring = false
    private var connectedM4GHalfRegistryIDs: Set<UInt64> = []

    public init() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    deinit {
        stop()
    }

    @discardableResult
    public func start() -> HIDInputMonitorStatus {
        lock.lock()
        if monitoring {
            let result = currentStatusLocked(errorCode: nil)
            lock.unlock()
            return result
        }
        lock.unlock()

        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: Self.m4gVendorID,
            kIOHIDProductIDKey as String: Self.m4gProductID,
            kIOHIDDeviceUsagePageKey as String: Int(kHIDPage_GenericDesktop),
            kIOHIDDeviceUsageKey as String: Int(kHIDUsage_GD_Keyboard)
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            let monitor = Unmanaged<HIDInputSourceMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.deviceMatched(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            let monitor = Unmanaged<HIDInputSourceMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.deviceRemoved(device)
        }, context)
        IOHIDManagerRegisterInputValueCallback(manager, { context, result, _, value in
            guard let context, result == kIOReturnSuccess else { return }
            let monitor = Unmanaged<HIDInputSourceMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.received(value)
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            return HIDInputMonitorStatus(
                isMonitoring: false,
                m4gHalfCount: discoveredM4GHalves().count,
                errorCode: openResult
            )
        }

        let devices = discoveredM4GHalves()
        lock.lock()
        connectedM4GHalfRegistryIDs = Set(devices.compactMap(Self.registryID(for:)))
        monitoring = true
        let result = currentStatusLocked(errorCode: nil)
        lock.unlock()
        return result
    }

    public func stop() {
        lock.lock()
        let wasMonitoring = monitoring
        monitoring = false
        correlator = HIDInputCorrelator()
        connectedM4GHalfRegistryIDs.removeAll()
        lock.unlock()

        guard wasMonitoring else { return }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    public func source(forEventTimestamp timestampNanoseconds: UInt64, virtualKeyCode: CGKeyCode) -> PhysicalInputSource {
        lock.lock()
        defer { lock.unlock() }
        guard monitoring else { return .unknown }
        let matchedSource = correlator.source(for: timestampNanoseconds, virtualKeyCode: virtualKeyCode)
        return matchedSource == .unknown ? .keyboard : matchedSource
    }

    public var status: HIDInputMonitorStatus {
        lock.lock()
        defer { lock.unlock() }
        return currentStatusLocked(errorCode: nil)
    }

    private func received(_ value: IOHIDValue) {
        guard let sample = Self.keySample(from: value) else { return }
        lock.lock()
        if monitoring {
            correlator.record(sample)
        }
        lock.unlock()
    }

    private func deviceMatched(_ device: IOHIDDevice) {
        guard Self.identity(for: device).isM4GHalf,
              let registryID = Self.registryID(for: device) else { return }
        lock.lock()
        connectedM4GHalfRegistryIDs.insert(registryID)
        lock.unlock()
    }

    private func deviceRemoved(_ device: IOHIDDevice) {
        guard let registryID = Self.registryID(for: device) else { return }
        lock.lock()
        connectedM4GHalfRegistryIDs.remove(registryID)
        lock.unlock()
    }

    private func discoveredM4GHalves() -> [IOHIDDevice] {
        ((IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? [])
            .filter { Self.identity(for: $0).isM4GHalf }
    }

    private func currentStatusLocked(errorCode: Int32?) -> HIDInputMonitorStatus {
        HIDInputMonitorStatus(
            isMonitoring: monitoring,
            m4gHalfCount: connectedM4GHalfRegistryIDs.count,
            errorCode: errorCode
        )
    }

    static func identity(for device: IOHIDDevice) -> HIDKeyboardDeviceIdentity {
        HIDKeyboardDeviceIdentity(
            product: stringProperty(kIOHIDProductKey, from: device) ?? "",
            manufacturer: stringProperty(kIOHIDManufacturerKey, from: device) ?? "",
            vendorID: integerProperty(kIOHIDVendorIDKey, from: device),
            productID: integerProperty(kIOHIDProductIDKey, from: device),
            locationID: integerProperty(kIOHIDLocationIDKey, from: device)
        )
    }

    static func keySample(from value: IOHIDValue) -> HIDKeySample? {
        let element = IOHIDValueGetElement(value)
        guard IOHIDElementGetUsagePage(element) == UInt32(kHIDPage_KeyboardOrKeypad) else {
            return nil
        }

        let integerValue = IOHIDValueGetIntegerValue(value)
        guard integerValue > 0 else { return nil }

        guard let usage = keyboardUsage(
            elementUsage: IOHIDElementGetUsage(element),
            isArray: IOHIDElementIsArray(element),
            integerValue: integerValue
        ) else { return nil }

        guard let virtualKeyCode = virtualKeyCode(forHIDUsage: usage) else { return nil }
        return HIDKeySample(
            timestampNanoseconds: EventClock.nanoseconds(fromMachTicks: IOHIDValueGetTimeStamp(value)),
            virtualKeyCode: virtualKeyCode,
            source: .m4g
        )
    }

    static func virtualKeyCode(forHIDUsage usage: UInt32) -> CGKeyCode? {
        hidUsageToVirtualKeyCode[usage]
    }

    /// HID Manager usually exposes every possible keyboard-array usage as an
    /// individual element. Some devices instead deliver the raw array slot,
    /// whose sentinel usage is 0xffff/0xffffffff and whose value is the scan
    /// code. Supporting both representations is required for the M4G's
    /// 12-key-rollover report descriptor.
    static func keyboardUsage(elementUsage: UInt32, isArray: Bool, integerValue: CFIndex) -> UInt32? {
        guard integerValue > 0 else { return nil }
        if isArray && elementUsage > 0xFF {
            guard integerValue <= UInt32.max else { return nil }
            return UInt32(integerValue)
        }
        return elementUsage
    }

    private static func registryID(for device: IOHIDDevice) -> UInt64? {
        let service = IOHIDDeviceGetService(device)
        guard service != IO_OBJECT_NULL else { return nil }
        var registryID: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(service, &registryID) == kIOReturnSuccess else {
            return nil
        }
        return registryID
    }

    private static func stringProperty(_ key: String, from device: IOHIDDevice) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }

    private static func integerProperty(_ key: String, from device: IOHIDDevice) -> Int? {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
    }

    private static let hidUsageToVirtualKeyCode: [UInt32: CGKeyCode] = [
        0x04: 0, 0x05: 11, 0x06: 8, 0x07: 2, 0x08: 14, 0x09: 3,
        0x0A: 5, 0x0B: 4, 0x0C: 34, 0x0D: 38, 0x0E: 40, 0x0F: 37,
        0x10: 46, 0x11: 45, 0x12: 31, 0x13: 35, 0x14: 12, 0x15: 15,
        0x16: 1, 0x17: 17, 0x18: 32, 0x19: 9, 0x1A: 13, 0x1B: 7,
        0x1C: 16, 0x1D: 6,
        0x1E: 18, 0x1F: 19, 0x20: 20, 0x21: 21, 0x22: 23,
        0x23: 22, 0x24: 26, 0x25: 28, 0x26: 25, 0x27: 29,
        0x28: 36, 0x29: 53, 0x2A: 51, 0x2B: 48, 0x2C: 49,
        0x2D: 27, 0x2E: 24, 0x2F: 33, 0x30: 30, 0x31: 42,
        0x33: 41, 0x34: 39, 0x35: 50, 0x36: 43, 0x37: 47,
        0x38: 44, 0x39: 57
    ]
}
