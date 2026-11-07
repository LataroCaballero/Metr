import Darwin
import Dispatch
import MetrCore

/// Reads the kernel's 64-bit per-interface byte counters and turns consecutive snapshots into an
/// aggregate download and upload rate over the physical interfaces (NET-01, D-19).
///
/// The source is the routing sysctl in its interface-list-2 form, whose records carry the 64-bit
/// data block, so a counter never wraps at 4 GiB. The older per-interface address list API has
/// 32-bit byte counters and is never used. No socket is opened and nothing leaves the Mac: the
/// figures come only from the kernel. Confined to the sampler queue; not Sendable.
public final class NetworkCollector {
    /// Cumulative bytes received and sent, keyed by interface index, physical interfaces only.
    struct Counters: Equatable {
        var received: [UInt32: UInt64] = [:]
        var sent: [UInt32: UInt64] = [:]
    }

    private var baseline: (counters: Counters, uptimeNanos: UInt64)?

    public init() {}

    /// First call (or the first after `resetBaseline()`) stores a baseline and returns `.pending`.
    /// Later calls return the rate over the monotonic time since the previous call. A rate the math
    /// rejects (a reset or an impossible burst) rebases and returns `.pending`; a failed read is
    /// `.unavailable`. Never a fabricated zero for missing data.
    public func sample() -> Reading<NetworkReading> {
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
        // Per interface, then summed: a new interface contributes 0 on its first sample.
        let down = CounterDeltas.total(previous: previous.counters.received, current: current.received)
        let up = CounterDeltas.total(previous: previous.counters.sent, current: current.sent)
        guard let downRate = NetworkMath.rate(bytes: down, seconds: seconds),
            let upRate = NetworkMath.rate(bytes: up, seconds: seconds)
        else { return .pending }
        return .value(
            NetworkReading(
                downBytesPerSec: downRate, upBytesPerSec: upRate, downBytes: down, upBytes: up))
    }

    /// Forgets the baseline: the next sample is `.pending`. Called on a real wake, when the window
    /// closes and at start, so no rate ever spans a sleep or a gap in sampling.
    public func resetBaseline() {
        baseline = nil
    }

    // MARK: Kernel read

    /// The counters of every physical interface, or nil when the kernel call fails.
    static func readCounters() -> Counters? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        // The interface list can grow between the size query and the read, so leave headroom and
        // retry once on ENOMEM (T-03-12).
        for attempt in 0..<2 {
            var size = 0
            guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var buffer = [UInt8](repeating: 0, count: size + 4096)
            var length = buffer.count
            if sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) != 0 {
                if errno == ENOMEM, attempt == 0 { continue }
                return nil
            }
            return parse(buffer, length: min(length, buffer.count))
        }
        return nil
    }

    /// Walks the variable-length records by their own length, with bounds checks, and keeps the
    /// 64-bit counters of the physical interfaces. Unaligned loads: a record start is only 4-byte
    /// aligned.
    static func parse(_ buffer: [UInt8], length: Int) -> Counters {
        var counters = Counters()
        let headerSize = MemoryLayout<if_msghdr2>.size
        buffer.withUnsafeBytes { raw in
            var offset = 0
            // A record starts with ifm_msglen (u_short), ifm_version, ifm_type.
            while offset + 4 <= length {
                let messageLength = Int(raw.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
                // A zero or short length would never advance; a record past the end is truncated.
                guard messageLength >= 4, offset + messageLength <= length else { break }
                let type = Int32(raw[offset + 3])
                if type == RTM_IFINFO2, messageLength >= headerSize {
                    let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    let index = UInt32(header.ifm_index)
                    if isPhysical(index: index) {
                        counters.received[index] = header.ifm_data.ifi_ibytes
                        counters.sent[index] = header.ifm_data.ifi_obytes
                    }
                }
                offset += messageLength
            }
        }
        return counters
    }

    private static func isPhysical(index: UInt32) -> Bool {
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        guard if_indextoname(index, &name) != nil else { return false }
        let bytes = name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return NetworkMath.isPhysical(interfaceName: String(decoding: bytes, as: UTF8.self))
    }
}
