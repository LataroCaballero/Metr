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

    @Test func coreCountChangeReturnsNil() {
        let eight = Array(repeating: CPUTicks(user: 0, system: 0, idle: 0, nice: 0), count: 8)
        let ten = Array(repeating: CPUTicks(user: 5, system: 5, idle: 5, nice: 5), count: 10)
        #expect(CPUMath.usage(previous: eight, current: ten) == nil)
    }

    @Test func allIdleDeltaIsZero() throws {
        let previous = [CPUTicks(user: 1, system: 1, idle: 1, nice: 1)]
        let current = [CPUTicks(user: 1, system: 1, idle: 101, nice: 1)]
        let reading = try #require(CPUMath.usage(previous: previous, current: current))
        #expect(reading.total == 0.0)
    }

    @Test func allBusyDeltaIsOne() throws {
        let previous = [CPUTicks(user: 0, system: 0, idle: 7, nice: 0)]
        let current = [CPUTicks(user: 60, system: 40, idle: 7, nice: 0)]
        let reading = try #require(CPUMath.usage(previous: previous, current: current))
        #expect(reading.total == 1.0)
    }

    @Test func niceTicksCountAsBusy() throws {
        let previous = [CPUTicks(user: 0, system: 0, idle: 0, nice: 0)]
        let current = [CPUTicks(user: 0, system: 0, idle: 50, nice: 50)]
        let reading = try #require(CPUMath.usage(previous: previous, current: current))
        #expect(abs(reading.total - 0.5) < 1e-9)
    }

    // PANEL-01: user = user + nice ticks, system = system ticks, same all-core denominator as total.
    @Test func userAndSystemSplitCountsNiceAsUser() throws {
        let previous = [
            CPUTicks(user: 0, system: 0, idle: 0, nice: 0),
            CPUTicks(user: 0, system: 0, idle: 0, nice: 0),
        ]
        // each core: +20 user, +5 nice, +15 system, +60 idle
        let current = [
            CPUTicks(user: 20, system: 15, idle: 60, nice: 5),
            CPUTicks(user: 20, system: 15, idle: 60, nice: 5),
        ]
        let reading = try #require(CPUMath.usage(previous: previous, current: current))
        #expect(abs(reading.total - 0.40) < 1e-9)
        #expect(abs(reading.user - 0.25) < 1e-9)
        #expect(abs(reading.system - 0.15) < 1e-9)
    }

    @Test func userAndSystemClampToUnitRange() throws {
        let previous = [
            CPUTicks(user: UInt32.max - 4, system: 3, idle: 9, nice: 0),
            CPUTicks(user: 10, system: 10, idle: 10, nice: 10),
        ]
        let current = [
            CPUTicks(user: 30, system: 70, idle: 9, nice: 0),
            CPUTicks(user: 40, system: 10, idle: 110, nice: 20),
        ]
        let reading = try #require(CPUMath.usage(previous: previous, current: current))
        #expect((0...1).contains(reading.user))
        #expect((0...1).contains(reading.system))
        #expect(abs(reading.user + reading.system - reading.total) < 1e-9)
    }
}
