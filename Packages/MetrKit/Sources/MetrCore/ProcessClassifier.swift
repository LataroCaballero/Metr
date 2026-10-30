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
public enum ProcessClassifier {
    public static let protectedPaths: Set<String> = []

    public static func kind(pid: Int32, uid: UInt32, path: String?, selfPID: Int32, selfUID: UInt32) -> ProcessKind {
        .own
    }

    public static func kind(of group: ProcessGroup, selfPID: Int32, selfUID: UInt32) -> ProcessKind {
        .own
    }
}
