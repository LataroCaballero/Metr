import AppKit
import MetrCore

/// The Force Quit confirmation of the window: a standard alert sheet that hangs from the window
/// (WIN-04, D-15; RESEARCH Pitfall 9, T-03-31).
///
/// Cancel is added first, so it is the default button and Return cancels. Force Quit is the second
/// button, marked destructive, with an empty key equivalent. Esc is mapped to Cancel by a key monitor
/// that lives only while the sheet is up, because a localized "Cancelar" would not get Esc from AppKit
/// by its title. Nothing a key can do force quits.
///
/// The sheet opens through `ProcessActionController.requestForceQuit`, which captures the row's role at
/// that moment. Confirming executes that captured role behind `ActionGuard`, so an app that restarted
/// while the sheet was open is left alone.
@MainActor
enum ForceQuitAlert {
    /// The alert, not yet shown. Cancel first (Return), then a destructive Force Quit with no key equivalent.
    static func make(title: String, message: String) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        let cancel = alert.addButton(withTitle: String(localized: "Cancel"))
        // AppKit gives a button titled "Cancel" the Esc key and leaves the alert with no default
        // button. Cancel is wanted as the default, so Return cancels; Esc is mapped in `present`.
        cancel.keyEquivalent = "\r"
        let forceQuit = alert.addButton(withTitle: String(localized: "Force Quit"))
        forceQuit.hasDestructiveAction = true
        forceQuit.keyEquivalent = ""
        return alert
    }

    /// The title and body for a row: an app or standalone process, or a helper of an app. Names are
    /// cleaned again at this boundary, so a hostile name cannot reorder or hide the question (T-03-32).
    static func text(forName name: String, helperOf app: String?) -> (title: String, message: String) {
        let name = ProcessText.sanitize(name)
        if let app {
            let app = ProcessText.sanitize(app)
            return (String(localized: "Force quit \(name) in \(app)?"), String(localized: "The app may stop responding."))
        }
        return (String(localized: "Force quit \(name)?"), String(localized: "Unsaved changes will be lost."))
    }

    /// Opens the confirmation for a row as a sheet of `window`. Nothing opens when the controller
    /// refuses (a protected row, no role, already working) or another sheet is up.
    static func present(
        for rowID: String, title: String, message: String, in window: NSWindow, controller: ProcessActionController
    ) {
        guard window.attachedSheet == nil, controller.requestForceQuit(rowID) else { return }
        let alert = make(title: title, message: message)

        // Esc cancels while this sheet is the one on screen, whatever language Cancel is written in.
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak window] event in
            guard event.keyCode == 53, let window, let sheet = window.attachedSheet, sheet === alert.window else {
                return event
            }
            window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
            return nil
        }
        // The row's process may exit while the sheet is up; then there is nothing left to confirm.
        let watch = Task { @MainActor [weak window] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let window, let sheet = window.attachedSheet, sheet === alert.window else { continue }
                if controller.state(for: rowID) != .confirming {
                    window.endSheet(sheet, returnCode: .cancel)
                }
            }
        }

        alert.beginSheetModal(for: window) { response in
            if let monitor { NSEvent.removeMonitor(monitor) }
            watch.cancel()
            if response == .alertSecondButtonReturn {
                controller.confirmForceQuit(rowID)
            } else {
                controller.cancelForceQuit(rowID)
            }
        }
    }
}
