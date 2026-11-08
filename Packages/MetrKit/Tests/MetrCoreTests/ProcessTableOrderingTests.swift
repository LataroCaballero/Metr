import Testing

@testable import MetrCore

@Suite struct ProcessTableOrderingTests {
    private let mib: UInt64 = 1_048_576

    private func item(
        _ id: String, cpu: Double? = nil, memory: UInt64? = nil, name: String? = nil,
        read: Double? = nil, write: Double? = nil
    ) -> ProcessTableItem {
        ProcessTableItem(
            id: id, name: name ?? id, cpuPercent: cpu, footprintBytes: memory, diskReadPerSec: read,
            diskWritePerSec: write)
    }

    private func order(
        _ items: [ProcessTableItem], _ column: ProcessTableColumn, ascending: Bool? = nil,
        previous: [String] = []
    ) -> [String] {
        ProcessTableOrdering.order(
            items, column: column, ascending: ascending ?? ProcessTableOrdering.defaultAscending(column),
            previous: previous)
    }

    @Test func cpuDescendingByDefault() {
        let items = [item("a", cpu: 50), item("b", cpu: 20), item("c", cpu: 80)]
        #expect(order(items, .cpu) == ["c", "a", "b"])
        #expect(ProcessTableOrdering.defaultAscending(.name))
        for column in [ProcessTableColumn.cpu, .memory, .diskRead, .diskWrite] {
            #expect(!ProcessTableOrdering.defaultAscending(column))
        }
    }

    @Test func tiesKeepThePreviousOrder() {
        // 20.2 and 19.9 both read "20 %".
        let items = [item("a", cpu: 20.2), item("b", cpu: 19.9)]
        #expect(order(items, .cpu, ascending: false, previous: ["b", "a"]) == ["b", "a"])
        #expect(order(items, .cpu, ascending: false, previous: ["a", "b"]) == ["a", "b"])
        #expect(order(items, .cpu, ascending: true, previous: ["b", "a"]) == ["b", "a"])
        #expect(order(items, .cpu, ascending: true, previous: ["a", "b"]) == ["a", "b"])
    }

    @Test func ascendingAndName() {
        let items = [item("a", cpu: 50), item("b", cpu: 20), item("c", cpu: 80)]
        #expect(order(items, .cpu, ascending: true) == ["b", "a", "c"])
        let names = [
            item("x", name: "App10"), item("y", name: "App9"), item("z", name: "Alpha"),
        ]
        #expect(order(names, .name, ascending: true) == ["z", "y", "x"])
        #expect(order(names, .name, ascending: false) == ["x", "y", "z"])
    }

    @Test func pendingSortsLast() {
        let items = [
            item("none", cpu: nil, memory: 9_000 * mib), item("zero", cpu: 0), item("some", cpu: 3),
        ]
        #expect(order(items, .cpu, ascending: false) == ["some", "zero", "none"])
        #expect(order(items, .cpu, ascending: true) == ["zero", "some", "none"])
        let rates = [item("r1", read: nil), item("r2", read: 5_000), item("r3", read: 2_000_000)]
        #expect(order(rates, .diskRead, ascending: false) == ["r3", "r2", "r1"])
        #expect(order(rates, .diskRead, ascending: true) == ["r2", "r3", "r1"])
    }

    @Test func effectiveColumnWhilePending() {
        for column in [ProcessTableColumn.cpu, .diskRead, .diskWrite] {
            #expect(ProcessTableOrdering.effectiveColumn(column, cpuReady: false) == .memory)
            #expect(ProcessTableOrdering.effectiveColumn(column, cpuReady: true) == column)
        }
        for column in [ProcessTableColumn.name, .memory] {
            #expect(ProcessTableOrdering.effectiveColumn(column, cpuReady: false) == column)
            #expect(ProcessTableOrdering.effectiveColumn(column, cpuReady: true) == column)
        }
        let items = [item("cpuHeavy", cpu: 90, memory: 10 * mib), item("memHeavy", cpu: 1, memory: 2_000 * mib)]
        let before = ProcessTableOrdering.next(
            items, column: .cpu, ascending: false, cpuReady: false, previous: [], frozen: false)
        #expect(before == ["memHeavy", "cpuHeavy"])
        let after = ProcessTableOrdering.next(
            items, column: .cpu, ascending: false, cpuReady: true, previous: before, frozen: false)
        #expect(after == ["cpuHeavy", "memHeavy"])
    }

