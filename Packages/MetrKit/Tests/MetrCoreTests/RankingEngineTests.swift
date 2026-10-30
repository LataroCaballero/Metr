import Testing

@testable import MetrCore

@Suite struct RankingEngineTests {
    private let mib: UInt64 = 1_048_576
    private let gib: UInt64 = 1_073_741_824

    private func item(_ id: String, cpu: Double?, memory: UInt64? = nil, name: String? = nil) -> RankItem {
        RankItem(id: id, cpuPercent: cpu, footprintBytes: memory, name: name ?? id)
    }

    // MARK: Quantization

    @Test func cpuQuantizationRoundsToTheDisplayedPercent() {
        #expect(RankingEngine.quantizedCPU(41.4) == 41)
        #expect(RankingEngine.quantizedCPU(41.6) == 42)
        #expect(RankingEngine.quantizedCPU(0) == 0)
        #expect(RankingEngine.quantizedCPU(nil) == -1)
    }

    @Test func memoryQuantization() {
        // Below 1 GiB: whole MiB.
        #expect(
            RankingEngine.quantizedMemory(410 * mib) == RankingEngine.quantizedMemory(410 * mib + mib * 4 / 10))
        #expect(RankingEngine.quantizedMemory(410 * mib) != RankingEngine.quantizedMemory(412 * mib))
        // At or above 1 GiB: tenths of a GiB (2.10 and 2.14 tie, 2.10 and 2.21 do not).
        let a = UInt64(2.10 * Double(gib))
        let b = UInt64(2.14 * Double(gib))
        let c = UInt64(2.21 * Double(gib))
        #expect(RankingEngine.quantizedMemory(a) == RankingEngine.quantizedMemory(b))
        #expect(RankingEngine.quantizedMemory(a) != RankingEngine.quantizedMemory(c))
        #expect(RankingEngine.quantizedMemory(nil) == -1)
    }

    @Test func memoryQuantizationNeverInvertsTheOrderAcrossOneGiB() {
        // Both sides of 1 GiB use different units; the key must still be monotonic.
        let below = RankingEngine.quantizedMemory(gib - mib / 4)
        let above = RankingEngine.quantizedMemory(gib + gib / 20)
        let big = RankingEngine.quantizedMemory(5 * gib)
        #expect(below <= above)
        #expect(above < big)
    }

    // MARK: Order

    @Test func equalDisplayedValuesKeepPreviousOrder() {
        let items = [item("a", cpu: 41.4), item("b", cpu: 41.2)]
        #expect(RankingEngine.order(items, by: .cpu, previous: ["b", "a"]) == ["b", "a"])
        #expect(RankingEngine.order(items, by: .cpu, previous: ["a", "b"]) == ["a", "b"])
        let moved = [item("a", cpu: 42.6), item("b", cpu: 41.2)]
        #expect(RankingEngine.order(moved, by: .cpu, previous: ["b", "a"]) == ["a", "b"])
    }

    @Test func initialTiesBreakByMemoryThenName() {
        let items = [
            item("zeta", cpu: 10, memory: 100 * mib),
            item("alpha", cpu: 10, memory: 100 * mib),
            item("big", cpu: 10, memory: 900 * mib),
        ]
        #expect(RankingEngine.order(items, by: .cpu, previous: []) == ["big", "alpha", "zeta"])
    }

    @Test func rowsNotInPreviousSortAfterThoseInIt() {
        let items = [item("new", cpu: 10), item("old", cpu: 10)]
        #expect(RankingEngine.order(items, by: .cpu, previous: ["old"]) == ["old", "new"])
    }

    @Test func nilValuesSortLast() {
        let items = [item("none", cpu: nil, memory: 9_000 * mib), item("zero", cpu: 0), item("some", cpu: 3)]
        #expect(RankingEngine.order(items, by: .cpu, previous: []) == ["some", "zero", "none"])
        let mem = [item("m1", cpu: 1, memory: nil), item("m2", cpu: 1, memory: 5 * mib)]
        #expect(RankingEngine.order(mem, by: .memory, previous: []) == ["m2", "m1"])
    }

    @Test func memoryColumnRanksByQuantizedFootprint() {
        let items = [
            item("a", cpu: 90, memory: 410 * mib), item("b", cpu: 5, memory: 410 * mib + mib * 4 / 10),
            item("c", cpu: 1, memory: 900 * mib),
        ]
        // a and b tie at the displayed unit, so their previous order holds; c is clearly larger.
        #expect(RankingEngine.order(items, by: .memory, previous: ["b", "a"]) == ["c", "b", "a"])
    }

    // MARK: Effective column (D-20)

    @Test func holdUntilCPUReady() {
        let items = [
            item("cpuHeavy", cpu: 90, memory: 10 * mib), item("memHeavy", cpu: 1, memory: 2 * gib),
        ]
        #expect(RankingEngine.effectiveColumn(.cpu, cpuReady: false) == .memory)
        #expect(RankingEngine.effectiveColumn(.cpu, cpuReady: true) == .cpu)
        #expect(RankingEngine.effectiveColumn(.memory, cpuReady: false) == .memory)
        let before = RankingEngine.next(
            items, column: .cpu, cpuReady: false, previous: [], frozen: false, limit: 5)
        #expect(before == ["memHeavy", "cpuHeavy"])
        let after = RankingEngine.next(
            items, column: .cpu, cpuReady: true, previous: before, frozen: false, limit: 5)
        #expect(after == ["cpuHeavy", "memHeavy"])
    }

    // MARK: Freeze (D-10)

    @Test func frozenKeepsSetAndOrder() {
        let previous = ["a", "b", "c", "d", "e"]
        let items = [
            item("a", cpu: 5), item("b", cpu: 4), item("c", cpu: 3), item("d", cpu: 2), item("e", cpu: 1),
            item("f", cpu: 99),
        ]
        #expect(
            RankingEngine.next(items, column: .cpu, cpuReady: true, previous: previous, frozen: true, limit: 5)
                == previous)
        let withoutC = items.filter { $0.id != "c" }
        #expect(
            RankingEngine.next(withoutC, column: .cpu, cpuReady: true, previous: previous, frozen: true, limit: 5)
                == ["a", "b", "d", "e"])
        #expect(
            RankingEngine.next(items, column: .cpu, cpuReady: true, previous: previous, frozen: false, limit: 5)
                == ["f", "a", "b", "c", "d"])
    }

    @Test func frozenWithNothingPreviousRanksNormally() {
        let items = [item("a", cpu: 1), item("b", cpu: 2)]
        #expect(
            RankingEngine.next(items, column: .cpu, cpuReady: true, previous: [], frozen: true, limit: 5)
                == ["b", "a"])
    }

    @Test func frozenWhoseRowsAllExitedRanksNormally() {
        let items = [item("x", cpu: 1), item("y", cpu: 2)]
        #expect(
            RankingEngine.next(items, column: .cpu, cpuReady: true, previous: ["gone"], frozen: true, limit: 5)
                == ["y", "x"])
    }

    @Test func limitIsRespected() {
        let items = (0..<8).map { item("p\($0)", cpu: Double($0)) }
        let result = RankingEngine.next(
            items, column: .cpu, cpuReady: true, previous: [], frozen: false, limit: 3)
        #expect(result == ["p7", "p6", "p5"])
    }
}
