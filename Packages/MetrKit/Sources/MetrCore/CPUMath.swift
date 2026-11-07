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
    /// Busy fraction of each core of the cluster, 0...1, in `host_processor_info` order inside the
    /// cluster (WIN-03, D-09). Empty when any core of the cluster saw no ticks: a missing value is
    /// never a fabricated 0.
    public var coreUsage: [Double]

    public init(name: String, usage: Double, coreUsage: [Double] = []) {
        self.name = name
        self.usage = usage
        self.coreUsage = coreUsage
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

/// One `hw.perflevelN` tier: the system's name for it and how many logical CPUs it has.
public struct CoreLevel: Sendable, Equatable {
    public var name: String
    public var logicalCPUs: Int

    public init(name: String, logicalCPUs: Int) {
        self.name = name
        self.logicalCPUs = logicalCPUs
    }
}

/// The cores of one cluster as indices into the `host_processor_info` array.
public struct CoreClusterRange: Sendable, Equatable {
    public var name: String
    public var cores: Range<Int>

    public init(name: String, cores: Range<Int>) {
        self.name = name
        self.cores = cores
    }
}

/// The chip's core tiers as the kernel reports them (CPU-02, D-02).
///
/// `levels[0]` is the highest-performance tier (`hw.perflevel0`). `host_processor_info` numbers
/// the cores least-performant first (verified on an M4: indices 0-5 are Efficiency, 6-9
/// Performance; research Open Question 3, assumption A1 for 3-tier chips), so the ranges are laid
/// out by walking the levels from the highest index down.
public struct CoreLayout: Sendable, Equatable {
    public var levels: [CoreLevel]

    public init(levels: [CoreLevel]) {
        self.levels = levels
    }

    /// Core index ranges in display order (perflevel 0 first), or nil when the layout cannot be
    /// trusted: no levels, a level with no CPUs, or counts that do not add up to `coreCount`.
    /// Nil makes `CPUMath` omit the clusters rather than guess a mapping (T-02-01).
    public func clusterRanges(coreCount: Int) -> [CoreClusterRange]? {
        guard !levels.isEmpty, levels.allSatisfy({ $0.logicalCPUs > 0 }),
            levels.reduce(0, { $0 + $1.logicalCPUs }) == coreCount
        else { return nil }
        var ranges: [CoreClusterRange] = []
        var start = 0
        for level in levels.reversed() {
            ranges.append(CoreClusterRange(name: level.name, cores: start..<(start + level.logicalCPUs)))
            start += level.logicalCPUs
        }
        return ranges.reversed()
    }
}

public enum CPUMath {
    /// Utilization between two snapshots, summed over all cores.
    /// Returns nil for empty arrays, mismatched core counts, or a zero total delta.
    ///
    /// With a `layout` whose counts add up to the core count, also returns one average busy
    /// fraction per cluster (CPU-02, D-02), in `levels` order. If the layout does not add up, or a
    /// cluster saw no ticks at all, `clusters` is empty: a missing value is never a fabricated 0.
    public static func usage(
        previous: [CPUTicks], current: [CPUTicks], layout: CoreLayout? = nil
    ) -> CPUReading? {
        guard !previous.isEmpty, previous.count == current.count else { return nil }
        var userBusy: UInt64 = 0
        var systemBusy: UInt64 = 0
        var total: UInt64 = 0
        var coreBusy: [UInt64] = []
        var coreTotal: [UInt64] = []
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
            coreBusy.append(user + system + nice)
            coreTotal.append(user + system + nice + idle)
        }
        guard total > 0 else { return nil }
        let denominator = Double(total)
        let busy = Double(userBusy + systemBusy) / denominator
        return CPUReading(
            total: min(1, max(0, busy)),
            user: min(1, max(0, Double(userBusy) / denominator)),
            system: min(1, max(0, Double(systemBusy) / denominator)),
            clusters: clusters(layout: layout, coreBusy: coreBusy, coreTotal: coreTotal)
        )
    }

    private static func clusters(layout: CoreLayout?, coreBusy: [UInt64], coreTotal: [UInt64]) -> [CPUCluster] {
        guard let ranges = layout?.clusterRanges(coreCount: coreTotal.count) else { return [] }
        var result: [CPUCluster] = []
        for range in ranges {
            let busy = coreBusy[range.cores].reduce(0, +)
            let total = coreTotal[range.cores].reduce(0, +)
            guard total > 0 else { return [] }
            // One fraction per core, or none at all when any core of the range saw no ticks.
            let perCore: [Double] =
                range.cores.allSatisfy { coreTotal[$0] > 0 }
                ? range.cores.map { min(1, max(0, Double(coreBusy[$0]) / Double(coreTotal[$0]))) }
                : []
            result.append(
                CPUCluster(
                    name: range.name, usage: min(1, max(0, Double(busy) / Double(total))),
                    coreUsage: perCore))
        }
        return result
    }
}
