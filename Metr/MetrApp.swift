import SwiftUI

@main
struct MetrApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // No windows in Phase 1. The status item and popover are owned by AppDelegate.
        Settings { EmptyView() }
    }
}
