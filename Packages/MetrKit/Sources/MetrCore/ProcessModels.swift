/// A process that cannot be confused with a later one that reuses its pid: the pid plus the
/// kernel's start time in microseconds since the epoch (RESEARCH Pattern 1). Every baseline,
/// cache and row key in the process pipeline uses this, never the bare pid (T-02-10).
public struct ProcessIdentity: Sendable, Hashable {
    public var pid: Int32
    public var startMicros: Int64

    public init(pid: Int32, startMicros: Int64) {
        self.pid = pid
        self.startMicros = startMicros
    }
}

/// One row of the kernel process table: who the process is, not what it uses.
public struct ProcessEntry: Sendable, Equatable {
    public var identity: ProcessIdentity
    public var ppid: Int32
    public var uid: UInt32
    /// The kernel's 16-character short name. A fallback only, for processes with no path.
    public var command: String

    public init(identity: ProcessIdentity, ppid: Int32, uid: UInt32, command: String) {
        self.identity = identity
        self.ppid = ppid
        self.uid = uid
        self.command = command
    }
}

/// Cumulative usage of one process at one instant.
public struct ProcessUsage: Sendable, Equatable {
    /// User plus system CPU time in nanoseconds, since the process started.
    public var cpuNanos: UInt64
    /// Physical footprint in bytes: what Activity Monitor calls Memory (D-11).
    public var footprintBytes: UInt64

    public init(cpuNanos: UInt64, footprintBytes: UInt64) {
        self.cpuNanos = cpuNanos
        self.footprintBytes = footprintBytes
    }
}

/// One process in a snapshot.
public struct ProcessSample: Sendable, Equatable {
    public var identity: ProcessIdentity
    public var ppid: Int32
    public var uid: UInt32
    /// The executable path, nil when the kernel would not give one.
    public var path: String?
    public var command: String
    /// Percent of ONE core, so a process busy on three cores reads about 300 (D-11).
    /// Nil is pending: CPU needs two readings (D-20). Never a fabricated zero.
    public var cpuPercent: Double?
    public var footprintBytes: UInt64?

    public init(
        identity: ProcessIdentity, ppid: Int32, uid: UInt32, path: String?, command: String,
        cpuPercent: Double?, footprintBytes: UInt64?
    ) {
        self.identity = identity
        self.ppid = ppid
        self.uid = uid
        self.path = path
        self.command = command
        self.cpuPercent = cpuPercent
        self.footprintBytes = footprintBytes
    }
}

/// Whether the other-users half of the process list could be read.
public enum OtherUsersState: String, Sendable, Equatable {
    case pending, available, unavailable
}

/// Everything one process pass saw.
public struct ProcessSnapshot: Sendable, Equatable {
    /// Increases by one per delivered snapshot; lets a consumer tell a new reading from a re-render.
    public var sequence: UInt64
    public var processes: [ProcessSample]
    /// True once CPU is known for at least one process (the second reading after an open, D-20).
    public var cpuReady: Bool
    /// Whether system and other-user processes are in `processes` (RED skeleton).
    public var otherUsers: OtherUsersState

    public init(
        sequence: UInt64, processes: [ProcessSample], cpuReady: Bool, otherUsers: OtherUsersState = .pending
    ) {
        self.sequence = sequence
        self.processes = processes
        self.cpuReady = cpuReady
        self.otherUsers = otherUsers
    }
}

/// The column the process list is ranked by.
public enum SortColumn: String, Sendable, Equatable {
    case cpu, memory
}
