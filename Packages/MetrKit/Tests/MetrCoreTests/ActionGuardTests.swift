import Synchronization
import Testing

@testable import MetrCore

/// A recording `send`: remembers every (pid, signal) it was asked to deliver and returns a fixed result.
private final class Recorder: Sendable {
    private let calls = Mutex<[(pid: Int32, signal: Int32)]>([])
    let result: Bool

    init(result: Bool = true) { self.result = result }

    var recorded: [(pid: Int32, signal: Int32)] { calls.withLock { $0 } }

    var send: @Sendable (Int32, Int32) -> Bool {
        { [self] pid, signal in
            calls.withLock { $0.append((pid, signal)) }
            return result
        }
    }
}

private let appPath = "/Applications/Foo.app"
private let mainExecutable = "/Applications/Foo.app/Contents/MacOS/Foo"
private let windowServer = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer"
private let loginwindow = "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow"

private func makeGuard(
    live: LiveProcess? = nil, canSignal: Bool = true, recorder: Recorder = Recorder()
) -> ActionGuard {
    ActionGuard(
        selfPID: 400, selfUID: 501,
        lookup: { _ in live },
        canSignal: { _ in canSignal },
        send: recorder.send)
}

@Suite("ActionGuard")
struct ActionGuardTests {
    @Test("availability follows the classifier, then the signal-0 probe")
    func availabilityMatrix() {
        let guardian = makeGuard()
        #expect(guardian.availability(pid: 400, uid: 501, path: mainExecutable) == .disabled(.thisIsMetr))
        #expect(guardian.availability(pid: 1, uid: 0, path: "/sbin/launchd") == .disabled(.systemProcess))
        #expect(guardian.availability(pid: 0, uid: 0, path: nil) == .disabled(.systemProcess))
        #expect(guardian.availability(pid: 397, uid: 88, path: windowServer) == .disabled(.systemProcess))
        #expect(guardian.availability(pid: 398, uid: 501, path: loginwindow) == .disabled(.systemProcess))
        #expect(guardian.availability(pid: 500, uid: 0, path: mainExecutable) == .disabled(.systemProcess))
        #expect(guardian.availability(pid: 501, uid: 502, path: mainExecutable) == .disabled(.otherUser))

        let cannot = makeGuard(canSignal: false)
        #expect(cannot.availability(pid: 500, uid: 501, path: mainExecutable) == .disabled(.cannotSignal))
        let can = makeGuard(canSignal: true)
        #expect(can.availability(pid: 500, uid: 501, path: mainExecutable) == .allowed)
    }

    @Test("a signal is sent only after the identity was re-read and matched")
    func performRequiresAFreshIdentity() {
        let identity = ProcessIdentity(pid: 500, startMicros: 1_000)
        let live = LiveProcess(identity: identity, uid: 501, path: mainExecutable)

        // A reused pid: same pid, another start time.
        let reused = Recorder()
        let reusedLive = LiveProcess(
            identity: ProcessIdentity(pid: 500, startMicros: 1_001), uid: 501, path: mainExecutable)
        #expect(
            makeGuard(live: reusedLive, recorder: reused)
                .perform(15, on: identity, expectedPath: mainExecutable) == false)
        #expect(reused.recorded.isEmpty)

        // Gone.
        let gone = Recorder()
        #expect(makeGuard(live: nil, recorder: gone).perform(15, on: identity, expectedPath: mainExecutable) == false)
        #expect(gone.recorded.isEmpty)

