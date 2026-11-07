import Foundation
import IOKit
import MetrCore

/// Reads how busy the Apple Silicon GPU is from the IOKit registry (GPU-01): the
/// `PerformanceStatistics` property of every `IOAccelerator` service, key "Device Utilization %".
/// No root and no private framework. The keys are undocumented and verified only on the M4 dev
/// Mac, so every failure path is `.unavailable` and the window hides the value (D-20); `0` is a
/// real reading. Confined to the sampler queue.
///
/// The initializer creates no IOKit object (RESEARCH Pitfall 16): the first window sample creates
/// and releases everything it touches, and nothing is read while the window is closed.
public final class GPUCollector {
    private static let statisticsKey = "PerformanceStatistics"
    private static let utilizationKey = "Device Utilization %"
    private static let coreCountKey = "gpu-core-count"
    private static let modelKey = "model"

    /// Read from the first accelerator that has them, then reused.
    private var chipName: String?
    private var coreCount: Int?

    public init() {}

    /// The busiest accelerator's utilization (RESEARCH Open Question 6), or `.unavailable` when no
    /// accelerator exists or none reports a number. Never a fabricated zero.
    public func sample() -> Reading<GPUReading> {
        var iterator: io_iterator_t = 0
        let status = IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator)
        guard status == KERN_SUCCESS else { return .unavailable }
        defer { IOObjectRelease(iterator) }

        var values: [Double] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            if let statistics = Self.dictionary(of: service, key: Self.statisticsKey),
                let utilization = Self.utilization(fromStatistics: statistics)
            {
                values.append(utilization)
            }
            readIdentity(of: service)
        }
        guard let busiest = Self.best(values) else { return .unavailable }
        return .value(GPUReading(utilization: busiest, chipName: chipName, coreCount: coreCount))
    }

    /// "Device Utilization %" as a 0...1 fraction. nil for a missing key or a value that is not a
    /// number (a String, a Bool), so a registry shape change reads as unavailable.
    static func utilization(fromStatistics statistics: [String: Any]) -> Double? {
        guard let percent = number(statistics[utilizationKey]) else { return nil }
        return min(max(percent / 100, 0), 1)
    }

    /// The busiest of several accelerators, nil when there are none.
    static func best(_ values: [Double]) -> Double? {
        values.max()
    }

    /// The model name and core count come from the first service that has them, and stay cached.
    private func readIdentity(of service: io_registry_entry_t) {
        if chipName == nil {
            chipName = Self.string(of: service, key: Self.modelKey)
        }
        if coreCount == nil, let count = Self.number(Self.property(of: service, key: Self.coreCountKey)),
            count >= 1
        {
            coreCount = Int(count)
        }
    }

    // MARK: Registry helpers (each retained CF value is taken exactly once)

    private static func property(of service: io_registry_entry_t, key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }

    private static func dictionary(of service: io_registry_entry_t, key: String) -> [String: Any]? {
        property(of: service, key: key) as? [String: Any]
    }

    /// The registry stores the model as a string on current chips; a data blob is accepted too.
    private static func string(of service: io_registry_entry_t, key: String) -> String? {
        let raw = property(of: service, key: key)
        let text: String?
        if let string = raw as? String {
            text = string
        } else if let data = raw as? Data {
            text = String(decoding: data, as: UTF8.self)
        } else {
            text = nil
        }
        let trimmed = text?.trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespacesAndNewlines))
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// A finite number, from a Swift or a bridged value. Booleans and strings are not numbers.
    private static func number(_ value: Any?) -> Double? {
        guard let value, let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }
}
