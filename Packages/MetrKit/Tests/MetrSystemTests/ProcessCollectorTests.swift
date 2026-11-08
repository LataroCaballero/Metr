import Darwin
import Foundation
import MetrCore
import Synchronization
import Testing

@testable import MetrSystem

/// Scripted process sources: the test sets the process list, per-pid usage and the clock.
private final class FakeProcesses: Sendable {
    struct State: Sendable {
        var entries: [ProcessEntry]? = []
        var usage: [Int32: ProcessUsage] = [:]
        var now: UInt64 = 10_000_000_000
        var pathCalls = 0
        var pathOverride: [Int32: String] = [:]
        var pathAsked: Set<Int32> = []
    }
    let state = Mutex(State())

    static let uid: UInt32 = 501

    func entry(
        _ pid: Int32, start: Int64 = 1_000, uid: UInt32 = FakeProcesses.uid, ppid: Int32 = 1
    ) -> ProcessEntry {
        ProcessEntry(
            identity: ProcessIdentity(pid: pid, startMicros: start), ppid: ppid, uid: uid, command: "cmd\(pid)")
    }

    func setPath(_ pid: Int32, _ path: String) { state.withLock { $0.pathOverride[pid] = path } }
    func askedPath(for pid: Int32) -> Bool { state.withLock { $0.pathAsked.contains(pid) } }

    func set(_ entries: [ProcessEntry]?) { state.withLock { $0.entries = entries } }
    func setUsage(
        _ pid: Int32, cpuSeconds: Double, footprint: UInt64 = 50_000_000,
        diskRead: UInt64 = 0, diskWritten: UInt64 = 0
    ) {
        state.withLock {
            $0.usage[pid] = ProcessUsage(
                cpuNanos: UInt64(cpuSeconds * 1e9), footprintBytes: footprint,
                diskReadBytes: diskRead, diskWrittenBytes: diskWritten)
        }
    }
    func advance(seconds: Double) { state.withLock { $0.now += UInt64(seconds * 1e9) } }
    var pathCalls: Int { state.withLock { $0.pathCalls } }

    var sources: ProcessSources {
        ProcessSources(
            selfPID: 999, selfUID: Self.uid,
            listAll: { [self] in state.withLock { $0.entries } },
            usage: { [self] pid in state.withLock { $0.usage[pid] } },
            path: { [self] pid in
                state.withLock {
                    $0.pathCalls += 1
                    $0.pathAsked.insert(pid)
                    return $0.pathOverride[pid] ?? "/Applications/App\(pid).app/Contents/MacOS/App\(pid)"
                }
            },
            now: { [self] in state.withLock { $0.now } })
    }
}

private func footprint() -> UInt64 {
    var info = rusage_info_v4()
    let rc = withUnsafeMutablePointer(to: &info) { p in
        p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
        }
    }
    return rc == 0 ? info.ri_phys_footprint : 0
}

@Suite struct ProcessCollectorTests {
    @Test func firstSampleHasFootprintAndPendingCPU() throws {
        let fake = FakeProcesses()
        fake.set([fake.entry(10), fake.entry(11)])
        fake.setUsage(10, cpuSeconds: 1)
        fake.setUsage(11, cpuSeconds: 2, footprint: 70_000_000)
        let collector = ProcessCollector(sources: fake.sources)
        let snapshot = try #require(collector.sample().value)
        #expect(snapshot.processes.count == 2)
        #expect(snapshot.processes.allSatisfy { $0.cpuPercent == nil })
        #expect(snapshot.processes.first { $0.identity.pid == 11 }?.footprintBytes == 70_000_000)
        #expect(snapshot.processes.first { $0.identity.pid == 10 }?.footprintBytes == 50_000_000)
        #expect(!snapshot.cpuReady)
    }

