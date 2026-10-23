import AppKit

/// What the About item calls on its target.
@objc protocol RightClickMenuActions: AnyObject {
    func showAbout(_ sender: Any?)
}

/// The right-click and control-click menu (D-10): About Metr, a separator, Quit Metr.
/// Text only. Later phases add the preferences and window items.
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
