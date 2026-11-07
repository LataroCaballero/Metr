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

    /// The system's names for the core tiers (`hw.perflevelN.name`, perflevel 0 first), read once.
    /// Empty when the layout cannot be read. They name the cluster bars while CPU is not yet sampled.
    let coreLevelNames: [String] = CPUCollector.readLayout()?.levels.map(\.name) ?? []

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
        windowSessionActive = true
        windowSessionStart = time
    }

    /// Ends the session when the window closes: recording stops and every buffer is discarded.
    func endWindowSession() {
        clearHistory()
        windowSessionActive = false
        windowSessionStart = nil
        DebugHooks.log("history cleared")
    }

    private func clearHistory() {
        cpuHistory.removeAll()
    }

    func apply(_ batch: MetricsBatch, at time: Double = Date.now.timeIntervalSinceReferenceDate) {
        if let reading = batch.cpu {
            // A baseline-only sample after launch or wake is .pending: keep the last real
            // value until the primed one arrives, so the ring never flashes to a track.
            if reading == .pending, cpu.value != nil {
                // keep
            } else {
                cpu = reading
            }
            recordCPUHistory(reading, at: time)
        }
        if let reading = batch.memory {
            memory = reading
        }
        if let reading = batch.disk {
            disk = reading
        }
        if let reading = batch.processes {
            processes = reading
            DebugHooks.log(Self.describe(processes: reading))
            for line in Self.describeProbes(reading, pids: DebugHooks.probePIDs) { DebugHooks.log(line) }
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
        DebugHooks.log("history cpu=\(cpuHistory.samples.count)")
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
