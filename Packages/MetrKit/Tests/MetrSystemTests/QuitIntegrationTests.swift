import Darwin
import Foundation
import MetrCore
import Synchronization
import Testing

@testable import MetrSystem

/// The force-quit matrix on real processes (PROC-05, PROC-07; T-02-25 to T-02-28, T-02-31).
///
/// Real signals go only to `/bin/sleep` children that each test spawned and holds a `Process`
/// handle for. Every live system pid (launchd, WindowServer, loginwindow, this test process, a
/// root daemon, a service account) goes through the real lookup with a RECORDING send, so a
/// wrongly allowed action shows up as a recorded call instead of a signal to the developer's Mac.

private final class Recorder: Sendable {
    private let calls = Mutex<[(pid: Int32, signal: Int32)]>([])

    var recorded: [(pid: Int32, signal: Int32)] { calls.withLock { $0 } }

    var send: @Sendable (Int32, Int32) -> Bool {
        { [self] pid, signal in
            calls.withLock { $0.append((pid, signal)) }
            return true
        }
    }
}

private func spawnSleep() throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["60"]
    try process.run()
    return process
}

/// True when `process` ended within `seconds`.
private func ended(_ process: Process, within seconds: Double) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while process.isRunning {
        if Date() > deadline { return false }
        Thread.sleep(forTimeInterval: 0.02)
    }
    return true
}

/// The real lookup and probe with a recording send.
private func recordingGuard(_ recorder: Recorder) -> ActionGuard {
    ActionGuard(
        selfPID: getpid(), selfUID: getuid(),
        lookup: { ProcessLookup.live($0) },
        canSignal: { ProcessLookup.canSignal($0) },
        send: recorder.send)
}

/// Executes a signal route the way the coordinator does for a standalone or helper row.
@discardableResult
private func execute(_ route: ActionRoute?, with guardian: ActionGuard) -> Bool {
    guard case .signal(let signal, let identity, let path)? = route else { return false }
    return guardian.perform(signal, on: identity, expectedPath: path)
}

@Suite("QuitIntegration")
struct QuitIntegrationTests {
    @Test("the named signal numbers are Darwin's")
    func signalConstantsMatchDarwin() {
        #expect(ActionRoutes.sigterm == SIGTERM)
        #expect(ActionRoutes.sigkill == SIGKILL)
    }

    @Test("the live lookup describes a real child")
    func liveLookupDescribesAChild() throws {
        let child = try spawnSleep()
        defer { child.terminate() }
        let live = try #require(ProcessLookup.live(child.processIdentifier))
        #expect(live.identity.pid == child.processIdentifier)
        let nowMicros = Int64(Date().timeIntervalSince1970 * 1_000_000)
        #expect(abs(nowMicros - live.identity.startMicros) < 5_000_000)
        #expect(live.uid == getuid())
        #expect(live.path == "/bin/sleep")
        #expect(ActionGuard.system().availability(pid: live.identity.pid, uid: live.uid, path: live.path) == .allowed)
        #expect(ProcessLookup.live(0x7FFF_FFF0) == nil)
    }

    @Test("a stale identity signals nothing and the child stays alive")
    func staleIdentityLeavesTheChildAlive() throws {
        let child = try spawnSleep()
        defer { child.terminate() }
        let live = try #require(ProcessLookup.live(child.processIdentifier))
        let stale = ProcessIdentity(pid: live.identity.pid, startMicros: live.identity.startMicros + 1)
        #expect(ActionGuard.system().perform(ActionRoutes.sigterm, on: stale, expectedPath: "/bin/sleep") == false)
        #expect(!ended(child, within: 0.3))
        #expect(child.isRunning)
    }

    @Test("the standalone quit route ends an own process with SIGTERM")
    func standaloneQuitRouteTerminatesTheChild() throws {
        let child = try spawnSleep()
        defer { child.terminate() }
        let live = try #require(ProcessLookup.live(child.processIdentifier))
        let route = ActionRoutes.route(for: .standalone(identity: live.identity, path: "/bin/sleep"), op: .quit)
        #expect(execute(route, with: .system()) == true)
        #expect(ended(child, within: 1))
        #expect(child.terminationReason == .uncaughtSignal)
        #expect(child.terminationStatus == SIGTERM)
    }

    @Test("a helper can only be force quit, with SIGKILL, and a stale helper is left alone")
    func helperForceQuitRoute() throws {
        #expect(
            ActionRoutes.route(for: .helper(identity: ProcessIdentity(pid: 2, startMicros: 2), path: nil), op: .quit)
                == nil)

        let child = try spawnSleep()
        let spare = try spawnSleep()
        defer {
            child.terminate()
            spare.terminate()
        }
        let live = try #require(ProcessLookup.live(child.processIdentifier))
        let route = ActionRoutes.route(for: .helper(identity: live.identity, path: "/bin/sleep"), op: .forceQuit)
        #expect(execute(route, with: .system()) == true)
        #expect(ended(child, within: 1))
        #expect(child.terminationReason == .uncaughtSignal)
        #expect(child.terminationStatus == SIGKILL)

