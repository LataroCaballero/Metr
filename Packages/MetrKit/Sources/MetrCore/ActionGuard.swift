/// A process as the kernel describes it right now: the facts an action decision may rely on.
public struct LiveProcess: Sendable, Equatable {
    public var identity: ProcessIdentity
    public var uid: UInt32
    /// The canonical executable path, nil when the kernel would not give one.
    public var path: String?

    public init(identity: ProcessIdentity, uid: UInt32, path: String?) {
        self.identity = identity
        self.uid = uid
        self.path = path
    }
}

/// Why a row offers no action (PROC-07, D-17).
public enum DisabledReason: String, Sendable, Equatable {
    /// pid 0 or 1, a protected system executable, or a service account.
    case systemProcess
    /// A process of another human user.
    case otherUser
    /// Metr itself.
    case thisIsMetr
    /// The user's own process, but the signal-0 probe says the kernel would refuse a signal.
    case cannotSignal
}

public enum ActionAvailability: Sendable, Equatable {
    case allowed
    case disabled(DisabledReason)
}

/// The only gate between a row and a signal (PROC-07, D-17; RESEARCH Pattern 6).
///
/// Everything it needs from the system is injected, so the rules are pure and testable:
/// `lookup` re-reads one pid from the kernel, `canSignal` is the signal-0 probe (the kernel's own
/// answer to "may this user signal that process", which fails with EPERM for another user's or
/// root's process), and `send` delivers a signal.
///
/// A signal is sent only when, immediately before, the pid was re-read and its identity (pid and
/// start time) and, when given, its executable path equal what the row was built from, and the
/// live uid, pid and path still classify the process as one the user may act on. A row is seconds
/// old: its process may have exited, or its pid may belong to a stranger by now. In both cases
/// the answer is silence (T-02-25, T-02-26, T-02-27).
///
/// Accepted residual risk (T-02-29): the re-read and the signal are two system calls. macOS has
/// no way to signal "this exact process" (there is no pidfd), so a pid reused between two
/// adjacent calls cannot be detected. It would need the 99,999-pid space to wrap in that window.
public struct ActionGuard: Sendable {
    public var selfPID: Int32
    public var selfUID: UInt32
    public var lookup: @Sendable (Int32) -> LiveProcess?
    public var canSignal: @Sendable (Int32) -> Bool
    public var send: @Sendable (Int32, Int32) -> Bool

    public init(
        selfPID: Int32, selfUID: UInt32,
        lookup: @escaping @Sendable (Int32) -> LiveProcess?,
        canSignal: @escaping @Sendable (Int32) -> Bool,
        send: @escaping @Sendable (Int32, Int32) -> Bool
    ) {
        self.selfPID = selfPID
        self.selfUID = selfUID
        self.lookup = lookup
        self.canSignal = canSignal
        self.send = send
    }

    /// What a row of this process may offer. Starts from `ProcessClassifier` (pid, uid and
    /// canonical path, never a name), and for the user's own processes adds the signal-0 probe,
    /// which only ever restricts further.
    public func availability(pid: Int32, uid: UInt32, path: String?) -> ActionAvailability {
        switch ProcessClassifier.kind(pid: pid, uid: uid, path: path, selfPID: selfPID, selfUID: selfUID) {
        case .metr: return .disabled(.thisIsMetr)
        case .system: return .disabled(.systemProcess)
        case .otherUser: return .disabled(.otherUser)
        case .own: return canSignal(pid) ? .allowed : .disabled(.cannotSignal)
        }
    }

    /// True while the kernel still reports this exact process (same pid and start time).
    public func isAlive(_ identity: ProcessIdentity) -> Bool {
        lookup(identity.pid)?.identity == identity
    }

    /// The live process, only when it is still the one `identity` names, still has `expectedPath`
    /// (when one is given), and may be acted on. Nil otherwise, which callers treat as a silent no-op.
    public func verifiedTarget(_ identity: ProcessIdentity, expectedPath: String?) -> LiveProcess? {
        guard let live = lookup(identity.pid), live.identity == identity else { return nil }
        if let expectedPath, live.path != expectedPath { return nil }
        guard availability(pid: live.identity.pid, uid: live.uid, path: live.path) == .allowed else { return nil }
        return live
    }

    /// Sends `signal` to the process, after `verifiedTarget` passed. Returns the result of the send,
    /// or false without sending when the identity did not verify.
    @discardableResult
    public func perform(_ signal: Int32, on identity: ProcessIdentity, expectedPath: String?) -> Bool {
        guard let target = verifiedTarget(identity, expectedPath: expectedPath) else { return false }
        return send(target.identity.pid, signal)
    }
}

