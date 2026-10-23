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
    }

    private static var fixtures: [Fixture] {
        [
            Fixture(
                name: "idle",
                batch: MetricsBatch(
                    cpu: .value(CPUReading(total: 0.12)),
                    memory: .value(
                        MemoryReading(
                            usedBytes: 12_025_908_428, totalBytes: 17_179_869_184,
                            swapUsedBytes: 0, freePercent: 60, pressure: .normal)),
                    disk: .value(DiskReading(totalBytes: 494_000_000_000, availableBytes: 210_000_000_000)),
                    elapsed: 1)),
            Fixture(
                name: "stress",
                batch: MetricsBatch(
                    cpu: .value(CPUReading(total: 1.0)),
                    memory: .value(
                        MemoryReading(
                            usedBytes: 16_500_000_000, totalBytes: 17_179_869_184,
                            swapUsedBytes: 4_000_000_000, freePercent: 3, pressure: .critical)),
                    disk: .value(DiskReading(totalBytes: 245_000_000_000, availableBytes: 7_000_000_000)),
                    elapsed: 1)),
            Fixture(
                name: "unavailable",
                batch: MetricsBatch(cpu: .unavailable, memory: .unavailable, disk: .unavailable, elapsed: 1)),
        ]
    }

    static func renderAndExit(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        for fixture in fixtures {
            for scheme in [ColorScheme.light, .dark] {
                let store = MetricsStore()
                store.apply(fixture.batch)
                let name = "panel-\(language)-\(fixture.name)-\(scheme == .dark ? "dark" : "light").png"
                if write(PanelView(store: store), scheme: scheme, to: directory.appending(path: name)) {
                    DebugHooks.log("rendered \(name)")
                }
            }
        }
        for (state, usedFallback) in [("default", false), ("fallback", true)] {
            for scheme in [ColorScheme.light, .dark] {
                let name = "welcome-\(language)-\(state)-\(scheme == .dark ? "dark" : "light").png"
                let view = WelcomeView(onDone: {}, usedFallback: usedFallback)
                if write(view, scheme: scheme, to: directory.appending(path: name)) {
                    DebugHooks.log("rendered \(name)")
                }
            }
        }
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
