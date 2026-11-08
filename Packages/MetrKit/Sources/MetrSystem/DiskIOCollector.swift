import Foundation
import IOKit
import MetrCore

/// Compile-only stub for the RED run (03-11 Task 1): every behavior returns a wrong default.
public final class DiskIOCollector {
    public init() {}

    public func sample() -> Reading<DiskIOReading> { .unavailable }

    public func resetBaseline() {}

    static func isDiskImage(parentClassName: String) -> Bool { false }

    static func counters(fromStatistics statistics: [String: Any]) -> (read: UInt64, write: UInt64)? { nil }
}
