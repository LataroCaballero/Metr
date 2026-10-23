import Foundation

/// Decides whether the first-launch welcome window may be presented (D-14, D-15).
///
/// The flag is written when the claim is made, which is when the window is first presented, so a
/// quit or a crash right after cannot cause a repeat. Nothing else in the app presents the window.
public struct FirstRunGate {
    public static let welcomeKey = "MetrDidPresentWelcome"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// True exactly once per preferences domain: the first call records the claim and returns true,
    /// every later call (also from another gate on the same domain) returns false.
    public func claimWelcomePresentation() -> Bool {
        if defaults.bool(forKey: Self.welcomeKey) { return false }
        defaults.set(true, forKey: Self.welcomeKey)
        return true
    }
}
