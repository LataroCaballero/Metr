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

public enum ProcessTableOrdering {
    public static func effectiveColumn(_ column: ProcessTableColumn, cpuReady: Bool) -> ProcessTableColumn {
        column
    }

    public static func defaultAscending(_ column: ProcessTableColumn) -> Bool { true }

    public static func order(
        _ items: [ProcessTableItem], column: ProcessTableColumn, ascending: Bool, previous: [String]
    ) -> [String] {
        items.map(\.id)
    }

    public static func next(
        _ items: [ProcessTableItem], column: ProcessTableColumn, ascending: Bool, cpuReady: Bool,
        previous: [String], frozen: Bool
    ) -> [String] {
        []
    }

    public static func quantizedRate(_ bytesPerSecond: Double?) -> Int64 { 0 }
}
