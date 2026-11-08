import Foundation
import MetrCore
import MetrSystem
import Observation

/// MainActor-owned snapshot of the latest readings. Fed by `AppDelegate.makeBatchSink`.
@MainActor
@Observable
final class MetricsStore {
    private(set) var cpu: Reading<CPUReading> = .pending
    private(set) var memory: Reading<MemoryReading> = .pending
    private(set) var disk: Reading<DiskReading> = .pending
    /// The user's processes, sampled only while the panel or window is open (D-20). `.pending`
    /// until the first reading and again after the last close.
    private(set) var processes: Reading<ProcessSnapshot> = .pending
    /// The aggregate network rate over physical interfaces (NET-01), sampled only while the window is
    /// open. `.pending` until the second sample and again after the window closes, so a reopened
    /// window never shows a stale rate.
    private(set) var network: Reading<NetworkReading> = .pending
    /// The GPU (GPU-01), sampled only while the window is open. `.pending` until the first reading
    /// and again after the window closes, so a reopened window never shows a stale value.
    private(set) var gpu: Reading<GPUReading> = .pending
    /// System-wide disk read and write speed (WIN-02, D-08), sampled only while the window is open.
    /// `.pending` until the second sample and again after the window closes, so a reopened window
    /// never shows a stale rate.
    private(set) var diskIO: Reading<DiskIOReading> = .pending
    /// Every real local and external volume, one entry per container (DISK-01), read only while the
    /// window is open. `.pending` until the first reading and again after the window closes.
    private(set) var volumes: Reading<[VolumeInfo]> = .pending
    /// Disk tint with its 1-point hysteresis (D-03). One state shared by the glyph and the panel.
    private(set) var diskTint: RingTint = .none

    /// True from `beginWindowSession` to `endWindowSession`: the window is open. History is
    /// recorded only while it is true (D-06); nothing is recorded, and nothing is on disk, otherwise.
    private(set) var windowSessionActive = false
    /// When the current window session began, on the same clock as the samples. The chart's empty
    /// axes end here until the first sample arrives.
    private(set) var windowSessionStart: Double?
    /// The CPU history of the open window: first = user, second = system, both on the whole-Mac
    /// scale. One stored property per series, so `@Observable` invalidates per chart.
    private(set) var cpuHistory = HistoryBuffer<SeriesPair>()
    /// The GPU history of the open window: utilization 0...1, a nil value is a gap.
    private(set) var gpuHistory = HistoryBuffer<Double>()
    /// The memory history of the open window: the ring's fill and the pressure level that tints it.
    /// A nil value is a gap.
    private(set) var memoryHistory = HistoryBuffer<MemoryHistoryValue>()
    /// The network history of the open window: first = download, second = upload, both in bytes per
    /// second. A pending or failed read is a gap, never a zero.
    private(set) var networkHistory = HistoryBuffer<SeriesPair>()
    /// The disk I/O history of the open window: first = read, second = write, both in bytes per
    /// second. A pending or failed read is a gap, never a zero.
    private(set) var diskIOHistory = HistoryBuffer<SeriesPair>()
    /// Bytes received and sent since the window opened (D-18): the sum of every reading's byte
    /// deltas, not a rate times the cadence, so they match what netstat counted. Zero outside a
    /// window session.
    private(set) var networkSessionDown: UInt64 = 0
    private(set) var networkSessionUp: UInt64 = 0
    /// Network values seen this session, to log the totals every fifth one.
    @ObservationIgnored private var networkValuesThisSession = 0

    /// The system's core tiers (`hw.perflevelN`, perflevel 0 first) with their core counts, read once.
    /// Empty when the layout cannot be read. They name the cluster bars, in the panel and in the
    /// window, while CPU is not yet sampled.
    let coreLevels: [CoreLevel] = CPUCollector.readLayout()?.levels ?? []

    /// The tier names alone, for the panel.
    var coreLevelNames: [String] { coreLevels.map(\.name) }

    /// The Mac's thermal state (PANEL-05). Read once at init and on the system's change
    /// notification; never polled (D-19).
    private(set) var thermal: ThermalLevel = ThermalReader.current()

    /// Token of the thermal change observer; kept so the block stays registered.
    @ObservationIgnored private var thermalToken: (any NSObjectProtocol)?

