import Testing

@testable import MetrCore

@Suite struct CPUMathTests {
    @Test func twoCoreFixtureGivesExpectedRatio() throws {
        let previous = [
            CPUTicks(user: 100, system: 50, idle: 800, nice: 0),
            CPUTicks(user: 200, system: 100, idle: 700, nice: 0),
        ]
        // core 0: +30 user +10 system +60 idle ; core 1: +10 user +10 system +80 idle
        let current = [
            CPUTicks(user: 130, system: 60, idle: 860, nice: 0),
            CPUTicks(user: 210, system: 110, idle: 780, nice: 0),
        ]
        let reading = try #require(CPUMath.usage(previous: previous, current: current))
        // busy = 40 + 20 = 60 ; total = 100 + 100 = 200
        #expect(abs(reading.total - 0.30) < 1e-9)
    }

    @Test func uint32WrapIsHandled() throws {
        let previous = [CPUTicks(user: UInt32.max - 9, system: 0, idle: 0, nice: 0)]
        let current = [CPUTicks(user: 10, system: 0, idle: 20, nice: 0)]
        // busy delta = 20 (wrapped), idle delta = 20
        let reading = try #require(CPUMath.usage(previous: previous, current: current))
        #expect(abs(reading.total - 0.5) < 1e-9)
    }

    @Test func zeroTotalDeltaReturnsNil() {
        let ticks = [CPUTicks(user: 5, system: 5, idle: 5, nice: 5)]
        #expect(CPUMath.usage(previous: ticks, current: ticks) == nil)
    }

    @Test func mismatchedCoreCountsReturnNil() {
        let a = [CPUTicks(user: 0, system: 0, idle: 0, nice: 0)]
        let b = [
            CPUTicks(user: 1, system: 1, idle: 1, nice: 1),
            CPUTicks(user: 1, system: 1, idle: 1, nice: 1),
        ]
        #expect(CPUMath.usage(previous: a, current: b) == nil)
        #expect(CPUMath.usage(previous: [], current: []) == nil)
    }
}
