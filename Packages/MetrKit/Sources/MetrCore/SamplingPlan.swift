/// A metric the sampler can collect on its own cadence. `processes` is last, so the log order
/// stays cpu,memory,disk,gpu,processes. `processes` exists only while the panel is open or the
/// window shows Processes (D-05, D-20). `gpu` is window-only (D-05): it is sampled while the window
/// is open, whatever section it shows, so its chart keeps filling, and never otherwise.
public enum Metric: String, Sendable, Hashable, CaseIterable {
    case cpu, memory, disk, gpu, processes
}

/// Who is asking for faster sampling. Only the popover delegate registers `.panel`, and it
/// switches the process list on. `.window` is registered by WindowController while the window is
/// open and samples the cheap metrics at the window cadence. `.windowProcesses` is registered
/// by WindowController only while Processes is the selected section and the window is not
/// minimized (D-05 and the owner's visibility decision of 2026-11-02: no occlusion gating);
/// it switches the process list on. With no process consumer, no process is read at all.
public enum DemandConsumer: String, Sendable, Hashable {
    case panel, window, windowProcesses
}

public enum SamplingTier: String, Sendable {
    case idle, panel, window, suspended
}

/// Why sampling is suspended. Reasons overlap (display sleep inside a system sleep),
/// so the scheduler keeps a set and resumes only when the set is empty.
public enum SuspendReason: String, Sendable, Hashable {
    case systemSleep, displaySleep, sessionInactive
}

/// Pure mapping from (demand, suspended, constrained) to per-metric cadences.
///
/// Cost basis (RESEARCH Pattern 2): a CPU+memory tick costs about 20 microseconds, but the
/// volume `resourceValues` disk read costs 16.6 ms, so disk never sits on the 1-2 s path.
public struct SamplingPlan: Sendable, Equatable {
    public var tier: SamplingTier
    /// Timer interval in seconds, or nil while suspended (the timer is cancelled).
    public var baseInterval: Double?
    /// Seconds between samples, per metric. Empty while suspended.
    public var cadence: [Metric: Double]
    public var constrained: Bool
    /// The clamped scale this plan was built with; scales the CPU window floor too.
    public var cadenceScale: Double

    // Tier table in seconds (starting values; FND-03 measurement sets the final budget).
    public static let idleCPUMemory = 2.0
    public static let idleDisk = 60.0
    public static let panelCPUMemory = 1.0
    public static let panelDisk = 10.0
    public static let windowCPUMemory = 1.0
    public static let windowDisk = 10.0
    public static let windowGPU = 1.0
    /// The roadmap's "2 s or slower" for the process list; absent from the idle tier (D-20).
    public static let panelProcesses = 2.0
    public static let windowProcesses = 2.0

    /// A CPU delta over a window shorter than this is noise, so CPU is not due sooner.
    public static let minimumCPUWindow = 0.5
    /// Delay between the baseline sample and the first real CPU value after start or resume.
    public static let primingDelay = 0.5
    public static let scaleRange: ClosedRange<Double> = 0.01...10

    public static func make(demand: Set<DemandConsumer>, suspended: Bool, constrained: Bool, cadenceScale: Double = 1)
        -> SamplingPlan
    {
        let scale = min(max(cadenceScale, scaleRange.lowerBound), scaleRange.upperBound)
        if suspended {
            return SamplingPlan(
                tier: .suspended, baseInterval: nil, cadence: [:],
                constrained: constrained, cadenceScale: scale)
        }
        let tier: SamplingTier
        let fast: Double
        let disk: Double
        let base: Double
        let processes: Double?
        if carriesWindow(demand) {
            (tier, fast, disk, base) = (.window, windowCPUMemory, windowDisk, 1)
            processes = carriesProcesses(demand) ? windowProcesses : nil
        } else if demand.contains(.panel) {
            (tier, fast, disk, base, processes) = (.panel, panelCPUMemory, panelDisk, 1, panelProcesses)
        } else {
            (tier, fast, disk, base, processes) = (.idle, idleCPUMemory, idleDisk, 2, nil)
        }
        let k = (constrained ? 2.0 : 1.0) * scale
        var cadence: [Metric: Double] = [.cpu: fast * k, .memory: fast * k, .disk: disk * k]
        if tier == .window { cadence[.gpu] = windowGPU * k }
        if let processes { cadence[.processes] = processes * k }
        return SamplingPlan(
            tier: tier,
            baseInterval: base * k,
            cadence: cadence,
            constrained: constrained,
            cadenceScale: scale)
    }

    /// True when the demand wants the process list: the panel, or the window showing Processes.
    public static func carriesProcesses(_ demand: Set<DemandConsumer>) -> Bool {
        demand.contains(.panel) || demand.contains(.windowProcesses)
    }

    /// True when the window tier applies: the window is open, whatever section it shows.
    public static func carriesWindow(_ demand: Set<DemandConsumer>) -> Bool {
        demand.contains(.window) || demand.contains(.windowProcesses)
    }

    /// Metrics whose last sample is old enough. Timer jitter is absorbed by treating a metric
    /// as due a quarter of the base interval early; CPU additionally needs a minimum window.
    public func dueMetrics(now: Double, lastSampled: [Metric: Double]) -> Set<Metric> {
        guard let base = baseInterval else { return [] }
        var due: Set<Metric> = []
        for (metric, cadence) in cadence {
            guard let last = lastSampled[metric] else {
                due.insert(metric)
                continue
            }
            let floor = metric == .cpu ? Self.minimumCPUWindow * cadenceScale : 0
            let threshold = max(cadence - 0.25 * base, floor)
            if now - last >= threshold { due.insert(metric) }
        }
        return due
    }
}
