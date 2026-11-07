import AppKit

/// What the About item calls on its target.
@objc protocol RightClickMenuActions: AnyObject {
    func showAbout(_ sender: Any?)
    func openWindow(_ sender: Any?)
}

/// The right-click and control-click menu (D-10, extended by Phase 3 D-01): About Metr, Open Window
/// (Cmd-0 shown), a separator, Quit Metr. Text only. A later phase adds the preferences item.
enum RightClickMenu {
    /// Activates Metr and shows the standard About panel in front of other apps' windows.
    static func showAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    static func make(target: any RightClickMenuActions) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let about = NSMenuItem(
            title: String(localized: "About Metr"),
            action: #selector(RightClickMenuActions.showAbout(_:)),
            keyEquivalent: "")
        about.target = target
        menu.addItem(about)

        let open = NSMenuItem(
            title: String(localized: "Open Window"),
            action: #selector(RightClickMenuActions.openWindow(_:)),
            keyEquivalent: "0")
        open.keyEquivalentModifierMask = .command
        open.target = target
        menu.addItem(open)

        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(
            title: String(localized: "Quit Metr"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)

        return menu
    }
}
