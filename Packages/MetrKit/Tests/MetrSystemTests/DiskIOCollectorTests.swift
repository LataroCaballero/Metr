import Darwin
import Foundation
import Synchronization
import Testing

import MetrCore

@testable import MetrSystem

// File-private copies of MetricsSamplerTests' helpers, which are private there.
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

@Suite struct DiskIOCollectorTests {
    @Test func skipsDiskImages() {
        #expect(DiskIOCollector.isDiskImage(parentClassName: "IODiskImageBlockStorageDeviceOutKernel"))
        #expect(!DiskIOCollector.isDiskImage(parentClassName: "IOEmbeddedNVMeBlockDevice"))
        #expect(!DiskIOCollector.isDiskImage(parentClassName: "IOBlockStorageServices"))
    }

    @Test func parsesStatistics() throws {
        let parsed = try #require(
            DiskIOCollector.counters(fromStatistics: ["Bytes (Read)": NSNumber(value: 5), "Bytes (Write)": NSNumber(value: 7)]))
        #expect(parsed.read == 5)
        #expect(parsed.write == 7)
        // A missing key, or a value that is not a number, is "no reading", never a zero.
        #expect(DiskIOCollector.counters(fromStatistics: ["Bytes (Read)": NSNumber(value: 5)]) == nil)
        #expect(DiskIOCollector.counters(fromStatistics: ["Bytes (Read)": "5", "Bytes (Write)": NSNumber(value: 7)]) == nil)
    }

    @Test func readsThisMac() async throws {
        let collector = DiskIOCollector()
        guard case .pending = collector.sample() else {
            Issue.record("the first sample must store the baseline and be pending")
            return
        }
        try await sleep(1100)
        let reading = try #require(collector.sample().value, "a second sample over a live registry read must be a value")
        #expect(reading.readBytesPerSec >= 0)
        #expect(reading.writeBytesPerSec >= 0)
    }

    @Test func resetBaselineMakesTheNextSamplePending() {
        let collector = DiskIOCollector()
        _ = collector.sample()
        collector.resetBaseline()
        guard case .pending = collector.sample() else {
            Issue.record("a sample right after resetBaseline must be pending")
            return
        }
    }

    /// Wake policy (CLAUDE.md "Wake/sleep"; the phase policy stated in 03-06): the disk I/O baseline
    /// resets on a real wake through `onBaseline`, so the first rate after the wake is measured from
    /// a post-wake baseline and no rate spans the sleep. A resume that does not re-prime keeps the
    /// baseline (WR-04). Fails if `diskIO.resetBaseline()` is missing from `onBaseline`.
    @Test func realWakeRebaselinesDiskIO() async throws {
        let sampler = MetricsSampler(cadenceScale: 0.05)
        let recorder = BatchRecorder()
        sampler.start(onBatch: { recorder.add($0) })
        sampler.register(.window)
        try await sleep(300)
        #expect(
            recorder.batches.contains { $0.diskIO?.value != nil },
            "no disk I/O value arrived while the window was open")

        sampler.suspend(reason: .systemSleep)
        try await sleep(150)
        let countBefore = recorder.batches.count
        sampler.resume(reason: .systemSleep)
        try await sleep(300)

        let afterWake = Array(recorder.batches.dropFirst(countBefore).compactMap(\.diskIO))
        let first = try #require(afterWake.first, "no disk I/O batch after the wake")
        #expect(isPending(first), "the first disk I/O batch after a real wake must be pending, not a rate across the sleep")
        #expect(afterWake.dropFirst().contains { $0.value != nil }, "no disk I/O value after the post-wake baseline")

        // A resume with no matching suspend keeps the baseline (WR-04): no pending batch follows.
        let countBeforeSpurious = recorder.batches.count
        sampler.resume(reason: .sessionInactive)
        try await sleep(300)
        sampler.stop()
        let afterSpurious = recorder.batches.dropFirst(countBeforeSpurious).compactMap(\.diskIO)
        #expect(afterSpurious.count >= 2, "disk I/O batches after the spurious resume: \(afterSpurious.count)")
        #expect(!afterSpurious.contains(where: isPending), "a spurious resume re-took the disk I/O baseline")
    }
}
