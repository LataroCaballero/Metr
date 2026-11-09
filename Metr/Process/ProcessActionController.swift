import AppKit
import MetrCore
import Observation

/// The one Quit / Force Quit state machine, shared by the panel's Top Apps list and the window's
/// process table (RESEARCH Pitfall 8; PROC-05, PROC-06, PROC-07; WIN-04).
///
/// It moved here from `TopAppsModel` with its behaviour unchanged. Both surfaces own an instance;
/// neither adds a signal path. Everything that signals goes through `QuitCoordinator.execute`,
/// which re-reads the process from the kernel behind `ActionGuard` (pid, start time, uid and path)
/// before anything is sent, so a stale row or a reused pid is a silent no-op.
///
/// A row is identified by its id (an app path, `pid:<pid>:<start>` for a standalone process, or a
/// helper id). The owning model registers each row's role and availability while it builds rows
/// (`setRole`); the controller never reads processes by itself.
@MainActor
@Observable
final class ProcessActionController {
    /// Each row's action state, by row id. Observed: row views dim and restore from it. A row with
    /// no entry is at rest.
    private(set) var actionStates: [String: RowActionState] = [:]

    /// What each visible row stands for, by row id, for the actions (D-16).
    @ObservationIgnored private var roles: [String: RowRole] = [:]
    /// The availability each visible row was built with, by row id (app, standalone and helper rows).
    @ObservationIgnored private var availabilities: [String: ActionAvailability] = [:]
    /// What the user was asked to confirm, by row id: the role as it was when the confirmation
    /// opened. If the app has restarted since, the identity no longer matches and nothing is sent.
    @ObservationIgnored private var confirmedRoles: [String: RowRole] = [:]
    @ObservationIgnored private let guardian = ActionGuard.system()
    @ObservationIgnored private let coordinator = QuitCoordinator()
    /// Rows whose process was seen to exit after Quit: hidden at once, before the next reading.
    @ObservationIgnored private var exitedIDs: Set<String> = []
    /// One exit poll per quitting row, only while the row is Quitting or Force-quitting.
    @ObservationIgnored private var pollTasks: [String: Task<Void, Never>] = [:]

    #if DEBUG
    /// What every row of a preset controller may do, so a fixture does not depend on whether a
    /// synthetic pid happens to exist on the machine that renders it. nil in the app.
    @ObservationIgnored private var presetAvailability: ActionAvailability?
    #endif

    /// One monotonic clock for all action timing.
    private static var now: Double { ProcessInfo.processInfo.systemUptime }

    init() {}

    #if DEBUG
    /// DEBUG only, for the snapshot renderer: puts rows into action states (Quitting, Did not quit,
    /// Confirming) without a click or a signal. Compiled out of Release.
    func preset(actionStates: [String: RowActionState], availability: ActionAvailability? = nil) {
        self.actionStates = actionStates
        presetAvailability = availability
    }
    #endif

    // MARK: Roles and availability

    /// What a process may offer, from the guard. A preset controller (DEBUG) answers with its fixed value.
    func availability(pid: Int32, uid: UInt32, path: String?) -> ActionAvailability {
        #if DEBUG
        if let presetAvailability { return presetAvailability }
        #endif
        return guardian.availability(pid: pid, uid: uid, path: path)
    }

    /// Registers what a row stands for and what it was offered, while the owner builds its rows. A
    /// nil role (an app group with no main process running) offers nothing.
    func setRole(_ role: RowRole?, availability: ActionAvailability, for id: String) {
        roles[id] = role
        availabilities[id] = availability
    }

    /// Forgets every registered role, before the owner registers the rows of a new build.
    func resetRoles() {
        roles.removeAll(keepingCapacity: true)
        availabilities.removeAll(keepingCapacity: true)
    }

    func role(for id: String) -> RowRole? { roles[id] }

    func availability(for id: String) -> ActionAvailability { availabilities[id] ?? .disabled(.cannotSignal) }

    func state(for id: String) -> RowActionState { actionStates[id] ?? .rest }

    /// Any row is in a state that keeps the list in its order while it lasts (D-10, D-15, D-16).
    var holdsOrder: Bool { actionStates.values.contains(where: RowActions.holdsOrder) }

    // MARK: Exits

    /// Whether this row's process was seen to exit after Quit and the row should already be hidden.
    func isExited(_ id: String) -> Bool { exitedIDs.contains(id) }

    /// The rows hidden at once after their process exited, for a memo key.
    var exited: Set<String> { exitedIDs }

    /// Keeps only the exited ids that are still in the newest reading, so the set cannot grow.
    func retainExited(in live: some Collection<String>) {
        exitedIDs.formIntersection(live)
    }

    // MARK: Actions

    /// Drops the action state, the poll and the open confirmation of these rows.
    func forget(_ ids: some Sequence<String>) {
        for id in ids {
            pollTasks[id]?.cancel()
            pollTasks[id] = nil
            actionStates[id] = nil
            confirmedRoles[id] = nil
        }
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

    /// Opens a Force Quit confirmation on a row and captures its role as it is now. Returns whether
    /// one opened: a row that is disabled, has no role, or is already working opens nothing
    /// (PROC-07, D-17).
    @discardableResult
    func requestForceQuit(_ rowID: String) -> Bool {
        guard let role = roles[rowID], availabilities[rowID] == .allowed,
            ActionRoutes.route(for: role, op: .forceQuit) != nil
        else { return false }
        // One confirmation at a time: opening another replaces the first (D-14).
        for (id, state) in actionStates where state == .confirming && id != rowID {
            apply(.confirmCancelled, to: id)
            confirmedRoles[id] = nil
        }
        guard actionStates[rowID] != .confirming else { return false }
        apply(.forceQuitRequested, to: rowID)
        // A row that is already Quitting or Force-quitting does not open a confirmation.
        guard actionStates[rowID] == .confirming else { return false }
        confirmedRoles[rowID] = role
        // The row leaves the confirmation by itself if its process exits meanwhile.
        pollExit(of: rowID, identity: Self.identity(of: role))
        return true
    }

    /// The user confirmed the Force Quit. The route is the one for the role that was confirmed (the
    /// app's main process only, or the helper itself), executed behind the guard, which re-reads
    /// the process first. A refusal leaves the row as it was (PROC-06, D-16).
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
}
