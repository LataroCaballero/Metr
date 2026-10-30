import Synchronization
import Testing

import MetrCore

@testable import MetrSystem

private final class BatchRecorder: Sendable {
    private let storage = Mutex<[MetricsBatch]>([])
    func add(_ batch: MetricsBatch) { storage.withLock { $0.append(batch) } }
    var batches: [MetricsBatch] { storage.withLock { $0 } }
}

private func sleep(_ ms: Int) async throws {
    try await Task.sleep(for: .milliseconds(ms))
}

private func isPending<V>(_ reading: Reading<V>) -> Bool {
    if case .pending = reading { return true }
    return false
}

/// WR-04: the CPU baseline is reset only when the scheduler takes a fresh baseline.
/// cadenceScale 0.05 gives an idle base of 0.1 s and a 25 ms priming delay.
@Suite struct MetricsSamplerTests {
    @Test func resumeWithoutSuspendKeepsTheCPUBaseline() async throws {
        let sampler = MetricsSampler(cadenceScale: 0.05)
        let recorder = BatchRecorder()
        sampler.start(onBatch: { recorder.add($0) })
        try await sleep(300)
        let countBefore = recorder.batches.count
        #expect(countBefore >= 2)

        sampler.resume(reason: .sessionInactive)
        try await sleep(350)
        sampler.stop()

        let cpuAfter = recorder.batches.dropFirst(countBefore).compactMap(\.cpu)
        #expect(cpuAfter.count >= 2, "cpu batches after the resume: \(cpuAfter.count)")
        #expect(!cpuAfter.contains(where: isPending), "a spurious resume left a pending CPU batch")
    }

    @Test func realResumeRebaselinesThenPrimes() async throws {
        let sampler = MetricsSampler(cadenceScale: 0.05)
        let recorder = BatchRecorder()
        sampler.start(onBatch: { recorder.add($0) })
        try await sleep(300)
        sampler.suspend(reason: .systemSleep)
        try await sleep(150)
        let countBefore = recorder.batches.count

        sampler.resume(reason: .systemSleep)
        try await sleep(300)
        sampler.stop()

        let cpuAfter = Array(recorder.batches.dropFirst(countBefore).compactMap(\.cpu))
        let first = try #require(cpuAfter.first, "no CPU batch after the resume")
        #expect(isPending(first), "the baseline tick after a real resume must be pending")
        #expect(cpuAfter.dropFirst().contains { $0.value != nil }, "no priming value after the baseline")
    }

    /// D-20: closing the last consumer returns the store's processes to pending and stops reading.
    @Test func cancellingTheLastDemandEmitsPendingProcesses() async throws {
        let sampler = MetricsSampler(cadenceScale: 0.05)
        let recorder = BatchRecorder()
        sampler.start(onBatch: { recorder.add($0) })
        sampler.register(.panel)
        try await sleep(300)
        #expect(
            recorder.batches.contains { $0.processes?.value != nil },
            "no processes value arrived while the panel was open")

        sampler.cancel(.panel)
        try await sleep(100)
        let settled = recorder.batches.count
        try await sleep(250)
        sampler.stop()

        let batches = recorder.batches
        let pendingIndex = try #require(
            batches.firstIndex { $0.processes.map(isPending) == true },
            "no processes .pending batch after the last cancel")
        #expect(
            !batches.dropFirst(pendingIndex + 1).contains { $0.processes?.value != nil },
            "a processes value arrived after the pending batch")
        #expect(
            !batches.dropFirst(settled).contains { $0.processes != nil },
            "processes were still being emitted after the panel closed")
    }
}
