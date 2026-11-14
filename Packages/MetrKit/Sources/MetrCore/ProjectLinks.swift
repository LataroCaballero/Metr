import Foundation

/// The two addresses Metr's About panel links to (D-14, D-15, D-22). Both are compile-time constants
/// with no user-controlled part, and both are opened in the browser by the system: Metr itself never
/// makes a request to either.
public enum ProjectLinks {
    /// The source code.
    public static let repository = URL(string: "https://github.com/LataroCaballero/Metr")!

    /// The releases page, where the update check lives (a link, never a request from the app).
    public static let releases = repository.appendingPathComponent("releases")
}
