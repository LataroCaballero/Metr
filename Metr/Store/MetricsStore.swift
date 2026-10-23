import Foundation
import MetrCore
import Observation

/// MainActor-owned snapshot of the latest readings. Fed by `AppDelegate.makeBatchSink`.
@MainActor
@Observable
final class MetricsStore {
    private(set) var cpu: Reading<CPUReading> = .pending
    private(set) var memory: Reading<MemoryReading> = .pending
    private(set) var disk: Reading<DiskReading> = .pending

    /// Called after every applied batch. Not observed; the status item redraws from it.
    @ObservationIgnored var didApply: (() -> Void)?

    func apply(_ batch: MetricsBatch) {
        if let reading = batch.cpu {
            // A baseline-only sample after launch or wake is .pending: keep the last real
            // value until the primed one arrives, so the ring never flashes to a track.
            if reading == .pending, cpu.value != nil {
                // keep
            } else {
                cpu = reading
            }
        }
        if let reading = batch.memory {
            memory = reading
        }
        if let reading = batch.disk {
            disk = reading
        }
        didApply?()
        DebugHooks.log(Self.describe(cpu: cpu, memory: memory, disk: disk))
    }

    /// Pending and unavailable readings are named, never printed as a number.
    private static func describe(
        cpu: Reading<CPUReading>, memory: Reading<MemoryReading>, disk: Reading<DiskReading>
    ) -> String {
        "batch cpu=\(text(cpu.value.map(\.total), cpu)) mem=\(text(memory.value?.ringFill, memory))"
            + " disk=\(text(disk.value?.usedFraction, disk))"
    }

    private static func text<V>(_ number: Double?, _ reading: Reading<V>) -> String {
        if let number { return String(format: "%.2f", number) }
        if case .unavailable = reading { return "unavailable" }
        return "pending"
    }
}
