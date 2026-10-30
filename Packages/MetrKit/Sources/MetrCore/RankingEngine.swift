import Foundation

/// One candidate row for the Top Apps list: what the ranking needs and nothing else.
public struct RankItem: Sendable, Equatable {
    /// Stable row identity (app bundle path, or pid plus start time), the same id the view keys by.
    public var id: String
    public var cpuPercent: Double?
    public var footprintBytes: UInt64?
    /// A cheap name used only to break ties.
    public var name: String

    public init(id: String, cpuPercent: Double?, footprintBytes: UInt64?, name: String) {
        self.id = id
        self.cpuPercent = cpuPercent
        self.footprintBytes = footprintBytes
        self.name = name
    }
}

/// Pure ranking rules of the Top Apps list (D-10, D-20), in the shape of `TintLogic`: a function of
/// the input and the `previous` order, so a list of nearly equal rows does not shuffle every tick.
public enum RankingEngine {
    private static let mib: Int64 = 1_048_576
    private static let gib: Int64 = 1_073_741_824

    /// The CPU value at the unit the row shows: whole percent. Nil (pending) is -1, so it sorts
    /// below a real zero.
    public static func quantizedCPU(_ percent: Double?) -> Int {
        guard let percent else { return -1 }
        return Int(max(0, percent).rounded().asInt64)
    }

    /// The footprint at the unit the row shows: whole MiB below 1 GiB, tenths of a GiB from there.
    /// The result is in bytes so both ranges sit on one monotonic scale, and anything that shows
    /// as "1 GB" or less ties at 1 GiB. Nil (pending) is -1.
    public static func quantizedMemory(_ bytes: UInt64?) -> Int64 {
        guard let bytes else { return -1 }
        let value = Int64(clamping: bytes)
        if value < gib {
            return (Double(value) / Double(mib)).rounded().asInt64 * mib
        }
        let tenths = (Double(value) / Double(gib) * 10).rounded().asInt64
        return max(gib, tenths * (gib / 10))
    }

    /// The column the list is actually ranked by: memory until CPU is known for everyone, then the
    /// selection. This is D-20's single transition: the list is never CPU-sorted from half the data.
    public static func effectiveColumn(_ column: SortColumn, cpuReady: Bool) -> SortColumn {
        cpuReady ? column : .memory
    }

    /// Ids in rank order. Key, in this order: the quantized active value descending, the index in
    /// `previous` ascending (absent last), the footprint descending, the name ascending (D-10).
    /// Two rows therefore swap only when their active values differ by at least one displayed unit.
    public static func order(_ items: [RankItem], by column: SortColumn, previous: [String]) -> [String] {
        var index: [String: Int] = [:]
        for (position, id) in previous.enumerated() where index[id] == nil { index[id] = position }

        struct Keyed {
            let item: RankItem
            let value: Int64
            let slot: Int
        }
        let keyed = items.map { item in
            Keyed(
                item: item,
                value: column == .cpu
                    ? Int64(quantizedCPU(item.cpuPercent)) : quantizedMemory(item.footprintBytes),
                slot: index[item.id] ?? Int.max)
        }
        return keyed.sorted { a, b in
            if a.value != b.value { return a.value > b.value }
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
    /// rows that exited drop out, no new row enters (D-10). Otherwise the first `limit` of `order`
    /// under the effective column. A freeze whose rows have all exited falls through to a fresh ranking.
    public static func next(
        _ items: [RankItem], column: SortColumn, cpuReady: Bool, previous: [String], frozen: Bool, limit: Int
    ) -> [String] {
        if frozen, !previous.isEmpty {
            let present = Set(items.map(\.id))
            let kept = previous.filter { present.contains($0) }
            if !kept.isEmpty { return kept }
        }
        let effective = effectiveColumn(column, cpuReady: cpuReady)
        return Array(order(items, by: effective, previous: previous).prefix(limit))
    }
}

extension Double {
    /// Saturating conversion; NaN reads as 0. A plain `Int(self)` would trap on out-of-range input.
    fileprivate var asInt64: Int64 {
        if isNaN { return 0 }
        if self >= 9.2e18 { return Int64.max }
        if self <= -9.2e18 { return Int64.min }
        return Int64(self)
    }
}
