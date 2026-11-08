#if DEBUG
import AppKit
import MetrCore
import SwiftUI

/// A window that may sit outside every screen: AppKit would otherwise pull a titled window back
/// onto a display when it is ordered in.
private final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// DEBUG-only: renders the panel fixtures to PNG files and exits, so a CLI run can review the
/// layout in EN and ES, light and dark, without a click (T-01-13: writes only `panel-*.png`
/// or `welcome-*.png` inside the directory it is given, and is compiled out of Release).
/// Surfaces: the panel fixtures and the first-launch welcome window (default and fallback tip).
@MainActor
enum DebugSnapshotRenderer {
    private struct Fixture {
        let name: String
        let batch: MetricsBatch
        var thermal: ThermalLevel = .normal
        /// The Top Apps group to render open, by row id (the app bundle path).
        var expanded: String?
        /// Row action states to render, by row id (Quitting, Did not quit, Confirming).
        var actionStates: [String: RowActionState] = [:]

        /// True when the fixture needs a preset Top Apps model.
        var presetsRows: Bool { expanded != nil || !actionStates.isEmpty }
    }

    /// Row ids of the apps the new fixtures put into a state: the app bundle path (`ProcessGroup.id`).
    private static let chromeID = "/Applications/Google Chrome.app"
    private static let textEditID = "/Applications/TextEdit.app"
    private static let safariID = "/Applications/Safari.app"

    private static let totalMemory: UInt64 = 17_179_869_184

    /// True while fixtures render, so AppKit-backed helper views can step aside: `ImageRenderer`
    /// draws them as a "prohibited" badge over the content.
    static var isRendering = false

    /// One fixture per column or status-line state worth looking at (PANEL-01/02/03/05, CPU-02).
    private static var fixtures: [Fixture] {
        [
            // Quiet Mac: no swap, normal thermal state.
            Fixture(
                name: "idle",
                batch: MetricsBatch(
                    cpu: .value(
                        CPUReading(
                            total: 0.12, user: 0.08, system: 0.04,
                            clusters: [
                                CPUCluster(name: "Performance", usage: 0.10),
                                CPUCluster(name: "Efficiency", usage: 0.14),
                            ])),
                    memory: .value(
                        MemoryReading(
                            usedBytes: 12_025_908_428, totalBytes: totalMemory,
                            swapUsedBytes: 0, freePercent: 60, pressure: .normal)),
                    disk: .value(DiskReading(totalBytes: 494_000_000_000, availableBytes: 210_000_000_000)),
                    processes: columnProcesses,
                    elapsed: 1)),
            // Worst case for width: 3-digit percents, Critical sentence, swap, 7 of 245 GB free.
            // The system share carries the whole 100 % so the longest "System 100 %" row is on screen.
            Fixture(
                name: "stress",
                batch: MetricsBatch(
                    cpu: .value(
                        CPUReading(
                            total: 1.0, user: 0, system: 1.0,
                            clusters: [
                                CPUCluster(name: "Performance", usage: 1.0),
                                CPUCluster(name: "Efficiency", usage: 1.0),
                            ])),
                    memory: .value(
                        MemoryReading(
                            usedBytes: 16_500_000_000, totalBytes: totalMemory,
                            swapUsedBytes: 4_294_967_296, freePercent: 3, pressure: .critical)),
                    disk: .value(DiskReading(totalBytes: 245_000_000_000, availableBytes: 7_000_000_000)),
                    processes: columnProcesses,
                    elapsed: 1),
                thermal: .critical),
            // Elevated everywhere: memory warn with swap, disk under 10 % free, thermal Elevated.
            Fixture(
                name: "elevated",
                batch: MetricsBatch(
                    cpu: .value(
                        CPUReading(
                            total: 0.55, user: 0.40, system: 0.15,
                            clusters: [
                                CPUCluster(name: "Performance", usage: 0.60),
                                CPUCluster(name: "Efficiency", usage: 0.45),
                            ])),
                    memory: .value(
                        MemoryReading(
                            usedBytes: 13_500_000_000, totalBytes: totalMemory,
                            swapUsedBytes: 1_288_490_189, freePercent: 12, pressure: .warn)),
                    disk: .value(DiskReading(totalBytes: 494_000_000_000, availableBytes: 39_500_000_000)),
                    processes: columnProcesses,
                    elapsed: 1),
                thermal: .elevated),
            // Three core tiers, in the order the reader reports them (Super, Performance, Efficiency).
            Fixture(
                name: "threetier",
                batch: MetricsBatch(
                    cpu: .value(
                        CPUReading(
                            total: 0.30, user: 0.20, system: 0.10,
                            clusters: [
                                CPUCluster(name: "Super", usage: 0.50),
                                CPUCluster(name: "Performance", usage: 0.30),
                                CPUCluster(name: "Efficiency", usage: 0.10),
                            ])),
                    memory: .value(
                        MemoryReading(
                            usedBytes: 9_000_000_000, totalBytes: totalMemory,
                            swapUsedBytes: 0, freePercent: 45, pressure: .normal)),
                    disk: .value(DiskReading(totalBytes: 494_000_000_000, availableBytes: 210_000_000_000)),
                    processes: columnProcesses,
                    elapsed: 1)),
            // First sample not in yet: CPU shows the em dash and track-only bars named by the system.
            Fixture(
                name: "pending",
                batch: MetricsBatch(
                    cpu: .pending,
                    memory: .value(
                        MemoryReading(
                            usedBytes: 12_025_908_428, totalBytes: totalMemory,
                            swapUsedBytes: 0, freePercent: 60, pressure: .normal)),
                    disk: .value(DiskReading(totalBytes: 494_000_000_000, availableBytes: 210_000_000_000)),
                    processes: firstFrameProcesses,
                    elapsed: 1)),
            Fixture(
                name: "unavailable",
                batch: MetricsBatch(
                    cpu: .unavailable, memory: .unavailable, disk: .unavailable, processes: .unavailable,
                    elapsed: 1)),
            // The Top Apps list with a multi-process browser, system apps and a busy tool
            // (PANEL-04, PROC-02, PROC-03). Synthetic values; the Chrome members sum to 182 % and 2.1 GB.
            Fixture(name: "apps", batch: appsBatch(processes: appsSnapshot)),
            // The same list with system rows among the top five: WindowServer, kernel_task and a
            // root-owned app group, each with the lock after its name (PROC-01, D-09; owner decision Q5).
            Fixture(name: "apps-system", batch: appsBatch(processes: appsSystemSnapshot)),
            // System processes could not be read: own rows only and the footer says so (E5 partial).
            Fixture(name: "apps-partial", batch: appsBatch(processes: appsPartialSnapshot)),
            // Chrome open: its three heaviest helpers and "and 11 more…" (D-08, PROC-02).
            Fixture(name: "apps-expanded", batch: appsBatch(processes: appsSnapshot), expanded: chromeID),
            // The worst-case height: a group open and a Force Quit confirmation open on TextEdit (E5 populated).
            Fixture(
                name: "apps-confirm", batch: appsBatch(processes: appsTextEditSnapshot),
                expanded: chromeID, actionStates: [textEditID: .confirming]),
            // TextEdit is quitting and Safari did not quit, so it offers Force Quit… (D-15).
            Fixture(
                name: "apps-quitting", batch: appsBatch(processes: appsTextEditSnapshot),
                actionStates: [textEditID: .quitting(startedAt: 0), safariID: .didNotQuit]),
            // The process list cannot be read at all: one quiet line in the reserved area (E5 error).
            Fixture(name: "apps-error", batch: appsBatch(reading: .unavailable)),
        ]
    }

