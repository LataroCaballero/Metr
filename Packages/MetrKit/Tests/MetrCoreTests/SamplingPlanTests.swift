import Testing

@testable import MetrCore

@Suite struct SamplingPlanTests {
    @Test func idleTableIsExact() {
        let plan = SamplingPlan.make(demand: [], suspended: false, constrained: false)
        #expect(plan.tier == .idle)
        #expect(plan.baseInterval == 2)
        #expect(plan.cadence == [.cpu: 2, .memory: 2, .disk: 60])
        #expect(!plan.constrained)
    }

    @Test func panelTableIsExact() {
        let plan = SamplingPlan.make(demand: [.panel], suspended: false, constrained: false)
        #expect(plan.tier == .panel)
        #expect(plan.baseInterval == 1)
        #expect(plan.cadence == [.cpu: 1, .memory: 1, .disk: 10])
    }

    @Test func windowTableIsExact() {
        let plan = SamplingPlan.make(demand: [.window], suspended: false, constrained: false)
        #expect(plan.tier == .window)
        #expect(plan.baseInterval == 1)
        #expect(plan.cadence == [.cpu: 1, .memory: 1, .disk: 10])
    }

    @Test func windowWinsOverPanel() {
        let plan = SamplingPlan.make(demand: [.panel, .window], suspended: false, constrained: false)
        #expect(plan.tier == .window)
    }

    @Test func suspendedHasNoBaseAndNothingDue() {
        let plan = SamplingPlan.make(demand: [.panel, .window], suspended: true, constrained: false)
        #expect(plan.tier == .suspended)
        #expect(plan.baseInterval == nil)
        #expect(plan.cadence.isEmpty)
        #expect(plan.dueMetrics(now: 1000, lastSampled: [:]).isEmpty)
    }

    @Test func constrainedDoublesEverything() {
        let plan = SamplingPlan.make(demand: [], suspended: false, constrained: true)
        #expect(plan.baseInterval == 4)
        #expect(plan.cadence == [.cpu: 4, .memory: 4, .disk: 120])
        #expect(plan.constrained)
        let panel = SamplingPlan.make(demand: [.panel], suspended: false, constrained: true)
        #expect(panel.baseInterval == 2)
        #expect(panel.cadence == [.cpu: 2, .memory: 2, .disk: 20])
    }

    @Test func cadenceScaleClampsAtBothEnds() {
        let low = SamplingPlan.make(demand: [], suspended: false, constrained: false, cadenceScale: 0.0001)
        #expect(low.cadenceScale == 0.01)
        #expect(abs(low.baseInterval! - 0.02) < 1e-12)
        let high = SamplingPlan.make(demand: [], suspended: false, constrained: false, cadenceScale: 1000)
        #expect(high.cadenceScale == 10)
        #expect(abs(high.baseInterval! - 20) < 1e-12)
    }

    @Test func diskIsNotDueAt50sButIsAt59point6sWhenIdle() {
        let plan = SamplingPlan.make(demand: [], suspended: false, constrained: false)
        #expect(!plan.dueMetrics(now: 50, lastSampled: [.cpu: 49, .memory: 49, .disk: 0]).contains(.disk))
        #expect(plan.dueMetrics(now: 59.6, lastSampled: [.cpu: 59, .memory: 59, .disk: 0]).contains(.disk))
    }

    @Test func cpuIsNotDue300msAfterItsLastSampleEvenInPanelTier() {
        let plan = SamplingPlan.make(demand: [.panel], suspended: false, constrained: false)
        let due = plan.dueMetrics(now: 100.3, lastSampled: [.cpu: 100, .memory: 0, .disk: 0])
        #expect(!due.contains(.cpu))
        #expect(due.contains(.memory))
    }

    @Test func neverSampledMetricsAreDue() {
        let plan = SamplingPlan.make(demand: [], suspended: false, constrained: false)
        #expect(plan.dueMetrics(now: 5, lastSampled: [:]) == [.cpu, .memory, .disk])
    }

    @Test func jitterWithinAQuarterBaseIsStillDue() {
        let plan = SamplingPlan.make(demand: [.panel], suspended: false, constrained: false)
        // 0.8 s since the last sample at a 1 s cadence: timer jitter, still due.
        #expect(plan.dueMetrics(now: 10.8, lastSampled: [.cpu: 10, .memory: 10, .disk: 10]).isSuperset(of: [.cpu, .memory]))
    }
}