/// What a row stands for, as far as an action is concerned (D-16).
public enum RowRole: Sendable, Equatable {
    /// An app group with its main process running: the app is asked to terminate.
    case app(appPath: String, main: ProcessIdentity, mainPath: String?)
    /// One helper under an open app. It can only ever be force quit (D-16).
    case helper(identity: ProcessIdentity, path: String?)
    /// A process with no app around it: it gets signals.
    case standalone(identity: ProcessIdentity, path: String?)
}

public enum ActionOp: Sendable, Equatable {
    case quit
    case forceQuit
}

/// What executing an operation on a row means.
public enum ActionRoute: Sendable, Equatable {
    /// Ask the app (`NSRunningApplication`) to terminate, or force terminate it.
    case terminateApp(appPath: String, main: ProcessIdentity, mainPath: String?, force: Bool)
    /// Send a signal to one process.
    case signal(Int32, ProcessIdentity, String?)
}

public enum ActionRoutes {
    /// Darwin's SIGTERM and SIGKILL. MetrCore does not import Darwin, so a test pins these.
    public static let sigterm: Int32 = 15
    public static let sigkill: Int32 = 9

    /// The route for one row and operation, nil when there is none: a helper has no graceful quit
    /// (D-16), so the only thing it offers is the force quit.
    public static func route(for role: RowRole, op: ActionOp) -> ActionRoute? {
        switch (role, op) {
        case (.app(let appPath, let main, let mainPath), .quit):
            return .terminateApp(appPath: appPath, main: main, mainPath: mainPath, force: false)
        case (.app(let appPath, let main, let mainPath), .forceQuit):
            return .terminateApp(appPath: appPath, main: main, mainPath: mainPath, force: true)
        case (.helper, .quit):
            return nil
        case (.helper(let identity, let path), .forceQuit):
            return .signal(sigkill, identity, path)
        case (.standalone(let identity, let path), .quit):
            return .signal(sigterm, identity, path)
        case (.standalone(let identity, let path), .forceQuit):
            return .signal(sigkill, identity, path)
        }
    }
}

/// Where a row is in its action (D-14, D-15).
public enum RowActionState: Sendable, Equatable {
    case rest
    /// Quit was sent at this monotonic time; the row waits for the process to exit.
    case quitting(startedAt: Double)
    /// The process was still alive when the wait ended; the row is back to normal.
    case didNotQuit
    /// A Force Quit confirmation is open (02-11).
    case confirming
    case forceQuitting(startedAt: Double)
}

public enum RowActionEvent: Sendable, Equatable {
    case quitSent(at: Double)
    case forceQuitRequested
    case confirmCancelled
    case forceQuitSent(at: Double)
    case exited
    case tick(now: Double)
    /// The guard refused (stale identity, protected process): nothing happened, the row is as before.
    case actionRejected
}

/// The pure state machine of one row's action (D-14, D-15). Times are monotonic seconds supplied
/// by the caller. An exit always wins: a row whose process left is simply gone on the next reading.
public enum RowActions {
    /// Seconds a row waits for the process to exit before it returns to normal (D-15 allows 3 to 5).
    public static let quitTimeout: Double = 4.0

    public static func reduce(_ state: RowActionState, _ event: RowActionEvent) -> RowActionState {
        switch (state, event) {
        case (_, .actionRejected), (_, .exited), (.confirming, .confirmCancelled):
            return .rest
        case (.rest, .quitSent(let at)), (.didNotQuit, .quitSent(let at)):
            return .quitting(startedAt: at)
        case (.rest, .forceQuitRequested), (.didNotQuit, .forceQuitRequested):
            return .confirming
        case (.confirming, .forceQuitSent(let at)):
            return .forceQuitting(startedAt: at)
        case (.quitting(let start), .tick(let now)), (.forceQuitting(let start), .tick(let now)):
            return now - start >= quitTimeout - 1e-9 ? .didNotQuit : state
        default:
            return state
        }
    }

    /// Whether the list must keep its order while a row is in this state, so the row under the
    /// pointer cannot move away (D-10).
    public static func holdsOrder(_ state: RowActionState) -> Bool {
        switch state {
        case .quitting, .confirming, .forceQuitting: return true
        case .rest, .didNotQuit: return false
        }
    }
}
