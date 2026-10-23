import Foundation

/// Opens the place where the user allows Metr's menu bar item (D-16).
///
/// Both URLs are compile-time constants with no user-controlled parts (T-01-15). The deep link
/// targets the Control Center settings extension; whether it lands on the Menu Bar pane is
/// unverified on macOS 26 (RESEARCH A7) and cannot be detected in code, so the caller treats any
/// outcome other than `.deepLink` as "tell the user the path in words".
public enum MenuBarSettingsLink {
    public static let deepLink = URL(
        string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension")!
    public static let systemSettingsApp = URL(fileURLWithPath: "/System/Applications/System Settings.app")

    public enum Outcome: Sendable, Equatable {
        /// The deep link was accepted.
        case deepLink
        /// The deep link was refused but System Settings itself opened.
        case systemSettings
        /// Nothing opened.
        case failed
    }

    /// Tries the deep link first, then System Settings itself. `opener` returns whether the URL
    /// was opened (for example `NSWorkspace.shared.open`).
    public static func open(using opener: (URL) -> Bool) -> Outcome {
        if opener(deepLink) { return .deepLink }
        if opener(systemSettingsApp) { return .systemSettings }
        return .failed
    }
}
