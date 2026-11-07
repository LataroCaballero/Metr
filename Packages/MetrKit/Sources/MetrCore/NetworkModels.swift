/// The Mac's aggregate network rate over its physical interfaces (NET-01).
public struct NetworkReading: Sendable, Equatable {
    /// Bytes per second received and sent over the last sampling interval, decimal.
    public var downBytesPerSec: Double
    public var upBytesPerSec: Double
    /// Bytes received and sent during that same interval, for the session totals of the Network section.
    public var downBytes: UInt64
    public var upBytes: UInt64
    /// The primary interface's name, and whether one exists. Both stay nil / false until the Network
    /// section reads the primary interface.
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
