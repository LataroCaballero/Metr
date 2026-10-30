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

/// One core cluster (a `hw.perflevelN` tier) and its average busy fraction over the window.
public struct CPUCluster: Sendable, Equatable {
    /// The system tier name from `hw.perflevelN.name`, e.g. "Performance". Never hard-coded.
    public var name: String
    /// Average busy fraction of the cluster's cores, 0...1.
    public var usage: Double

    public init(name: String, usage: Double) {
        self.name = name
        self.usage = usage
    }
}

/// CPU utilization over a sampling window, 0...1.
///
/// `user` and `system` share the all-core denominator of `total` (PANEL-01), so
/// `user + system == total` and each matches the corresponding figure in `top`'s "CPU usage" line.
public struct CPUReading: Sendable, Equatable {
    public var total: Double
    /// User + nice ticks over the same delta as `total`.
    public var user: Double
    /// System ticks over the same delta as `total`.
    public var system: Double
    /// One entry per core cluster in display order (empty when the layout is unknown).
    public var clusters: [CPUCluster]

    public init(total: Double, user: Double = 0, system: Double = 0, clusters: [CPUCluster] = []) {
        self.total = total
        self.user = user
        self.system = system
        self.clusters = clusters
    }
}

public enum CPUMath {
    /// Utilization between two snapshots, summed over all cores.
    /// Returns nil for empty arrays, mismatched core counts, or a zero total delta.
    public static func usage(previous: [CPUTicks], current: [CPUTicks]) -> CPUReading? {
        guard !previous.isEmpty, previous.count == current.count else { return nil }
        var userBusy: UInt64 = 0
        var systemBusy: UInt64 = 0
        var total: UInt64 = 0
        for (p, c) in zip(previous, current) {
            // Wrapping subtraction: the tick counters are UInt32 and may wrap.
            let user = UInt64(c.user &- p.user)
            let system = UInt64(c.system &- p.system)
            let nice = UInt64(c.nice &- p.nice)
            let idle = UInt64(c.idle &- p.idle)
            // PANEL-01: nice time is user time, as in top's "user" figure.
            userBusy += user + nice
            systemBusy += system
            total += user + system + nice + idle
        }
        guard total > 0 else { return nil }
        let denominator = Double(total)
        let busy = Double(userBusy + systemBusy) / denominator
        return CPUReading(
            total: min(1, max(0, busy)),
            user: min(1, max(0, Double(userBusy) / denominator)),
            system: min(1, max(0, Double(systemBusy) / denominator))
        )
    }
}
