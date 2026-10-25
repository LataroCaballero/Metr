import Dispatch
import Foundation
import MetrCore

/// Queue-confined sampling pipeline. Owns one serial utility queue, one `SamplingScheduler`
/// (and through it the single `TickSource`) and the collectors; emits immutable `MetricsBatch`
/// values to a `@Sendable` sink.
public final class MetricsSampler: @unchecked Sendable {
    /// Metrics this build has collectors for.
    private static let supported: Set<Metric> = [.cpu, .memory, .disk]

    private let queue = DispatchQueue(label: "Metr.sampler", qos: .utility)
    private let scheduler: SamplingScheduler
    private let cpu = CPUCollector()  // confined to `queue`
    private let memory = MemoryCollector()  // confined to `queue`
    private let disk = DiskCollector()  // confined to `queue`
    private var registry = DemandRegistry()  // confined to `queue`
    private var diagnostics: (@Sendable (String) -> Void)?  // confined to `queue`

    public init(cadenceScale: Double = 1) {
        scheduler = SamplingScheduler(queue: queue, cadenceScale: cadenceScale)
    }

    /// Starts the scheduler. `diagnostics` receives plain log lines (never user-facing).
    public func start(
        onBatch: @escaping @Sendable (MetricsBatch) -> Void,
        diagnostics: (@Sendable (String) -> Void)? = nil
    ) {
        queue.async {
            self.diagnostics = diagnostics
            self.cpu.resetBaseline()
            self.scheduler.onPlanChange = { plan in
                diagnostics?(Self.describe(plan))
            }
        }
        scheduler.start(
            onTick: { [self] due, elapsed, priming in
                // Runs on `queue`; the collectors are confined there.
                let sampled = due.intersection(Self.supported)
                guard !sampled.isEmpty else { return }
                if priming { diagnostics?("prime") }
                diagnostics?(Self.describe(tick: elapsed, metrics: sampled))
                var batch = MetricsBatch(elapsed: elapsed)
                if sampled.contains(.cpu) { batch.cpu = cpu.sample() }
                if sampled.contains(.memory) { batch.memory = memory.sample() }
                if sampled.contains(.disk) { batch.disk = disk.sample() }
                onBatch(batch)
            },
            onBaseline: { [self] in
                // Runs on `queue`, right before the scheduler's all-metrics baseline tick: a
                // delta must never span a suspension.
                cpu.resetBaseline()
            })
    }

    public func stop() {
        scheduler.stop()
    }

    public func register(_ consumer: DemandConsumer) {
        queue.async {
            if self.registry.register(consumer) {
                self.scheduler.setDemand(self.registry.active)
            }
        }
    }

    public func cancel(_ consumer: DemandConsumer) {
        queue.async {
            if self.registry.cancel(consumer) {
                self.scheduler.setDemand(self.registry.active)
            }
        }
    }

    public func suspend(reason: SuspendReason) {
        queue.async {
            self.diagnostics?("suspend reason=\(reason.rawValue)")
            self.scheduler.suspend(reason: reason)
        }
    }

    /// The scheduler resets the CPU baseline through `onBaseline` only when it actually
    /// re-primes (it takes a fresh baseline tick, then primes). A resume with no matching
    /// suspend, or one made while another reason still holds, keeps the last baseline (WR-04).
    public func resume(reason: SuspendReason) {
        queue.async {
            self.diagnostics?("resume reason=\(reason.rawValue)")
            self.scheduler.resume(reason: reason)
        }
    }

    public func setConstrained(_ value: Bool) {
        scheduler.setConstrained(value)
    }

    // MARK: Diagnostics (POSIX formatting)

    private static func describe(_ plan: SamplingPlan) -> String {
        let base = plan.baseInterval.map { String(format: "%.1f", $0) } ?? "none"
        return "tier=\(plan.tier.rawValue) base=\(base) constrained=\(plan.constrained ? 1 : 0)"
    }

    private static func describe(tick elapsed: Double, metrics: Set<Metric>) -> String {
        let list = Metric.allCases.filter(metrics.contains).map(\.rawValue).joined(separator: ",")
        return "tick dt=\(String(format: "%.3f", elapsed)) metrics=\(list)"
    }
}