        // Another executable now lives under that identity.
        let moved = Recorder()
        let movedLive = LiveProcess(identity: identity, uid: 501, path: "/Applications/Bar.app/Contents/MacOS/Bar")
        #expect(
            makeGuard(live: movedLive, recorder: moved)
                .perform(15, on: identity, expectedPath: mainExecutable) == false)
        #expect(moved.recorded.isEmpty)

        // The same process, but its uid is now root.
        let root = Recorder()
        let rootLive = LiveProcess(identity: identity, uid: 0, path: mainExecutable)
        #expect(
            makeGuard(live: rootLive, recorder: root).perform(15, on: identity, expectedPath: mainExecutable) == false)
        #expect(root.recorded.isEmpty)

        // The match: exactly one send, with the requested signal, and its result comes back.
        let ok = Recorder(result: true)
        #expect(makeGuard(live: live, recorder: ok).perform(9, on: identity, expectedPath: mainExecutable) == true)
        #expect(ok.recorded.count == 1)
        #expect(ok.recorded.first?.pid == 500)
        #expect(ok.recorded.first?.signal == 9)

        let failing = Recorder(result: false)
        #expect(makeGuard(live: live, recorder: failing).perform(15, on: identity, expectedPath: mainExecutable) == false)
        #expect(failing.recorded.count == 1)
    }

    @Test("isAlive is the identity re-read")
    func aliveIsTheIdentity() {
        let identity = ProcessIdentity(pid: 500, startMicros: 1_000)
        let live = LiveProcess(identity: identity, uid: 501, path: nil)
        #expect(makeGuard(live: live).isAlive(identity))
        #expect(!makeGuard(live: nil).isAlive(identity))
        #expect(!makeGuard(live: LiveProcess(identity: ProcessIdentity(pid: 500, startMicros: 2), uid: 501, path: nil)).isAlive(identity))
    }

    @Test("rows map to their route: helpers can only be force quit")
    func routesFollowRoleAndOperation() {
        let main = ProcessIdentity(pid: 500, startMicros: 1)
        let helper = ProcessIdentity(pid: 501, startMicros: 2)
        let solo = ProcessIdentity(pid: 502, startMicros: 3)

        let app = RowRole.app(appPath: appPath, main: main, mainPath: mainExecutable)
        #expect(
            ActionRoutes.route(for: app, op: .quit)
                == .terminateApp(appPath: appPath, main: main, mainPath: mainExecutable, force: false))
        #expect(
            ActionRoutes.route(for: app, op: .forceQuit)
                == .terminateApp(appPath: appPath, main: main, mainPath: mainExecutable, force: true))

        let helperRole = RowRole.helper(identity: helper, path: "/x/Helper")
        #expect(ActionRoutes.route(for: helperRole, op: .quit) == nil)
        #expect(ActionRoutes.route(for: helperRole, op: .forceQuit) == .signal(ActionRoutes.sigkill, helper, "/x/Helper"))

        let standalone = RowRole.standalone(identity: solo, path: "/usr/bin/yes")
        #expect(ActionRoutes.route(for: standalone, op: .quit) == .signal(ActionRoutes.sigterm, solo, "/usr/bin/yes"))
        #expect(ActionRoutes.route(for: standalone, op: .forceQuit) == .signal(ActionRoutes.sigkill, solo, "/usr/bin/yes"))
    }

    @Test("a row goes quitting, then back to rest or to did-not-quit")
    func rowStateMachine() {
        typealias S = RowActionState
        #expect(RowActions.quitTimeout == 4.0)
        #expect(RowActions.reduce(.rest, .quitSent(at: 0)) == .quitting(startedAt: 0))
        #expect(RowActions.reduce(.quitting(startedAt: 0), .tick(now: 3.9)) == .quitting(startedAt: 0))
        #expect(RowActions.reduce(.quitting(startedAt: 0), .tick(now: 4.0)) == .didNotQuit)
        #expect(RowActions.reduce(.quitting(startedAt: 0), .exited) == .rest)

        #expect(RowActions.reduce(.rest, .forceQuitRequested) == .confirming)
        #expect(RowActions.reduce(.didNotQuit, .forceQuitRequested) == .confirming)
        #expect(RowActions.reduce(.confirming, .confirmCancelled) == .rest)
        #expect(RowActions.reduce(.confirming, .forceQuitSent(at: 10)) == .forceQuitting(startedAt: 10))
        #expect(RowActions.reduce(.forceQuitting(startedAt: 10), .tick(now: 14)) == .didNotQuit)
        #expect(RowActions.reduce(.forceQuitting(startedAt: 10), .tick(now: 13)) == .forceQuitting(startedAt: 10))

        let all: [S] = [.rest, .quitting(startedAt: 0), .didNotQuit, .confirming, .forceQuitting(startedAt: 0)]
        for state in all { #expect(RowActions.reduce(state, .actionRejected) == .rest) }

        #expect(RowActions.holdsOrder(.rest) == false)
        #expect(RowActions.holdsOrder(.didNotQuit) == false)
        #expect(RowActions.holdsOrder(.quitting(startedAt: 0)))
        #expect(RowActions.holdsOrder(.confirming))
        #expect(RowActions.holdsOrder(.forceQuitting(startedAt: 0)))
    }
}
