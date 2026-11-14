import Foundation

/// The one line of status the Open at login control can show under its switch (D-04, D-13).
/// It is the control's own status line, not a third setting (D-02): it appears only while the
/// projection carries a message and changes nothing by itself.
public enum LoginItemMessage: Sendable, Equatable {
    /// macOS holds the registration disabled until the user allows Metr in System Settings.
    case approval
    /// The last request failed, or the status is one Metr does not know.
    case failure
    /// Metr runs from outside /Applications, so it cannot be turned on there (D-13).
    case location
}

/// What the Open at login switch shows, as a pure function of the system's raw status
/// (`SMAppService.Status`: 0 notRegistered, 1 enabled, 2 requiresApproval, 3 notFound), whether the
/// last action failed, and whether Metr runs from /Applications. Nothing is stored: the switch is a
/// projection of what macOS holds, so it can never claim On while the system has Metr disabled (D-04).
public struct LoginItemProjection: Sendable, Equatable {
    public let isOn: Bool
    public let isEnabled: Bool
    public let message: LoginItemMessage?

    public init(isOn: Bool, isEnabled: Bool, message: LoginItemMessage?) {
        self.isOn = isOn
        self.isEnabled = isEnabled
        self.message = message
    }

    /// Precedence: outside /Applications the location line wins (it names the real way out); then
    /// `.requiresApproval` shows the approval line even when the action also threw; an unknown or
    /// `.notFound` raw value is Off with the failure line.
    public static func project(rawStatus: Int, actionFailed: Bool, inApplications: Bool) -> LoginItemProjection {
        let isOn = rawStatus == 1
        if !inApplications {
            // An existing registration can still be turned off, never a new one made (D-13).
            return LoginItemProjection(isOn: isOn, isEnabled: isOn, message: .location)
        }
        switch rawStatus {
        case 0:
            return LoginItemProjection(isOn: false, isEnabled: true, message: actionFailed ? .failure : nil)
        case 1:
            return LoginItemProjection(isOn: true, isEnabled: true, message: actionFailed ? .failure : nil)
        case 2:
            return LoginItemProjection(isOn: false, isEnabled: true, message: .approval)
        default:
            return LoginItemProjection(isOn: false, isEnabled: true, message: .failure)
        }
    }
}

/// The one rule for "Metr runs from /Applications" (D-13). Settings uses it for the switch and the
/// install-location class of the move offer reuses it, so the two can never disagree.
public enum ApplicationsFolder {
    /// True only for a bundle path under `/Applications/`. App Translocation, a mounted DMG,
    /// Downloads and every development path are outside.
    public static func contains(bundlePath: String) -> Bool {
        bundlePath.hasPrefix("/Applications/")
    }
}

/// What a request from the switch asks the system to do.
public enum LoginItemAction: Sendable, Equatable {
    case register
    case unregister
    case none

    /// Never register outside /Applications (D-13): the copy would not persist, and the user would
    /// not be told. A request to turn off always unregisters.
    public static func decide(requestOn: Bool, inApplications: Bool) -> LoginItemAction {
        if requestOn { return inApplications ? .register : .none }
        return .unregister
    }
}