    /// D-11: percent of one core, so one busy core over the whole window is 100 and more cores
    /// give more than 100.
    @Test func cpuIsPercentOfOneCore() throws {
        let fake = FakeProcesses()
        fake.set([fake.entry(10), fake.entry(11)])
        fake.setUsage(10, cpuSeconds: 1)
        fake.setUsage(11, cpuSeconds: 1)
        let collector = ProcessCollector(sources: fake.sources)
        _ = collector.sample()
        fake.advance(seconds: 2)
        fake.setUsage(10, cpuSeconds: 2)  // +1 s over 2 s = 50 %
        fake.setUsage(11, cpuSeconds: 4.64)  // +3.64 s over 2 s = 182 %
        let snapshot = try #require(collector.sample().value)
        let a = try #require(snapshot.processes.first { $0.identity.pid == 10 }?.cpuPercent)
        let b = try #require(snapshot.processes.first { $0.identity.pid == 11 }?.cpuPercent)
        #expect(abs(a - 50) < 0.001, "got \(a)")
        #expect(abs(b - 182) < 0.001, "got \(b)")
        #expect(snapshot.cpuReady)
    }

    /// T-02-10: a pid reused by a new process starts a fresh baseline.
    @Test func reusedPidWithANewStartTimeIsANewProcess() throws {
        let fake = FakeProcesses()
        fake.set([fake.entry(10, start: 1_000)])
        fake.setUsage(10, cpuSeconds: 50)
        let collector = ProcessCollector(sources: fake.sources)
        _ = collector.sample()
        fake.advance(seconds: 2)
        fake.set([fake.entry(10, start: 2_000)])
        fake.setUsage(10, cpuSeconds: 0.2)  // the new process: a smaller counter than the old one
        let snapshot = try #require(collector.sample().value)
        #expect(snapshot.processes.count == 1)
        #expect(snapshot.processes[0].cpuPercent == nil)
        #expect(snapshot.processes[0].identity.startMicros == 2_000)
    }

    @Test func otherUsersAreNotInTheSnapshot() throws {
        let fake = FakeProcesses()
        fake.set([fake.entry(10), fake.entry(11, uid: 0), fake.entry(12, uid: 88)])
        fake.setUsage(10, cpuSeconds: 1)
        fake.setUsage(11, cpuSeconds: 1)
        fake.setUsage(12, cpuSeconds: 1)
        let collector = ProcessCollector(sources: fake.sources)
        let snapshot = try #require(collector.sample().value)
        #expect(snapshot.processes.map(\.identity.pid) == [10])
    }

    @Test func aProcessWithoutUsageIsSkipped() throws {
        let fake = FakeProcesses()
        fake.set([fake.entry(10), fake.entry(11)])
        fake.setUsage(10, cpuSeconds: 1)  // 11 has no usage: it exited between the two reads
        let collector = ProcessCollector(sources: fake.sources)
        let snapshot = try #require(collector.sample().value)
        #expect(snapshot.processes.map(\.identity.pid) == [10])
    }

    @Test func aFailedListIsUnavailableNeverAnEmptyList() {
        let fake = FakeProcesses()
        fake.set(nil)
        let collector = ProcessCollector(sources: fake.sources)
        #expect(collector.sample() == .unavailable)
    }

    @Test func sequenceIncreasesByOnePerSampleAndResetClearsReadiness() throws {
        let fake = FakeProcesses()
        fake.set([fake.entry(10)])
        fake.setUsage(10, cpuSeconds: 1)
        let collector = ProcessCollector(sources: fake.sources)
        let first = try #require(collector.sample().value)
        fake.advance(seconds: 2)
        fake.setUsage(10, cpuSeconds: 2)
        let second = try #require(collector.sample().value)
        #expect(second.sequence == first.sequence + 1)
        #expect(!first.cpuReady)
        #expect(second.cpuReady)

        collector.reset()
        fake.advance(seconds: 2)
        let third = try #require(collector.sample().value)
        #expect(third.processes[0].cpuPercent == nil, "reset must make the next sample a baseline again")
        #expect(!third.cpuReady)
    }

    // MARK: Disk rates (PROC-04, D-11)

