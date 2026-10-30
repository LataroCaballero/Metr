import Darwin
import Foundation
import MetrCore

/// The live side of `ActionGuard` (PROC-05, PROC-07): re-reading one process from the kernel, the
/// signal-0 probe and the signal itself. This file is the only place in Metr that calls the
/// signal system call (T-02-26, enforced by a grep in the plan's acceptance criteria).
public enum ProcessLookup {
    /// One process by pid: `sysctl(CTL_KERN, KERN_PROC, KERN_PROC_PID)` into a single `kinfo_proc`.
    /// A reply of size 0, a failed call or a different pid means the process is gone (RESEARCH
    /// "Single-pid identity re-read"). The identity is the pid plus `p_starttime`, the same pair
    /// `ProcessSources.live.listAll` builds, so a row's identity compares equal to the re-read.
    public static func live(_ pid: Int32) -> LiveProcess? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let rc = sysctl(&mib, 4, &info, &size, nil, 0)
        guard rc == 0, size >= MemoryLayout<kinfo_proc>.stride, info.kp_proc.p_pid == pid else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return LiveProcess(
            identity: ProcessIdentity(
                pid: pid, startMicros: Int64(start.tv_sec) * 1_000_000 + Int64(start.tv_usec)),
            uid: info.kp_eproc.e_ucred.cr_uid,
            path: ProcessKernel.path(of: pid))
    }

    /// The signal-0 probe: the kernel checks permission and existence and delivers nothing.
    /// False for another user's and root's processes (EPERM) and for a process that is gone.
    public static func canSignal(_ pid: Int32) -> Bool {
        pid > 0 && kill(pid, 0) == 0
    }

    /// Delivers `signal`. Callers go through `ActionGuard.perform`, which re-verifies first.
    public static func send(_ pid: Int32, _ signal: Int32) -> Bool {
        pid > 0 && kill(pid, signal) == 0
    }
}

extension ActionGuard {
    /// The guard wired to this machine: this process's pid and uid, the live lookup, the probe and the signal.
    public static func system() -> ActionGuard {
        ActionGuard(
            selfPID: getpid(), selfUID: getuid(),
            lookup: { ProcessLookup.live($0) },
            canSignal: { ProcessLookup.canSignal($0) },
            send: { ProcessLookup.send($0, $1) })
    }
}
