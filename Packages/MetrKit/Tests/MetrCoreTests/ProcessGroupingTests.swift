import Testing

@testable import MetrCore

@Suite struct ProcessGroupingTests {
    // MARK: Text and paths (Task 1)

    @Test func outermostBundle() {
        let brave =
            "/Applications/Brave Browser.app/Contents/Frameworks/Brave Browser Framework.framework"
            + "/Versions/1/Helpers/Brave Browser Helper (Renderer).app/Contents/MacOS/Brave Browser Helper (Renderer)"
        #expect(ProcessPaths.outermostAppBundle(of: brave) == "/Applications/Brave Browser.app")
        #expect(ProcessPaths.outermostAppBundle(of: "/usr/libexec/trustd") == nil)
        #expect(ProcessPaths.outermostAppBundle(of: "/Users/x/my.application/bin/tool") == nil)
        // A bundle path with nothing after it is not an executable inside a bundle.
        #expect(ProcessPaths.outermostAppBundle(of: "/Applications/Foo.app") == nil)
    }

    @Test func sanitize() {
        // C0, C1 and bidi controls go; ordinary text stays.
        #expect(ProcessText.sanitize("Safe\u{0007}Name\u{0085}") == "SafeName")
        #expect(ProcessText.sanitize("a\u{202E}b\u{2066}c\u{2069}d") == "abcd")
        #expect(ProcessText.sanitize("  padded name \n") == "padded name")
        let long = String(repeating: "x", count: 300)
        #expect(ProcessText.sanitize(long).count == 128)
        #expect(ProcessText.sanitize(long, limit: 10).count == 10)
        #expect(ProcessText.sanitize("Café — 日本語") == "Café — 日本語")
    }

    // MARK: Grouping (Task 2)

    private func sample(
        _ pid: Int32, path: String?, command: String = "proc", uid: UInt32 = 501,
        cpu: Double? = nil, footprint: UInt64? = nil
    ) -> ProcessSample {
        ProcessSample(
            identity: ProcessIdentity(pid: pid, startMicros: Int64(pid) * 1_000),
            ppid: 1, uid: uid, path: path, command: command, cpuPercent: cpu, footprintBytes: footprint)
    }

    @Test func braveRollsIntoOneGroup() {
        let app = "/Applications/Brave Browser.app"
        let helperDir = app + "/Contents/Frameworks/Brave Browser Framework.framework/Versions/1/Helpers"
        var samples = [sample(100, path: app + "/Contents/MacOS/Brave Browser", cpu: 10, footprint: 1_000)]
        for i in 0..<10 {
            samples.append(
                sample(
                    200 + Int32(i),
                    path: helperDir + "/Brave Browser Helper (Renderer).app/Contents/MacOS/Brave Browser Helper (Renderer)",
                    cpu: 2, footprint: 100))
        }
        for i in 0..<5 {
            samples.append(
                sample(
                    300 + Int32(i),
                    path: helperDir + "/Brave Browser Helper.app/Contents/MacOS/Brave Browser Helper",
                    cpu: nil, footprint: 50))
        }
        samples.append(sample(400, path: app + "/Contents/Frameworks/x/chrome_crashpad_handler", cpu: 1, footprint: 10))
        let groups = ProcessGrouping.groups(from: samples, regularAppBundlePaths: [])
        #expect(groups.count == 1)
        let group = groups[0]
        #expect(group.id == app)
        #expect(group.appPath == app)
        #expect(group.main?.identity.pid == 100)
        #expect(group.helpers.count == 16)
        // 10 + 10 x 2 + 1 = 31; the five nil-CPU helpers do not blank the sum.
        #expect(group.cpuPercent == 31)
        #expect(group.footprintBytes == 1_000 + 1_000 + 250 + 10)
    }

