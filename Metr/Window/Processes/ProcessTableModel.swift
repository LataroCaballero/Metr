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

    /// The same row with other children: a search that matched only some helpers shows just those.
    func replacingChildren(_ children: [ProcessTableRow]) -> ProcessTableRow {
        ProcessTableRow(
            id: id, name: name, help: help, icon: icon, kind: kind, pid: pid, isHelper: isHelper,
            isOwn: isOwn, cpuPercent: cpuPercent, footprintBytes: footprintBytes,
            diskReadPerSec: diskReadPerSec, diskWritePerSec: diskWritePerSec, helperCount: helperCount,
            children: children)
    }

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

    /// The text of the toolbar search field (D-13). Never persisted: it dies with the window.
    var searchText = ""

    /// True while the pointer is over the table: the order holds still so the next click lands on
    /// the row the user aimed at (D-16, T-03-27). Observed, because a change must re-evaluate the rows.
    private(set) var isPointerInTable = false

    /// The table's frame in screen coordinates, reported by the view. The watchdog compares the
    /// pointer with it, because a hover end can be missed (the panel's rule, Phase 2 D-10).
    @ObservationIgnored var tableScreenFrame: CGRect?

    /// Whether the order is held still (D-16): the pointer is over the table or a row is selected.
    /// A selected row never moves, so a toolbar action can never act on a row that slid away.
    var isFrozen: Bool { isPointerInTable || !selection.isEmpty }

    /// Groups the current search opened because only some of their helpers matched. Derived from the
    /// query and the reading on every build, never the user's own expansion (D-13).
    @ObservationIgnored private(set) var searchExpanded: Set<String> = []

    /// A query is active: an empty result then means "no match", not "no processes".
    var hasQuery: Bool { ProcessSearch.normalize(searchText) != nil }

    /// The group the outline should scroll into view on its next update. Written by `focus`, read and
    /// cleared by the host while it applies a refresh, so it is not observed.
    @ObservationIgnored var scrollTarget: String?
    /// A deep link whose group is not in a reading yet (the window just opened). Applied on the first
    /// reading that has it, dropped silently after three seconds (T-03-28).
    @ObservationIgnored private var pendingFocus: (id: String, deadline: Date)?
    private static let pendingFocusLifetime: TimeInterval = 3

    @ObservationIgnored private let naming = ProcessNaming(cacheLimit: ProcessTableModel.cacheLimit)
    @ObservationIgnored private var grouped: (sequence: UInt64, groups: [ProcessGroup])?
    @ObservationIgnored private var previousGroups: [String] = []
    @ObservationIgnored private var previousChildren: [String: [String]] = [:]
    @ObservationIgnored private var memo: (key: MemoKey, rows: [ProcessTableRow])?
    /// The ids of every row of the newest build, after the search and the freeze: what can be selected.
    @ObservationIgnored private var liveIDs: Set<String> = []
    /// The ids of every group in the newest reading, whatever the search hides: what can stay expanded
    /// and what a deep link can find.
    @ObservationIgnored private var readingGroupIDs: Set<String> = []
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
        var query: String?
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

    /// The "and N more…" deep link (D-01, D-02): opens one group, selects it and asks the outline to
    /// scroll it into view. A search in the way is cleared so the group can be seen. When the group is
    /// not in a reading yet the focus waits for it, for up to three seconds, and then disappears
    /// without an error (T-03-28).
    func focus(groupID: String) {
        pendingFocus = (groupID, Date().addingTimeInterval(Self.pendingFocusLifetime))
        applyPendingFocus()
    }

    /// Applies a waiting focus once its group is in a reading. Called when the table appears and on
    /// every new reading, outside the view update.
    func applyPendingFocus() {
        guard let pending = pendingFocus else { return }
        if readingGroupIDs.contains(pending.id) {
            pendingFocus = nil
            if !searchText.isEmpty { searchText = "" }
            expanded.insert(pending.id)
            selection = [pending.id]
            scrollTarget = pending.id
        } else if Date() > pending.deadline {
            pendingFocus = nil
        }
    }

    /// Whether a group is open in the outline: the user opened it, or the search did.
    func isOpen(_ id: String) -> Bool { expanded.contains(id) || searchExpanded.contains(id) }

    /// The user opened or closed a group with the disclosure triangle or the keyboard. Closing one
    /// the search had opened closes it for the rest of that search too.
    func userSetExpanded(_ id: String, open: Bool) {
        if open {
            expanded.insert(id)
        } else {
            expanded.remove(id)
            searchExpanded.remove(id)
        }
    }

    /// Esc, a click on empty space or an exited process ends the selection, and with it the freeze.
    func clearSelection() {
        if !selection.isEmpty { selection = [] }
    }

    /// The host reports the pointer entering or leaving the table.
    func setPointerInTable(_ inside: Bool) {
        if isPointerInTable != inside { isPointerInTable = inside }
    }

    /// Releases a hold that outlived its pointer: when the pointer is outside the table's frame the
    /// hover end was missed. A pointer resting inside the frame never releases it (D-16). Called after
    /// each process reading, so a stuck freeze lasts one tick at most.
    func runFreezeWatchdog() {
        #if DEBUG
        if scriptedPointer { return }
        #endif
        guard isPointerInTable, let frame = tableScreenFrame else { return }
        if !frame.contains(NSEvent.mouseLocation) { isPointerInTable = false }
    }

    /// Forgets expansion of groups that are gone and selection of rows that are gone or that a search
    /// hid. Called once per new reading and when the search changes, outside the view update.
    func prune() {
        guard !readingGroupIDs.isEmpty else { return }
        let openAndLive = expanded.intersection(readingGroupIDs)
        if openAndLive != expanded { expanded = openAndLive }
        let selectedAndShown = selection.intersection(liveIDs)
        if selectedAndShown != selection { selection = selectedAndShown }
    }

    /// The root rows for one reading. Grouping runs once per sequence; ordering and row building
    /// are memoized by (sequence, column, direction, freeze, expansion), so a re-render with
    /// nothing changed costs none.
    func rows(for snapshot: ProcessSnapshot) -> [ProcessTableRow] {
        let query = ProcessSearch.normalize(searchText)
        let frozen = isFrozen
        let key = MemoKey(
            sequence: snapshot.sequence, column: column, ascending: ascending, frozen: frozen,
            expanded: expanded, query: query)
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
        for group in live {
            let row = row(
                for: group, snapshot: snapshot, selfPID: pid, selfUID: me, frozen: frozen,
                sortChanged: sortChanged, children: &newChildren)
            guard rowsByID[group.id] == nil else { continue }
            rowsByID[group.id] = row
            items.append(
                ProcessTableItem(
                    id: row.id, name: row.name, cpuPercent: row.cpuPercent,
                    footprintBytes: row.footprintBytes, diskReadPerSec: row.diskReadPerSec,
                    diskWritePerSec: row.diskWritePerSec))
        }
        // Ordered and frozen over every group; the search only filters afterwards, so a query never
        // reorders anything and the order the freeze holds is the order the user was looking at.
        let order = ProcessTableOrdering.next(
            items, column: column, ascending: ascending, cpuReady: snapshot.cpuReady,
            previous: previousGroups, frozen: frozen, sortChanged: sortChanged)

        var rows: [ProcessTableRow] = []
        var opened: Set<String> = []
        if let query {
            for id in order {
                guard let row = rowsByID[id] else { continue }
                let fields = ProcessSearchFields(
                    groupID: id, name: row.name, pid: row.pid,
                    helpers: row.children.map { ProcessSearchHelper(id: $0.id, name: $0.name, pid: $0.pid) })
                guard let match = ProcessSearch.match(query, fields) else { continue }
                if match.groupMatches {
                    // A group that matches by name stays as the user left it, all helpers included.
                    rows.append(row)
                } else {
                    // Only helpers matched: the group opens by itself, showing just those.
                    opened.insert(id)
                    rows.append(row.replacingChildren(row.children.filter { match.helperIDs.contains($0.id) }))
                }
            }
        } else {
            rows = order.compactMap { rowsByID[$0] }
        }

        var shown: Set<String> = []
        var helperTotal = 0
        for row in rows {
            shown.insert(row.id)
            for child in row.children { shown.insert(child.id) }
            helperTotal += row.children.count
        }

        previousGroups = order
        previousChildren = newChildren
        readingGroupIDs = Set(rowsByID.keys)
        liveIDs = shown
        searchExpanded = opened
        memo = (key, rows)
        // The header indicator and the emphasis follow the effective column. It changes at most once
        // (the first CPU reading), and never while the view reads it for the first time in a body.
        if effectiveColumn != effective { effectiveColumn = effective }
        logTable(sequence: snapshot.sequence, rows: rows, helpers: helperTotal, effective: effective, ready: snapshot.cpuReady)
        logSearchAndFreeze(
            sequence: snapshot.sequence, query: query, rows: rows, helpers: helperTotal, order: order,
            frozen: frozen, sortChanged: sortChanged)
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
        frozen: Bool, sortChanged: Bool, children newChildren: inout [String: [String]]
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
            previous: previousChildren[group.id] ?? [], frozen: frozen, sortChanged: sortChanged)
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

    /// `table search=<chars> groups=<n> helpers=<n>` when the filtered result changes, and
    /// `table frozen=<0|1> moved=<n>` once per reading and per change of the freeze. `moved` counts
    /// rows whose order against the others changed since the freeze began; it must be 0 while frozen.
    /// Numbers only, never a name.
    private func logSearchAndFreeze(
        sequence: UInt64, query: String?, rows: [ProcessTableRow], helpers: Int, order: [String],
        frozen: Bool, sortChanged: Bool
    ) {
        #if DEBUG
        if let query {
            let key = "\(query)/\(rows.map(\.id))/\(helpers)"
            if loggedSearchKey != key {
                loggedSearchKey = key
                DebugHooks.log("table search=\(query.count) groups=\(rows.count) helpers=\(helpers)")
            }
        } else {
            loggedSearchKey = nil
        }

        var moved = 0
        if frozen {
            if freezeBaseline == nil || sortChanged {
                freezeBaseline = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
            } else if let baseline = freezeBaseline {
                var last = -1
                for id in order {
                    guard let index = baseline[id] else { continue }
                    if index < last { moved += 1 } else { last = index }
                }
            }
        } else {
            freezeBaseline = nil
        }
        let freezeKey = "\(sequence)/\(frozen)"
        guard loggedFreezeKey != freezeKey else { return }
        loggedFreezeKey = freezeKey
        DebugHooks.log("table frozen=\(frozen ? 1 : 0) moved=\(moved)")
        #endif
    }

    #if DEBUG
    @ObservationIgnored private var loggedSearchKey: String?
    @ObservationIgnored private var loggedFreezeKey: String?
    /// The order the table held when the current freeze began, by id.
    @ObservationIgnored private var freezeBaseline: [String: Int]?
    /// A scripted `hover:` step stands in for the pointer, so the watchdog leaves it alone.
    @ObservationIgnored private var scriptedPointer = false

    /// The window script's `hover:<0|1>` step.
    func scriptPointer(_ inside: Bool) {
        scriptedPointer = inside
        setPointerInTable(inside)
    }

    /// The rows of the newest reading, for the DEBUG outline probe. Empty before the first read.
    var debugRows: [ProcessTableRow] { memo?.rows ?? [] }
    #endif
}