    /// Rates are the counter delta over the same window as CPU; the first reading has none; a
    /// window under the minimum carries the last rates and keeps the baseline.
    @Test func diskRatesFollowTheCPUWindow() throws {
        let fake = FakeProcesses()
        fake.set([fake.entry(10)])
        fake.setUsage(10, cpuSeconds: 1, diskRead: 100_000_000, diskWritten: 50_000_000)
        let collector = ProcessCollector(sources: fake.sources, minimumCPUWindowNanos: 500_000_000)
        let first = try #require(collector.sample().value?.processes.first)
        #expect(first.diskReadPerSec == nil)
        #expect(first.diskWritePerSec == nil)

        fake.advance(seconds: 2)
        fake.setUsage(10, cpuSeconds: 2, diskRead: 110_000_000, diskWritten: 54_000_000)
        let second = try #require(collector.sample().value?.processes.first)
        #expect(second.diskReadPerSec == 5_000_000)
        #expect(second.diskWritePerSec == 2_000_000)

        fake.advance(seconds: 0.1)  // under the floor: carried, baseline kept
        fake.setUsage(10, cpuSeconds: 2.1, diskRead: 110_900_000, diskWritten: 54_100_000)
        let carried = try #require(collector.sample().value?.processes.first)
        #expect(carried.diskReadPerSec == 5_000_000)
        #expect(carried.diskWritePerSec == 2_000_000)

        fake.advance(seconds: 1.9)  // 2.0 s since the kept baseline
        fake.setUsage(10, cpuSeconds: 3, diskRead: 112_000_000, diskWritten: 54_000_000 + 6_000_000)
        let next = try #require(collector.sample().value?.processes.first)
        #expect(next.diskReadPerSec == 1_000_000)
        #expect(next.diskWritePerSec == 3_000_000)
    }

    /// An idle process that has two readings reads a real zero, not nil.
    @Test func anIdleProcessReadsARealZero() throws {
        let fake = FakeProcesses()
        fake.set([fake.entry(10)])
        fake.setUsage(10, cpuSeconds: 1, diskRead: 7_000, diskWritten: 9_000)
        let collector = ProcessCollector(sources: fake.sources)
        _ = collector.sample()
        fake.advance(seconds: 2)
        fake.setUsage(10, cpuSeconds: 1, diskRead: 7_000, diskWritten: 9_000)
        let sample = try #require(collector.sample().value?.processes.first)
        #expect(sample.diskReadPerSec == 0)
        #expect(sample.diskWritePerSec == 0)
    }

    /// T-03-23: a pid reused by a new process never inherits the old counters.
    @Test func reusedPidStartsOver() throws {
        let fake = FakeProcesses()
        fake.set([fake.entry(10, start: 1_000)])
        fake.setUsage(10, cpuSeconds: 5, diskRead: 900_000_000, diskWritten: 900_000_000)
        let collector = ProcessCollector(sources: fake.sources)
        _ = collector.sample()
        fake.advance(seconds: 2)
        fake.set([fake.entry(10, start: 2_000)])
        fake.setUsage(10, cpuSeconds: 0.1, diskRead: 4_000, diskWritten: 4_000)
        let sample = try #require(collector.sample().value?.processes.first)
        #expect(sample.diskReadPerSec == nil)
        #expect(sample.diskWritePerSec == nil)
    }

    /// A counter that went down is not a negative rate and not a huge unsigned wrap: nil, rebased.
    @Test func backwardsCounterIsNotARate() throws {
        let fake = FakeProcesses()
        fake.set([fake.entry(10)])
        fake.setUsage(10, cpuSeconds: 1, diskRead: 80_000_000, diskWritten: 80_000_000)
        let collector = ProcessCollector(sources: fake.sources)
        _ = collector.sample()
        fake.advance(seconds: 2)
        fake.setUsage(10, cpuSeconds: 2, diskRead: 10_000, diskWritten: 90_000_000)
        let broken = try #require(collector.sample().value?.processes.first)
        #expect(broken.diskReadPerSec == nil, "the read counter decreased")
        #expect(broken.diskWritePerSec == 5_000_000, "the write counter is still good")

        fake.advance(seconds: 2)
        fake.setUsage(10, cpuSeconds: 3, diskRead: 4_010_000, diskWritten: 90_000_000)
        let rebased = try #require(collector.sample().value?.processes.first)
        #expect(rebased.diskReadPerSec == 2_000_000, "measured from the rebased counter")
    }