    @Test func standaloneAndPathless() {
        let trustd = (0..<4).map { sample(500 + Int32($0), path: "/usr/libexec/trustd", command: "trustd") }
        let kernel = sample(0, path: nil, command: "kernel_task")
        let groups = ProcessGrouping.groups(from: trustd + [kernel], regularAppBundlePaths: [])
        #expect(groups.count == 5)
        for group in groups {
            #expect(group.main != nil)
            #expect(group.helpers.isEmpty)
            #expect(group.appPath == nil)
        }
        let ids = Set(groups.map(\.id))
        #expect(ids.count == 5)
        #expect(ids.contains("pid:500:\(500 * 1_000)"))
        #expect(ids.contains("pid:0:0"))
    }

    @Test func nestedRegularAppGetsItsOwnGroup() {
        let xcode = "/Applications/Xcode.app"
        let simulator = xcode + "/Contents/Developer/Applications/Simulator.app"
        let samples = [
            sample(10, path: xcode + "/Contents/MacOS/Xcode"),
            sample(11, path: simulator + "/Contents/MacOS/Simulator"),
        ]
        let own = ProcessGrouping.groups(from: samples, regularAppBundlePaths: [simulator])
        #expect(Set(own.map(\.id)) == [xcode, simulator])
        let rolled = ProcessGrouping.groups(from: samples, regularAppBundlePaths: [])
        #expect(rolled.map(\.id) == [xcode])
        #expect(rolled[0].main?.identity.pid == 10)
        #expect(rolled[0].helpers.map(\.identity.pid) == [11])
    }

    @Test func rootOwnedAppBundleGroupsLikeUserApps() {
        let app = "/Library/Application Support/Vendor/Agent.app"
        let samples = [
            sample(60, path: app + "/Contents/MacOS/Agent", uid: 0),
            sample(61, path: app + "/Contents/Helpers/Agent Helper.app/Contents/MacOS/Agent Helper", uid: 0),
            sample(62, path: app + "/Contents/Helpers/Agent Helper.app/Contents/MacOS/Agent Helper", uid: 0),
        ]
        let groups = ProcessGrouping.groups(from: samples, regularAppBundlePaths: [])
        #expect(groups.count == 1)
        #expect(groups[0].main?.identity.pid == 60)
        #expect(groups[0].helpers.count == 2)
    }

    @Test func helperNames() {
        #expect(ProcessGrouping.helperName(executableName: "Google Chrome Helper (Renderer)", appName: "Google Chrome") == "Renderer")
        #expect(ProcessGrouping.helperName(executableName: "Google Chrome Helper (GPU)", appName: "Google Chrome") == "GPU Process")
        #expect(ProcessGrouping.helperName(executableName: "Google Chrome Helper", appName: "Google Chrome") == "Helper")
        #expect(ProcessGrouping.helperName(executableName: "Brave Browser Helper (Plugin)", appName: "Brave Browser") == "Plugin")
        #expect(ProcessGrouping.helperName(executableName: "chrome_crashpad_handler", appName: "Google Chrome") == "chrome_crashpad_handler")
    }

    @Test func groupCPUNilOnlyWhenNoMemberKnown() {
        let app = "/Applications/Foo.app"
        let none = [
            sample(1, path: app + "/Contents/MacOS/Foo", cpu: nil, footprint: nil),
            sample(2, path: app + "/Contents/Helpers/H", cpu: nil, footprint: nil),
        ]
        let blank = ProcessGrouping.groups(from: none, regularAppBundlePaths: [])[0]
        #expect(blank.cpuPercent == nil)
        #expect(blank.footprintBytes == nil)
        let one = [
            sample(1, path: app + "/Contents/MacOS/Foo", cpu: nil, footprint: 5),
            sample(2, path: app + "/Contents/Helpers/H", cpu: 7, footprint: nil),
        ]
        let known = ProcessGrouping.groups(from: one, regularAppBundlePaths: [])[0]
        #expect(known.cpuPercent == 7)
        #expect(known.footprintBytes == 5)
    }
}
