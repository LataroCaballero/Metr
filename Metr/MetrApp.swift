import MetrCore
import SwiftUI

@main
struct MetrApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The status item, the panel and the windows are owned by AppDelegate (they are AppKit hosted,
        // see WindowController and SettingsWindowController, D-25). The only scene is the required empty
        // one: it is never shown, and the real Settings item is the command below.
        Settings { EmptyView() }
            .commands {
                MetrCommands(
                    model: appDelegate.windowModel, open: { appDelegate.showWindow($0) },
                    showSettings: { appDelegate.showSettings() })
            }
    }
}

/// The main-menu items of the Metr window (D-01, WIN-01). They reach the AppKit-owned window
/// through `open`, so they work the same as the panel button and the right-click item.
struct MetrCommands: Commands {
    let model: WindowModel
    let open: (WindowRoute) -> Void
    let showSettings: () -> Void

    var body: some Commands {
        // Metr > Settings… (Cmd-,). Replaces the system item, which would open the empty scene above
        // (RESEARCH Pitfall 3); same title, shortcut and position.
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { showSettings() }
                .keyboardShortcut(",")
        }

        // File > Close (Cmd-W): the system closes the key window, which is the Metr window.
        CommandGroup(after: .newItem) {
            Button("Close") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w")
        }

        // Window > Metr
        CommandGroup(before: .windowList) {
            Button("Metr") { open(.lastVisited) }
                .keyboardShortcut("0")
        }

        // View > CPU ... Processes, Cmd-1 to Cmd-6 in sidebar order (Activity Monitor convention).
        CommandGroup(after: .sidebar) {
            ForEach(Array(WindowSection.allCases.enumerated()), id: \.element) { index, section in
                Button(section.title) { open(.section(section)) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                    .disabled(!model.isOpen)
            }
        }
    }
}