    @Test func resetClearsTheDiskBaselines() throws {
        let fake = FakeProcesses()
        fake.set([fake.entry(10)])
        fake.setUsage(10, cpuSeconds: 1, diskRead: 1_000_000_000, diskWritten: 1_000_000_000)
        let collector = ProcessCollector(sources: fake.sources)
        _ = collector.sample()
        fake.advance(seconds: 2)
        fake.setUsage(10, cpuSeconds: 2, diskRead: 1_002_000_000, diskWritten: 1_004_000_000)
        let measured = try #require(collector.sample().value?.processes.first)
        #expect(measured.diskReadPerSec == 1_000_000)
        #expect(measured.diskWritePerSec == 2_000_000)

        // The sleep: reset() is what suspend and onBaseline call; the counters grew while asleep.
        collector.reset()
        fake.advance(seconds: 1)
        fake.setUsage(10, cpuSeconds: 3, diskRead: 1_502_000_000, diskWritten: 1_504_000_000)
        let afterWake = try #require(collector.sample().value?.processes.first)
        #expect(afterWake.diskReadPerSec == nil, "no rate may span the sleep")
        #expect(afterWake.diskWritePerSec == nil)

        fake.advance(seconds: 2)
        fake.setUsage(10, cpuSeconds: 4, diskRead: 1_504_000_000, diskWritten: 1_506_000_000)
        let next = try #require(collector.sample().value?.processes.first)
        #expect(next.diskReadPerSec == 1_000_000, "only the post-reset delta")
        #expect(next.diskWritePerSec == 1_000_000)
    }

    /// The real host: two samples 600 ms apart contain this test process.
    @Test func liveSamplesContainThisProcess() async throws {
        let collector = ProcessCollector()
        let me = getpid()
        let first = try #require(collector.sample().value)
        let mine = try #require(first.processes.first { $0.identity.pid == me })
        #expect((mine.footprintBytes ?? 0) > 0)
        #expect(first.processes.count > 10)
        try await Task.sleep(for: .milliseconds(600))
        let second = try #require(collector.sample().value)
        let mine2 = try #require(second.processes.first { $0.identity.pid == me })
        #expect((mine2.footprintBytes ?? 0) > 0)
        #expect(mine2.cpuPercent != nil)
        #expect(second.cpuReady)
    }

    // MARK: Task 2: bounded bookkeeping

    /// A window under the minimum carries the last value and keeps the baseline, so the next
    /// full window is measured from the first reading.
    @Test func aShortWindowKeepsThePreviousValueAndTheBaseline() throws {
        let fake = FakeProcesses()
        fake.set([fake.entry(10)])
        fake.setUsage(10, cpuSeconds: 1)
        let collector = ProcessCollector(sources: fake.sources, minimumCPUWindowNanos: 500_000_000)
        _ = collector.sample()
        fake.advance(seconds: 2)
        fake.setUsage(10, cpuSeconds: 2)
        let measured = try #require(collector.sample().value?.processes[0].cpuPercent)
        #expect(abs(measured - 50) < 0.001)

        fake.advance(seconds: 0.1)  // under the 0.5 s floor
        fake.setUsage(10, cpuSeconds: 2.09)
        let carried = try #require(collector.sample().value?.processes[0].cpuPercent)
        #expect(abs(carried - 50) < 0.001, "a short window must carry the previous value, got \(carried)")

        fake.advance(seconds: 1.9)  // 2.0 s since the kept baseline, +1.0 s of CPU in total
        fake.setUsage(10, cpuSeconds: 3.0)
        let next = try #require(collector.sample().value?.processes[0].cpuPercent)
        #expect(abs(next - 50) < 0.001, "the baseline must not advance on a short window, got \(next)")
    }

    @Test func pathIsResolvedOncePerIdentity() throws {
        let fake = FakeProcesses()
        fake.set([fake.entry(10), fake.entry(11)])
        fake.setUsage(10, cpuSeconds: 1)
        fake.setUsage(11, cpuSeconds: 1)
        let collector = ProcessCollector(sources: fake.sources)
        for _ in 0..<4 {
            fake.advance(seconds: 2)
            _ = collector.sample()
        }
        #expect(fake.pathCalls == 2)
    }

    @Test func vanishedIdentitiesArePrunedFromBaselinesAndThePathCache() throws {
        let fake = FakeProcesses()
        fake.set([fake.entry(10), fake.entry(11)])
        fake.setUsage(10, cpuSeconds: 1)
        fake.setUsage(11, cpuSeconds: 1)
        let collector = ProcessCollector(sources: fake.sources)
        _ = collector.sample()
        #expect(collector.trackedIdentityCount == 2)
        fake.advance(seconds: 2)
        fake.set([fake.entry(10)])
        _ = collector.sample()
        #expect(collector.trackedIdentityCount == 1)

        // 11 comes back as the same identity: its path is resolved again and its CPU restarts.
        fake.advance(seconds: 2)
        fake.set([fake.entry(10), fake.entry(11)])
        let calls = fake.pathCalls
        let snapshot = try #require(collector.sample().value)
        #expect(fake.pathCalls == calls + 1)
        #expect(snapshot.processes.first { $0.identity.pid == 11 }?.cpuPercent == nil)
    }

