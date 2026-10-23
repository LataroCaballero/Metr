import Foundation
import MetrCore

/// Reads the startup volume's capacity. About 16.6 ms per call, so it only runs when the
/// `SamplingPlan` marks disk due. Confined to the sampler queue.
public final class DiskCollector {
    private let volume: URL

    public init(volume: URL = URL(fileURLWithPath: "/")) {
        self.volume = volume
    }

    /// `.unavailable` when the call throws, a value is missing, or the total is not positive.
    public func sample() -> Reading<DiskReading> {
        guard
            let values = try? volume.resourceValues(forKeys: [
                .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
            ]),
            let total = values.volumeTotalCapacity,
            let available = values.volumeAvailableCapacityForImportantUsage,
            total > 0
        else { return .unavailable }
        return .value(DiskReading(totalBytes: Int64(total), availableBytes: available))
    }
}