    /// The batch shared by the Top Apps fixtures: a busy-but-normal Mac with the given process reading.
    private static func appsBatch(processes: ProcessSnapshot) -> MetricsBatch {
        appsBatch(reading: .value(processes))
    }

    private static func appsBatch(reading processes: Reading<ProcessSnapshot>) -> MetricsBatch {
        MetricsBatch(
            cpu: .value(
                CPUReading(
                    total: 0.34, user: 0.22, system: 0.12,
                    clusters: [
                        CPUCluster(name: "Performance", usage: 0.41),
                        CPUCluster(name: "Efficiency", usage: 0.18),
                    ])),
            memory: .value(
                MemoryReading(
                    usedBytes: 12_025_908_428, totalBytes: totalMemory,
                    swapUsedBytes: 0, freePercent: 60, pressure: .normal)),
            disk: .value(DiskReading(totalBytes: 494_000_000_000, availableBytes: 210_000_000_000)),
            processes: processes,
            elapsed: 1)
    }

    /// `apps-system`: Chrome and Safari from the `apps` set plus three system rows, so the top five
    /// by CPU are Chrome (182 %), the root-owned Agent group (50 %), kernel_task (18 %),
    /// WindowServer (12 %) and Safari (9 %).
    private static var appsSystemSnapshot: ProcessSnapshot {
        let mib: UInt64 = 1_048_576
        let own = appsSnapshot.processes.filter {
            $0.path?.contains("/Google Chrome.app/") == true || $0.path?.contains("/Safari.app/") == true
        }
        func system(_ pid: Int32, uid: UInt32, path: String?, _ command: String, cpu: Double, mib size: UInt64)
            -> ProcessSample
        {
            ProcessSample(
                identity: ProcessIdentity(pid: pid, startMicros: Int64(pid) * 1_000),
                ppid: 1, uid: uid, path: path, command: command, cpuPercent: cpu, footprintBytes: size * mib)
        }
        let agent = "/Library/Application Support/Vendor/Agent.app/Contents"
        let rows = [
            system(0, uid: 0, path: nil, "kernel_task", cpu: 18, mib: 900),
            system(
                190, uid: 88,
                path: "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer",
                "WindowServer", cpu: 12, mib: 512),
            system(300, uid: 0, path: agent + "/MacOS/Agent", "Agent", cpu: 30, mib: 240),
            system(301, uid: 0, path: agent + "/Helpers/Agent Helper", "Agent Helper", cpu: 12, mib: 80),
            system(302, uid: 0, path: agent + "/Helpers/Agent Updater", "Agent Updater", cpu: 8, mib: 40),
        ]
        return ProcessSnapshot(sequence: 1, processes: rows + own, cpuReady: true, otherUsers: .available)
    }

