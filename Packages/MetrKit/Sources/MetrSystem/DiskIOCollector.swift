import Foundation
import IOKit
import MetrCore

/// Reads how fast the Mac reads and writes its storage from the IOKit registry (WIN-02, D-08): the
/// `Statistics` property of every `IOBlockStorageDriver`, keys "Bytes (Read)" and "Bytes (Write)",
/// cumulative since the driver appeared. No root and no private framework.
///
/// Disk images are skipped. A mounted image (the Xcode sparsebundle on this Mac) has a block-storage
/// driver of its own, but every byte it moves is also moved on the physical drive that backs it, so
/// summing both would count that I/O twice. The test is the driver's parent class: a disk image's
/// parent has "DiskImage" in its name.
///
/// Counters are kept per driver, keyed by registry entry id, and the rate is the sum of the
/// per-driver growth (`CounterDeltas.total`), never a delta of sums: a drive that is plugged in
/// or removed between two samples changes nothing. Confined to the sampler queue; not Sendable.
///
/// The initializer creates no IOKit object (RESEARCH Pitfall 16): each sample creates and releases
/// everything it touches, and nothing is read while the window is closed.
public final class DiskIOCollector {
    /// Cumulative bytes read and written, keyed by driver registry entry id, disk images excluded.
    struct Counters: Equatable {
        var read: [UInt64: UInt64] = [:]
        var write: [UInt64: UInt64] = [:]
    }

    private static let statisticsKey = "Statistics"
    private static let readKey = "Bytes (Read)"
    private static let writeKey = "Bytes (Write)"

    private var baseline: (counters: Counters, uptimeNanos: UInt64)?

    public init() {}

    /// First call (or the first after `resetBaseline()`) stores a baseline and returns `.pending`.
    /// Later calls return the rate over the monotonic time since the previous call. A rate the math
    /// rejects rebases and returns `.pending`; no readable driver is `.unavailable`. Never a
    /// fabricated zero for missing data.
    public func sample() -> Reading<DiskIOReading> {
        guard let current = Self.readCounters() else {
            baseline = nil
            return .unavailable
        }
        let now = DispatchTime.now().uptimeNanoseconds
        guard let previous = baseline else {
            baseline = (current, now)
            return .pending
        }
        baseline = (current, now)
        let seconds = Double(now &- previous.uptimeNanos) / 1_000_000_000
        // Per driver, then summed: a new driver contributes 0 on its first sample.
        let read = CounterDeltas.total(previous: previous.counters.read, current: current.read)
        let write = CounterDeltas.total(previous: previous.counters.write, current: current.write)
        // The same sanity bound as the network rate: more than 100 GB/s is a reset, not I/O.
        guard let readRate = NetworkMath.rate(bytes: read, seconds: seconds),
            let writeRate = NetworkMath.rate(bytes: write, seconds: seconds)
        else { return .pending }
        return .value(DiskIOReading(readBytesPerSec: readRate, writeBytesPerSec: writeRate))
    }

    /// Forgets the baseline: the next sample is `.pending`. Called on a real wake, when the window
    /// closes and at start, so no rate ever spans a sleep or a gap in sampling.
    public func resetBaseline() {
        baseline = nil
    }

    // MARK: Pure rules

    /// True for a driver whose parent is a disk image's device (class name contains "DiskImage").
    static func isDiskImage(parentClassName: String) -> Bool {
        parentClassName.contains("DiskImage")
    }

    /// The two cumulative counters of a driver's `Statistics`. nil when either key is missing or is
    /// not a non-negative number (a String, a Bool), so a registry shape change reads as unavailable.
    static func counters(fromStatistics statistics: [String: Any]) -> (read: UInt64, write: UInt64)? {
        guard let read = counter(statistics[readKey]), let write = counter(statistics[writeKey]) else { return nil }
        return (read, write)
    }

    private static func counter(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        // Counters are unsigned 64-bit; a negative or fractional value is not one.
        let double = number.doubleValue
        guard double.isFinite, double >= 0 else { return nil }
        return number.uint64Value
    }

    // MARK: Registry read

    /// The counters of every block-storage driver that is not a disk image, or nil when none can be
    /// read. Every iterator and service is released on every path.
    static func readCounters() -> Counters? {
        var iterator: io_iterator_t = 0
        guard
            IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator)
                == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }

        var counters = Counters()
        var readable = false
        while case let driver = IOIteratorNext(iterator), driver != 0 {
            defer { IOObjectRelease(driver) }
            if isDiskImage(driver: driver) { continue }
            var entryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(driver, &entryID) == KERN_SUCCESS,
                let statistics = IORegistryEntryCreateCFProperty(
                    driver, statisticsKey as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
                let parsed = Self.counters(fromStatistics: statistics)
            else { continue }
            counters.read[entryID] = parsed.read
            counters.write[entryID] = parsed.write
            readable = true
        }
        return readable ? counters : nil
    }

    /// Whether this driver sits under a disk image. A driver whose parent cannot be looked up is
    /// counted: a missing parent is not evidence of an image, and the other drivers still are.
    private static func isDiskImage(driver: io_registry_entry_t) -> Bool {
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(driver, kIOServicePlane, &parent) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(parent) }
        // io_name_t is a fixed 128-byte C array, imported as a tuple; read it through a raw buffer.
        var name = [CChar](repeating: 0, count: 128)
        guard IOObjectGetClass(parent, &name) == KERN_SUCCESS else { return false }
        return isDiskImage(parentClassName: String(cString: name))
    }
}