    init() {
        // ProcessInfo can post from any thread, and a MainActor selector invoked off-main traps
        // under Swift 6, so the observer is a block on the main queue (T-01-08).
        thermalToken = NotificationCenter.default.addObserver(
            forName: ThermalReader.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyThermal(ThermalReader.current()) }
        }
    }

    /// Applies a new thermal level and logs it when it changed. DEBUG log only.
    func applyThermal(_ level: ThermalLevel) {
        guard level != thermal else { return }
        thermal = level
        DebugHooks.log("thermal=\(level.rawValue)")
    }

    /// Memory tint straight from the pressure level (D-01); it has no hysteresis of its own.
    var memoryTint: RingTint { TintLogic.memory(memory.value?.pressure) }

    /// True once no metric is still `.pending`. An `.unavailable` reading counts as answered.
    var isReadyForPanel: Bool {
        cpu != .pending && memory != .pending && disk != .pending
    }

    /// Called after every applied batch. Not observed; the status item redraws from it.
    @ObservationIgnored var didApply: (() -> Void)?

    /// Starts a window session: every buffer is empty and recording begins (D-06).
    func beginWindowSession(at time: Double = Date.now.timeIntervalSinceReferenceDate) {
        clearHistory()
        resetNetworkTotals()
        windowSessionActive = true
        windowSessionStart = time
    }

    /// Ends the session when the window closes: recording stops and every buffer is discarded.
    func endWindowSession() {
        clearHistory()
        // The final totals, for scripts/verify/net-vs-netstat.sh (numbers only, T-03-40).
        if networkValuesThisSession > 0 {
            DebugHooks.log("net total down=\(networkSessionDown) up=\(networkSessionUp)")
        }
        resetNetworkTotals()
        // Window-only readings do not outlive the window (D-06).
        gpu = .pending
        network = .pending
        diskIO = .pending
        volumes = .pending
        windowSessionActive = false
        windowSessionStart = nil
        DebugHooks.log("history cleared")
    }

    private func resetNetworkTotals() {
        networkSessionDown = 0
        networkSessionUp = 0
        networkValuesThisSession = 0
    }

    private func clearHistory() {
        cpuHistory.removeAll()
        gpuHistory.removeAll()
        memoryHistory.removeAll()
        networkHistory.removeAll()
        diskIOHistory.removeAll()
    }

    func apply(_ batch: MetricsBatch, at time: Double = Date.now.timeIntervalSinceReferenceDate) {
        var recorded = false
        if let reading = batch.cpu {
            // A baseline-only sample after launch or wake is .pending: keep the last real
            // value until the primed one arrives, so the ring never flashes to a track.
            if reading == .pending, cpu.value != nil {
                // keep
            } else {
                cpu = reading
            }
            recordCPUHistory(reading, at: time)
            recorded = true
        }
        if let reading = batch.memory {
            memory = reading
            if windowSessionActive {
                // The same signal as the ring (D-08); a pending or failed read is a gap.
                memoryHistory.append(time: time, value: reading.value.map(MemoryHistoryValue.init))
                recorded = true
            }
        }
        if let reading = batch.disk {
            disk = reading
        }
        if let reading = batch.network {
            // A baseline-only sample after a wake or a rebase is .pending: keep the last real
            // rate until the next one arrives, like CPU. The window closing resets it explicitly.
            if reading == .pending, network.value != nil {
                // keep
            } else {
                network = reading
            }
            DebugHooks.log(Self.describe(network: reading))
            if windowSessionActive {
                // The rates of this sample, or a gap: a baseline-only or failed read plots nothing.
                networkHistory.append(
                    time: time,
                    value: reading.value.map { SeriesPair(first: $0.downBytesPerSec, second: $0.upBytesPerSec) })
                recorded = true
                accumulateNetworkTotals(reading)
            }
        }
        if let reading = batch.processes {
            processes = reading
            DebugHooks.log(Self.describe(processes: reading))
            for line in Self.describeProbes(reading, pids: DebugHooks.probePIDs) { DebugHooks.log(line) }
        }
        if let reading = batch.gpu {
            gpu = reading
            DebugHooks.log(Self.describe(gpu: reading))
            if windowSessionActive {
                gpuHistory.append(time: time, value: reading.value?.utilization)
                recorded = true
            }
        }
        if let reading = batch.diskIO {
            // A baseline-only sample after a wake or a rebase is .pending: keep the last real rate
            // until the next one arrives, like CPU. The window closing resets it explicitly.
            if reading == .pending, diskIO.value != nil {
                // keep
            } else {
                diskIO = reading
            }
            DebugHooks.log(Self.describe(diskIO: reading))
            if windowSessionActive {
                // The rates of this sample, or a gap: a baseline-only or failed read plots nothing.
                diskIOHistory.append(
                    time: time,
                    value: reading.value.map { SeriesPair(first: $0.readBytesPerSec, second: $0.writeBytesPerSec) })
                recorded = true
            }
        }
        if let reading = batch.volumes {
            volumes = reading
            for line in Self.describe(volumes: reading) { DebugHooks.log(line) }
        }
        if recorded, windowSessionActive {
            // Counts only (T-03-07).
            DebugHooks.log(
                "history cpu=\(cpuHistory.samples.count) mem=\(memoryHistory.samples.count)"
                    + " gpu=\(gpuHistory.samples.count) net=\(networkHistory.samples.count)"
                    + " diskio=\(diskIOHistory.samples.count)")
        }
        diskTint = TintLogic.disk(freeFraction: disk.value?.freeFraction, previous: diskTint)
        didApply?()
        DebugHooks.log(Self.describe(cpu: cpu, memory: memory, disk: disk, thermal: thermal))
    }

    /// Appends one CPU sample while the window is open. A pending or failed read is a gap, never a
    /// zero, and nothing is back-filled after a wake. DEBUG log: the count only (T-03-07).
    private func recordCPUHistory(_ reading: Reading<CPUReading>, at time: Double) {
        guard windowSessionActive else { return }
        let pair = reading.value.map { SeriesPair(first: $0.user, second: $0.system) }
        cpuHistory.append(time: time, value: pair)
    }

    /// Adds a value reading's interval bytes to the session totals (saturating), and logs both totals
    /// every fifth value for scripts/verify/net-vs-netstat.sh. Numbers only, DEBUG log only (T-03-40).
    private func accumulateNetworkTotals(_ reading: Reading<NetworkReading>) {
        guard case .value(let value) = reading else { return }
        networkSessionDown = networkSessionDown.addingReportingOverflow(value.downBytes).overflow
            ? .max : networkSessionDown + value.downBytes
        networkSessionUp = networkSessionUp.addingReportingOverflow(value.upBytes).overflow
            ? .max : networkSessionUp + value.upBytes
        networkValuesThisSession += 1
        if networkValuesThisSession % 5 == 0 {
            DebugHooks.log("net total down=\(networkSessionDown) up=\(networkSessionUp)")
        }
    }

    /// Byte counts and a flag only, never an interface or service name: `net down=1200 up=300 primary=0`
    /// or the pending / unavailable word. DEBUG log only (T-03-15).
    private static func describe(network reading: Reading<NetworkReading>) -> String {
        switch reading {
        case .pending: return "net pending"
        case .unavailable: return "net unavailable"
        case .value(let value):
            return "net down=\(Int64(value.downBytesPerSec.rounded())) up=\(Int64(value.upBytesPerSec.rounded()))"
                + " primary=\(value.hasPrimary ? 1 : 0)"
        }
    }

    /// Whole bytes per second only: `diskio r=1200 w=300`, or the pending / unavailable word.
    /// DEBUG log only.
    private static func describe(diskIO reading: Reading<DiskIOReading>) -> String {
        switch reading {
        case .pending: return "diskio pending"
        case .unavailable: return "diskio unavailable"
        case .value(let value):
            return "diskio r=\(Int64(value.readBytesPerSec.rounded())) w=\(Int64(value.writeBytesPerSec.rounded()))"
        }
    }

    /// Roles, counts and byte figures only, never a volume name or a mount path (T-03-19):
    /// `volumes n=2 startup=1 internal=0 external=1`, then `volume role=startup total=245107195904 free=11504558144`
    /// per row (`-` for a figure the volume did not report), or the pending / unavailable word.
    /// DEBUG log only.
    private static func describe(volumes reading: Reading<[VolumeInfo]>) -> [String] {
        switch reading {
        case .pending: return ["volumes pending"]
        case .unavailable: return ["volumes unavailable"]
        case .value(let rows):
            func count(_ role: VolumeRole) -> Int { rows.filter { $0.role == role }.count }
            var lines = [
                "volumes n=\(rows.count) startup=\(count(.startup)) internal=\(count(.internal))"
                    + " external=\(count(.external))"
            ]
            for row in rows {
                let total = row.totalBytes.map { String($0) } ?? "-"
                let free = row.freeBytes.map { String($0) } ?? "-"
                lines.append("volume role=\(row.role.rawValue) total=\(total) free=\(free)")
            }
            return lines
        }
    }

    /// Numbers only: `gpu util=0.45 cores=8`, or the pending / unavailable word. DEBUG log only (T-03-11).
    private static func describe(gpu reading: Reading<GPUReading>) -> String {
        switch reading {
        case .pending: return "gpu pending"
        case .unavailable: return "gpu unavailable"
        case .value(let value):
            let cores = value.coreCount.map { String($0) } ?? "-"
            return "gpu util=\(String(format: "%.2f", value.utilization)) cores=\(cores)"
        }
    }

    /// Counts and a ready flag only: never a process name, path or command line (T-02-08).
    private static func describe(processes reading: Reading<ProcessSnapshot>) -> String {
        switch reading {
        case .pending: return "procs pending"
        case .unavailable: return "procs unavailable"
        case .value(let snapshot):
            let me = getuid()
            let own = snapshot.processes.filter { $0.uid == me }.count
            return "procs n=\(snapshot.processes.count) own=\(own)"
                + " other=\(snapshot.processes.count - own) ready=\(snapshot.cpuReady ? 1 : 0)"
                + " sys=\(snapshot.otherUsers.rawValue)"
        }
    }

    /// One line per probe pid present in the batch (DEBUG, opt-in): pids and numbers only, never a
    /// name or a path. For scripts/verify/procs-vs-top.sh.
    private static func describeProbes(_ reading: Reading<ProcessSnapshot>, pids: Set<Int32>) -> [String] {
        guard !pids.isEmpty, case .value(let snapshot) = reading else { return [] }
        return snapshot.processes.filter { pids.contains($0.identity.pid) }.map { sample in
            let mem = sample.footprintBytes.map { String($0) } ?? "-"
            let cpu = sample.cpuPercent.map { String(format: "%.1f", $0) } ?? "pending"
            return "probe pid=\(sample.identity.pid) mem=\(mem) cpu=\(cpu)"
        }
    }

    /// Pending and unavailable readings are named, never printed as a number.
    private static func describe(
        cpu: Reading<CPUReading>, memory: Reading<MemoryReading>, disk: Reading<DiskReading>,
        thermal: ThermalLevel
    ) -> String {
        "batch cpu=\(text(cpu.value.map(\.total), cpu)) mem=\(text(memory.value?.ringFill, memory))"
            + " disk=\(text(disk.value?.usedFraction, disk))"
            + " diskfree=\(freeBytesText(disk))"
            // PANEL-01: the CPU split, for scripts/verify/cpu-vs-top.sh. DEBUG log only.
            + " cpuuser=\(text(cpu.value.map(\.user), cpu)) cpusys=\(text(cpu.value.map(\.system), cpu))"
            + " clusters=\(clustersText(cpu))"
            // PANEL-05: the thermal level, for scripts/verify/run-debug.sh. DEBUG log only.
            + " thermal=\(thermal.rawValue)"
    }

    /// `Name:0.00,Name:0.00`, `none` when the value has no clusters, or the pending / unavailable word.
    /// Tier names are system names, not personal data. DEBUG log only.
    private static func clustersText(_ cpu: Reading<CPUReading>) -> String {
        if let value = cpu.value {
            if value.clusters.isEmpty { return "none" }
            return value.clusters.map { "\($0.name):" + String(format: "%.2f", $0.usage) }.joined(separator: ",")
        }
        if case .unavailable = cpu { return "unavailable" }
        return "pending"
    }

    /// Whole bytes free, for scripts/verify/disk-live.sh. DEBUG log only.
    private static func freeBytesText(_ disk: Reading<DiskReading>) -> String {
        if let free = disk.value?.availableBytes { return String(free) }
        if case .unavailable = disk { return "unavailable" }
        return "pending"
    }

    private static func text<V>(_ number: Double?, _ reading: Reading<V>) -> String {
        if let number { return String(format: "%.2f", number) }
        if case .unavailable = reading { return "unavailable" }
        return "pending"
    }
}