    /// The `apps` rows plus TextEdit at 15 %, so it ranks fourth by CPU and the top five are Chrome,
    /// swift-frontend, Xcode, TextEdit and Safari: both rows the state fixtures act on are visible.
    private static var appsTextEditSnapshot: ProcessSnapshot {
        var samples = appsSamples
        let pid: Int32 = 2_000
        samples.append(
            ProcessSample(
                identity: ProcessIdentity(pid: pid, startMicros: Int64(pid) * 1_000),
                ppid: 1, uid: getuid(), path: "/Applications/TextEdit.app/Contents/MacOS/TextEdit",
                command: "TextEdit", cpuPercent: 15, footprintBytes: 180 * 1_048_576))
        return ProcessSnapshot(sequence: 1, processes: samples, cpuReady: true)
    }

    /// `apps-partial`: the `apps` rows with the other-users half unavailable.
    private static var appsPartialSnapshot: ProcessSnapshot {
        var snapshot = appsSnapshot
        snapshot.otherUsers = .unavailable
        return snapshot
    }

    /// The process reading the column fixtures carry, so no panel render shows an empty list area
    /// (D-20): the `apps` own-uid samples, CPU-ready.
    private static var columnProcesses: Reading<ProcessSnapshot> { .value(appsSnapshot) }

    /// D-20's first frame: the same samples with no CPU yet, so the list is memory-sorted, the CPU
    /// column reads the em dash and Memory is the emphasized one.
    private static var firstFrameProcesses: Reading<ProcessSnapshot> {
        let samples = appsSamples.map { sample -> ProcessSample in
            var pending = sample
            pending.cpuPercent = nil
            return pending
        }
        return .value(ProcessSnapshot(sequence: 1, processes: samples, cpuReady: false))
    }

    private static var appsSnapshot: ProcessSnapshot {
        ProcessSnapshot(sequence: 1, processes: appsSamples, cpuReady: true)
    }

    /// Synthetic own-uid processes shared by the `apps` fixture and the column fixtures: Chrome
    /// with its helpers, three system apps, a compiler and Xcode.
    private static var appsSamples: [ProcessSample] {
        let me = getuid()
        let mib: UInt64 = 1_048_576
        var next: Int32 = 1_000
        var samples: [ProcessSample] = []
        func add(_ path: String, _ command: String, cpu: Double, mib size: UInt64) {
            next += 1
            samples.append(
                ProcessSample(
                    identity: ProcessIdentity(pid: next, startMicros: Int64(next) * 1_000),
                    ppid: 1, uid: me, path: path, command: command,
                    cpuPercent: cpu, footprintBytes: size * mib))
        }
        let chrome = "/Applications/Google Chrome.app"
        let helpers = chrome + "/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers"
        func helper(_ kind: String?) -> String {
            let name = "Google Chrome Helper" + (kind.map { " (\($0))" } ?? "")
            return helpers + "/" + name + ".app/Contents/MacOS/" + name
        }
        add(chrome + "/Contents/MacOS/Google Chrome", "Google Chrome", cpu: 14, mib: 300)
        let renderers: [(Double, UInt64)] = [
            (42, 310), (24, 220), (18, 170), (13, 140), (10, 110), (8, 100), (6, 90), (5, 70), (3, 60), (2, 50),
        ]
        for (cpu, size) in renderers { add(helper("Renderer"), "Google Chrome H", cpu: cpu, mib: size) }
        add(helper("GPU"), "Google Chrome H", cpu: 24, mib: 400)
        for (cpu, size) in [(6.0, UInt64(60)), (4, 45), (3, 35)] {
            add(helper(nil), "Google Chrome H", cpu: cpu, mib: size)
        }
        add("/System/Applications/Mail.app/Contents/MacOS/Mail", "Mail", cpu: 4, mib: 520)
        add("/System/Applications/Music.app/Contents/MacOS/Music", "Music", cpu: 3, mib: 380)
        add("/Applications/Safari.app/Contents/MacOS/Safari", "Safari", cpu: 9, mib: 610)
        add("/usr/bin/swift-frontend", "swift-frontend", cpu: 140, mib: 1_400)
        add("/Applications/Xcode.app/Contents/MacOS/Xcode", "Xcode", cpu: 22, mib: 2_400)
        return samples
    }

