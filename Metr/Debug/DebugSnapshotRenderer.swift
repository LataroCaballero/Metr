#if DEBUG
import AppKit
import MetrCore
import SwiftUI

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
    }

    private static let totalMemory: UInt64 = 17_179_869_184

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
                    elapsed: 1)),
            Fixture(
                name: "unavailable",
                batch: MetricsBatch(cpu: .unavailable, memory: .unavailable, disk: .unavailable, elapsed: 1)),
            // The Top Apps list with a multi-process browser, system apps and a busy tool
            // (PANEL-04, PROC-02, PROC-03). Synthetic values; the Chrome members sum to 182 % and 2.1 GB.
            Fixture(name: "apps", batch: appsBatch(processes: appsSnapshot)),
            // The same list with system rows among the top five: WindowServer, kernel_task and a
            // root-owned app group, each with the lock after its name (PROC-01, D-09; owner decision Q5).
            Fixture(name: "apps-system", batch: appsBatch(processes: appsSystemSnapshot)),
        ]
    }

    /// The batch shared by the Top Apps fixtures: a busy-but-normal Mac with the given process reading.
    private static func appsBatch(processes: ProcessSnapshot) -> MetricsBatch {
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
            processes: .value(processes),
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

    /// Synthetic own-uid processes for the `apps` fixture: Chrome with its helpers, three system
    /// apps, a compiler and Xcode.
    private static var appsSnapshot: ProcessSnapshot {
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
        return ProcessSnapshot(sequence: 1, processes: samples, cpuReady: true)
    }

    static func renderAndExit(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        var panelCount = 0
        var welcomeCount = 0
        for fixture in fixtures {
            for scheme in [ColorScheme.light, .dark] {
                let store = MetricsStore()
                store.apply(fixture.batch)
                store.applyThermal(fixture.thermal)
                let name = "panel-\(language)-\(fixture.name)-\(scheme == .dark ? "dark" : "light").png"
                if write(PanelView(store: store), scheme: scheme, to: directory.appending(path: name)) {
                    DebugHooks.log("rendered \(name)")
                    panelCount += 1
                }
            }
        }
        for (state, usedFallback) in [("default", false), ("fallback", true)] {
            for scheme in [ColorScheme.light, .dark] {
                let name = "welcome-\(language)-\(state)-\(scheme == .dark ? "dark" : "light").png"
                let view = WelcomeView(onDone: {}, usedFallback: usedFallback)
                if write(view, scheme: scheme, to: directory.appending(path: name)) {
                    DebugHooks.log("rendered \(name)")
                    welcomeCount += 1
                }
            }
        }
        // The render gate compares this line with the PNGs on disk, so it measures what was written.
        DebugHooks.log("rendered-total panel=\(panelCount) welcome=\(welcomeCount)")
        NSApp.terminate(nil)
    }

    /// The backdrop exists only in the renderer, standing in for the popover's glass.
    private static func write(_ content: some View, scheme: ColorScheme, to url: URL) -> Bool {
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
            let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { return false }
        return (try? png.write(to: url)) != nil
    }
}
#endif