    @Test func resetClearsTheBaselinesAndThePathCache() throws {
        let fake = FakeProcesses()
        fake.set([fake.entry(10)])
        fake.setUsage(10, cpuSeconds: 1)
        let collector = ProcessCollector(sources: fake.sources)
        _ = collector.sample()
        #expect(collector.trackedIdentityCount == 1)
        collector.reset()
        #expect(collector.trackedIdentityCount == 0)
        fake.advance(seconds: 2)
        _ = collector.sample()
        #expect(fake.pathCalls == 2)
    }

    /// T-02-09: 1,000 live samples must not grow Metr's memory. The footprint is process-wide and
    /// other suites run in parallel, so the threshold matches CPUCollectorTests: 32 MiB.
    @Test func thousandSamplesDoNotGrowFootprint() throws {
        let collector = ProcessCollector()
        _ = collector.sample()  // warm up
        let before = footprint()
        #expect(before > 0)
        for _ in 0..<1_000 {
            _ = collector.sample()
        }
        let after = footprint()
        let growth = after > before ? after - before : 0
        #expect(growth < 33_554_432, "footprint grew by \(growth) bytes")
    }
}

/// A scripted top source: the test sets the state and the latest block, and counts start and stop.
private final class FakeTop: TopSnapshotSource, Sendable {
    struct State: Sendable {
        var block: TopBlock?
        var state: TopStreamState = .stopped
        var starts = 0
        var stops = 0
    }
    let box = Mutex(State())

    func start() { box.withLock { $0.starts += 1; $0.state = .starting } }
    func stop() { box.withLock { $0.stops += 1; $0.state = .stopped; $0.block = nil } }
    func latest() -> TopBlock? { box.withLock { $0.block } }
    var state: TopStreamState { box.withLock { $0.state } }

    func set(state: TopStreamState, block: TopBlock?) { box.withLock { $0.state = state; $0.block = block } }
    var starts: Int { box.withLock { $0.starts } }
    var stops: Int { box.withLock { $0.stops } }

    static func block(
        sequence: Int, notBefore: Int64 = 1_000_000, rows: [TopRow]
    ) -> TopBlock {
        TopBlock(
            sequence: sequence, rows: Dictionary(uniqueKeysWithValues: rows.map { ($0.pid, $0) }),
            notBeforeMicros: notBefore)
    }
}

@Suite struct ProcessCollectorTopMergeTests {
    private func fixture() -> (FakeProcesses, FakeTop) {
        let fake = FakeProcesses()
        let top = FakeTop()
        return (fake, top)
    }

    @Test func otherUidEntriesTakeFootprintFromTheBlockAndCPUOnlyWhenValid() throws {
        let (fake, top) = fixture()
        fake.set([
            fake.entry(10), fake.entry(900, uid: 0), fake.entry(901, uid: 88), fake.entry(902, uid: 0),
        ])
        fake.setUsage(10, cpuSeconds: 1)
        let rows = [
            TopRow(pid: 900, cpuPercent: 12.5, footprintBytes: 600_000_000),
            TopRow(pid: 901, cpuPercent: 3.0, footprintBytes: 70_000_000),
            TopRow(pid: 5555, cpuPercent: 99, footprintBytes: 1),  // in the block but not in listAll
        ]
        let collector = ProcessCollector(sources: fake.sources, top: top)

        top.set(state: .running, block: FakeTop.block(sequence: 1, rows: rows))
        let first = try #require(collector.sample().value)
        #expect(Set(first.processes.map(\.identity.pid)) == [10, 900, 901], "902 is missing from the block")
        let ws = try #require(first.processes.first { $0.identity.pid == 900 })
        #expect(ws.footprintBytes == 600_000_000)
        #expect(ws.cpuPercent == nil, "block 1 has no CPU baseline: pending, never a fabricated 0")
        #expect(ws.uid == 0)

        top.set(state: .running, block: FakeTop.block(sequence: 2, rows: rows))
        let second = try #require(collector.sample().value)
        #expect(second.processes.first { $0.identity.pid == 900 }?.cpuPercent == 12.5)
        #expect(second.processes.first { $0.identity.pid == 901 }?.footprintBytes == 70_000_000)
    }

