import Darwin
import MetrCore

/// Reads memory counters, pressure and swap. Confined to the sampler queue; not Sendable.
/// Any failed kernel call yields `.unavailable`, never zeros (T-01-09).
public final class MemoryCollector {
    private var cachedPageSize: UInt64?

    public init() {}

    public func sample() -> Reading<MemoryReading> {
        guard let pageSize = pageSize(),
            let counters = Self.readCounters(pageSize: pageSize),
            let total = Self.sysctlUInt64("hw.memsize"),
            let level = Self.sysctlInt32("kern.memorystatus_level"),
            let rawPressure = Self.sysctlInt32("kern.memorystatus_vm_pressure_level"),
            let pressure = MemoryPressure(rawLevel: Int(rawPressure)),
            let swap = Self.readSwapUsed()
        else { return .unavailable }
        return .value(
            MemoryReading(
                usedBytes: MemoryMath.usedBytes(counters),
                totalBytes: total,
                swapUsedBytes: swap,
                freePercent: Int(min(100, max(0, level))),
                pressure: pressure
            )
        )
    }

    /// Runtime page size (16384 on Apple Silicon), read once.
    private func pageSize() -> UInt64? {
        if let cachedPageSize { return cachedPageSize }
        var size: vm_size_t = 0
        guard host_page_size(mach_host_self(), &size) == KERN_SUCCESS, size > 0 else { return nil }
        cachedPageSize = UInt64(size)
        return cachedPageSize
    }

    static func readCounters(pageSize: UInt64) -> MemoryCounters? {
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        var vm = vm_statistics64_data_t()
        let kr = withUnsafeMutablePointer(to: &vm) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        return MemoryCounters(
            internalPages: UInt64(vm.internal_page_count),
            purgeablePages: UInt64(vm.purgeable_count),
            wiredPages: UInt64(vm.wire_count),
            compressorPages: UInt64(vm.compressor_page_count),
            pageSize: pageSize
        )
    }

    static func readSwapUsed() -> UInt64? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return usage.xsu_used
    }

    static func sysctlUInt64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    static func sysctlInt32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}
