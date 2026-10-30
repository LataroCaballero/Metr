import Darwin
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


/// `kill(pid, 0)` as (result, errno). top is setuid root but keeps the user's real uid, so the
/// same-user probe answers 0 while the child runs and ESRCH once it is gone and reaped.
private func probe(_ pid: Int32) -> (result: Int32, error: Int32) {
    let result = kill(pid, 0)
    return (result, result == 0 ? 0 : errno)
}

/// Polls `topChildPID()` until it matches `wantPresent`, up to `timeoutMs`.
private func waitForTopChild(_ sampler: MetricsSampler, present: Bool, timeoutMs: Int) async throws -> Int32? {
    var waited = 0
    while waited <= timeoutMs {
        let pid = sampler.topChildPID()
        if (pid != nil) == present { return pid }
        try await sleep(10)
        waited += 10
    }
    return sampler.topChildPID()
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

    /// T-02-21 / RESEARCH Pitfall 3: the top child exists only while panel or window demand does.
    @Test func topChildLivesOnlyWhileDemandExists() async throws {
        let sampler = MetricsSampler(cadenceScale: 0.05)
        sampler.start(onBatch: { _ in })
        try await sleep(100)
        #expect(sampler.topChildPID() == nil, "a top child exists with no demand")

        sampler.register(.panel)
        let pid = try #require(
            try await waitForTopChild(sampler, present: true, timeoutMs: 1500),
            "no top child within 1.5 s of the panel opening")
        let alive = probe(pid)
        #expect(alive.result == 0, "top pid \(pid) is not alive: result \(alive.result) errno \(alive.error)")

        sampler.cancel(.panel)
        let after = try await waitForTopChild(sampler, present: false, timeoutMs: 1000)
        #expect(after == nil, "the top child is still held after the last cancel")
        var gone = probe(pid)
        var waited = 0
        while gone.result == 0 && waited < 1000 {
            try await sleep(10)
            waited += 10
            gone = probe(pid)
        }
        sampler.stop()
        #expect(gone.result == -1 && gone.error == ESRCH, "top pid \(pid) survived: \(gone)")
    }

    /// Sleep and display-off end the child: the suspended state costs nothing, and the wake starts
    /// a fresh one.
    @Test func suspendTerminatesTheTopChild() async throws {
        let sampler = MetricsSampler(cadenceScale: 0.05)
        sampler.start(onBatch: { _ in })
        sampler.register(.panel)
        let pid = try #require(
            try await waitForTopChild(sampler, present: true, timeoutMs: 1500),
            "no top child within 1.5 s of the panel opening")
        #expect(probe(pid).result == 0)

        sampler.suspend(reason: .systemSleep)
        var gone = probe(pid)
        var waited = 0
        while gone.result == 0 && waited < 1000 {
            try await sleep(10)
            waited += 10
            gone = probe(pid)
        }
        #expect(gone.result == -1 && gone.error == ESRCH, "top pid \(pid) survived the suspend: \(gone)")
        #expect(sampler.topChildPID() == nil, "the stream still holds a child after the suspend")

        sampler.resume(reason: .systemSleep)
        let fresh = try await waitForTopChild(sampler, present: true, timeoutMs: 1500)
        sampler.stop()
        #expect(fresh != nil, "no new top child within 1.5 s of the resume")
        if let fresh { #expect(fresh != pid) }
    }
}
