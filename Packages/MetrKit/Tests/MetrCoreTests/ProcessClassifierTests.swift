import Testing

@testable import MetrCore

@Suite struct ProcessClassifierTests {
    private let selfPID: Int32 = 4_242
    private let selfUID: UInt32 = 501

    private func kind(_ pid: Int32, uid: UInt32, path: String?) -> ProcessKind {
        ProcessClassifier.kind(pid: pid, uid: uid, path: path, selfPID: selfPID, selfUID: selfUID)
    }

    @Test func matrix() {
        let windowServer = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer"
        let loginwindow = "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow"

        // Metr itself, by pid, whatever its uid or path.
        #expect(kind(selfPID, uid: 501, path: "/Applications/Metr.app/Contents/MacOS/Metr") == .metr)
        // kernel_task and launchd, by pid.
        #expect(kind(0, uid: 0, path: nil) == .system)
        #expect(kind(1, uid: 0, path: "/sbin/launchd") == .system)
        // A protected executable is system even when it runs as the user (loginwindow, uid 501).
        #expect(kind(400, uid: 88, path: windowServer) == .system)
        #expect(kind(401, uid: 501, path: loginwindow) == .system)
        // Service accounts.
        #expect(kind(500, uid: 0, path: "/usr/libexec/anything") == .system)
        #expect(kind(501, uid: 89, path: nil) == .system)
        #expect(kind(502, uid: 499, path: "/usr/sbin/x") == .system)
        // Another human account.
        #expect(kind(600, uid: 502, path: "/Applications/Safari.app/Contents/MacOS/Safari") == .otherUser)
        #expect(kind(601, uid: 500, path: nil) == .otherUser)
        // The user's own processes.
        #expect(kind(700, uid: 501, path: "/Applications/Xcode.app/Contents/MacOS/Xcode") == .own)
        #expect(kind(701, uid: 501, path: nil) == .own)
    }

    @Test func nameSpoofingDoesNotProtect() {
        // A user-space binary called WindowServer is an ordinary process: only the canonical path counts.
        #expect(kind(800, uid: 501, path: "/Users/x/WindowServer") == .own)
        #expect(kind(801, uid: 501, path: "/tmp/loginwindow.app/Contents/MacOS/loginwindow") == .own)
    }

    @Test func finderDockAndFriendsAreOrdinary() {
        // Owner decision Q4 (2026-10-30): they relaunch, as in Activity Monitor, so they are not protected.
        for path in [
            "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder",
            "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock",
            "/System/Library/CoreServices/SystemUIServer.app/Contents/MacOS/SystemUIServer",
            "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter",
        ] {
            #expect(kind(900, uid: 501, path: path) == .own)
        }
    }

    @Test func protectedPathsAreExactlyTheRoadmapList() {
        #expect(
            ProcessClassifier.protectedPaths == [
                "/sbin/launchd",
                "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer",
                "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow",
            ])
    }

    private func sample(_ pid: Int32, uid: UInt32, path: String?, command: String = "x") -> ProcessSample {
        ProcessSample(
            identity: ProcessIdentity(pid: pid, startMicros: Int64(pid)), ppid: 1, uid: uid, path: path,
            command: command, cpuPercent: 1, footprintBytes: 1_000)
    }

    @Test func groupKindFollowsMainMember() {
        let agent = "/Library/Application Support/Vendor/Agent.app"
        let rootGroup = ProcessGrouping.groups(
            from: [
                sample(30, uid: 0, path: agent + "/Contents/MacOS/Agent"),
                sample(31, uid: 0, path: agent + "/Contents/Helpers/H1"),
                sample(32, uid: 0, path: agent + "/Contents/Helpers/H2"),
            ], regularAppBundlePaths: [])
        #expect(rootGroup.count == 1)
        #expect(rootGroup[0].helpers.count == 2)
        #expect(ProcessClassifier.kind(of: rootGroup[0], selfPID: selfPID, selfUID: selfUID) == .system)

        let own = ProcessGrouping.groups(
            from: [
                sample(40, uid: 501, path: "/Applications/Foo.app/Contents/MacOS/Foo"),
                sample(41, uid: 501, path: "/Applications/Foo.app/Contents/Helpers/H"),
            ], regularAppBundlePaths: [])
        #expect(ProcessClassifier.kind(of: own[0], selfPID: selfPID, selfUID: selfUID) == .own)

        // No main member: the lowest-pid member decides.
        let helpersOnly = ProcessGrouping.groups(
            from: [
                sample(52, uid: 501, path: agent + "/Contents/Helpers/B"),
                sample(51, uid: 0, path: agent + "/Contents/Helpers/A"),
            ], regularAppBundlePaths: [])
        #expect(helpersOnly[0].main == nil)
        #expect(ProcessClassifier.kind(of: helpersOnly[0], selfPID: selfPID, selfUID: selfUID) == .system)

        // A standalone group is its single process.
        let standalone = ProcessGrouping.groups(
            from: [sample(0, uid: 0, path: nil, command: "kernel_task")], regularAppBundlePaths: [])
        #expect(ProcessClassifier.kind(of: standalone[0], selfPID: selfPID, selfUID: selfUID) == .system)
    }
}
