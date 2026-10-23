/// Cumulative per-core scheduler ticks from `host_processor_info`.
public struct CPUTicks: Sendable, Equatable {
    public var user: UInt32
    public var system: UInt32
    public var idle: UInt32
    public var nice: UInt32

    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }
}

/// Total CPU utilization over a sampling window, 0...1.
public struct CPUReading: Sendable, Equatable {
    public var total: Double

    public init(total: Double) {
        self.total = total
    }
}

public enum CPUMath {
    /// Utilization between two snapshots, summed over all cores.
    /// Returns nil for empty arrays, mismatched core counts, or a zero total delta.
    public static func usage(previous: [CPUTicks], current: [CPUTicks]) -> CPUReading? {
        guard !previous.isEmpty, previous.count == current.count else { return nil }
        var busy: UInt64 = 0
        var total: UInt64 = 0
        for (p, c) in zip(previous, current) {
            // Wrapping subtraction: the tick counters are UInt32 and may wrap.
            let user = UInt64(c.user &- p.user)
            let system = UInt64(c.system &- p.system)
            let nice = UInt64(c.nice &- p.nice)
            let idle = UInt64(c.idle &- p.idle)
            busy += user + system + nice
            total += user + system + nice + idle
        }
        guard total > 0 else { return nil }
        return CPUReading(total: min(1, max(0, Double(busy) / Double(total))))
    }
}
