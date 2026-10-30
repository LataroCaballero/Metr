import AppKit
import MetrCore
import MetrSystem

/// Executes an `ActionRoute` on the main actor, always behind `ActionGuard` (PROC-05, PROC-07).
///
/// For an app row the app is asked to terminate through `NSRunningApplication`, but only after the
/// main process was re-read from the kernel and matched (pid, start time, path, may-act rules) and
/// the running application's bundle path equals the group's app path (T-02-25, T-02-28). A standalone
/// process, and an app with no matching `NSRunningApplication`, gets a signal through
/// `ActionGuard.perform`, which re-verifies again. A refusal is a silent `false`.
@MainActor
final class QuitCoordinator {
    private let guardian: ActionGuard

    init(guardian: ActionGuard = .system()) {
        self.guardian = guardian
    }

    /// True when a terminate request or a signal was delivered.
    func execute(_ route: ActionRoute) -> Bool {
        switch route {
        case .terminateApp(let appPath, let main, let mainPath, let force):
            let sent = terminateApp(appPath: appPath, main: main, mainPath: mainPath, force: force)
            log(op: force ? "forceQuit" : "quit", sent: sent, pid: main.pid)
            return sent
        case .signal(let signal, let identity, let path):
            let sent = guardian.perform(signal, on: identity, expectedPath: path)
            log(op: signal == ActionRoutes.sigkill ? "forceQuit" : "quit", sent: sent, pid: identity.pid)
            return sent
        }
    }

    func isAlive(_ identity: ProcessIdentity) -> Bool {
        guardian.isAlive(identity)
    }

    private func terminateApp(appPath: String, main: ProcessIdentity, mainPath: String?, force: Bool) -> Bool {
        guard guardian.verifiedTarget(main, expectedPath: mainPath) != nil else { return false }
        let expected = URL(fileURLWithPath: appPath).standardizedFileURL.path
        if let app = NSRunningApplication(processIdentifier: main.pid),
            app.bundleURL?.standardizedFileURL.path == expected
        {
            if force { return app.forceTerminate() }
            return app.terminate()
        }
        // No matching running application (an agent or a bundle without a regular app record):
        // fall back to a signal on the same verified identity.
        let signal = force ? ActionRoutes.sigkill : ActionRoutes.sigterm
        return guardian.perform(signal, on: main, expectedPath: mainPath)
    }

    /// DEBUG only: pid and outcome, never names or paths (T-02-30).
    private func log(op: String, sent: Bool, pid: Int32) {
        #if DEBUG
        DebugHooks.log("action op=\(op) outcome=\(sent ? "sent" : "stale") pid=\(pid)")
        #endif
    }
}