        let spareLive = try #require(ProcessLookup.live(spare.processIdentifier))
        let staleIdentity = ProcessIdentity(pid: spareLive.identity.pid, startMicros: spareLive.identity.startMicros + 1)
        let staleRoute = ActionRoutes.route(for: .helper(identity: staleIdentity, path: "/bin/sleep"), op: .forceQuit)
        #expect(execute(staleRoute, with: .system()) == false)
        #expect(!ended(spare, within: 0.3))
    }

    @Test("a child that already exited is a no-op")
    func exitedChildIsANoOp() throws {
        let child = try spawnSleep()
        let live = try #require(ProcessLookup.live(child.processIdentifier))
        child.terminate()
        child.waitUntilExit()
        #expect(ActionGuard.system().perform(ActionRoutes.sigterm, on: live.identity, expectedPath: "/bin/sleep") == false)
        #expect(!ActionGuard.system().isAlive(live.identity))
    }

    @Test("launchd, WindowServer, loginwindow and Metr itself receive no signal")
    func protectedProcessesRecordNoSend() throws {
        let sources = ProcessSources.live
        let entries = try #require(sources.listAll())
        func pid(ofPath path: String) -> Int32? {
            entries.first { sources.path($0.identity.pid) == path }?.identity.pid
        }
        let windowServerPID = try #require(
            pid(ofPath: "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer"))
        let loginwindowPID = try #require(
            pid(ofPath: "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow"))

        let recorder = Recorder()
        let guardian = recordingGuard(recorder)
        for target in [1, windowServerPID, loginwindowPID, getpid()] {
            let live = try #require(ProcessLookup.live(target))
            #expect(guardian.perform(ActionRoutes.sigterm, on: live.identity, expectedPath: live.path) == false)
            #expect(guardian.perform(ActionRoutes.sigkill, on: live.identity, expectedPath: nil) == false)
            #expect(guardian.availability(pid: target, uid: live.uid, path: live.path) != .allowed)
        }
        #expect(recorder.recorded.isEmpty)
        // WindowServer belongs to a service account, so the kernel itself refuses it.
        #expect(ProcessLookup.canSignal(windowServerPID) == false)
        #expect(ProcessLookup.canSignal(1) == false)
    }

    @Test("a real root daemon is view-only and receives no signal")
    func rootDaemonRecordsNoSend() throws {
        let sources = ProcessSources.live
        let entries = try #require(sources.listAll())
        let daemon = try #require(
            entries.first {
                // The sampler tests start top and ps children in parallel. Both are setuid root but keep
                // the user's real uid, so they are signalable and are not daemons. A real daemon is a
                // child of launchd (ppid 1), which no short-lived helper of the tests ever is.
                $0.uid == 0 && $0.identity.pid > 1 && $0.ppid == 1 && $0.command != "top" && $0.command != "ps"
                    && !(sources.path($0.identity.pid).map { ProcessClassifier.protectedPaths.contains($0) } ?? false)
                    && ProcessLookup.live($0.identity.pid) != nil
            })
        print("quit-matrix root daemon pid=\(daemon.identity.pid) uid=\(daemon.uid)")
        let live = try #require(ProcessLookup.live(daemon.identity.pid))

        let recorder = Recorder()
        let guardian = recordingGuard(recorder)
        #expect(guardian.availability(pid: live.identity.pid, uid: live.uid, path: live.path) == .disabled(.systemProcess))
        #expect(ProcessLookup.canSignal(live.identity.pid) == false)
        #expect(guardian.perform(ActionRoutes.sigterm, on: live.identity, expectedPath: live.path) == false)
        #expect(recorder.recorded.isEmpty)
    }

    @Test("a real service account process is view-only and receives no signal")
    func serviceAccountRecordsNoSend() throws {
        let sources = ProcessSources.live
        let entries = try #require(sources.listAll())
        let service = try #require(
            entries.first {
                (1..<500).contains($0.uid)
                    && !(sources.path($0.identity.pid).map { ProcessClassifier.protectedPaths.contains($0) } ?? false)
                    && ProcessLookup.live($0.identity.pid) != nil
            })
        print("quit-matrix service account pid=\(service.identity.pid) uid=\(service.uid)")
        let live = try #require(ProcessLookup.live(service.identity.pid))

        let recorder = Recorder()
        let guardian = recordingGuard(recorder)
        #expect(guardian.availability(pid: live.identity.pid, uid: live.uid, path: live.path) == .disabled(.systemProcess))
        #expect(ProcessLookup.canSignal(live.identity.pid) == false)
        #expect(guardian.perform(ActionRoutes.sigterm, on: live.identity, expectedPath: live.path) == false)
        #expect(recorder.recorded.isEmpty)
    }
}