    static func renderAndExit(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        isRendering = true
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        var panelCount = 0
        var welcomeCount = 0
        for fixture in fixtures {
            for scheme in [ColorScheme.light, .dark] {
                let store = MetricsStore()
                store.apply(fixture.batch)
                store.applyThermal(fixture.thermal)
                let name = "panel-\(language)-\(fixture.name)-\(scheme == .dark ? "dark" : "light").png"
                var topApps: TopAppsModel?
                if fixture.presetsRows {
                    let model = TopAppsModel()
                    // A preset model answers `.allowed` for every row, so what is drawn does not
                    // depend on which synthetic pids exist on this machine.
                    model.preset(
                        expanded: fixture.expanded, actionStates: fixture.actionStates, availability: .allowed)
                    topApps = model
                }
                if let height = write(
                    PanelView(store: store, topApps: topApps), scheme: scheme,
                    to: directory.appending(path: name))
                {
                    DebugHooks.log("rendered \(name) height=\(Int(height.rounded(.up)))")
                    panelCount += 1
                }
            }
        }
        for (state, usedFallback) in [("default", false), ("fallback", true)] {
            for scheme in [ColorScheme.light, .dark] {
                let name = "welcome-\(language)-\(state)-\(scheme == .dark ? "dark" : "light").png"
                let view = WelcomeView(onDone: {}, usedFallback: usedFallback)
                if write(view, scheme: scheme, to: directory.appending(path: name)) != nil {
                    DebugHooks.log("rendered \(name)")
                    welcomeCount += 1
                }
            }
        }
        // The window fixtures need the run loop (the real window lays out and draws on it), so they
        // render asynchronously; the totals line and the exit come after the last one.
        Task { @MainActor in
            let windowCount = await renderWindows(to: directory, language: language)
            // The render gate compares this line with the PNGs on disk, so it measures what was written.
            DebugHooks.log("rendered-total panel=\(panelCount) welcome=\(welcomeCount) window=\(windowCount)")
            NSApp.terminate(nil)
        }
    }

    // MARK: Window fixtures

    /// A window fixture: the section to show, the history to feed the store, and the content size.
    private struct WindowFixture {
        let name: String
        let section: WindowSection
        /// 5 minutes of synthetic CPU history plus per-core values; false = nothing sampled yet.
        let populated: Bool
        let contentSize: NSSize
        /// What the GPU reading looks like in this fixture.
        var gpu: GPUFixtureState = .none
        /// What the memory history looks like in this fixture.
        var memory: MemoryFixtureState = .lastOnly
        /// What the network history looks like in this fixture.
        var network: NetworkFixtureState = .none
        /// What the volume list looks like in this fixture.
        var volumes: VolumeFixtureState = .none
        /// What the system-wide disk read / write history looks like in this fixture.
        var diskIO: DiskIOFixtureState = .none
        /// A preset hover position, in seconds before the newest sample: the readout is drawn as if
        /// the pointer rested there. nil = no pointer.
        var hoverSecondsAgo: Double?
        /// What the process list looks like in this fixture.
        var processes: ProcessFixtureState = .none
    }

    private enum ProcessFixtureState {
        /// No process reading is fed.
        case none
        /// About 40 rows, Chrome open with its helpers, CPU known.
        case live
        /// The first reading: no CPU yet, so the rows are in Memory order and CPU reads the em dash.
        case pending
        /// The process list cannot be read.
        case unavailable
    }

    private enum MemoryFixtureState {
        /// One memory reading, in the last second (the other sections' fixtures).
        case lastOnly
        /// Five minutes at Normal pressure with swap in use.
        case steady
        /// Five minutes that go Normal, Elevated, Critical and back to Normal.
        case pressure
    }

    private enum NetworkFixtureState {
        /// No network reading is fed.
        case none
        /// Five minutes of mirrored traffic over Wi-Fi: a download with bursts and a lighter upload.
        case live
        /// Five minutes of nothing, with no primary interface: "Not connected" and real zeros.
        case idle
        /// The long-text case: the largest hero values the window has to fit (128.4 MB/s, 999.9 kB/s).
        case wide
    }

    private enum DiskIOFixtureState {
        /// No disk I/O reading is fed: the heroes read the em dash.
        case none
        /// Five minutes of mirrored disk activity: reads in bursts, a heavier write stretch, ending on
        /// 1.2 MB/s read and 340 kB/s write.
        case live
        /// The disk statistics cannot be read.
        case unavailable
    }

    private enum VolumeFixtureState {
        /// No volume reading is fed.
        case none
        /// The startup disk, an internal disk, an external drive that is nearly full and one that
        /// reports no capacity.
        case live
        /// A Mac with only its startup volume: one row and no empty-state text.
        case single
        /// Twelve drives, one with a very long name: the list scrolls and the name is cut.
        case many
        /// The startup disk is 93 % full (7 % free): its bar is orange, the others stay neutral.
        case low
        /// The drives cannot be read: one quiet line replaces the list.
        case unavailable
    }

    private enum GPUFixtureState {
        /// No GPU reading is fed.
        case none
        /// 5 minutes of varied GPU load on an M4 chip line.
        case live
        /// The GPU cannot be read.
        case unavailable
    }

