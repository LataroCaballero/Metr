import AppKit
import MetrCore

/// What the About item calls on its target.
@objc protocol RightClickMenuActions: AnyObject {
    func showAbout(_ sender: Any?)
    func openWindow(_ sender: Any?)
    func openSettings(_ sender: Any?)
}

/// The right-click and control-click menu (D-10, extended by Phase 3 D-01 and Phase 4 D-01): About Metr,
/// Open Window (Cmd-0 shown), Settings (Cmd-, shown), a separator, Quit Metr. Text only.
enum RightClickMenu {
    /// Activates Metr and shows the standard About panel in front of other apps' windows. The panel
    /// supplies the icon, the name, Version and build and the localized copyright line; the credits
    /// add the license and no-network statement and the two links (D-14, D-15).
    static func showAbout() {
        NSApp.activate()
        let credits = aboutCredits()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        #if DEBUG
        var links = 0
        credits.enumerateAttribute(.link, in: NSRange(location: 0, length: credits.length)) { value, _, _ in
            if value != nil { links += 1 }
        }
        DebugHooks.log("about credits links=\(links)")
        #endif
    }

    /// The About credits: the statement, then "Check for updates on GitHub" and "Source code" as links.
    /// 11 pt system font, centered, system secondary color. The panel's text view opens a link in the
    /// default browser through NSWorkspace, so Metr itself never makes a request (D-15).
    static func aboutCredits() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let plain: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]
        let credits = NSMutableAttributedString(
            string: String(localized: "Free and open source (MIT License). Metr makes no network connections."),
            attributes: plain)
        credits.append(NSAttributedString(string: "\n", attributes: plain))
        credits.append(
            NSAttributedString(
                string: String(localized: "Check for updates on GitHub"),
                attributes: plain.merging([.link: ProjectLinks.releases]) { $1 }))
        credits.append(NSAttributedString(string: " · ", attributes: plain))
        credits.append(
            NSAttributedString(
                string: String(localized: "Source code"),
                attributes: plain.merging([.link: ProjectLinks.repository]) { $1 }))
        return credits
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

        let settings = NSMenuItem(
            title: String(localized: "Settings…"),
            action: #selector(RightClickMenuActions.openSettings(_:)),
            keyEquivalent: ",")
        settings.keyEquivalentModifierMask = .command
        settings.target = target
        menu.addItem(settings)

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
