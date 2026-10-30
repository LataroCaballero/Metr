/// A metric value that is not yet known, failed, or present.
/// Pending and unavailable are never a fabricated zero.
public enum Reading<Value: Sendable & Equatable>: Sendable, Equatable {
    case pending
    case value(Value)
    case unavailable

    public var value: Value? {
        if case .value(let v) = self { return v }
        return nil
    }
}

/// One tick's worth of readings. A nil field means the metric was not sampled this tick.
public struct MetricsBatch: Sendable, Equatable {
    public var cpu: Reading<CPUReading>?
    public var memory: Reading<MemoryReading>?
    public var disk: Reading<DiskReading>?
    /// The user's processes (D-20). Present only while the panel or window is open, and
    /// `.pending` once on the last close so a later open never shows stale numbers.
    public var processes: Reading<ProcessSnapshot>?
    public var elapsed: Double

    public init(
        cpu: Reading<CPUReading>? = nil,
        memory: Reading<MemoryReading>? = nil,
        disk: Reading<DiskReading>? = nil,
        processes: Reading<ProcessSnapshot>? = nil,
        elapsed: Double
    ) {
        self.cpu = cpu
        self.memory = memory
        self.disk = disk
        self.processes = processes
        self.elapsed = elapsed
    }
}
