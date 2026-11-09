import AppKit
import MetrCore
import Observation

/// What the Top Apps area shows (D-20, E5).
struct TopAppsDisplay: Equatable {
    enum Content: Equatable {
        /// Up to five rows, in display order.
        case rows([TopAppRowData])
        /// The process list is not available: "App list unavailable." inside the reserved area (E5 error).
        case unavailable
    }

    var content: Content
    /// The column the list is actually ranked by: memory until CPU is known, then the selection (D-20).
    var effectiveSort: SortColumn

    /// The ids of the rows on screen, in order.
    var rowIDs: [String] {
        if case .rows(let rows) = content { return rows.map(\.id) }
        return []
    }
}

/// One visible app or standalone-process row. Identifiable by the app path or the process key,
/// so a row keeps its identity across readings.
struct TopAppRowData: Identifiable, Equatable {
    let id: String
    let name: String
    let icon: NSImage
    let cpuPercent: Double?
    let footprintBytes: UInt64?
    /// Who owns the row, from pid, uid and canonical path only (D-09). `.system` rows show a lock.
    let kind: ProcessKind
    /// How many helpers the group has. Above zero the row has a disclosure chevron.
    let helperCount: Int
    /// Present only while this group is the open one: its three heaviest helpers (D-08).
    let helpers: [HelperRowData]
    /// Helpers beyond the three shown; above zero draws the "and N more…" line.
    let moreCount: Int
    /// Whether the hover Quit is offered: only `.allowed` shows it, a disabled row shows nothing (PROC-07, D-17).
    let availability: ActionAvailability
    /// Where the row is in its action: Quitting dims it, Did-not-quit brings it back (D-15).
    let actionState: RowActionState

    var isExpanded: Bool { helperCount > 0 && !helpers.isEmpty }
}

/// One helper under an open group.
struct HelperRowData: Identifiable, Equatable {
    let id: String
    /// The cleaned name (D-12).
    let name: String
    /// The name and PID, for the tooltip (D-12).
    let help: String
    let cpuPercent: Double?
    let footprintBytes: UInt64?
    /// Whether Force Quit Process is offered for this helper, with the reason when it is not (D-16, D-17).
    let availability: ActionAvailability
    /// Where the helper is in its Force Quit (D-14, D-15).
    let actionState: RowActionState
}

/// The display model behind the Top Apps list (PANEL-04, PROC-02, PROC-03; D-06, D-07, D-08, D-12, D-20).
///
/// It lives in `@State` inside the panel content, so it is created when the popover opens and
/// destroyed when it closes; the name and icon caches go with it (RESEARCH Pitfall 11, T-02-12).
/// The init does nothing, because `@State` may evaluate it more than once.
@MainActor
@Observable
final class TopAppsModel {
    /// Rows shown in the list (D-07).
    static let rowLimit = 5
    /// Helpers listed under an open group (D-08).
    static let helperLimit = 3
    /// The group that is open, if any. Opening one closes the other (D-08).
    private(set) var expandedGroupID: String?

    /// Groups of the newest reading, computed once per snapshot sequence on the MainActor
    /// (about 600 paths, a few ms every 2 s, only while the panel is open).
    @ObservationIgnored private var grouped: (sequence: UInt64, groups: [ProcessGroup])?
    /// Names and icons, shared in rule with the window's table (`ProcessNaming`).
    @ObservationIgnored private let naming = ProcessNaming()

    /// True while the pointer is over the list rows: the set and order of rows hold still so the
    /// next click lands on the row the user aimed at (D-10, T-02-23). Observed, because a change
    /// must re-evaluate the display.
    private(set) var isPointerInList = false

    /// The list's frame in screen coordinates, reported by the view. The watchdog compares the
    /// pointer with it, because a transient popover may never deliver the hover end (RESEARCH A8).
    @ObservationIgnored var listScreenFrame: CGRect?

    /// The rows on screen the last time the display was built, in order (D-10). The ranking uses
    /// them as the tie-break, and the freeze keeps them. Not observed: they are a function of the
    /// readings, never a second live source of truth for what the view shows.
    @ObservationIgnored private var previousApps: [String] = []
    /// The same for the helpers of the open group.
    @ObservationIgnored private var previousHelpers: (group: String, ids: [String])?
    /// The last built display and what it was built from, so a re-render does no ranking work.
    @ObservationIgnored private var memo: (key: MemoKey, display: TopAppsDisplay)?
    @ObservationIgnored private var lastSort: SortColumn?

    /// The helper ids on screen in the newest build, so their action state outlives a re-render.
    @ObservationIgnored private var shownHelperIDs: Set<String> = []
    /// The one Quit / Force Quit state machine, shared in type with the window's table (RESEARCH
    /// Pitfall 8). The panel model keeps only the display logic; every action forwards to it.
    @ObservationIgnored private let actions = ProcessActionController()

    private struct MemoKey: Equatable {
        var sequence: UInt64
        var sort: SortColumn
        var frozen: Bool
        var expanded: String?
        var actions: [String: RowActionState]
        var exited: Set<String>
    }

