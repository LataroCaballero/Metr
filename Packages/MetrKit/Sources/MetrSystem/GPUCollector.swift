import Foundation
import MetrCore

/// RED-phase stub: compiles the tests so they fail on their assertions. Replaced by the real reader.
public final class GPUCollector {
    public init() {}
    public func sample() -> Reading<GPUReading> { .unavailable }
    public static func utilization(fromStatistics statistics: [String: Any]) -> Double? { nil }
    public static func best(_ values: [Double]) -> Double? { nil }
}