    private static var windowFixtures: [WindowFixture] {
        let standard = NSSize(width: 1000, height: 640)
        return [
            WindowFixture(name: "cpu", section: .cpu, populated: true, contentSize: standard),
            WindowFixture(name: "cpu-pending", section: .cpu, populated: false, contentSize: standard),
            WindowFixture(
                name: "cpu-min", section: .cpu, populated: true, contentSize: NSSize(width: 900, height: 520)),
            WindowFixture(name: "gpu", section: .gpu, populated: true, contentSize: standard, gpu: .live),
            WindowFixture(
                name: "gpu-unavailable", section: .gpu, populated: false, contentSize: standard, gpu: .unavailable),
            // The hover readout over the stacked CPU chart, with the pointer in the middle of the plot.
            WindowFixture(name: "cpu-readout", section: .cpu, populated: true, contentSize: standard, hoverSecondsAgo: 150),
            WindowFixture(name: "memory", section: .memory, populated: true, contentSize: standard, memory: .steady),
            WindowFixture(
                name: "memory-pressure", section: .memory, populated: true, contentSize: standard, memory: .pressure),
            WindowFixture(name: "network", section: .network, populated: true, contentSize: standard, network: .live),
            WindowFixture(
                name: "network-idle", section: .network, populated: true, contentSize: standard, network: .idle),
            WindowFixture(
                name: "network-min", section: .network, populated: true, contentSize: NSSize(width: 900, height: 520),
                network: .wide),
            WindowFixture(
                name: "disk", section: .disk, populated: true, contentSize: standard, volumes: .live, diskIO: .live),
            WindowFixture(
                name: "disk-one", section: .disk, populated: true, contentSize: standard, volumes: .single),
            WindowFixture(
                name: "disk-many", section: .disk, populated: true, contentSize: NSSize(width: 900, height: 520),
                volumes: .many, diskIO: .live),
            WindowFixture(
                name: "disk-low", section: .disk, populated: true, contentSize: standard, volumes: .low,
                diskIO: .live),
            WindowFixture(
                name: "disk-unavailable", section: .disk, populated: true, contentSize: standard,
                volumes: .unavailable, diskIO: .unavailable),
            WindowFixture(
                name: "processes", section: .processes, populated: false, contentSize: standard, processes: .live),
            WindowFixture(
                name: "processes-pending", section: .processes, populated: false, contentSize: standard,
                processes: .pending),
            WindowFixture(
                name: "processes-error", section: .processes, populated: false, contentSize: standard,
                processes: .unavailable),
            WindowFixture(
                name: "processes-min", section: .processes, populated: false,
                contentSize: NSSize(width: 900, height: 520), processes: .live),
        ]
    }

    /// What the store is told about the drives: nothing for a fixture without any, an unreadable list,
    /// or the rows.
    private static func volumeReading(for state: VolumeFixtureState) -> Reading<[VolumeInfo]>? {
        switch state {
        case .none: nil
        case .unavailable: .unavailable
        default: .value(volumeRows(for: state))
        }
    }

    /// The volumes of a volume fixture. Figures are decimal bytes, as the system reports them.
    private static func volumeRows(for state: VolumeFixtureState) -> [VolumeInfo] {
        let startup = VolumeInfo(
            id: "disk3", name: "Macintosh HD", role: .startup, totalBytes: 494_384_795_648,
            freeBytes: 210_000_000_000)
        switch state {
        case .none, .unavailable:
            return []
        case .single:
            return [startup]
        case .low:
            // 7 % free of 245 GB, with an external drive that is even fuller and stays neutral.
            return [
                VolumeInfo(
                    id: "disk3", name: "Macintosh HD", role: .startup, totalBytes: 245_107_195_904,
                    freeBytes: 17_150_000_000),
                VolumeInfo(
                    id: "disk4", name: "Archive", role: .external, totalBytes: 4_000_000_000_000,
                    freeBytes: 120_000_000_000),
            ]
        case .live:
            return [
                startup,
                VolumeInfo(
                    id: "disk1", name: "Projects", role: .internal, totalBytes: 1_000_000_000_000,
                    freeBytes: 640_000_000_000),
                VolumeInfo(
                    id: "disk4", name: "Lexar", role: .external, totalBytes: 1_023_966_052_352,
                    freeBytes: 899_851_485_184),
                VolumeInfo(
                    id: "disk5", name: "Archive", role: .external, totalBytes: 4_000_000_000_000,
                    freeBytes: 120_000_000_000),
                VolumeInfo(id: "disk7", name: "Camera Card", role: .external, totalBytes: nil, freeBytes: nil),
            ]
        case .many:
            var rows = [startup]
            rows.append(
                VolumeInfo(
                    id: "disk4",
                    name: "Photography archive 2019 to 2026, full-resolution originals, proofs, edits and exports for every client",
                    role: .external, totalBytes: 8_000_000_000_000, freeBytes: 2_345_000_000_000))
            for index in 1...10 {
                rows.append(
                    VolumeInfo(
                        id: "disk\(10 + index)", name: "Drive \(index)", role: .external,
                        totalBytes: 500_000_000_000, freeBytes: Int64(index) * 40_000_000_000))
            }
            return rows
        }
    }

