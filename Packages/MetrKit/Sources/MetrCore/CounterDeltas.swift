/// Sums the growth of cumulative counters that are tracked per key (an interface index, a disk
/// device, a process).
///
/// The delta is taken per key and then summed, never as the difference of two sums (RESEARCH
/// Pattern 3, Pitfall 10): a key that appears between two snapshots would otherwise add its whole
/// lifetime counter as one interval of traffic, and one that vanishes would subtract. Shared by
/// the network rate (03-06) and disk I/O (03-11, 03-12).
public enum CounterDeltas {
    /// The total growth across keys present in BOTH snapshots whose counter did not go backwards.
    /// A new key contributes 0 on its first sample, a counter that went backwards (a reset) contributes
    /// 0, and a vanished key is ignored. The sum saturates at `UInt64.max` rather than trapping.
    public static func total<K: Hashable>(previous: [K: UInt64], current: [K: UInt64]) -> UInt64 {
        var sum: UInt64 = 0
        for (key, now) in current {
            guard let before = previous[key], now >= before else { continue }
            let (next, overflow) = sum.addingReportingOverflow(now - before)
            sum = overflow ? UInt64.max : next
        }
        return sum
    }
}