    /// D-11: top has no per-process I/O, so another user's row says nothing, never a zero.
    @Test func otherUsersHaveNoDiskRates() throws {
        let (fake, top) = fixture()
        fake.set([fake.entry(10), fake.entry(900, uid: 0)])
        fake.setUsage(10, cpuSeconds: 1, diskRead: 1_000, diskWritten: 1_000)
        let rows = [TopRow(pid: 900, cpuPercent: 12.5, footprintBytes: 600_000_000)]
        let collector = ProcessCollector(sources: fake.sources, top: top)
        top.set(state: .running, block: FakeTop.block(sequence: 1, rows: rows))
        _ = collector.sample()
        fake.advance(seconds: 2)
        fake.setUsage(10, cpuSeconds: 2, diskRead: 5_001_000, diskWritten: 1_000)
        top.set(state: .running, block: FakeTop.block(sequence: 2, rows: rows))
        let snapshot = try #require(collector.sample().value)
        let own = try #require(snapshot.processes.first { $0.identity.pid == 10 })
        #expect(own.diskReadPerSec == 2_500_000)
        let ws = try #require(snapshot.processes.first { $0.identity.pid == 900 })
        #expect(ws.diskReadPerSec == nil)
        #expect(ws.diskWritePerSec == nil)
    }

    /// T-02-15: a pid reused by a process that started after the block's window began never
    /// borrows the old process's numbers.
    @Test func reusedPidAfterTheBlockIsOmitted() throws {
        let (fake, top) = fixture()
        let rows = [TopRow(pid: 900, cpuPercent: 40, footprintBytes: 500_000_000)]
        top.set(state: .running, block: FakeTop.block(sequence: 2, notBefore: 1_000_000, rows: rows))
        let collector = ProcessCollector(sources: fake.sources, top: top)

        fake.set([fake.entry(900, start: 999_000, uid: 0)])
        let before = try #require(collector.sample().value)
        #expect(before.processes.map(\.identity.pid) == [900])

        fake.set([fake.entry(900, start: 1_200_000, uid: 0)])
        let after = try #require(collector.sample().value)
        #expect(after.processes.isEmpty, "a process that started after the block began must wait")
    }

    @Test func metrsOwnTopChildIsExcluded() throws {
        let (fake, top) = fixture()
        // selfPID is 999 in the fake sources.
        fake.set([
            fake.entry(800, uid: 0, ppid: 999),  // our top child
            fake.entry(801, uid: 501, ppid: 999),  // some other child of ours
            fake.entry(802, uid: 0, ppid: 1),  // a top that is not ours
        ])
        fake.setUsage(801, cpuSeconds: 1)
        fake.setPath(800, "/usr/bin/top")
        fake.setPath(802, "/usr/bin/top")
        let rows = [
            TopRow(pid: 800, cpuPercent: 5, footprintBytes: 9_000_000),
            TopRow(pid: 802, cpuPercent: 5, footprintBytes: 9_000_000),
        ]
        top.set(state: .running, block: FakeTop.block(sequence: 2, rows: rows))
        let snapshot = try #require(ProcessCollector(sources: fake.sources, top: top).sample().value)
        #expect(Set(snapshot.processes.map(\.identity.pid)) == [801, 802])
    }

    @Test func pathsAreResolvedForOtherUidIdentitiesToo() throws {
        let (fake, top) = fixture()
        fake.set([fake.entry(10), fake.entry(900, uid: 0)])
        fake.setUsage(10, cpuSeconds: 1)
        top.set(state: .running, block: FakeTop.block(sequence: 2, rows: [TopRow(pid: 900, cpuPercent: 1, footprintBytes: 5)]))
        let snapshot = try #require(ProcessCollector(sources: fake.sources, top: top).sample().value)
        #expect(fake.askedPath(for: 900))
        #expect(snapshot.processes.first { $0.identity.pid == 900 }?.path == "/Applications/App900.app/Contents/MacOS/App900")
    }

