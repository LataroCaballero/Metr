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

    // CPU-02 / D-02: clusters come from the system's perflevels, never from hard-coded P/E.
    @Test func clusterRangesTwoLevelsEfficiencyFirst() throws {
        let layout = CoreLayout(levels: [
            CoreLevel(name: "Performance", logicalCPUs: 4),
            CoreLevel(name: "Efficiency", logicalCPUs: 6),
        ])
        let ranges = try #require(layout.clusterRanges(coreCount: 10))
        #expect(ranges.map(\.name) == ["Performance", "Efficiency"])
        #expect(ranges.map(\.cores) == [6..<10, 0..<6])
    }

    @Test func clusterRangesOneAndThreeLevels() throws {
        let one = CoreLayout(levels: [CoreLevel(name: "Only", logicalCPUs: 8)])
        let oneRanges = try #require(one.clusterRanges(coreCount: 8))
        #expect(oneRanges.map(\.name) == ["Only"])
        #expect(oneRanges.map(\.cores) == [0..<8])

        let three = CoreLayout(levels: [
            CoreLevel(name: "Super", logicalCPUs: 2),
            CoreLevel(name: "Performance", logicalCPUs: 4),
            CoreLevel(name: "Efficiency", logicalCPUs: 4),
        ])
        let threeRanges = try #require(three.clusterRanges(coreCount: 10))
        #expect(threeRanges.map(\.name) == ["Super", "Performance", "Efficiency"])
        #expect(threeRanges.map(\.cores) == [8..<10, 4..<8, 0..<4])
    }

    @Test func clusterRangesRejectMismatch() {
        let two = CoreLayout(levels: [
            CoreLevel(name: "Performance", logicalCPUs: 4),
            CoreLevel(name: "Efficiency", logicalCPUs: 6),
        ])
        #expect(two.clusterRanges(coreCount: 12) == nil)
        #expect(two.clusterRanges(coreCount: 8) == nil)
        #expect(CoreLayout(levels: []).clusterRanges(coreCount: 10) == nil)
        let zero = CoreLayout(levels: [
            CoreLevel(name: "Performance", logicalCPUs: 0),
            CoreLevel(name: "Efficiency", logicalCPUs: 10),
        ])
        #expect(zero.clusterRanges(coreCount: 10) == nil)
    }

    @Test func clusterUsageFollowsLayout() throws {
        let zero = CPUTicks(user: 0, system: 0, idle: 0, nice: 0)
        let previous = Array(repeating: zero, count: 10)
        // cores 0-5: 10 % busy ; cores 6-9: 80 % busy
        var current: [CPUTicks] = []
        for i in 0..<10 {
            current.append(
                i < 6
                    ? CPUTicks(user: 10, system: 0, idle: 90, nice: 0)
                    : CPUTicks(user: 60, system: 20, idle: 20, nice: 0))
        }
        let layout = CoreLayout(levels: [
            CoreLevel(name: "Performance", logicalCPUs: 4),
            CoreLevel(name: "Efficiency", logicalCPUs: 6),
        ])
        let withLayout = try #require(CPUMath.usage(previous: previous, current: current, layout: layout))
        #expect(withLayout.clusters.map(\.name) == ["Performance", "Efficiency"])
        #expect(abs(withLayout.clusters[0].usage - 0.80) < 1e-9)
        #expect(abs(withLayout.clusters[1].usage - 0.10) < 1e-9)

        let plain = try #require(CPUMath.usage(previous: previous, current: current))
        let mismatched = CoreLayout(levels: [CoreLevel(name: "Performance", logicalCPUs: 4)])
        let bad = try #require(CPUMath.usage(previous: previous, current: current, layout: mismatched))
        #expect(plain.clusters.isEmpty)
        #expect(bad.clusters.isEmpty)
        #expect(bad.total == plain.total && bad.user == plain.user && bad.system == plain.system)
        #expect(withLayout.total == plain.total)
    }

    @Test func clusterWithZeroDeltaYieldsNoClusters() throws {
        // Cores 0-1 did not advance at all; cores 2-3 did. A cluster with no delta cannot be averaged.
        let previous = Array(repeating: CPUTicks(user: 5, system: 5, idle: 5, nice: 5), count: 4)
        var current = previous
        current[2] = CPUTicks(user: 15, system: 5, idle: 15, nice: 5)
        current[3] = CPUTicks(user: 15, system: 5, idle: 15, nice: 5)
        let layout = CoreLayout(levels: [
            CoreLevel(name: "Performance", logicalCPUs: 2),
            CoreLevel(name: "Efficiency", logicalCPUs: 2),
        ])
        let reading = try #require(CPUMath.usage(previous: previous, current: current, layout: layout))
        #expect(reading.clusters.isEmpty)
        #expect(reading.total > 0)
    }
}
