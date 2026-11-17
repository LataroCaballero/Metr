import Dispatch
import Synchronization
import Testing

@testable import MetrCore

/// Scaled scheduler timings: cadenceScale 0.05 gives idle base 0.1 s, panel base 0.05 s,
/// constrained idle base 0.2 s and a 0.025 s priming delay. Tolerances are wide (about 50%).
final class SchedulerRecorder: Sendable {
    struct Event: Sendable {
        let due: Set<Metric>
        let elapsed: Double
        let priming: Bool
    }
    private let storage = Mutex<[Event]>([])
    private let planStorage = Mutex<[SamplingPlan]>([])

    func add(_ e: Event) { storage.withLock { $0.append(e) } }
    func addPlan(_ p: SamplingPlan) { planStorage.withLock { $0.append(p) } }
    var events: [Event] { storage.withLock { $0 } }
    var plans: [SamplingPlan] { planStorage.withLock { $0 } }
    func clear() { storage.withLock { $0.removeAll() } }
}

private func makeScheduler(_ label: String) -> (SamplingScheduler, SchedulerRecorder) {
    let queue = DispatchQueue(label: "test.sched.\(label)", qos: .utility)
    let scheduler = SamplingScheduler(queue: queue, cadenceScale: 0.05)
    let rec = SchedulerRecorder()
    scheduler.onPlanChange = { rec.addPlan($0) }
    scheduler.start { due, elapsed, priming in
        rec.add(.init(due: due, elapsed: elapsed, priming: priming))
    }
    return (scheduler, rec)
}

private func sleep(_ ms: Int) async throws {
    try await Task.sleep(for: .milliseconds(ms))
}

private func median(_ values: [Double]) -> Double {
    let s = values.sorted()
    return s[s.count / 2]
}

@Suite struct SamplingSchedulerTests {
    @Test func startDeliversAllMetricsThenAPrimingCPUTick() async throws {
        let (scheduler, rec) = makeScheduler("start")
        try await sleep(150)
        scheduler.stop()
        let events = rec.events
        #expect(events.count >= 2)
        #expect(events[0].due == [.cpu, .memory, .disk])
        #expect(!events[0].priming)
        #expect(events[1].due == [.cpu])
        #expect(events[1].priming)
        #expect(events[1].elapsed < 0.1, "priming elapsed \(events[1].elapsed)")
        #expect(rec.plans.first?.tier == .idle)
    }

    /// D-20 / RESEARCH Pitfall 4: the idle start and wake baselines never sample processes.
    @Test func idleStartNeverDeliversProcesses() async throws {
        let (scheduler, rec) = makeScheduler("idle-no-processes")
        try await sleep(300)
        scheduler.stop()
        #expect(rec.events.count >= 2)
        #expect(!rec.events.contains { $0.due.contains(.processes) })
    }

    @Test func panelDemandDeliversProcessesAtOnceThenOnCadence() async throws {
        let (scheduler, rec) = makeScheduler("panel-processes")
        try await sleep(150)
        rec.clear()
        scheduler.setDemand([.panel])
        try await sleep(30)
        // Any delivery in this window may carry processes: an idle tick that was already queued
        // when the demand changed can legitimately come first, so the first event is not the one
        // to inspect (it made this test flaky on a loaded CI runner).
        #expect(rec.events.contains { $0.due.contains(.processes) }, "events: \(rec.events.map(\.due))")
        try await sleep(370)
        scheduler.stop()
        let withProcesses = rec.events.filter { $0.due.contains(.processes) }.count
        #expect(withProcesses >= 3, "events with processes: \(withProcesses)")
    }

