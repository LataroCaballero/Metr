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
        ]
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
