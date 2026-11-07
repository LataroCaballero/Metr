/// The Mac's aggregate network rate over its physical interfaces (NET-01).
public struct NetworkReading: Sendable, Equatable {
    /// Bytes per second received and sent over the last sampling interval, decimal.
    public var downBytesPerSec: Double
    public var upBytesPerSec: Double
    /// Bytes received and sent during that same interval, for the session totals of the Network section.
    public var downBytes: UInt64
    public var upBytes: UInt64
    /// The name of the connection that carries the traffic ("Wi-Fi", the service's own name, the
    /// interface name only as a last resort), and whether a primary interface exists at all.
    public var primaryInterface: String?
    public var hasPrimary: Bool

    public init(
        downBytesPerSec: Double, upBytesPerSec: Double, downBytes: UInt64, upBytes: UInt64,
        primaryInterface: String? = nil, hasPrimary: Bool = false
    ) {
        self.downBytesPerSec = downBytesPerSec
        self.upBytesPerSec = upBytesPerSec
        self.downBytes = downBytes
        self.upBytes = upBytes
        self.primaryInterface = primaryInterface
        self.hasPrimary = hasPrimary
    }
}

/// Pure rules for turning interface counters into a rate.
public enum NetworkMath {
    /// A delta implying more than this many bytes per second is a counter reset, not traffic (Pitfall 10).
    public static let maximumBytesPerSecond: Double = 100e9

    /// True only for a physical interface: "en" followed by one or more digits (Wi-Fi, Ethernet,
    /// Thunderbolt ports). Every virtual interface (tunnels, VPNs, loopback, AirDrop, bridges and
    /// the like) is false, so traffic that crosses a VPN is counted once, on the physical link (D-19).
    public static func isPhysical(interfaceName: String) -> Bool {
        let prefix = "en"
        guard interfaceName.utf8.count > prefix.utf8.count, interfaceName.hasPrefix(prefix) else { return false }
        return interfaceName.utf8.dropFirst(prefix.utf8.count).allSatisfy { (0x30...0x39).contains($0) }
    }

    /// Bytes per second over `seconds`. Nil for a non-positive interval or an impossible result.
    public static func rate(bytes: UInt64, seconds: Double) -> Double? {
        guard seconds > 0, seconds.isFinite else { return nil }
        let value = Double(bytes) / seconds
        guard value <= maximumBytesPerSecond else { return nil }
        return value
    }
}

extension NetworkMath {
    /// The longest connection name the window shows; the user chose the text, so it is capped.
    public static let maximumNameLength = 64

    /// The name of the primary connection for the window (D-18): the service's user-defined name
    /// ("Wi-Fi", or what the user called a VPN), else the interface's localized display name, else
    /// the BSD name ("en5") as a last fallback. Each candidate goes through `ProcessText.sanitize`
    /// (T-03-13: control and bidirectional characters out, length capped); an empty one is skipped.
    public static func connectionName(userDefined: String?, displayName: String?, bsdName: String?) -> String? {
        for candidate in [userDefined, displayName, bsdName] {
            guard let candidate else { continue }
            let clean = ProcessText.sanitize(candidate, limit: maximumNameLength)
            if !clean.isEmpty { return clean }
        }
        return nil
    }
}