    /// RESEARCH Pitfall 5: closing the panel forgets when processes were last read, so reopening
    /// within the cadence still gets an immediate processes baseline.
    @Test func reopenWithinASecondDeliversAnImmediateProcessesBaseline() async throws {
        let (scheduler, rec) = makeScheduler("reopen")
        try await sleep(150)
        scheduler.setDemand([.panel])
        // Close right after a processes delivery, so the last read is only a few ms old.
        var waited = 0
        while !rec.events.contains(where: { $0.due.contains(.processes) }) && waited < 500 {
            try await sleep(5)
            waited += 5
        }
        let before = rec.events.filter { $0.due.contains(.processes) }.count
        #expect(before >= 1)
        scheduler.setDemand([])
        try await sleep(20)
        rec.clear()
        scheduler.setDemand([.panel])
        try await sleep(30)
        scheduler.stop()
        #expect(
            rec.events.contains { $0.due.contains(.processes) },
            "events after the reopen: \(rec.events.map(\.due))")
    }

    @Test func suspendStopsAllTicks() async throws {
        let (scheduler, rec) = makeScheduler("suspend")
        try await sleep(250)
        scheduler.suspend(reason: .displaySleep)
        try await sleep(60)
        let countAtSuspend = rec.events.count
        #expect(countAtSuspend >= 2)
        try await sleep(300)
        scheduler.stop()
        #expect(rec.events.count == countAtSuspend)
        #expect(rec.plans.last?.tier == .suspended)
    }

    @Test func overlappingReasonsKeepTheSchedulerSuspended() async throws {
        let (scheduler, rec) = makeScheduler("overlap")
        try await sleep(150)
        scheduler.suspend(reason: .systemSleep)
        scheduler.suspend(reason: .displaySleep)
        try await sleep(60)
        scheduler.resume(reason: .displaySleep)
        try await sleep(60)
        let count = rec.events.count
        try await sleep(300)
        scheduler.stop()
        #expect(rec.events.count == count)
        #expect(rec.plans.last?.tier == .suspended)
    }

    @Test func resumingTheLastReasonDeliversBaselineThenPriming() async throws {
        let (scheduler, rec) = makeScheduler("resume")
        try await sleep(150)
        scheduler.suspend(reason: .systemSleep)
        scheduler.suspend(reason: .sessionInactive)
        try await sleep(80)
        scheduler.resume(reason: .systemSleep)
        scheduler.resume(reason: .sessionInactive)
        let before = rec.events.count
        try await sleep(200)
        scheduler.stop()
        let after = Array(rec.events.dropFirst(before))
        #expect(after.count >= 2)
        #expect(after[0].due == [.cpu, .memory, .disk])
        #expect(!after[0].priming)
        #expect(after[1].due == [.cpu])
        #expect(after[1].priming)
        #expect(rec.plans.last?.tier == .idle)
    }

    @Test func constrainedDoublesTheInterval() async throws {
        let (scheduler, rec) = makeScheduler("constrained")
        try await sleep(100)
        scheduler.setConstrained(true)
        try await sleep(60)
        rec.clear()
        try await sleep(1400)
        scheduler.stop()
        let intervals = rec.events.map(\.elapsed)
        #expect(intervals.count >= 4)
        let m = median(intervals)
        #expect(m > 0.1 && m < 0.3, "median \(m)")
        #expect(rec.plans.last?.constrained == true)
    }

    @Test func panelDemandHalvesTheIdleInterval() async throws {
        let (scheduler, rec) = makeScheduler("panel")
        try await sleep(150)
        scheduler.setDemand([.panel])
        try await sleep(60)
        rec.clear()
        try await sleep(700)
        scheduler.stop()
        let intervals = rec.events.map(\.elapsed)
        #expect(intervals.count >= 6)
        let m = median(intervals)
        #expect(m > 0.025 && m < 0.075, "median \(m)")
        #expect(rec.plans.last?.tier == .panel)
    }

    @Test func demandChangeWhileSuspendedAppliesOnResume() async throws {
        let (scheduler, rec) = makeScheduler("demand-suspended")
        try await sleep(100)
        scheduler.suspend(reason: .displaySleep)
        scheduler.setDemand([.panel])
        try await sleep(60)
        scheduler.resume(reason: .displaySleep)
        try await sleep(100)
        scheduler.stop()
        #expect(rec.plans.last?.tier == .panel)
    }

    /// T-02-22: an event-driven early sample only ever carries metrics the current plan already
    /// samples, so it can never add process work to the idle state.
    @Test func deliverNowOnlyForMetricsInThePlan() async throws {
        let (scheduler, rec) = makeScheduler("deliver-now")
        try await sleep(150)

        // Idle plan: processes are not in the plan, so nothing is delivered for them.
        rec.clear()
        scheduler.deliverNow([.processes])
        try await sleep(50)
        #expect(
            !rec.events.contains { $0.due.contains(.processes) },
            "an idle deliverNow added process work: \(rec.events.map(\.due))")

        // Panel plan: exactly the requested metric, as its own event.
        scheduler.setDemand([.panel])
        try await sleep(30)
        rec.clear()
        scheduler.deliverNow([.processes])
        try await sleep(20)
        #expect(
            rec.events.contains { $0.due == [.processes] },
            "no deliverNow event in the panel plan: \(rec.events.map(\.due))")

        // Suspended: nothing, even for a metric that was in the plan a moment ago.
        scheduler.suspend(reason: .displaySleep)
        try await sleep(60)
        rec.clear()
        scheduler.deliverNow([.processes])
        try await sleep(50)
        scheduler.stop()
        #expect(rec.events.isEmpty, "deliverNow delivered while suspended: \(rec.events.map(\.due))")
    }

    @Test func baselineHookFiresOnStartAndOnlyOnRealResume() async throws {
        let queue = DispatchQueue(label: "test.sched.baseline", qos: .utility)
        let scheduler = SamplingScheduler(queue: queue, cadenceScale: 0.05)
        let rec = SchedulerRecorder()
        let baselines = Mutex(0)
        scheduler.start(
            onTick: { due, elapsed, priming in
                rec.add(.init(due: due, elapsed: elapsed, priming: priming))
            },
            onBaseline: { baselines.withLock { $0 += 1 } })

        try await sleep(150)
        #expect(baselines.withLock { $0 } == 1)

        // A resume with no matching suspend leaves the plan unchanged.
        scheduler.resume(reason: .sessionInactive)
        try await sleep(100)
        #expect(baselines.withLock { $0 } == 1)

        // Another reason still holds, so this resume does not re-prime.
        scheduler.suspend(reason: .systemSleep)
        scheduler.suspend(reason: .displaySleep)
        try await sleep(60)
        scheduler.resume(reason: .displaySleep)
        try await sleep(60)
        #expect(baselines.withLock { $0 } == 1)

        // The last reason clears: a fresh baseline, then an all-metrics tick.
        rec.clear()
        scheduler.resume(reason: .systemSleep)
        try await sleep(150)
        scheduler.stop()
        #expect(baselines.withLock { $0 } == 2)
        #expect(rec.events.first?.due == [.cpu, .memory, .disk])
    }
}
