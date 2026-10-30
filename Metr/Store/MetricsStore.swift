import Foundation
import MetrCore
import MetrSystem
import Observation

/// MainActor-owned snapshot of the latest readings. Fed by `AppDelegate.makeBatchSink`.
@MainActor
@Observable
final class MetricsStore {
    private(set) var cpu: Reading<CPUReading> = .pending
    private(set) var memory: Reading<MemoryReading> = .pending
    private(set) var disk: Reading<DiskReading> = .pending
    /// Disk tint with its 1-point hysteresis (D-03). One state shared by the glyph and the panel.
    private(set) var diskTint: RingTint = .none

    /// The system's names for the core tiers (`hw.perflevelN.name`, perflevel 0 first), read once.
    /// Empty when the layout cannot be read. They name the cluster bars while CPU is not yet sampled.
    let coreLevelNames: [String] = CPUCollector.readLayout()?.levels.map(\.name) ?? []

    /// Memory tint straight from the pressure level (D-01); it has no hysteresis of its own.
    var memoryTint: RingTint { TintLogic.memory(memory.value?.pressure) }

    /// True once no metric is still `.pending`. An `.unavailable` reading counts as answered.
    var isReadyForPanel: Bool {
        cpu != .pending && memory != .pending && disk != .pending
    }

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
        diskTint = TintLogic.disk(freeFraction: disk.value?.freeFraction, previous: diskTint)
        didApply?()
        DebugHooks.log(Self.describe(cpu: cpu, memory: memory, disk: disk))
    }

    /// Pending and unavailable readings are named, never printed as a number.
    private static func describe(
        cpu: Reading<CPUReading>, memory: Reading<MemoryReading>, disk: Reading<DiskReading>
    ) -> String {
        "batch cpu=\(text(cpu.value.map(\.total), cpu)) mem=\(text(memory.value?.ringFill, memory))"
            + " disk=\(text(disk.value?.usedFraction, disk))"
            + " diskfree=\(freeBytesText(disk))"
            // PANEL-01: the CPU split, for scripts/verify/cpu-vs-top.sh. DEBUG log only.
            + " cpuuser=\(text(cpu.value.map(\.user), cpu)) cpusys=\(text(cpu.value.map(\.system), cpu))"
            + " clusters=\(clustersText(cpu))"
    }

    /// `Name:0.00,Name:0.00`, `none` when the value has no clusters, or the pending / unavailable word.
    /// Tier names are system names, not personal data. DEBUG log only.
    private static func clustersText(_ cpu: Reading<CPUReading>) -> String {
        if let value = cpu.value {
            if value.clusters.isEmpty { return "none" }
            return value.clusters.map { "\($0.name):" + String(format: "%.2f", $0.usage) }.joined(separator: ",")
        }
        if case .unavailable = cpu { return "unavailable" }
        return "pending"
    }

    /// Whole bytes free, for scripts/verify/disk-live.sh. DEBUG log only.
    private static func freeBytesText(_ disk: Reading<DiskReading>) -> String {
        if let free = disk.value?.availableBytes { return String(free) }
        if case .unavailable = disk { return "unavailable" }
        return "pending"
    }

    private static func text<V>(_ number: Double?, _ reading: Reading<V>) -> String {
        if let number { return String(format: "%.2f", number) }
        if case .unavailable = reading { return "unavailable" }
        return "pending"
    }
}
