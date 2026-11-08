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
    /// Memory), CPU is user plus system time converted from mach absolute units, and the disk
    /// counters are `ri_diskio_bytesread` / `ri_diskio_byteswritten` from the same call (PROC-04).
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
            footprintBytes: info.ri_phys_footprint,
            diskReadBytes: info.ri_diskio_bytesread, diskWrittenBytes: info.ri_diskio_byteswritten)
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

/// Samples every process the machine shows. Own-uid processes come from libproc; other-uid and
/// root processes are merged from a streamed top (`TopSnapshotSource`, owner decision Q1).
/// Confined to the sampler queue like `CPUCollector`; not Sendable.
///
/// Memory is the physical footprint, never RSS. CPU is percent of one core and can exceed 100 (D-11). The
/// first reading of an identity has memory and a nil CPU; CPU is known from the second on (D-20).
/// Everything kept per process is keyed by identity and pruned to the processes alive at each
/// sample, so the bookkeeping is bounded by the live process set (T-02-09).
public final class ProcessCollector {
    private struct Tracked {
        var cpuNanos: UInt64
        var wall: UInt64
        /// The last CPU percent measured over a full window; carried through short windows.
        var lastCPU: Double?
        /// The disk counters at the last full window, and the rates measured over it (PROC-04).
        /// They live here, beside the CPU baseline, so `reset()` drops them with it and no rate
        /// spans a sleep. A nil rate is not measured yet, never a zero.
        var diskReadBytes: UInt64 = 0
        var diskWrittenBytes: UInt64 = 0
        var lastDiskRead: Double?
        var lastDiskWrite: Double?
        var path: String?
    }

    private let sources: ProcessSources
    private let top: (any TopSnapshotSource)?
    private let minimumCPUWindowNanos: UInt64
    private var tracked: [ProcessIdentity: Tracked] = [:]
    private var sequence: UInt64 = 0
    private var cpuReadySeen = false
    /// Monotonic time of the last attempt to start top; a failed source waits `topRetryNanos`
    /// from it before the next one (T-02-16).
    private var lastTopStart: UInt64?
    private static let topRetryNanos: UInt64 = 10_000_000_000

    /// A CPU window shorter than `minimumCPUWindowNanos` is noise: the identity keeps its last
    /// value and its baseline, so the next full window is measured from the older reading.
    public init(
        sources: ProcessSources = .live, top: (any TopSnapshotSource)? = nil,
        minimumCPUWindowNanos: UInt64 = 500_000_000
    ) {
        self.sources = sources
        self.top = top
        self.minimumCPUWindowNanos = minimumCPUWindowNanos
    }

    /// How many identities hold a baseline and a cached path. Bounded by the live process set.
    var trackedIdentityCount: Int { tracked.count }