    /// The memory reading of second `second` of a memory fixture: Normal with swap, or the pressure
    /// story (Normal, then Elevated, then Critical, then Normal again).
    private static func memoryReading(second: Int, state: MemoryFixtureState) -> MemoryReading {
        let t = Double(second)
        switch state {
        case .lastOnly, .steady:
            let free = Int((58 + 6 * sin(t / 30) + 2 * sin(t / 7)).rounded())
            return MemoryReading(
                usedBytes: 12_025_908_428, totalBytes: totalMemory, swapUsedBytes: 1_288_490_189, freePercent: free,
                pressure: .normal)
        case .pressure:
            let (free, pressure): (Double, MemoryPressure) =
                switch second {
                case ..<90: (55 + 5 * sin(t / 20), .normal)
                case 90..<160: (28 - 4 * sin(t / 9), .warn)
                case 160..<220: (9 - 3 * sin(t / 6), .critical)
                default: (48 + 4 * sin(t / 15), .normal)
                }
            return MemoryReading(
                usedBytes: 14_500_000_000, totalBytes: totalMemory, swapUsedBytes: 2_147_483_648,
                freePercent: Int(free.rounded()), pressure: pressure)
        }
    }

    /// The network reading of second `second` of a network fixture. `live`: a download with bursts and
    /// a quiet stretch and an upload a fraction of it, ending on 2.1 MB/s down and 120 kB/s up, over
    /// Wi-Fi. `idle`: zeros and no primary interface. `wide`: the same shape scaled to end on
    /// 128.4 MB/s down and 999.9 kB/s up.
    private static func networkReading(second: Int, state: NetworkFixtureState) -> NetworkReading {
        if state == .idle {
            return NetworkReading(downBytesPerSec: 0, upBytesPerSec: 0, downBytes: 0, upBytes: 0)
        }
        let t = Double(second)
        let scale = state == .wide ? 30.0 : 1.0
        let burst = (max(0, sin(t / 22)) * 3_800_000 + max(0, sin(t / 6.5)) * 900_000) * scale
        let last = second == 299
        let down = last ? (state == .wide ? 128_400_000 : 2_100_000) : 150_000 * scale + burst
        let up = last ? (state == .wide ? 999_900 : 120_000) : 40_000 + 0.18 * burst * (1 + sin(t / 9)) / 2
        return NetworkReading(
            downBytesPerSec: down, upBytesPerSec: up, downBytes: UInt64(down), upBytes: UInt64(up),
            primaryInterface: "Wi-Fi", hasPrimary: true)
    }

    /// The disk I/O reading of second `second` of a disk fixture: reads in short bursts, a heavier
    /// write stretch in the middle, and a quiet tail, ending on 1.2 MB/s read and 340 kB/s write.
    /// `unavailable` feeds the failed read for every second.
    private static func diskIOReading(second: Int, state: DiskIOFixtureState) -> Reading<DiskIOReading>? {
        switch state {
        case .none: return nil
        case .unavailable: return .unavailable
        case .live:
            if second == 299 { return .value(DiskIOReading(readBytesPerSec: 1_200_000, writeBytesPerSec: 340_000)) }
            let t = Double(second)
            let read = 60_000 + max(0, sin(t / 17)) * 5_200_000 + max(0, sin(t / 5.5)) * 900_000
            let write = 30_000 + (120...190 ~= second ? 3_100_000 * (1 + sin(t / 4)) / 2 : 0) + max(0, sin(t / 9)) * 240_000
            return .value(DiskIOReading(readBytesPerSec: read, writeBytesPerSec: write))
        }
    }

