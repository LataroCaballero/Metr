import AppKit
import SwiftUI

/// Owns the one Settings window. AppKit hosts it, like the Welcome and main windows do (D-25, owner
/// approval of 2026-11-14): a SwiftUI `Settings` scene needs a live SwiftUI view to open, and this app
/// has none. The scene stays only as the required empty scene in `MetrApp`.
///
/// The window object is reused; its SwiftUI content exists only while the window is open, so a closed
/// Settings window costs nothing (the `StatusItemController.makePanelContent` lesson, FND-03).
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let windowIdentifier = "MetrSettingsWindow"
    private static let contentWidth: CGFloat = 480

    private let preferences: UserDefaults
    private let presence: WindowPresence
    private let loginItems: LoginItemModel

    init(preferences: UserDefaults, presence: WindowPresence, loginItems: LoginItemModel) {
        self.preferences = preferences
        self.loginItems = loginItems
        self.presence = presence
        // Not resizable and no zoom (UI-SPEC: the Form has a fixed width and its own height).
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 160),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier(Self.windowIdentifier)
        window.title = String(localized: "Settings")
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Opens the window in front with key focus, or brings the one that is open forward (never a
    /// second one). Esc does nothing: there is nothing to cancel.
    func show() {
        guard let window else { return }
        let firstOpen = window.contentViewController == nil
        if firstOpen {
            let host = NSHostingController(rootView: SettingsView(preferences: preferences, loginItems: loginItems))
            // The window owns its size: a hosting controller that resizes the window from the Form's
            // own layout pass loops (an AppKit "update constraints" exception on macOS 26). The Form
            // has a fixed width and an intrinsic height (`SettingsView` pins it), so measure it once
            // and set the content size.
            host.sizingOptions = []
            window.contentViewController = host
            let height = host.sizeThatFits(in: NSSize(width: Self.contentWidth, height: .greatestFiniteMagnitude)).height
            window.setContentSize(NSSize(width: Self.contentWidth, height: height))
            window.center()
        }
        presence.opened(.settings)
        NSApp.activate()
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        logShown(window)
    }

    /// Closes the window the way the red button does, so the same delegate path runs.
    func closeWindow() {
        window?.performClose(nil)
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        // A hosting controller left on a closed window keeps its SwiftUI content alive (FND-03).
        window?.contentViewController = nil
        presence.closed(.settings)
        #if DEBUG
        // The presence coordinator applies the policy on the next turn; log on the turn after that.
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    DebugHooks.log("settings closed policy=\(Self.policyName)")
                }
            }
        }
        #endif
    }

    // MARK: DEBUG logging

    private static var policyName: String { NSApp.activationPolicy() == .regular ? "regular" : "accessory" }

    private func logShown(_ window: NSWindow) {
        #if DEBUG
        // Same 0.3 s check as the main window: it shows what is visible and what policy holds.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            MainActor.assumeIsolated {
                let count = NSApp.windows.filter {
                    $0.identifier?.rawValue == Self.windowIdentifier && $0.isVisible
                }.count
                DebugHooks.log(
                    "settings shown count=\(count) key=\(window.isKeyWindow ? 1 : 0) policy=\(Self.policyName)")
            }
        }
        #endif
    }
}
