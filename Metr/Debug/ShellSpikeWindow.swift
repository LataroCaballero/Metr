#if DEBUG
import AppKit
import SwiftUI

/// Shell spike instrument (ROADMAP shell criterion 5: "a panel button can bring a window to the
/// front"). Phase 1's panel has no window-opening button, so this DEBUG-only window stands in for
/// the one Phase 3 adds. It is reachable only through the METR_DEBUG_SHELL_SPIKE footer button and
/// is compiled out of Release.
@MainActor
enum ShellSpikeWindow {
    private static var window: NSWindow?

    static func bringToFront() {
        let window = existingOrNewWindow()
        // Same activation path the welcome window and Phase 3's Open Window use. The activation
        // policy stays as the LSUIElement default (accessory).
        NSApp.activate()
        window.center()
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            MainActor.assumeIsolated {
                DebugHooks.log(
                    "spike window visible=\(window.isVisible ? 1 : 0)"
                        + " key=\(window.isKeyWindow ? 1 : 0)"
                        + " active=\(NSApp.isActive ? 1 : 0)")
            }
        }
    }

    private static func existingOrNewWindow() -> NSWindow {
        if let window { return window }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 160),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Metr"
        window.contentView = NSHostingView(
            rootView: Text(verbatim: "Metr shell spike window").padding())
        Self.window = window
        return window
    }
}
#endif
