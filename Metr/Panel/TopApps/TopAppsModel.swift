import AppKit
import MetrCore
import Observation
import UniformTypeIdentifiers

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
    /// Bound of the name and icon caches. On overflow they are dropped whole (T-02-12).
    static let cacheLimit = 64

    /// The group that is open, if any. Opening one closes the other (D-08).
    private(set) var expandedGroupID: String?

    /// Groups of the newest reading, computed once per snapshot sequence on the MainActor
    /// (about 600 paths, a few ms every 2 s, only while the panel is open).
    @ObservationIgnored private var grouped: (sequence: UInt64, groups: [ProcessGroup])?
    @ObservationIgnored private var nameCache: [String: String] = [:]
    @ObservationIgnored private var iconCache: [String: NSImage] = [:]

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

    /// What each visible row stands for, by row id, for the actions (D-16).
    @ObservationIgnored private var roles: [String: RowRole] = [:]
    /// The availability each visible row was built with, by row id (app, standalone and helper rows).
    @ObservationIgnored private var availabilities: [String: ActionAvailability] = [:]
    /// The helper ids on screen in the newest build, so their action state outlives a re-render.
    @ObservationIgnored private var shownHelperIDs: Set<String> = []
    /// What the user was asked to confirm, by row id: the role as it was when the confirmation
    /// opened. If the app has restarted since, the identity no longer matches and nothing is sent.
    @ObservationIgnored private var confirmedRoles: [String: RowRole] = [:]
    @ObservationIgnored private let guardian = ActionGuard.system()
    @ObservationIgnored private let coordinator = QuitCoordinator()

    /// Each row's action state, by row id. Observed: the row views dim and restore from it. A row
    /// with no entry is at rest.
    private(set) var actionStates: [String: RowActionState] = [:]
    /// Rows whose process was seen to exit after Quit: hidden at once, before the next reading.
    @ObservationIgnored private var exitedIDs: Set<String> = []
    /// One exit poll per quitting row, only while the row is Quitting or Force-quitting.
    @ObservationIgnored private var pollTasks: [String: Task<Void, Never>] = [:]

    /// One monotonic clock for all action timing.
    private static var now: Double { ProcessInfo.processInfo.systemUptime }

    private struct MemoKey: Equatable {
        var sequence: UInt64
        var sort: SortColumn
        var frozen: Bool
        var expanded: String?
        var actions: [String: RowActionState]
        var exited: Set<String>
    }

    init() {}

    /// The view reports the pointer entering or leaving the list rows.
    func setPointerInList(_ inside: Bool) {
        if isPointerInList != inside { isPointerInList = inside }
    }

    /// Releases a freeze that outlived its pointer: when the pointer is outside the list's frame,
    /// the hover end was missed. A pointer resting inside the frame never releases it (D-10).
    /// Called after each process reading, so a stuck freeze lasts one tick at most.
    func runFreezeWatchdog() {
        // A confirmation open keeps the order as it is; nothing is released under it (D-14).
        guard isPointerInList, !actionStates.values.contains(.confirming), let frame = listScreenFrame else { return }
        if !frame.contains(NSEvent.mouseLocation) { isPointerInList = false }
    }

    /// Opens a group, or closes it when it is already open.
    func toggle(_ id: String) {
        // The helpers of the group on screen leave with it; their actions leave with them.
        if let helpers = previousHelpers { forgetActions(of: helpers.ids) }
        expandedGroupID = expandedGroupID == id ? nil : id
        previousHelpers = nil
    }

    /// Drops the action state, the poll and the open confirmation of these rows.
    private func forgetActions(of ids: [String]) {
        for id in ids {
            pollTasks[id]?.cancel()
            pollTasks[id] = nil
            actionStates[id] = nil
            confirmedRoles[id] = nil
        }
    }

    /// Closes the open group once it is no longer on screen (it exited, or ranks out of the list).
    func collapse(unlessVisible visible: [String]) {
        // A row that left the screen takes its action state with it.
        forgetActions(of: actionStates.keys.filter { !visible.contains($0) && !shownHelperIDs.contains($0) })
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
                actions: actionStates, exited: exitedIDs)
            if let memo, memo.key == key { return memo.display }

            let sortChanged = lastSort != nil && lastSort != sort
            let holding = actionStates.values.contains(where: RowActions.holdsOrder)
            let frozen = (isPointerInList || holding) && !sortChanged
            let effective = RankingEngine.effectiveColumn(sort, cpuReady: snapshot.cpuReady)
            let live = groups(for: snapshot)
            exitedIDs.formIntersection(live.map(\.id) + live.flatMap { $0.helpers.map(Self.helperID(of:)) })
            let byID = Dictionary(
                live.filter { !exitedIDs.contains($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let items = byID.values.map {
                RankItem(
                    id: $0.id, cpuPercent: $0.cpuPercent, footprintBytes: $0.footprintBytes,
                    name: Self.sortName(of: $0))
            }
            let ids = RankingEngine.next(
                items, column: sort, cpuReady: snapshot.cpuReady, previous: previousApps, frozen: frozen,
                limit: Self.rowLimit)
            roles.removeAll(keepingCapacity: true)
            availabilities.removeAll(keepingCapacity: true)
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
        // Reads the running apps' bundle paths only, never their icons (RESEARCH Pitfall 11).
        let regular = Set(
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap { $0.bundleURL?.path })
        let groups = ProcessGrouping.groups(from: snapshot.processes, regularAppBundlePaths: regular)
        grouped = (snapshot.sequence, groups)
        return groups
    }

    // MARK: Ranking

    /// A cheap, unsanitized name used only to break ties.
    private static func sortName(of group: ProcessGroup) -> String {
        if let appPath = group.appPath { return (appPath as NSString).lastPathComponent }
        return group.main.map(executableName(of:)) ?? group.id
    }

    /// The executable's last path component, or the kernel short name for pid 0 and path-less
    /// processes. Never the kernel name when a path exists (T-02-11).
    private static func executableName(of sample: ProcessSample) -> String {
        if sample.identity.pid != 0, let path = sample.path {
            return (path as NSString).lastPathComponent
        }
        return sample.command
    }

    // MARK: Rows

    private func row(for group: ProcessGroup, sort: SortColumn, frozen: Bool) -> TopAppRowData {
        let appName = group.appPath.map(appDisplayName(atPath:))
        let (role, availability) = actionInfo(for: group)
        roles[group.id] = role
        availabilities[group.id] = availability
        let open = expandedGroupID == group.id && !group.helpers.isEmpty
        var helpers: [HelperRowData] = []
        var more = 0
        if open {
            // The helpers use the same rules and the same freeze as the rows above them.
            let byID = Dictionary(
                group.helpers.filter { !exitedIDs.contains(Self.helperID(of: $0)) }
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
            name: appName ?? standaloneName(of: group),
            icon: icon(forAppAt: group.appPath),
            cpuPercent: group.cpuPercent,
            footprintBytes: group.footprintBytes,
            kind: ProcessClassifier.kind(of: group, selfPID: getpid(), selfUID: getuid()),
            helperCount: group.helpers.count,
            helpers: helpers,
            moreCount: more,
            availability: availability,
            actionState: actionStates[group.id] ?? .rest)
    }

    /// The role and availability of a row, from its main member only. An app group with no main
    /// process running has no role and offers nothing; a root-owned bundle is view-only (Q5).
    private func actionInfo(for group: ProcessGroup) -> (role: RowRole?, availability: ActionAvailability) {
        guard let main = group.main else { return (nil, .disabled(.cannotSignal)) }
        let role: RowRole =
            group.appPath.map { .app(appPath: $0, main: main.identity, mainPath: main.path) }
            ?? .standalone(identity: main.identity, path: main.path)
        return (role, guardian.availability(pid: main.identity.pid, uid: main.uid, path: main.path))
    }

    /// Quit from the row: the route for the row's role, executed behind the guard. A refusal is a
    /// silent no-op; the row simply leaves on the next reading (PROC-05, PROC-07).
    func quit(_ rowID: String) {
        guard let role = roles[rowID], let route = ActionRoutes.route(for: role, op: .quit) else { return }
        guard coordinator.execute(route) else {
            apply(.actionRejected, to: rowID)
            return
        }
        apply(.quitSent(at: Self.now), to: rowID)
        pollExit(of: rowID, identity: Self.identity(of: role))
    }

    /// Opens the inline Force Quit confirmation on a row, from its context menu or from the
    /// Force Quit… offer. A row that is disabled, or has no role, opens nothing (PROC-07, D-17).
    func requestForceQuit(_ rowID: String) {
        guard let role = roles[rowID], availabilities[rowID] == .allowed,
            ActionRoutes.route(for: role, op: .forceQuit) != nil
        else { return }
        // One confirmation at a time: opening another replaces the first (D-14).
        for (id, state) in actionStates where state == .confirming && id != rowID {
            apply(.confirmCancelled, to: id)
            confirmedRoles[id] = nil
        }
        guard actionStates[rowID] != .confirming else { return }
        apply(.forceQuitRequested, to: rowID)
        // A row that is already Quitting or Force-quitting does not open a confirmation.
        guard actionStates[rowID] == .confirming else { return }
        confirmedRoles[rowID] = role
        // The row leaves the confirmation by itself if its process exits meanwhile.
        pollExit(of: rowID, identity: Self.identity(of: role))
    }

    /// The user clicked Force Quit in the confirmation. The route is the one for the role that was
    /// confirmed (the app's main process only, or the helper itself), executed behind the guard,
    /// which re-reads the process first. A refusal leaves the row as it was (PROC-06, D-16).
    func confirmForceQuit(_ rowID: String) {
        guard actionStates[rowID] == .confirming, let role = confirmedRoles[rowID],
            let route = ActionRoutes.route(for: role, op: .forceQuit)
        else { return }
        confirmedRoles[rowID] = nil
        guard coordinator.execute(route) else {
            apply(.actionRejected, to: rowID)
            return
        }
        apply(.forceQuitSent(at: Self.now), to: rowID)
        pollExit(of: rowID, identity: Self.identity(of: role))
    }

    /// Cancel in the confirmation of this row.
    func cancelForceQuit(_ rowID: String) {
        guard actionStates[rowID] == .confirming else { return }
        confirmedRoles[rowID] = nil
        apply(.confirmCancelled, to: rowID)
    }

    /// Esc: cancels the open confirmation and returns true, or returns false when none is open, so
    /// the next Esc closes the panel (D-14, RESEARCH Pitfall 9).
    @discardableResult
    func cancelConfirmation() -> Bool {
        guard let id = actionStates.first(where: { $0.value == .confirming })?.key else { return false }
        cancelForceQuit(id)
        return true
    }

    private static func identity(of role: RowRole) -> ProcessIdentity {
        switch role {
        case .app(_, let main, _): return main
        case .helper(let identity, _), .standalone(let identity, _): return identity
        }
    }

    /// Feeds one event to a row's state machine. A row back at rest keeps no entry.
    private func apply(_ event: RowActionEvent, to rowID: String) {
        let next = RowActions.reduce(actionStates[rowID] ?? .rest, event)
        if next == .rest {
            if actionStates[rowID] != nil { actionStates[rowID] = nil }
        } else if actionStates[rowID] != next {
            actionStates[rowID] = next
        }
    }

    /// Polls whether the process is still alive every 0.5 s, only while the row is Quitting or
    /// Force-quitting: an exit hides the row at once, the timeout returns it to normal (D-15).
    private func pollExit(of rowID: String, identity: ProcessIdentity) {
        pollTasks[rowID]?.cancel()
        pollTasks[rowID] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled else { return }
                if !self.coordinator.isAlive(identity) {
                    self.exitedIDs.insert(rowID)
                    self.apply(.exited, to: rowID)
                    self.pollTasks[rowID] = nil
                    return
                }
                self.apply(.tick(now: Self.now), to: rowID)
                if !RowActions.holdsOrder(self.actionStates[rowID] ?? .rest) {
                    self.pollTasks[rowID] = nil
                    return
                }
            }
        }
    }

    private static func helperID(of sample: ProcessSample) -> String {
        "pid:\(sample.identity.pid):\(sample.identity.startMicros)"
    }

    private func helperRow(for sample: ProcessSample, appName: String) -> HelperRowData {
        let raw = Self.executableName(of: sample)
        var name = ProcessText.sanitize(ProcessGrouping.helperName(executableName: raw, appName: appName))
        if name.isEmpty { name = "—" }
        let pid = Int(sample.identity.pid)
        let id = Self.helperID(of: sample)
        roles[id] = .helper(identity: sample.identity, path: sample.path)
        let availability = guardian.availability(pid: sample.identity.pid, uid: sample.uid, path: sample.path)
        availabilities[id] = availability
        return HelperRowData(
            id: id,
            name: name,
            help: String(localized: "\(name) · PID \(pid)"),
            cpuPercent: sample.cpuPercent,
            footprintBytes: sample.footprintBytes,
            availability: availability,
            actionState: actionStates[id] ?? .rest)
    }

    /// The Finder name of an app bundle, `.app` stripped, sanitized, cached by path.
    private func appDisplayName(atPath path: String) -> String {
        if let cached = nameCache[path] { return cached }
        var name = FileManager.default.displayName(atPath: path)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        var text = ProcessText.sanitize(name)
        if text.isEmpty { text = "—" }
        remember(name: text, forKey: path)
        return text
    }

    /// A standalone process: the executable name, or the kernel name for pid 0 and path-less ones.
    private func standaloneName(of group: ProcessGroup) -> String {
        guard let sample = group.main else { return "—" }
        let key = sample.path.map { "exe:" + $0 } ?? "cmd:" + sample.command
        if let cached = nameCache[key] { return cached }
        var text = ProcessText.sanitize(Self.executableName(of: sample))
        if text.isEmpty { text = ProcessText.sanitize(sample.command) }
        if text.isEmpty { text = "—" }
        remember(name: text, forKey: key)
        return text
    }

    private func remember(name: String, forKey key: String) {
        if nameCache.count >= Self.cacheLimit { nameCache.removeAll() }
        nameCache[key] = name
    }

    private func icon(forAppAt appPath: String?) -> NSImage {
        let key = appPath ?? "unixExecutable"
        if let cached = iconCache[key] { return cached }
        let image =
            appPath.map { NSWorkspace.shared.icon(forFile: $0) }
            ?? NSWorkspace.shared.icon(for: .unixExecutable)
        if iconCache.count >= Self.cacheLimit { iconCache.removeAll() }
        iconCache[key] = image
        return image
    }
}