    init() {}

    #if DEBUG
    /// DEBUG only, for the snapshot renderer: opens a group and puts rows into action states
    /// (Quitting, Did not quit, Confirming) without a click or a signal. Compiled out of Release.
    /// A preset model answers `.allowed` for every row when asked to.
    func preset(
        expanded: String?, actionStates: [String: RowActionState], availability: ActionAvailability? = nil
    ) {
        expandedGroupID = expanded
        actions.preset(actionStates: actionStates, availability: availability)
    }
    #endif

    /// The view reports the pointer entering or leaving the list rows.
    func setPointerInList(_ inside: Bool) {
        if isPointerInList != inside { isPointerInList = inside }
    }

    /// Releases a freeze that outlived its pointer: when the pointer is outside the list's frame,
    /// the hover end was missed. A pointer resting inside the frame never releases it (D-10).
    /// Called after each process reading, so a stuck freeze lasts one tick at most.
    func runFreezeWatchdog() {
        // A confirmation open keeps the order as it is; nothing is released under it (D-14).
        guard isPointerInList, !actions.actionStates.values.contains(.confirming), let frame = listScreenFrame else { return }
        if !frame.contains(NSEvent.mouseLocation) { isPointerInList = false }
    }

    /// Opens a group, or closes it when it is already open.
    func toggle(_ id: String) {
        // The helpers of the group on screen leave with it; their actions leave with them.
        if let helpers = previousHelpers { actions.forget(helpers.ids) }
        expandedGroupID = expandedGroupID == id ? nil : id
        previousHelpers = nil
    }

    /// Closes the open group once it is no longer on screen (it exited, or ranks out of the list).
    func collapse(unlessVisible visible: [String]) {
        // A row that left the screen takes its action state with it.
        actions.forget(actions.actionStates.keys.filter { !visible.contains($0) && !shownHelperIDs.contains($0) })
        if let id = expandedGroupID, !visible.contains(id) {
            expandedGroupID = nil
            previousHelpers = nil
        }
    }

