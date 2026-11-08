import AppKit
import MetrCore
import Observation
import SwiftUI

/// One row of the window's process table: an app group, a standalone process or a helper (D-10,
/// D-14). Identified by the group id (app path or `pid:<pid>:<start>`), never by position, so
/// selection and expansion survive every refresh (RESEARCH Pitfall 7).
struct ProcessTableRow: Identifiable, Equatable {
    let id: String
    /// The cleaned name (Phase 2 D-12).
    let name: String
    /// The name and PID, for the tooltip.
    let help: String
    let icon: NSImage
    /// Who owns the row, from pid, uid and canonical path only (Phase 2 D-09). `.system` shows a lock.
    let kind: ProcessKind
    let pid: Int32
    let isHelper: Bool
    /// The row's process (a group's main process) belongs to the current user.
    let isOwn: Bool
    let cpuPercent: Double?
    let footprintBytes: UInt64?
    /// Bytes per second over the last process sample (a group's is the sum of the members that
    /// report). Nil is "not available": a process macOS gives Metr no I/O for, or one with a single
    /// reading so far. Never a fabricated zero (PROC-04, D-11).
    let diskReadPerSec: Double?
    let diskWritePerSec: Double?
    let helperCount: Int
    /// Every helper of a group, in the active order. Empty for a helper and a standalone process.
    let children: [ProcessTableRow]

    /// The comparable values the column headers sort by. The table never sorts its data with them:
    /// the model orders the rows (`ProcessTableOrdering`); they exist for the header indicator.
    var sortName: String { name }
    var sortCPU: Double { cpuPercent ?? -1 }
    var sortMemory: UInt64 { footprintBytes ?? 0 }
}

/// The state of the window's process table, one per window session (WIN-04, D-10, D-12, D-14).
///
/// It is created when the window opens and dropped when it closes (`WindowModel.setOpen`), so
/// expansion, selection and the name and icon caches survive section switches and die with the
/// window. Only the sort is remembered between launches, silently, like the section.
@MainActor
@Observable
final class ProcessTableModel {
    static let columnKey = "windowProcessSortColumn"
    static let ascendingKey = "windowProcessSortAscending"
    /// The table names every app on the Mac, so its caches are larger than the panel's.
    private static let cacheLimit = 1024

    /// Open groups, by group id. Several can be open at once (D-14).
    var expanded: Set<String> = []
    /// The selected rows (a single selection is used).
    var selection: Set<String> = []

    /// The column the user chose, and its direction.
    private(set) var column: ProcessTableColumn
    private(set) var ascending: Bool

    /// Release always persists. A scripted DEBUG run never does (T-03-22).
    let persistsState: Bool

    /// The column the table was ordered by the last time it was built: Memory until CPU is known,
    /// then the selection. Not observed: the view derives the same value from the reading it draws,
    /// and a value changed during a view update would be a state change inside `body`.
    @ObservationIgnored private(set) var effectiveColumn: ProcessTableColumn

    /// Whether the order is held still. 03-13 sets it from the pointer and the selection (D-16).
    @ObservationIgnored var isFrozen = false

    @ObservationIgnored private let naming = ProcessNaming(cacheLimit: ProcessTableModel.cacheLimit)
    @ObservationIgnored private var grouped: (sequence: UInt64, groups: [ProcessGroup])?
    @ObservationIgnored private var previousGroups: [String] = []
    @ObservationIgnored private var previousChildren: [String: [String]] = [:]
    @ObservationIgnored private var memo: (key: MemoKey, rows: [ProcessTableRow])?
    @ObservationIgnored private var liveIDs: Set<String> = []
    @ObservationIgnored private var loggedKey: String?
    /// The sort the rows were last built with, so the first build after a header click knows it must
    /// ignore the freeze.
    @ObservationIgnored private var builtSort: Sort?

    private struct Sort: Equatable {
        var column: ProcessTableColumn
        var ascending: Bool
    }

    private struct MemoKey: Equatable {
        var sequence: UInt64
        var column: ProcessTableColumn
        var ascending: Bool
        var frozen: Bool
        var expanded: Set<String>
    }

