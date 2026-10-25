import Foundation
import MetrCore

/// Reads the startup volume's capacity. About 16.6 ms per call, so it only runs when the
/// `SamplingPlan` marks disk due. Confined to the sampler queue.
///
/// Foundation caches resource values per `URL` instance, and the sampler queue has no run loop
/// to flush that cache. Reading from one long-lived `URL` would freeze the reading at its first
/// value (CR-01). So the collector keeps only the volume's path and builds a fresh `URL` for
/// every sample, which makes each call hit the filesystem.
public final class DiskCollector {
    private let volumePath: String

    public init(volume: URL = URL(fileURLWithPath: "/")) {
        self.volumePath = volume.path(percentEncoded: false)
    }

    /// `.unavailable` when the call throws, a value is missing, or the total is not positive.
    public func sample() -> Reading<DiskReading> {
        let fresh = URL(filePath: volumePath, directoryHint: .isDirectory)
        guard
            let values = try? fresh.resourceValues(forKeys: [
                .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
            ]),
            let total = values.volumeTotalCapacity,
            let available = values.volumeAvailableCapacityForImportantUsage,
            total > 0
        else { return .unavailable }
        return .value(DiskReading(totalBytes: Int64(total), availableBytes: available))
    }
}
