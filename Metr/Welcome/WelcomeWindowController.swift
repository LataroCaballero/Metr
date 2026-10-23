import AppKit
import SwiftUI

/// The first-launch welcome window (D-14): small, centered, close button only, not resizable and
/// not modal, so the status item and the panel keep working while it is open.
@MainActor
final class WelcomeWindowController: NSWindowController {
    init() {
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

        let host = NSHostingController(rootView: WelcomeView(onDone: { [weak self] in self?.close() }))
        host.sizingOptions = .preferredContentSize
        window.contentViewController = host
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Brings the window in front of other apps (Metr is an accessory app) and centers it.
    func present() {
        NSApp.activate()
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        DebugHooks.log("welcome shown")
    }
}

/// Esc closes the window even when no SwiftUI view has focus.
private final class WelcomeWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        close()
    }
}
