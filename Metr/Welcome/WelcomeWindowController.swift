import AppKit
import SwiftUI

/// The first-launch welcome window (D-14): small, centered, close button only, not resizable and
/// not modal, so the status item and the panel keep working while it is open.
@MainActor
final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    private let presence: WindowPresence

    init(presence: WindowPresence) {
        self.presence = presence
        let window = WelcomeWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        super.init(window: window)
        window.delegate = self

        let host = NSHostingController(rootView: WelcomeView(onDone: { [weak self] in self?.close() }))
        // The window owns its size: a hosting controller that resizes the window from its own layout
        // pass loops (an AppKit "update constraints" exception on macOS 26, which crashed the first
        // launch; the Settings window carries the same rule). The view has a fixed width and an
        // intrinsic height, so measure it once, for the taller of its two tips, and set the content size.
        host.sizingOptions = []
        window.contentViewController = host
        let width: CGFloat = 420
        let height = [false, true].map { fallback in
            NSHostingController(rootView: WelcomeView(onDone: {}, usedFallback: fallback))
                .sizeThatFits(in: NSSize(width: width, height: .greatestFiniteMagnitude)).height
        }.max() ?? 360
        window.setContentSize(NSSize(width: width, height: height))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Brings the window in front of other apps (Metr is an accessory app) and centers it.
    func present() {
        presence.opened(.welcome)
        NSApp.activate()
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        DebugHooks.log("welcome shown")
    }

    /// The Done button, Esc and the close button all close through this window.
    func windowWillClose(_ notification: Notification) {
        presence.closed(.welcome)
    }
}

/// Esc closes the window even when no SwiftUI view has focus.
private final class WelcomeWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        close()
    }
}
