import Darwin
import Foundation
import MetrCore

/// Where the collector reads from. The live set reads the kernel; tests inject fakes.
public struct ProcessSources: Sendable {
    public var selfPID: Int32
    public var selfUID: UInt32
    /// Every process in the kernel table (identity only), or nil when the read failed.
    public var listAll: @Sendable () -> [ProcessEntry]?
    /// Cumulative CPU and footprint of one pid, or nil (the process exited, or is not ours to read).
    public var usage: @Sendable (Int32) -> ProcessUsage?
    /// The executable path of one pid, or nil.
    public var path: @Sendable (Int32) -> String?
    /// Monotonic nanoseconds; the same clock the scheduler uses.
    public var now: @Sendable () -> UInt64

    public init(
        selfPID: Int32, selfUID: UInt32,
        listAll: @escaping @Sendable () -> [ProcessEntry]?,
        usage: @escaping @Sendable (Int32) -> ProcessUsage?,
        path: @escaping @Sendable (Int32) -> String?,
        now: @escaping @Sendable () -> UInt64
    ) {
        self.selfPID = selfPID
        self.selfUID = selfUID
        self.listAll = listAll
        self.usage = usage
        self.path = path
        self.now = now
    }

    public static var live: ProcessSources {
        ProcessSources(
            selfPID: getpid(), selfUID: getuid(),
            listAll: { ProcessKernel.listAll() },
            usage: { ProcessKernel.usage(of: $0) },
            path: { ProcessKernel.path(of: $0) },
            now: { DispatchTime.now().uptimeNanoseconds })
    }
}

/// The real reads. Each call allocates its own buffer and frees it before returning, so nothing
/// accumulates between samples (T-02-09).
enum ProcessKernel {
    /// `sysctl(CTL_KERN, KERN_PROC, KERN_PROC_ALL)`: identity for every process, root ones included
    /// (RESEARCH Pattern 1). The size query and the read race with process creation, so the buffer
    /// has 64 entries of headroom and a failed read retries once.
    static func listAll() -> [ProcessEntry]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        for _ in 0..<2 {
            var size = 0
            guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
            let capacity = size / MemoryLayout<kinfo_proc>.stride + 64
            var table = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
            size = capacity * MemoryLayout<kinfo_proc>.stride
            let rc = table.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) }
            if rc != 0 {
                if errno == ENOMEM { continue }
                return nil
            }
            let count = size / MemoryLayout<kinfo_proc>.stride
            var entries: [ProcessEntry] = []
            entries.reserveCapacity(count)
            for i in 0..<count {
                var info = table[i]
                let pid = info.kp_proc.p_pid
                let start = info.kp_proc.p_un.__p_starttime
                let command = withUnsafeBytes(of: &info.kp_proc.p_comm) { raw -> String in
                    let bytes = raw.prefix { $0 != 0 }
                    return String(decoding: bytes, as: UTF8.self)
                }
                entries.append(
                    ProcessEntry(
                        identity: ProcessIdentity(
                            pid: pid, startMicros: Int64(start.tv_sec) * 1_000_000 + Int64(start.tv_usec)),
                        ppid: info.kp_eproc.e_ppid,
                        uid: info.kp_eproc.e_ucred.cr_uid,
                        command: command))
            }
            return entries
        }
        return nil
    }

    /// `proc_pid_rusage(RUSAGE_INFO_V4)`: footprint is `ri_phys_footprint` (Activity Monitor's
    /// Memory), CPU is user plus system time converted from mach absolute units.
    static func usage(of pid: Int32) -> ProcessUsage? {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard rc == 0 else { return nil }
        let (ticks, overflow) = info.ri_user_time.addingReportingOverflow(info.ri_system_time)
        return ProcessUsage(
            cpuNanos: overflow ? UInt64.max : machTicksToNanos(ticks),
            footprintBytes: info.ri_phys_footprint)
    }

    static func path(of pid: Int32) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE is 4 * MAXPATHLEN; the macro is not importable into Swift.
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    /// Read once: the timebase does not change while the app runs (125/3 on Apple Silicon).
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info.denom == 0 ? mach_timebase_info_data_t(numer: 1, denom: 1) : info
    }()

    /// `ticks * numer / denom` without overflowing for any realistic counter.
    static func machTicksToNanos(_ ticks: UInt64) -> UInt64 {
        let numer = UInt64(timebase.numer)
        let denom = UInt64(timebase.denom)
        let whole = (ticks / denom).multipliedReportingOverflow(by: numer)
        let rest = ((ticks % denom) * numer) / denom
        if whole.overflow { return UInt64.max }
        let (sum, overflow) = whole.partialValue.addingReportingOverflow(rest)
        return overflow ? UInt64.max : sum
    }
}

/// Samples the user's own processes. Confined to the sampler queue like `CPUCollector`; not Sendable.
///
/// Memory is the physical footprint. CPU is percent of one core and can exceed 100 (D-11). The
/// first reading of an identity has memory and a nil CPU; CPU is known from the second on (D-20).
public final class ProcessCollector {
    private struct Baseline {
        var cpuNanos: UInt64
        var wall: UInt64
    }

    private let sources: ProcessSources
    private var baselines: [ProcessIdentity: Baseline] = [:]
    private var sequence: UInt64 = 0
    private var cpuReadySeen = false

    public init(sources: ProcessSources = .live) {
        self.sources = sources
    }

    /// Own-uid processes only; other users arrive in plan 02-06. `.unavailable` when the kernel
    /// table could not be read, never an empty list standing in for a failure.
    public func sample() -> Reading<ProcessSnapshot> {
        guard let entries = sources.listAll() else { return .unavailable }
        let now = sources.now()
        var samples: [ProcessSample] = []
        samples.reserveCapacity(entries.count / 2)
        var anyCPU = false
        for entry in entries where entry.uid == sources.selfUID {
            let pid = entry.identity.pid
            // A process that exited between the table read and now has no usage: skip it.
            guard let usage = sources.usage(pid) else { continue }
            var cpu: Double?
            if let base = baselines[entry.identity], now > base.wall {
                let used = usage.cpuNanos >= base.cpuNanos ? usage.cpuNanos - base.cpuNanos : 0
                cpu = Double(used) / Double(now - base.wall) * 100
                anyCPU = true
            }
            baselines[entry.identity] = Baseline(cpuNanos: usage.cpuNanos, wall: now)
            samples.append(
                ProcessSample(
                    identity: entry.identity, ppid: entry.ppid, uid: entry.uid,
                    path: sources.path(pid), command: entry.command,
                    cpuPercent: cpu, footprintBytes: usage.footprintBytes))
        }
        if anyCPU { cpuReadySeen = true }
        sequence += 1
        return .value(ProcessSnapshot(sequence: sequence, processes: samples, cpuReady: cpuReadySeen))
    }

    /// Forgets every baseline: the next sample is a baseline again.
    public func reset() {
        baselines.removeAll()
        cpuReadySeen = false
    }
}