    /// Own-uid processes from libproc and other-uid processes from top. `.unavailable` when the
    /// kernel table could not be read, never an empty list standing in for a failure.
    public func sample() -> Reading<ProcessSnapshot> {
        guard let entries = sources.listAll() else { return .unavailable }
        let now = sources.now()
        startTopIfNeeded(now: now)
        let block = top?.latest()
        var samples: [ProcessSample] = []
        samples.reserveCapacity(entries.count / 2)
        var seen = Set<ProcessIdentity>()
        seen.reserveCapacity(entries.count)
        var anyOwnCPU = false
        for entry in entries {
            let pid = entry.identity.pid
            if entry.uid == sources.selfUID {
                // A process that exited between the table read and now has no usage: skip it.
                guard let usage = sources.usage(pid) else { continue }
                seen.insert(entry.identity)
                var item: Tracked
                var cpu: Double?
                if let known = tracked[entry.identity] {
                    item = known
                    if now > known.wall, now - known.wall >= minimumCPUWindowNanos {
                        let used = usage.cpuNanos >= known.cpuNanos ? usage.cpuNanos - known.cpuNanos : 0
                        let seconds = Double(now - known.wall) / 1e9
                        cpu = Double(used) / Double(now - known.wall) * 100
                        item.cpuNanos = usage.cpuNanos
                        item.wall = now
                        item.lastCPU = cpu
                        // Disk rates share the CPU window. A counter that went down (a restarted
                        // accounting, a wrap) is not a rate: nil for this window, rebased.
                        item.lastDiskRead = Self.rate(
                            from: known.diskReadBytes, to: usage.diskReadBytes, seconds: seconds)
                        item.lastDiskWrite = Self.rate(
                            from: known.diskWrittenBytes, to: usage.diskWrittenBytes, seconds: seconds)
                        item.diskReadBytes = usage.diskReadBytes
                        item.diskWrittenBytes = usage.diskWrittenBytes
                    } else {
                        cpu = known.lastCPU
                    }
                } else {
                    // First sight: a baseline, and the path is resolved once for this identity.
                    item = Tracked(
                        cpuNanos: usage.cpuNanos, wall: now, lastCPU: nil,
                        diskReadBytes: usage.diskReadBytes, diskWrittenBytes: usage.diskWrittenBytes,
                        path: sources.path(pid))
                }
                if cpu != nil { anyOwnCPU = true }
                tracked[entry.identity] = item
                if isOwnTopChild(entry, path: item.path) { continue }
                samples.append(
                    ProcessSample(
                        identity: entry.identity, ppid: entry.ppid, uid: entry.uid,
                        path: item.path, command: entry.command,
                        cpuPercent: cpu, footprintBytes: usage.footprintBytes,
                        diskReadPerSec: item.lastDiskRead, diskWritePerSec: item.lastDiskWrite))
            } else {
                // Another user's process: libproc cannot read it, top can. The path is still
                // resolved once so root-owned .app bundles group like user apps (owner decision Q5).
                seen.insert(entry.identity)
                let path: String?
                if let known = tracked[entry.identity] {
                    path = known.path
                } else {
                    path = sources.path(pid)
                    tracked[entry.identity] = Tracked(cpuNanos: 0, wall: now, lastCPU: nil, path: path)
                }
                if isOwnTopChild(entry, path: path) { continue }
                // A row is applied only to a process that started before the block's sampling
                // window began; a later holder of the pid waits for the next block (T-02-15).
                guard let block, let row = block.rows[pid],
                    entry.identity.startMicros < block.notBeforeMicros
                else { continue }
                samples.append(
                    ProcessSample(
                        identity: entry.identity, ppid: entry.ppid, uid: entry.uid,
                        path: path, command: entry.command,
                        cpuPercent: block.cpuValid ? row.cpuPercent : nil,
                        footprintBytes: row.footprintBytes))
            }
        }
        // Every seen identity is tracked, so equal counts mean equal sets.
        if tracked.count > seen.count {
            tracked = tracked.filter { seen.contains($0.key) }
        }
        if anyOwnCPU { cpuReadySeen = true }
        let otherUsers = otherUsersState(block: block)
        let cpuReady = cpuReadySeen && (otherUsers == .unavailable || block?.cpuValid == true)
        sequence += 1
        return .value(
            ProcessSnapshot(sequence: sequence, processes: samples, cpuReady: cpuReady, otherUsers: otherUsers))
    }

    private func startTopIfNeeded(now: UInt64) {
        guard let top else { return }
        switch top.state {
        case .stopped:
            top.start()
            lastTopStart = now
        case .failed:
            // Own rows keep ranking meanwhile. A source first seen failed waits a full interval too.
            guard let last = lastTopStart else {
                lastTopStart = now
                return
            }
            if now >= last, now - last >= Self.topRetryNanos {
                top.start()
                lastTopStart = now
            }
        case .starting, .running:
            break
        }
    }

    private func otherUsersState(block: TopBlock?) -> OtherUsersState {
        guard let top else { return .unavailable }
        switch top.state {
        case .failed: return .unavailable
        case .running: return block != nil ? .available : .pending
        case .stopped, .starting: return .pending
        }
    }

    /// Metr's own top child (a child of this process running /usr/bin/top) must not rank.
    private func isOwnTopChild(_ entry: ProcessEntry, path: String?) -> Bool {
        entry.ppid == sources.selfPID && path == "/usr/bin/top"
    }

    /// Bytes per second between two cumulative counters, nil when the counter went backwards.
    private static func rate(from before: UInt64, to after: UInt64, seconds: Double) -> Double? {
        guard after >= before, seconds > 0 else { return nil }
        return Double(after - before) / seconds
    }

    /// Forgets every baseline and cached path: the next sample is a baseline again. That includes
    /// the disk counters and rates, so the first reading after a sleep has no disk rate and the
    /// first one measured spans only time after the reset (PROC-04; the phase's wake policy).
    public func reset() {
        tracked.removeAll()
        cpuReadySeen = false
        top?.stop()
    }
}