    @Test func otherUsersStateFollowsTheSource() throws {
        let fake = FakeProcesses()
        fake.set([fake.entry(10), fake.entry(900, uid: 0)])
        fake.setUsage(10, cpuSeconds: 1)
        let rows = [TopRow(pid: 900, cpuPercent: 1, footprintBytes: 5)]

        let none = try #require(ProcessCollector(sources: fake.sources).sample().value)
        #expect(none.otherUsers == .unavailable)
        #expect(none.processes.map(\.identity.pid) == [10])

        let top = FakeTop()
        let collector = ProcessCollector(sources: fake.sources, top: top)
        top.set(state: .starting, block: nil)
        #expect(try #require(collector.sample().value).otherUsers == .pending)
        top.set(state: .running, block: nil)
        #expect(try #require(collector.sample().value).otherUsers == .pending)
        top.set(state: .running, block: FakeTop.block(sequence: 1, rows: rows))
        #expect(try #require(collector.sample().value).otherUsers == .available)
        top.set(state: .failed, block: nil)
        let failed = try #require(collector.sample().value)
        #expect(failed.otherUsers == .unavailable)
        #expect(failed.processes.map(\.identity.pid) == [10], "own rows keep ranking")
    }

    @Test func cpuReadyNeedsTheTopBlocksCPUUnlessUnavailable() throws {
        let (fake, top) = fixture()
        fake.set([fake.entry(10), fake.entry(900, uid: 0)])
        fake.setUsage(10, cpuSeconds: 1)
        let rows = [TopRow(pid: 900, cpuPercent: 1, footprintBytes: 5)]
        let collector = ProcessCollector(sources: fake.sources, top: top)

        top.set(state: .running, block: FakeTop.block(sequence: 1, rows: rows))
        _ = collector.sample()
        fake.advance(seconds: 2)
        fake.setUsage(10, cpuSeconds: 2)
        #expect(try #require(collector.sample().value).cpuReady == false, "block 1 has no CPU yet")

        top.set(state: .running, block: FakeTop.block(sequence: 2, rows: rows))
        fake.advance(seconds: 2)
        fake.setUsage(10, cpuSeconds: 3)
        #expect(try #require(collector.sample().value).cpuReady == true)

        // With top failed the list is the user's own processes and their CPU is enough.
        let (fake2, top2) = fixture()
        fake2.set([fake2.entry(10)])
        fake2.setUsage(10, cpuSeconds: 1)
        let collector2 = ProcessCollector(sources: fake2.sources, top: top2)
        top2.set(state: .failed, block: nil)
        _ = collector2.sample()
        fake2.advance(seconds: 2)
        fake2.setUsage(10, cpuSeconds: 2)
        #expect(try #require(collector2.sample().value).cpuReady == true)
    }

    @Test func aStoppedSourceIsStartedBySampleAndResetStopsIt() throws {
        let (fake, top) = fixture()
        fake.set([fake.entry(10)])
        fake.setUsage(10, cpuSeconds: 1)
        let collector = ProcessCollector(sources: fake.sources, top: top)
        _ = collector.sample()
        #expect(top.starts == 1)
        _ = collector.sample()
        #expect(top.starts == 1, "a starting source must not be started again")
        collector.reset()
        #expect(top.stops == 1)
    }

    @Test func failedSourceRetriesAfterTenSeconds() throws {
        let (fake, top) = fixture()
        fake.set([fake.entry(10)])
        fake.setUsage(10, cpuSeconds: 1)
        let collector = ProcessCollector(sources: fake.sources, top: top)
        _ = collector.sample()
        #expect(top.starts == 1)

        top.set(state: .failed, block: nil)  // the child died
        fake.advance(seconds: 5)
        let early = try #require(collector.sample().value)
        #expect(top.starts == 1, "a failing top must not be respawned every tick")
        #expect(early.otherUsers == .unavailable)
        #expect(early.processes.map(\.identity.pid) == [10], "own rows keep ranking")

        fake.advance(seconds: 5.1)  // 10.1 s since the start attempt
        _ = collector.sample()
        #expect(top.starts == 2)

        top.set(state: .failed, block: nil)
        fake.advance(seconds: 9)
        _ = collector.sample()
        #expect(top.starts == 2, "the 10 s runs from the latest start attempt")
    }
}