    /// A store holding a fixture's own history: a window session that began 300 s ago and one
    /// synthetic batch per second since, applied with explicit times so no wall clock is involved.
    private static func windowStore(for fixture: WindowFixture) -> MetricsStore {
        let store = MetricsStore()
        let now = Date.now.timeIntervalSinceReferenceDate
        store.beginWindowSession(at: now - 300)
        let memory = MemoryReading(
            usedBytes: 12_025_908_428, totalBytes: totalMemory, swapUsedBytes: 0, freePercent: 60, pressure: .normal)
        // The ring's own disk reading drives the startup bar's tint, so the low fixture feeds 7 % free.
        let disk =
            fixture.volumes == .low
            ? DiskReading(totalBytes: 245_107_195_904, availableBytes: 17_150_000_000)
            : DiskReading(totalBytes: 494_000_000_000, availableBytes: 210_000_000_000)
        guard fixture.populated else {
            store.apply(
                MetricsBatch(
                    memory: .value(memory), disk: .value(disk),
                    processes: processReading(for: fixture.processes),
                    gpu: fixture.gpu == .unavailable ? .unavailable : nil, elapsed: 1),
                at: now)
            return store
        }
        let performance = [0.62, 0.41, 0.18, 0.07]
        let efficiency = [0.30, 0.22, 0.15, 0.11, 0.06, 0.03]
        for second in 0..<300 {
            let t = Double(second)
            // A busy minute, a quiet one, a busy tail: both series move so the stacking is visible.
            let user = max(0.02, min(0.9, 0.22 + 0.14 * sin(t / 18) + 0.08 * sin(t / 5.5)))
            let system = max(0.01, min(0.4, 0.09 + 0.05 * sin(t / 11 + 1) + 0.02 * sin(t / 3)))
            let clusters = [
                CPUCluster(name: "Performance", usage: 0.32, coreUsage: performance),
                CPUCluster(name: "Efficiency", usage: 0.15, coreUsage: efficiency),
            ]
            let reading = CPUReading(total: user + system, user: user, system: system, clusters: clusters)
            // Varied GPU load: a ramp, a plateau and a quiet tail, with a real zero at the start.
            let load = max(0, min(1, 0.35 + 0.30 * sin(t / 25) + 0.15 * sin(t / 6)))
            let gpu: Reading<GPUReading>? =
                fixture.gpu == .live
                ? .value(GPUReading(utilization: second < 5 ? 0 : load, chipName: "Apple M4", coreCount: 8)) : nil
            // The memory fixtures feed one reading a second; the others only the last one.
            let memoryBatch: Reading<MemoryReading>? =
                fixture.memory == .lastOnly
                ? (second == 299 ? .value(memory) : nil)
                : .value(memoryReading(second: second, state: fixture.memory))
            let network: Reading<NetworkReading>? =
                fixture.network == .none ? nil : .value(networkReading(second: second, state: fixture.network))
            let batch = MetricsBatch(
                cpu: .value(reading), memory: memoryBatch,
                disk: second == 299 ? .value(disk) : nil, network: network, gpu: gpu,
                diskIO: diskIOReading(second: second, state: fixture.diskIO),
                volumes: second != 299 ? nil : volumeReading(for: fixture.volumes),
                elapsed: 1)
            store.apply(batch, at: now - 299 + t)
        }
        return store
    }

    /// What the store is told about the processes: nothing for a fixture without any, an unreadable
    /// list, the first reading (no CPU yet) or the full set.
    private static func processReading(for state: ProcessFixtureState) -> Reading<ProcessSnapshot>? {
        switch state {
        case .none: return nil
        case .unavailable: return .unavailable
        case .live: return .value(processTableSnapshot(cpuReady: true))
        case .pending: return .value(processTableSnapshot(cpuReady: false))
        }
    }

    /// About 40 rows for the Processes table: the `apps` set (Chrome with 14 helpers, Safari, Xcode,
    /// a compiler), WindowServer and kernel_task (they show the lock), and a few standalone tools.
    private static func processTableSnapshot(cpuReady: Bool) -> ProcessSnapshot {
        let mib: UInt64 = 1_048_576
        var samples = appsSamples
        func system(_ pid: Int32, uid: UInt32, path: String?, _ command: String, cpu: Double, mib size: UInt64) {
            samples.append(
                ProcessSample(
                    identity: ProcessIdentity(pid: pid, startMicros: Int64(pid) * 1_000),
                    ppid: 1, uid: uid, path: path, command: command, cpuPercent: cpu, footprintBytes: size * mib))
        }
        system(0, uid: 0, path: nil, "kernel_task", cpu: 18, mib: 900)
        system(
            190, uid: 88,
            path: "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer",
            "WindowServer", cpu: 12, mib: 512)
        let tools: [(String, String, Double, UInt64)] = [
            ("/usr/sbin/mDNSResponder", "mDNSResponder", 0.4, 22), ("/usr/libexec/trustd", "trustd", 0.2, 31),
            ("/usr/sbin/distnoted", "distnoted", 0.1, 9), ("/usr/libexec/syspolicyd", "syspolicyd", 0.1, 48),
            ("/usr/libexec/rapportd", "rapportd", 0.0, 14), ("/usr/sbin/cfprefsd", "cfprefsd", 0.1, 12),
            ("/usr/libexec/lsd", "lsd", 0.3, 26), ("/usr/sbin/coreaudiod", "coreaudiod", 0.6, 18),
            ("/usr/libexec/airportd", "airportd", 0.2, 11), ("/usr/sbin/bluetoothd", "bluetoothd", 0.1, 10),
            ("/usr/libexec/logd", "logd", 0.5, 40), ("/usr/sbin/notifyd", "notifyd", 0.0, 6),
            ("/usr/libexec/UserEventAgent", "UserEventAgent", 0.1, 8), ("/usr/bin/sharingd", "sharingd", 0.2, 33),
            ("/usr/libexec/powerd", "powerd", 0.1, 7), ("/usr/libexec/diskarbitrationd", "diskarbitrationd", 0.0, 5),
            ("/usr/libexec/containermanagerd", "containermanagerd", 0.1, 19),
            ("/usr/libexec/secd", "secd", 0.0, 13), ("/usr/bin/pbs", "pbs", 0.0, 8),
        ]
        for (index, tool) in tools.enumerated() {
            system(Int32(400 + index), uid: 0, path: tool.0, tool.1, cpu: tool.2, mib: tool.3)
        }
        if !cpuReady {
            samples = samples.map { sample in
                var pending = sample
                pending.cpuPercent = nil
                return pending
            }
        }
        return ProcessSnapshot(sequence: 1, processes: samples, cpuReady: cpuReady, otherUsers: .available)
    }

