/// Startup-volume capacity. `availableBytes` is the Finder-consistent "important usage" value,
/// which counts purgeable space as available (D-03).
public struct DiskReading: Sendable, Equatable {
    public var totalBytes: Int64
    public var availableBytes: Int64

    public init(totalBytes: Int64, availableBytes: Int64) {
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
    }

    /// 1 - available / total, clamped to 0...1.
    public var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(1, max(0, 1 - Double(availableBytes) / Double(totalBytes)))
    }

    public var freeFraction: Double { 1 - usedFraction }
}