    init(persistsState: Bool) {
        self.persistsState = persistsState
        var column = ProcessTableColumn.cpu
        var ascending = ProcessTableOrdering.defaultAscending(.cpu)
        if persistsState {
            let defaults = UserDefaults.standard
            if let stored = defaults.string(forKey: Self.columnKey).flatMap(ProcessTableColumn.init(rawValue:)) {
                column = stored
                ascending = (defaults.object(forKey: Self.ascendingKey) as? Bool)
                    ?? ProcessTableOrdering.defaultAscending(stored)
            }
        }
        self.column = column
        self.ascending = ascending
        effectiveColumn = column
    }

    /// Sorts by a column in a direction, at once: the memo key changes, so the next read re-orders
    /// even while frozen. Written to the preferences only when `persistsState` (T-03-22).
    func setSort(_ column: ProcessTableColumn, ascending: Bool) {
        guard column != self.column || ascending != self.ascending else { return }
        self.column = column
        self.ascending = ascending
        if persistsState {
            UserDefaults.standard.set(column.rawValue, forKey: Self.columnKey)
            UserDefaults.standard.set(ascending, forKey: Self.ascendingKey)
        }
    }

    /// A two-way binding to whether one group is open, for `DisclosureTableRow`.
    func binding(expandedFor id: String) -> Binding<Bool> {
        Binding(
            get: { self.expanded.contains(id) },
            set: { open in
                if open { self.expanded.insert(id) } else { self.expanded.remove(id) }
            })
    }

    /// Forgets expansion and selection of rows that are gone. Called once per new reading, outside
    /// the view update.
    func prune() {
        guard !liveIDs.isEmpty else { return }
        let openAndLive = expanded.intersection(liveIDs)
        if openAndLive != expanded { expanded = openAndLive }
        let selectedAndLive = selection.intersection(liveIDs)
        if selectedAndLive != selection { selection = selectedAndLive }
    }

    /// The root rows for one reading. Grouping runs once per sequence; ordering and row building
    /// are memoized by (sequence, column, direction, freeze, expansion), so a re-render with
    /// nothing changed costs none.
    func rows(for snapshot: ProcessSnapshot) -> [ProcessTableRow] {
        let key = MemoKey(
            sequence: snapshot.sequence, column: column, ascending: ascending, frozen: isFrozen,
            expanded: expanded)
        if let memo, memo.key == key { return memo.rows }

        let effective = ProcessTableOrdering.effectiveColumn(column, cpuReady: snapshot.cpuReady)
        let sortChanged = builtSort != nil && builtSort != Sort(column: column, ascending: ascending)
        builtSort = Sort(column: column, ascending: ascending)
        let live = groups(for: snapshot)
        let me = getuid()
        let pid = getpid()

        var rowsByID: [String: ProcessTableRow] = [:]
        var items: [ProcessTableItem] = []
        var newChildren: [String: [String]] = [:]
        var ids: Set<String> = []
        var helperTotal = 0
        for group in live {
            let row = row(
                for: group, snapshot: snapshot, selfPID: pid, selfUID: me, sortChanged: sortChanged,
                children: &newChildren)
            guard rowsByID[group.id] == nil else { continue }
            rowsByID[group.id] = row
            items.append(
                ProcessTableItem(
                    id: row.id, name: row.name, cpuPercent: row.cpuPercent,
                    footprintBytes: row.footprintBytes, diskReadPerSec: row.diskReadPerSec,
                    diskWritePerSec: row.diskWritePerSec))
            ids.insert(row.id)
            for child in row.children { ids.insert(child.id) }
            helperTotal += row.children.count
        }
        let order = ProcessTableOrdering.next(
            items, column: column, ascending: ascending, cpuReady: snapshot.cpuReady,
            previous: previousGroups, frozen: isFrozen, sortChanged: sortChanged)
        let rows = order.compactMap { rowsByID[$0] }

        previousGroups = order
        previousChildren = newChildren
        liveIDs = ids
        memo = (key, rows)
        // The header indicator and the emphasis follow the effective column. It changes at most once
        // (the first CPU reading), and never while the view reads it for the first time in a body.
        if effectiveColumn != effective { effectiveColumn = effective }
        logTable(sequence: snapshot.sequence, rows: rows, helpers: helperTotal, effective: effective, ready: snapshot.cpuReady)
        return rows
    }

    private func groups(for snapshot: ProcessSnapshot) -> [ProcessGroup] {
        if let grouped, grouped.sequence == snapshot.sequence { return grouped.groups }
        let groups = ProcessGrouping.groups(
            from: snapshot.processes, regularAppBundlePaths: naming.regularAppBundlePaths())
        grouped = (snapshot.sequence, groups)
        return groups
    }