    /// The sidebar's width in the window (UI-SPEC Shell: ideal 220 pt), taken off the content width
    /// to get the detail column the section fixtures render in.
    private static let sidebarWidth: CGFloat = 220

    /// Renders every window fixture in light and dark.
    ///
    /// Assumption A7 outcome (03-03): the real `WindowRootView` in an off-screen window does not
    /// draw through `cacheDisplay` or `CALayer.render`: the Liquid Glass sidebar and the grouped
    /// detail come out blank. So each fixture renders the detail column's content, the section view
    /// itself, hosted in an `NSHostingView` inside an off-screen window, which AppKit-backed grouped
    /// Forms and Swift Charts do draw in. The sidebar and toolbar chrome are covered by the
    /// end-of-phase human check. Width is the window's content width minus the sidebar.
    private static func renderWindows(to directory: URL, language: String) async -> Int {
        var count = 0
        for fixture in windowFixtures {
            for scheme in [ColorScheme.light, .dark] {
                let store = windowStore(for: fixture)
                let size = NSSize(
                    width: fixture.contentSize.width - sidebarWidth, height: fixture.contentSize.height)
                DebugChartHover.preset = fixture.hoverSecondsAgo.map {
                    HistoryChartTime.date(Date.now.timeIntervalSinceReferenceDate - $0)
                }
                // The table model is built here, with Chrome open, so the fixture shows an outline.
                let table = ProcessTableModel(persistsState: false)
                table.expanded = [chromeID]
                let content = detailView(for: fixture.section, store: store, table: table)
                    .frame(width: size.width, height: size.height)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .environment(\.colorScheme, scheme)
                let host = NSHostingView(rootView: content)
                host.frame = NSRect(origin: .zero, size: size)
                let window = OffscreenWindow(
                    contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                    backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                window.contentView = host
                // One point of it overlaps the main screen's left edge, because a window with no
                // visible point is occluded and SwiftUI stops drawing it; it is made see-through.
                let edge = NSScreen.screens.first?.frame.minX ?? 0
                window.setFrameOrigin(NSPoint(x: edge - size.width + 1, y: 0))
                window.alphaValue = 0.01
                window.ignoresMouseEvents = true
                window.orderFront(nil)
                try? await Task.sleep(for: .milliseconds(500))
                host.layoutSubtreeIfNeeded()

                let name = "window-\(language)-\(fixture.name)-\(scheme == .dark ? "dark" : "light").png"
                if let written = snapshot(host, to: directory.appending(path: name)) {
                    DebugHooks.log(
                        "rendered \(name) width=\(Int(written.width.rounded())) height=\(Int(written.height.rounded()))")
                    count += 1
                }
                window.close()
                DebugChartHover.preset = nil
            }
        }
        return count
    }

    /// The detail column of a section, as `WindowRootView` shows it.
    @ViewBuilder
    private static func detailView(
        for section: WindowSection, store: MetricsStore, table: ProcessTableModel
    ) -> some View {
        switch section {
        case .processes: ProcessesSectionView(store: store, model: table)
        case .cpu: CPUSectionView(store: store)
        case .gpu: GPUSectionView(store: store)
        case .memory: MemorySectionView(store: store)
        case .network: NetworkSectionView(store: store)
        case .disk: DiskSectionView(store: store)
        default: Color.clear
        }
    }

    /// Draws a view at 2x into a PNG with `cacheDisplay`. Returns its size in points, or nil when
    /// nothing was written.
    private static func snapshot(_ view: NSView, to url: URL) -> NSSize? {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0,
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]), (try? png.write(to: url)) != nil
        else { return nil }
        return bounds.size
    }

    /// The backdrop exists only in the renderer, standing in for the popover's glass. Returns the
    /// height of the written image in points, or nil when nothing was written.
    private static func write(_ content: some View, scheme: ColorScheme, to url: URL) -> CGFloat? {
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        var backdrop = NSColor.windowBackgroundColor
        appearance?.performAsCurrentDrawingAppearance {
            backdrop = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? backdrop
        }
        let view = content
            .background(Color(nsColor: backdrop))
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage,
            let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
            (try? png.write(to: url)) != nil
        else { return nil }
        return CGFloat(image.height) / renderer.scale
    }
}
#endif
