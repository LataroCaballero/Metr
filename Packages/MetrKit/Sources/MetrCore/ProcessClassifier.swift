/// Who owns a row, as far as the panel is concerned (PROC-01, D-09).
public enum ProcessKind: Sendable, Equatable {
    /// A process of the current user: the only kind whose actions can ever be enabled.
    case own
    /// pid 0 and 1, a protected system executable, or any service account (uid below 500).
    case system
    /// A process of another human user (uid 500 or above).
    case otherUser
    /// Metr itself.
    case metr
}

/// Classifies rows by trusted facts only (D-09; RESEARCH Pattern 6, Pitfall 13).
///
/// A process chooses its own name, but not its pid, its uid or the canonical path of its
/// executable, so decisions use those three and never a display name: a user-space binary called
/// `WindowServer` is an ordinary process.
///
/// The protected set is the roadmap list (launchd, WindowServer, loginwindow, kernel_task, Metr
/// itself) plus the service accounts. Finder, Dock, SystemUIServer and ControlCenter are
/// deliberately NOT protected: they relaunch on their own, as in Activity Monitor (owner decision
/// Q4, 2026-10-30). Plan 02-10's ActionGuard reuses this classifier and adds the signal-0 probe
/// (`kill(pid, 0)` failing with EPERM) on top, which only ever restricts further.
public enum ProcessClassifier {
    /// Canonical executable paths that are system even when they run as the user. kernel_task has
    /// no path (pid 0) and launchd is also pid 1; both are caught by pid first.
    public static let protectedPaths: Set<String> = [
        "/sbin/launchd",
        "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer",
        "/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow",
    ]

    /// Human accounts start at uid 500 (planner assumption A6, RESEARCH Pitfall 13); everything
    /// below is root or a service account such as `_windowserver` (88).
    private static let firstHumanUID: UInt32 = 500

    /// The kind of one process. Checked in this order: Metr's own pid, pid 0 and 1, a protected
    /// canonical path, a service-account uid, another user's uid; anything else is the user's own.
    public static func kind(
        pid: Int32, uid: UInt32, path: String?, selfPID: Int32, selfUID: UInt32
    ) -> ProcessKind {
        if pid == selfPID { return .metr }
        if pid <= 1 { return .system }
        if let path, protectedPaths.contains(path) { return .system }
        if uid < firstHumanUID { return .system }
        if uid != selfUID { return .otherUser }
        return .own
    }

    /// The kind of a row. A group is as protected as its main member; an app group with only
    /// helpers running takes the lowest-pid member's kind, so a root-owned bundle stays view-only.
    public static func kind(of group: ProcessGroup, selfPID: Int32, selfUID: UInt32) -> ProcessKind {
        guard let member = group.main ?? group.helpers.min(by: { $0.identity.pid < $1.identity.pid }) else {
            return .own
        }
        return kind(
            pid: member.identity.pid, uid: member.uid, path: member.path, selfPID: selfPID, selfUID: selfUID)
    }
}