    private func row(
        for group: ProcessGroup, snapshot: ProcessSnapshot, selfPID: Int32, selfUID: UInt32,
        sortChanged: Bool, children newChildren: inout [String: [String]]
    ) -> ProcessTableRow {
        let appName = group.appPath.map(naming.appDisplayName(atPath:))
        let name = appName ?? naming.standaloneName(of: group)
        let icon = naming.icon(forAppAt: group.appPath)

        var childRows: [String: ProcessTableRow] = [:]
        var items: [ProcessTableItem] = []
        for sample in group.helpers {
            let child = helperRow(for: sample, appName: appName ?? "", icon: icon, selfPID: selfPID, selfUID: selfUID)
            guard childRows[child.id] == nil else { continue }
            childRows[child.id] = child
            items.append(
                ProcessTableItem(
                    id: child.id, name: child.name, cpuPercent: child.cpuPercent,
                    footprintBytes: child.footprintBytes, diskReadPerSec: child.diskReadPerSec,
                    diskWritePerSec: child.diskWritePerSec))
        }
        let order = ProcessTableOrdering.next(
            items, column: column, ascending: ascending, cpuReady: snapshot.cpuReady,
            previous: previousChildren[group.id] ?? [], frozen: isFrozen, sortChanged: sortChanged)
        newChildren[group.id] = order

        let representative = group.main ?? group.helpers.min { $0.identity.pid < $1.identity.pid }
        let pid = representative?.identity.pid ?? 0
        return ProcessTableRow(
            id: group.id,
            name: name,
            help: String(localized: "\(name) · PID \(Int(pid))"),
            icon: icon,
            kind: ProcessClassifier.kind(of: group, selfPID: selfPID, selfUID: selfUID),
            pid: pid,
            isHelper: false,
            isOwn: representative?.uid == selfUID,
            cpuPercent: group.cpuPercent,
            footprintBytes: group.footprintBytes,
            diskReadPerSec: group.diskReadPerSec,
            diskWritePerSec: group.diskWritePerSec,
            helperCount: group.helpers.count,
            children: order.compactMap { childRows[$0] })
    }

    private func helperRow(
        for sample: ProcessSample, appName: String, icon: NSImage, selfPID: Int32, selfUID: UInt32
    ) -> ProcessTableRow {
        let name = naming.helperName(of: sample, appName: appName)
        return ProcessTableRow(
            id: ProcessNaming.helperID(of: sample),
            name: name,
            help: String(localized: "\(name) · PID \(Int(sample.identity.pid))"),
            icon: icon,
            kind: ProcessClassifier.kind(
                pid: sample.identity.pid, uid: sample.uid, path: sample.path, selfPID: selfPID, selfUID: selfUID),
            pid: sample.identity.pid,
            isHelper: true,
            isOwn: sample.uid == selfUID,
            cpuPercent: sample.cpuPercent,
            footprintBytes: sample.footprintBytes,
            diskReadPerSec: sample.diskReadPerSec,
            diskWritePerSec: sample.diskWritePerSec,
            helperCount: 0,
            children: [])
    }

    // MARK: DEBUG

    /// `table rows=<visible rows> groups=<n> helpers=<n> sort=<column>:<asc|desc> ready=<0|1>`, once
    /// per new reading. Numbers only, never a name (the `MetricsStore.describe` rule).
    private func logTable(
        sequence: UInt64, rows: [ProcessTableRow], helpers: Int, effective: ProcessTableColumn, ready: Bool
    ) {
        #if DEBUG
        let key = "\(sequence)/\(column.rawValue)/\(ascending)"
        guard loggedKey != key else { return }
        loggedKey = key
        let visible = rows.count + rows.filter { expanded.contains($0.id) }.reduce(0) { $0 + $1.children.count }
        let direction = (effective == column ? ascending : ProcessTableOrdering.defaultAscending(effective)) ? "asc" : "desc"
        DebugHooks.log(
            "table rows=\(visible) groups=\(rows.count) helpers=\(helpers)"
                + " sort=\(effective.rawValue):\(direction) ready=\(ready ? 1 : 0)")
        #endif
    }

    #if DEBUG
    /// The rows of the newest reading, for the DEBUG outline probe. Empty before the first read.
    var debugRows: [ProcessTableRow] { memo?.rows ?? [] }
    #endif
}
