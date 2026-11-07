import Darwin
import Dispatch
import MetrCore
import SystemConfiguration

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

    /// A session with the system's configuration daemon, made on the first value and dropped with the
    /// baseline, so nothing is held at idle. Local IPC; no network traffic.
    private var configStore: SCDynamicStore?
    /// The last primary-interface lookup and when it was made; asked again at most every 5 s.
    private var primary: (name: String?, hasPrimary: Bool, uptimeNanos: UInt64)?
    private static let primaryRefreshNanos: UInt64 = 5_000_000_000

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
        let connection = primaryConnection(now: now)
        return .value(
            NetworkReading(
                downBytesPerSec: downRate, upBytesPerSec: upRate, downBytes: down, upBytes: up,
                primaryInterface: connection.name, hasPrimary: connection.hasPrimary))
    }

    /// Forgets the baseline: the next sample is `.pending`. Called on a real wake, when the window
    /// closes and at start, so no rate ever spans a sleep or a gap in sampling.
    public func resetBaseline() {
        baseline = nil
        // The network may have changed across the gap, and nothing here is held at idle.
        primary = nil
        configStore = nil
    }

    // MARK: Primary interface

    /// The primary connection, from the cache while it is under 5 s old (D-18).
    private func primaryConnection(now: UInt64) -> (name: String?, hasPrimary: Bool) {
        if let cached = primary, now &- cached.uptimeNanos < Self.primaryRefreshNanos {
            return (cached.name, cached.hasPrimary)
        }
        let found = readPrimary()
        primary = (found.name, found.hasPrimary, now)
        return found
    }

    /// Asks the dynamic store which interface the default IPv4 route uses (IPv6 only when there is
    /// no IPv4 one), then names it. Never opens a socket or sends a packet; a failed lookup is "no
    /// primary interface", never a guess.
    private func readPrimary() -> (name: String?, hasPrimary: Bool) {
        if configStore == nil {
            configStore = SCDynamicStoreCreate(nil, "Metr" as CFString, nil, nil)
        }
        guard let store = configStore else { return (nil, false) }
        let global =
            SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
            ?? SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv6" as CFString) as? [String: Any]
        guard let bsdName = global?["PrimaryInterface"] as? String, !bsdName.isEmpty else {
            return (nil, false)
        }
        var userDefined: String?
        if let service = global?["PrimaryService"] as? String, !service.isEmpty {
            let setup = SCDynamicStoreCopyValue(store, "Setup:/Network/Service/\(service)" as CFString)
            userDefined = (setup as? [String: Any])?["UserDefinedName"] as? String
        }
        // The service name is the user's own; only without one is the interface's display name read.
        let display = ProcessText.sanitize(userDefined ?? "").isEmpty ? Self.displayName(ofInterface: bsdName) : nil
        return (NetworkMath.connectionName(userDefined: userDefined, displayName: display, bsdName: bsdName), true)
    }

    /// The localized display name the system gives the interface with this BSD name ("Wi-Fi").
    private static func displayName(ofInterface bsdName: String) -> String? {
        let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []
        for interface in interfaces where SCNetworkInterfaceGetBSDName(interface) as String? == bsdName {
            return SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?
        }
        return nil
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
