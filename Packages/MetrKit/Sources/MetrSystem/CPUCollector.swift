import Darwin
import MetrCore

/// Reads per-core ticks and turns consecutive snapshots into a `Reading`.
/// Confined to the sampler queue; not Sendable.
public final class CPUCollector {
    private var baseline: [CPUTicks]?
    /// Read once: the core tiers do not change while the app runs.
    private let layout: CoreLayout?

    public init() {
        layout = Self.readLayout()
    }

    /// The core tiers from `hw.nperflevels`, `hw.perflevelN.name` and `hw.perflevelN.logicalcpu`
    /// (CPU-02). Nil when any sysctl fails or the counts do not add up to `hw.logicalcpu`.
    public static func readLayout() -> CoreLayout? {
        guard let levelCount = sysctlInt32("hw.nperflevels"), levelCount > 0,
            let logical = sysctlInt32("hw.logicalcpu")
        else { return nil }
        var levels: [CoreLevel] = []
        for i in 0..<Int(levelCount) {
            guard let name = sysctlString("hw.perflevel\(i).name"), !name.isEmpty,
                let cpus = sysctlInt32("hw.perflevel\(i).logicalcpu")
            else { return nil }
            levels.append(CoreLevel(name: name, logicalCPUs: Int(cpus)))
        }
        guard levels.reduce(0, { $0 + $1.logicalCPUs }) == Int(logical) else { return nil }
        return CoreLayout(levels: levels)
    }

    private static func sysctlInt32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    /// String sysctl: size query first, then the read.
    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// Per-core cumulative ticks, or nil if the kernel call fails.
    public static func readTicks() -> [CPUTicks]? {
        var count: natural_t = 0
        var info: processor_info_array_t? = nil
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
            let info
        else { return nil }
        // The kernel allocates this array in our address space: free it on EVERY call (T-01-03).
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: info)),
                vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            )
        }
        return (0..<Int(count)).map { i in
            let b = i * Int(CPU_STATE_MAX)
            return CPUTicks(
                user: UInt32(bitPattern: info[b + Int(CPU_STATE_USER)]),
                system: UInt32(bitPattern: info[b + Int(CPU_STATE_SYSTEM)]),
                idle: UInt32(bitPattern: info[b + Int(CPU_STATE_IDLE)]),
                nice: UInt32(bitPattern: info[b + Int(CPU_STATE_NICE)])
            )
        }
    }

    /// First call stores a baseline and returns `.pending`. Never returns 0 for missing data.
    public func sample() -> Reading<CPUReading> {
        guard let current = Self.readTicks() else { return .unavailable }
        guard let previous = baseline else {
            baseline = current
            return .pending
        }
        if previous.count != current.count {
            baseline = current
            return .pending
        }
        baseline = current
        if let reading = CPUMath.usage(previous: previous, current: current, layout: layout) {
            return .value(reading)
        }
        return .pending
    }

    public func resetBaseline() {
        baseline = nil
    }
}
