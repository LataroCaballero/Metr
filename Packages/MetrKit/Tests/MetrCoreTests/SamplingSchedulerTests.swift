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
        #expect(events[0].due == Set(Metric.allCases))
        #expect(!events[0].priming)
        #expect(events[1].due == [.cpu])
        #expect(events[1].priming)
        #expect(events[1].elapsed < 0.1, "priming elapsed \(events[1].elapsed)")
        #expect(rec.plans.first?.tier == .idle)
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
        #expect(after[0].due == Set(Metric.allCases))
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
        #expect(rec.events.first?.due == Set(Metric.allCases))
    }
}
