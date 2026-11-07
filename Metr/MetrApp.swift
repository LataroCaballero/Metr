import MetrCore
import SwiftUI

@main
struct MetrApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The status item, the panel and the window are owned by AppDelegate (the window is AppKit
        // hosted, see WindowController). The only scene is the Settings placeholder, and its
        // menu item is removed below until Phase 4 gives it content.
        Settings { EmptyView() }
            .commands {
                MetrCommands(model: appDelegate.windowModel, open: { appDelegate.showWindow($0) })
            }
    }
}

/// The main-menu items of the Metr window (D-01, WIN-01). They reach the AppKit-owned window
/// through `open`, so they work the same as the panel button and the right-click item.
struct MetrCommands: Commands {
    let model: WindowModel
    let open: (WindowRoute) -> Void

    var body: some Commands {
        // No Settings... item until Phase 4, so Cmd-, cannot open an empty window (RESEARCH Pitfall 3).
        CommandGroup(replacing: .appSettings) {}

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