    /// The rows for one reading. Grouping runs once per sequence; ranking and row building only
    /// touch the groups, so a re-render costs five rows of work, and a re-render with nothing
    /// changed costs none (the result is memoized).
    ///
    /// Ranking is `RankingEngine` (D-10, D-20): equal displayed values keep their previous order,
    /// the list is memory-ranked until CPU is known and then ranks by the selection once, and
    /// while the pointer is over the rows the set and order hold. Changing the segment re-ranks
    /// at once even while frozen (an explicit user action, D-06).
    func display(for reading: Reading<ProcessSnapshot>, sort: SortColumn) -> TopAppsDisplay {
        switch reading {
        case .pending, .unavailable:
            // D-20 and E5: the open is held until the first reading (`PanelOpenGate`), so a pending
            // reading can be on screen only after the bounded wait ended with none. To the user that
            // is the total-failure state: one line in the reserved area, replaced in place by the
            // rows when the reading lands. Never an empty area, a spinner or a skeleton.
            return TopAppsDisplay(content: .unavailable, effectiveSort: sort)
        case .value(let snapshot):
            guard !snapshot.processes.isEmpty else {
                return TopAppsDisplay(content: .unavailable, effectiveSort: sort)
            }
            let key = MemoKey(
                sequence: snapshot.sequence, sort: sort, frozen: isPointerInList, expanded: expandedGroupID,
                actions: actions.actionStates, exited: actions.exited)
            if let memo, memo.key == key { return memo.display }

            let sortChanged = lastSort != nil && lastSort != sort
            let holding = actions.holdsOrder
            let frozen = (isPointerInList || holding) && !sortChanged
            let effective = RankingEngine.effectiveColumn(sort, cpuReady: snapshot.cpuReady)
            let live = groups(for: snapshot)
            actions.retainExited(in: live.map(\.id) + live.flatMap { $0.helpers.map(Self.helperID(of:)) })
            let byID = Dictionary(
                live.filter { !actions.isExited($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let items = byID.values.map {
                RankItem(
                    id: $0.id, cpuPercent: $0.cpuPercent, footprintBytes: $0.footprintBytes,
                    name: Self.sortName(of: $0))
            }
            let ids = RankingEngine.next(
                items, column: sort, cpuReady: snapshot.cpuReady, previous: previousApps, frozen: frozen,
                limit: Self.rowLimit)
            actions.resetRoles()
            shownHelperIDs.removeAll(keepingCapacity: true)
            let rows = ids.compactMap { byID[$0] }.map { row(for: $0, sort: effective, frozen: frozen) }
            let display = TopAppsDisplay(content: .rows(rows), effectiveSort: effective)

            previousApps = ids
            lastSort = sort
            memo = (key, display)
            return display
        }
    }

    private func groups(for snapshot: ProcessSnapshot) -> [ProcessGroup] {
        if let grouped, grouped.sequence == snapshot.sequence { return grouped.groups }
        let groups = ProcessGrouping.groups(
            from: snapshot.processes, regularAppBundlePaths: naming.regularAppBundlePaths())
        grouped = (snapshot.sequence, groups)
        return groups
    }

    // MARK: Ranking

    /// A cheap, unsanitized name used only to break ties.
    private static func sortName(of group: ProcessGroup) -> String {
        if let appPath = group.appPath { return (appPath as NSString).lastPathComponent }
        return group.main.map(executableName(of:)) ?? group.id
    }

    /// The executable's last path component (see `ProcessNaming`).
    private static func executableName(of sample: ProcessSample) -> String {
        ProcessNaming.executableName(of: sample)
    }

    // MARK: Rows

    private func row(for group: ProcessGroup, sort: SortColumn, frozen: Bool) -> TopAppRowData {
        let appName = group.appPath.map(naming.appDisplayName(atPath:))
        let (role, availability) = actionInfo(for: group)
        actions.setRole(role, availability: availability, for: group.id)
        let open = expandedGroupID == group.id && !group.helpers.isEmpty
        var helpers: [HelperRowData] = []
        var more = 0
        if open {
            // The helpers use the same rules and the same freeze as the rows above them.
            let byID = Dictionary(
                group.helpers.filter { !actions.isExited(Self.helperID(of: $0)) }
                    .map { (Self.helperID(of: $0), $0) },
                uniquingKeysWith: { first, _ in first })
            let items = byID.map { id, sample in
                RankItem(
                    id: id, cpuPercent: sample.cpuPercent, footprintBytes: sample.footprintBytes,
                    name: Self.executableName(of: sample))
            }
            let previous = previousHelpers?.group == group.id ? previousHelpers?.ids ?? [] : []
            let ids = RankingEngine.next(
                items, column: sort, cpuReady: true, previous: previous, frozen: frozen,
                limit: Self.helperLimit)
            helpers = ids.compactMap { byID[$0] }.map { helperRow(for: $0, appName: appName ?? "") }
            shownHelperIDs.formUnion(ids)
            more = max(0, group.helpers.count - ids.count)
            previousHelpers = (group.id, ids)
        }
        return TopAppRowData(
            id: group.id,
            name: appName ?? naming.standaloneName(of: group),
            icon: naming.icon(forAppAt: group.appPath),
            cpuPercent: group.cpuPercent,
            footprintBytes: group.footprintBytes,
            kind: ProcessClassifier.kind(of: group, selfPID: getpid(), selfUID: getuid()),
            helperCount: group.helpers.count,
            helpers: helpers,
            moreCount: more,
            availability: availability,
            actionState: actions.state(for: group.id))
    }

    /// The role and availability of a row, from its main member only. An app group with no main
    /// process running has no role and offers nothing; a root-owned bundle is view-only (Q5).
    private func actionInfo(for group: ProcessGroup) -> (role: RowRole?, availability: ActionAvailability) {
        guard let main = group.main else { return (nil, .disabled(.cannotSignal)) }
        let role: RowRole =
            group.appPath.map { .app(appPath: $0, main: main.identity, mainPath: main.path) }
            ?? .standalone(identity: main.identity, path: main.path)
        return (role, actions.availability(pid: main.identity.pid, uid: main.uid, path: main.path))
    }

    // MARK: Actions

    /// Quit from the row, behind the guard (PROC-05, PROC-07). See `ProcessActionController`.
    func quit(_ rowID: String) { actions.quit(rowID) }

    /// Opens the inline Force Quit confirmation on a row, from its context menu or from the
    /// Force Quit… offer (PROC-07, D-17).
    func requestForceQuit(_ rowID: String) { actions.requestForceQuit(rowID) }

    /// The user clicked Force Quit in the confirmation (PROC-06, D-16).
    func confirmForceQuit(_ rowID: String) { actions.confirmForceQuit(rowID) }

    /// Cancel in the confirmation of this row.
    func cancelForceQuit(_ rowID: String) { actions.cancelForceQuit(rowID) }

    /// Esc: cancels the open confirmation and returns true, or returns false when none is open, so
    /// the next Esc closes the panel (D-14, RESEARCH Pitfall 9).
    @discardableResult
    func cancelConfirmation() -> Bool { actions.cancelConfirmation() }

    private static func helperID(of sample: ProcessSample) -> String {
        ProcessNaming.helperID(of: sample)
    }

    private func helperRow(for sample: ProcessSample, appName: String) -> HelperRowData {
        let name = naming.helperName(of: sample, appName: appName)
        let pid = Int(sample.identity.pid)
        let id = Self.helperID(of: sample)
        let offered = actions.availability(pid: sample.identity.pid, uid: sample.uid, path: sample.path)
        actions.setRole(.helper(identity: sample.identity, path: sample.path), availability: offered, for: id)
        return HelperRowData(
            id: id,
            name: name,
            help: String(localized: "\(name) · PID \(pid)"),
            cpuPercent: sample.cpuPercent,
            footprintBytes: sample.footprintBytes,
            availability: offered,
            actionState: actions.state(for: id))
    }
}
