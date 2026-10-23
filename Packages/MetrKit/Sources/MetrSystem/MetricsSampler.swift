import Dispatch
import MetrCore

/// Queue-confined sampling pipeline. Owns one serial utility queue, one `TickSource`
/// and the collectors; emits immutable `MetricsBatch` values to a `@Sendable` sink.
public final class MetricsSampler: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Metr.sampler", qos: .utility)
    private let ticks: TickSource
    private let cpu = CPUCollector()  // confined to `queue`

    public init() {
        ticks = TickSource(queue: queue)
    }

    /// Takes the CPU baseline, then ticks every 2 s. Plan 01-03 replaces the fixed
    /// interval with the scheduler; the signature stays.
    public func start(onBatch: @escaping @Sendable (MetricsBatch) -> Void) {
        queue.async {
            self.cpu.resetBaseline()
            _ = self.cpu.sample()
        }
        ticks.start(interval: 2.0) { [self] dt in
            // Runs on `queue` (the timer's queue); the collector is confined there.
            onBatch(MetricsBatch(cpu: cpu.sample(), elapsed: dt))
        }
    }

    public func stop() {
        ticks.stop()
    }
}
