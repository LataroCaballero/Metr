import Foundation
import MetrCore

/// Reads every mounted volume. Confined to the sampler queue.
public final class VolumeCollector {
    public init() {}

    public func sample() -> Reading<[VolumeInfo]> {
        .unavailable
    }
}
