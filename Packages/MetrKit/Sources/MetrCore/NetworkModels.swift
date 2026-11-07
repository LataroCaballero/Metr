/// STUB for the RED step.
public struct NetworkReading: Sendable, Equatable {
    public var downBytesPerSec: Double
    public var upBytesPerSec: Double
    public var downBytes: UInt64
    public var upBytes: UInt64
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

public enum NetworkMath {
    public static let maximumBytesPerSecond: Double = 100e9
    public static func isPhysical(interfaceName: String) -> Bool { false }
    public static func rate(bytes: UInt64, seconds: Double) -> Double? { nil }
}
