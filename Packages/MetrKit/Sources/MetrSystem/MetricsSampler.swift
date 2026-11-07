import Dispatch
import Foundation
import MetrCore

/// Queue-confined sampling pipeline. Owns one serial utility queue, one `SamplingScheduler`
/// (and through it the single `TickSource`) and the collectors; emits immutable `MetricsBatch`
/// values to a `@Sendable` sink.
public final class MetricsSampler: @unchecked Sendable {
    /// Metrics this build has collectors for.
    private static let supported: Set<Metric> = [.cpu, .memory, .disk, .processes]

    private let queue = DispatchQueue(label: "Metr.sampler", qos: .utility)
    private let scheduler: SamplingScheduler
    private let cpu = CPUCollector()  // confined to `queue`
    private let memory = MemoryCollector()  // confined to `queue`
    private let disk = DiskCollector()  // confined to `queue`
    private let processes: ProcessCollector  // confined to `queue`
    /// The one top child behind the process list. Started by the collector on the first process
    /// sample and stopped by its `reset()`, so it exists only while the panel is open or the window shows Processes.
    private let topStream: TopStream
    private var registry = DemandRegistry()  // confined to `queue`
    private var diagnostics: (@Sendable (String) -> Void)?  // confined to `queue`
    private var emit: (@Sendable (MetricsBatch) -> Void)?  // confined to `queue`

    public init(cadenceScale: Double = 1) {
        scheduler = SamplingScheduler(queue: queue, cadenceScale: cadenceScale)
        // The CPU window floor scales with the cadence, like the scheduler's own.
        let scale = min(max(cadenceScale, SamplingPlan.scaleRange.lowerBound), SamplingPlan.scaleRange.upperBound)
        let stream = TopStream()
        topStream = stream
        processes = ProcessCollector(top: stream, minimumCPUWindowNanos: UInt64(500_000_000 * scale))
    }

    /// Starts the scheduler. `diagnostics` receives plain log lines (never user-facing).
    public func start(
        onBatch: @escaping @Sendable (MetricsBatch) -> Void,
        diagnostics: (@Sendable (String) -> Void)? = nil
    ) {
        queue.async {
            self.diagnostics = diagnostics
            self.emit = onBatch
            self.cpu.resetBaseline()
            self.scheduler.onPlanChange = { plan in
                diagnostics?(Self.describe(plan))
            }
        }
        // Warm-up (D-20, RESEARCH Open Question 2): top's first block carries every process's
        // memory (system rows appear about 0.2 s after the child starts) and its second carries
        // the first valid CPU (about 2.2 s). Each triggers an early process sample instead of
        // waiting out the 2 s cadence. `deliverNow` is a no-op unless the plan carries processes,
        // so a stray block can never add process work to the idle state.
        let scheduler = self.scheduler
        topStream.setBlockHandler { block in
            if block.sequence == 1 || block.sequence == 2 {
                scheduler.deliverNow([.processes])
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
                if sampled.contains(.processes) { batch.processes = processes.sample() }
                onBatch(batch)
            },
            onBaseline: { [self] in
                // Runs on `queue`, right before the scheduler's all-metrics baseline tick: a
                // delta must never span a suspension.
                cpu.resetBaseline()
                processes.reset()
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
            let before = self.registry.active
            if self.registry.cancel(consumer) {
                if SamplingPlan.carriesProcesses(before) && !SamplingPlan.carriesProcesses(self.registry.active) {
                    // Nothing wants processes any more (D-20), even if the window stays registered
                    // on another section (RESEARCH Pitfall 4): drop the baselines, which stops the
                    // top child, and hand the store a pending reading, so a later open never shows
                    // stale numbers. Both run on this serial queue, ahead of any later baseline.
                    self.processes.reset()
                    self.emit?(MetricsBatch(processes: .pending, elapsed: 0))
                }
                self.scheduler.setDemand(self.registry.active)
            }
        }
    }

    public func suspend(reason: SuspendReason) {
        queue.async {
            self.diagnostics?("suspend reason=\(reason.rawValue)")
            self.scheduler.suspend(reason: reason)
            // No top child survives sleep or display-off (T-02-21). The reset is queued behind the
            // scheduler's own suspend, so no process sample can restart the child in between: a
            // tick or early delivery queued earlier runs first and is stopped by this reset, and
            // one queued later finds the scheduler suspended and does nothing. Resume re-primes
            // through onBaseline, and the next process sample starts a fresh child.
            self.queue.async { self.processes.reset() }
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

    /// The pid of the top child behind the process list, nil when none runs. Read on the sampler
    /// queue; used only by the lifecycle tests through `@testable import`.
    func topChildPID() -> Int32? {
        queue.sync { topStream.childPID }
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
