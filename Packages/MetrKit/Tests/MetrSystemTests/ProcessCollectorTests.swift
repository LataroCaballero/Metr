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
    }
    let state = Mutex(State())

    static let uid: UInt32 = 501

    func entry(_ pid: Int32, start: Int64 = 1_000, uid: UInt32 = FakeProcesses.uid) -> ProcessEntry {
        ProcessEntry(
            identity: ProcessIdentity(pid: pid, startMicros: start), ppid: 1, uid: uid, command: "cmd\(pid)")
    }

    func set(_ entries: [ProcessEntry]?) { state.withLock { $0.entries = entries } }
    func setUsage(_ pid: Int32, cpuSeconds: Double, footprint: UInt64 = 50_000_000) {
        state.withLock {
            $0.usage[pid] = ProcessUsage(cpuNanos: UInt64(cpuSeconds * 1e9), footprintBytes: footprint)
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
                    return "/Applications/App\(pid).app/Contents/MacOS/App\(pid)"
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
}