    @Test func freezeHoldsTheSet() {
        let previous = ["a", "b", "c", "d"]
        let items = [item("a", cpu: 5), item("b", cpu: 4), item("c", cpu: 3), item("d", cpu: 2), item("f", cpu: 99)]
        #expect(
            ProcessTableOrdering.next(
                items, column: .cpu, ascending: false, cpuReady: true, previous: previous, frozen: true)
                == previous)
        let withoutC = items.filter { $0.id != "c" }
        #expect(
            ProcessTableOrdering.next(
                withoutC, column: .cpu, ascending: false, cpuReady: true, previous: previous, frozen: true)
                == ["a", "b", "d"])
        #expect(
            ProcessTableOrdering.next(
                items, column: .cpu, ascending: false, cpuReady: true, previous: previous, frozen: false)
                == ["f", "a", "b", "c", "d"])
        let gone = [item("x", cpu: 1), item("y", cpu: 2)]
        #expect(
            ProcessTableOrdering.next(
                gone, column: .cpu, ascending: false, cpuReady: true, previous: ["g1", "g2"], frozen: true)
                == ["y", "x"])
    }

    @Test func noLimit() {
        let items = (0..<450).map { item("p\($0)", cpu: Double($0 % 97), memory: UInt64($0) * mib) }
        let ids = ProcessTableOrdering.next(
            items, column: .cpu, ascending: false, cpuReady: true, previous: [], frozen: false)
        #expect(ids.count == 450)
        #expect(Set(ids).count == 450)
    }

    @Test func tieBreakChain() {
        // All four read "10 %". No previous: footprint descending, then name, then id.
        let items = [
            item("id2", cpu: 10, memory: 100 * mib, name: "same"),
            item("id1", cpu: 10, memory: 100 * mib, name: "same"),
            item("big", cpu: 10, memory: 900 * mib, name: "zzz"),
            item("alpha", cpu: 10, memory: 100 * mib, name: "alpha"),
        ]
        #expect(order(items, .cpu, ascending: false) == ["big", "alpha", "id1", "id2"])
        // A previous order beats footprint, name and id.
        #expect(
            order(items, .cpu, ascending: false, previous: ["id2", "alpha", "big", "id1"])
                == ["id2", "alpha", "big", "id1"])
    }

    @Test func rateQuantizer() {
        #expect(ProcessTableOrdering.quantizedRate(nil) == -1)
        // Below 1 MB/s: whole kB. 12 400 B/s and 12 100 B/s both read "12 kB/s".
        #expect(ProcessTableOrdering.quantizedRate(12_400) == ProcessTableOrdering.quantizedRate(12_100))
        #expect(ProcessTableOrdering.quantizedRate(12_400) != ProcessTableOrdering.quantizedRate(13_100))
        #expect(ProcessTableOrdering.quantizedRate(300) == 0)
        #expect(ProcessTableOrdering.quantizedRate(12_400) == 12_000)
        // From 1 MB/s: tenths of a MB. 2.41 MB and 2.44 MB tie, 2.41 MB and 2.56 MB do not.
        #expect(ProcessTableOrdering.quantizedRate(2_410_000) == ProcessTableOrdering.quantizedRate(2_440_000))
        #expect(ProcessTableOrdering.quantizedRate(2_410_000) != ProcessTableOrdering.quantizedRate(2_560_000))
        #expect(ProcessTableOrdering.quantizedRate(2_410_000) == 2_400_000)
        // From 1 GB/s: tenths of a GB.
        #expect(ProcessTableOrdering.quantizedRate(1_230_000_000) == 1_200_000_000)
        // One monotonic byte scale across the unit changes.
        let below = ProcessTableOrdering.quantizedRate(999_400)
        let above = ProcessTableOrdering.quantizedRate(1_040_000)
        let big = ProcessTableOrdering.quantizedRate(3_000_000_000)
        #expect(below <= above)
        #expect(above < big)
    }

    @Test func helpersFollowTheColumn() {
        let helpers = [
            item("h1", memory: 10 * mib, name: "Utility"), item("h2", memory: 30 * mib, name: "Renderer"),
            item("h3", memory: 20 * mib, name: "GPU Process"),
        ]
        #expect(order(helpers, .memory, ascending: false) == ["h2", "h3", "h1"])
        #expect(order(helpers, .memory, ascending: true) == ["h1", "h3", "h2"])
        let named = [item("u", name: "Utility"), item("r", name: "Renderer")]
        #expect(order(named, .name, ascending: true) == ["r", "u"])
    }

    @Test func headerChoiceBeatsTheFreeze() {
        // The rows were frozen in CPU order; the user clicks Memory.
        let items = [
            item("a", cpu: 50, memory: 1 * mib), item("b", cpu: 20, memory: 9 * mib),
            item("c", cpu: 80, memory: 5 * mib),
        ]
        let frozenCPUOrder = ["c", "a", "b"]
        let held = ProcessTableOrdering.next(
            items, column: .memory, ascending: false, cpuReady: true, previous: frozenCPUOrder,
            frozen: true, sortChanged: false)
        #expect(held == frozenCPUOrder)
        let applied = ProcessTableOrdering.next(
            items, column: .memory, ascending: false, cpuReady: true, previous: frozenCPUOrder,
            frozen: true, sortChanged: true)
        #expect(applied == ["b", "c", "a"])
        // A new row also enters at once, because the order is rebuilt rather than held.
        let withNew = items + [item("d", cpu: 1, memory: 99 * mib)]
        #expect(
            ProcessTableOrdering.next(
                withNew, column: .memory, ascending: false, cpuReady: true, previous: frozenCPUOrder,
                frozen: true, sortChanged: true) == ["d", "b", "c", "a"])
    }

    /// PROC-04: two rates that read the same at the displayed unit keep their previous order; the
    /// ties fall back to memory (largest first), then name; a row with no rate sorts last either way.
    @Test func diskColumnsTieAndOrder() {
        for column in [ProcessTableColumn.diskRead, .diskWrite] {
            func rated(_ id: String, _ rate: Double?, memory: UInt64? = nil, name: String? = nil) -> ProcessTableItem {
                column == .diskRead
                    ? item(id, memory: memory, name: name, read: rate)
                    : item(id, memory: memory, name: name, write: rate)
            }
            // 1_000_400 and 1_000_100 both read "1.0 MB/s".
            let pair = [rated("a", 1_000_400), rated("b", 1_000_100)]
            #expect(order(pair, column, ascending: false, previous: ["b", "a"]) == ["b", "a"])
            #expect(order(pair, column, ascending: false, previous: ["a", "b"]) == ["a", "b"])
            #expect(order(pair, column, ascending: true, previous: ["b", "a"]) == ["b", "a"])

            // No previous order: equal at the unit, then memory descending, then name ascending.
            let tied = [
                rated("small", 1_000_100, memory: 10 * mib, name: "alpha"),
                rated("big", 1_000_400, memory: 900 * mib, name: "zeta"),
                rated("bName", 1_000_200, memory: 10 * mib, name: "beta"),
            ]
            #expect(order(tied, column, ascending: false) == ["big", "small", "bName"])

            // Real differences still order, and a missing rate is last in both directions.
            let mixed = [rated("none", nil, memory: 9_000 * mib), rated("slow", 5_000), rated("fast", 3_000_000)]
            #expect(order(mixed, column, ascending: false) == ["fast", "slow", "none"])
            #expect(order(mixed, column, ascending: true) == ["slow", "fast", "none"])
        }
    }
}
