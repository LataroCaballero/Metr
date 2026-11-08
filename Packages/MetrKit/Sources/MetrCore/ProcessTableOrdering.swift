import Foundation

/// A column of the window's process table (D-10). The raw values are what the table remembers
/// between launches (`windowProcessSortColumn`).
public enum ProcessTableColumn: String, Sendable, CaseIterable {
    case name, cpu, memory, diskRead, diskWrite
}

/// One candidate row of the process table: what the ordering needs and nothing else. Groups and
/// helpers both use it, each ordered among its own siblings.
public struct ProcessTableItem: Sendable, Equatable {
    /// Stable row identity (app bundle path, or `pid:<pid>:<startMicros>`).
    public var id: String
    public var name: String
    public var cpuPercent: Double?
    public var footprintBytes: UInt64?
    public var diskReadPerSec: Double?
    public var diskWritePerSec: Double?

    public init(
        id: String, name: String, cpuPercent: Double?, footprintBytes: UInt64?,
        diskReadPerSec: Double? = nil, diskWritePerSec: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.cpuPercent = cpuPercent
        self.footprintBytes = footprintBytes
        self.diskReadPerSec = diskReadPerSec
        self.diskWritePerSec = diskWritePerSec
    }
}

/// Pure ordering rules of the window's process table (D-12, D-16; RESEARCH Pattern 6), in the shape
/// of `RankingEngine`: a function of the input and the `previous` order, so a table of nearly equal
/// rows does not shuffle every tick. The same rules order the groups and, per group, its helpers.
/// Unlike the panel's list there is no row limit: every process is a row.
public enum ProcessTableOrdering {
    private static let kilo: Double = 1_000
    private static let mega: Double = 1_000_000
    private static let giga: Double = 1_000_000_000

    /// The column the table is actually ordered by: Memory until CPU is known for everyone, then the
    /// selection. CPU and both disk-rate columns wait for the same second reading, so they share the
    /// Phase 2 D-20 single transition. Name and Memory never wait.
    public static func effectiveColumn(_ column: ProcessTableColumn, cpuReady: Bool) -> ProcessTableColumn {
        switch column {
        case .cpu, .diskRead, .diskWrite: cpuReady ? column : .memory
        case .name, .memory: column
        }
    }

    /// The direction a column starts in when it is clicked: Name A to Z, numbers biggest first.
    public static func defaultAscending(_ column: ProcessTableColumn) -> Bool {
        column == .name
    }

    /// A disk rate at the unit its cell shows, as bytes on one monotonic scale: whole kB below
    /// 1 MB/s, tenths of a MB from there, tenths of a GB from 1 GB/s (decimal units, as Finder and
    /// `MetricText.rate`). Two rates that read the same therefore tie. Nil (pending) is -1.
    public static func quantizedRate(_ bytesPerSecond: Double?) -> Int64 {
        guard let bytesPerSecond else { return -1 }
        guard bytesPerSecond.isFinite else { return bytesPerSecond > 0 ? Int64.max : 0 }
        let value = min(max(0, bytesPerSecond), 9e18)
        let unit: Double = value < mega ? kilo : value < giga ? mega / 10 : giga / 10
        return Int64(min(9e18, (value / unit).rounded() * unit))
    }

    /// Ids in table order. Key, in this order: the quantized active value (in `ascending` direction,
    /// nil last either way), the index in `previous` ascending (absent last), the footprint
    /// descending, the name ascending, the id ascending. Two rows therefore swap only when their
    /// active values differ by at least one displayed unit.
    public static func order(
        _ items: [ProcessTableItem], column: ProcessTableColumn, ascending: Bool, previous: [String]
    ) -> [String] {
        var index: [String: Int] = [:]
        for (position, id) in previous.enumerated() where index[id] == nil { index[id] = position }

        struct Keyed {
            let item: ProcessTableItem
            let value: Int64?
            let slot: Int
        }
        let keyed = items.map { item in
            Keyed(item: item, value: value(of: item, column: column), slot: index[item.id] ?? Int.max)
        }
        return keyed.sorted { a, b in
            if column == .name {
                let byName = a.item.name.localizedStandardCompare(b.item.name)
                if byName != .orderedSame { return (byName == .orderedAscending) == ascending }
            } else {
                switch (a.value, b.value) {
                case (nil, nil): break
                case (nil, _): return false
                case (_, nil): return true
                case (let x?, let y?):
                    if x != y { return ascending ? x < y : x > y }
                }
            }
            if a.slot != b.slot { return a.slot < b.slot }
            let fa = a.item.footprintBytes ?? 0
            let fb = b.item.footprintBytes ?? 0
            if fa != fb { return fa > fb }
            let byName = a.item.name.localizedStandardCompare(b.item.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return a.item.id < b.item.id
        }.map(\.item.id)
    }

    /// The ids to show. While `frozen` with a non-empty `previous`, the set and order are kept:
    /// rows that exited drop out, no new row enters (D-16). Otherwise every id in `order` under the
    /// effective column. A freeze whose rows have all exited falls through to a fresh order. While
    /// the effective column stands in for CPU, the direction is that column's default.
    public static func next(
        _ items: [ProcessTableItem], column: ProcessTableColumn, ascending: Bool, cpuReady: Bool,
        previous: [String], frozen: Bool, sortChanged: Bool = false
    ) -> [String] {
        if frozen, !previous.isEmpty {
            let present = Set(items.map(\.id))
            let kept = previous.filter { present.contains($0) }
            if !kept.isEmpty { return kept }
        }
        let effective = effectiveColumn(column, cpuReady: cpuReady)
        let direction = effective == column ? ascending : defaultAscending(effective)
        return order(items, column: effective, ascending: direction, previous: previous)
    }

    private static func value(of item: ProcessTableItem, column: ProcessTableColumn) -> Int64? {
        switch column {
        case .name: nil
        case .cpu: item.cpuPercent.map { Int64(RankingEngine.quantizedCPU($0)) }
        case .memory: item.footprintBytes.map { RankingEngine.quantizedMemory($0) }
        case .diskRead: item.diskReadPerSec.map { quantizedRate($0) }
        case .diskWrite: item.diskWritePerSec.map { quantizedRate($0) }
        }
    }
}
