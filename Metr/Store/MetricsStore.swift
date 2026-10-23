import Foundation
import MetrCore
import Observation

/// MainActor-owned snapshot of the latest readings. Fed by `AppDelegate.makeBatchSink`.
@MainActor
@Observable
final class MetricsStore {
    private(set) var cpu: Reading<CPUReading> = .pending

    /// Called after every applied batch. Not observed; the status item redraws from it.
    @ObservationIgnored var didApply: (() -> Void)?

    func apply(_ batch: MetricsBatch) {
        if let reading = batch.cpu {
            cpu = reading
        }
        didApply?()
        DebugHooks.log(Self.describe(cpu))
    }

    private static func describe(_ reading: Reading<CPUReading>) -> String {
        switch reading {
        case .value(let v): "batch cpu=" + String(format: "%.2f", v.total)
        case .pending: "batch cpu=pending"
        case .unavailable: "batch cpu=unavailable"
        }
    }
}
