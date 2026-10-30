import Dispatch

/// Demand-driven scheduler. Owns the single `TickSource`, recomputes a `SamplingPlan` whenever
/// demand, suspension or the constrained flag changes, and delivers the due metrics to `onTick`.
///
/// All state is confined to the injected queue. Public methods hop onto it.
public final class SamplingScheduler: @unchecked Sendable {
    public typealias TickHandler = @Sendable (_ due: Set<Metric>, _ elapsed: Double, _ priming: Bool) -> Void

    private let queue: DispatchQueue
    private let ticks: TickSource
    private let cadenceScale: Double

    private var demand: Set<DemandConsumer> = []
    private var suspendReasons: Set<SuspendReason> = []
    private var constrained = false
    private var plan: SamplingPlan
    private var lastSampled: [Metric: Double] = [:]
    private var lastDelivery: Double?
    private var onTick: TickHandler?
    private var onBaseline: (@Sendable () -> Void)?
    private var started = false
    /// True from a start/resume until the priming fire has been delivered.
    private var primePending = false

    /// Called on the queue whenever the plan changes. Set before `start`.
    public var onPlanChange: (@Sendable (SamplingPlan) -> Void)?

    public init(queue: DispatchQueue, cadenceScale: Double = 1) {
        self.queue = queue
        self.cadenceScale = cadenceScale
        self.ticks = TickSource(queue: queue)
        self.plan = SamplingPlan.make(
            demand: [], suspended: false, constrained: false, cadenceScale: cadenceScale)
    }

    // MARK: Public API (hops onto the queue)

    /// `onBaseline` is called on the queue right before the scheduler takes a fresh baseline
    /// (start, or a resume that re-primes). Never called for a resume that leaves the plan
    /// unchanged.
    public func start(onTick: @escaping TickHandler, onBaseline: (@Sendable () -> Void)? = nil) {
        queue.async {
            self.onTick = onTick
            self.onBaseline = onBaseline
            self.started = true
            self.plan = self.makePlan()
            self.onPlanChange?(self.plan)
            self.beginRunning()
        }
    }

    public func setDemand(_ newDemand: Set<DemandConsumer>) {
        queue.async {
            self.demand = newDemand
            guard self.started else { return }
            self.replan(restartTimer: true, deliverDue: true)
        }
    }

    public func suspend(reason: SuspendReason) {
        queue.async {
            self.suspendReasons.insert(reason)
            guard self.started else { return }
            self.replan(restartTimer: false, deliverDue: false)
        }
    }

    public func resume(reason: SuspendReason) {
        queue.async {
            self.suspendReasons.remove(reason)
            guard self.started else { return }
            self.replan(restartTimer: true, deliverDue: false, prime: self.suspendReasons.isEmpty)
        }
    }

    public func setConstrained(_ value: Bool) {
        queue.async {
            guard self.constrained != value else { return }
            self.constrained = value
            guard self.started else { return }
            self.replan(restartTimer: true, deliverDue: false)
        }
    }

    public func stop() {
        queue.async {
            self.started = false
            self.ticks.stop()
        }
    }

    // MARK: Queue-confined internals

    private static func uptime() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1e9
    }

    private func makePlan() -> SamplingPlan {
        SamplingPlan.make(
            demand: demand, suspended: !suspendReasons.isEmpty,
            constrained: constrained, cadenceScale: cadenceScale)
    }

    /// Recomputes the plan; on a change publishes it and (re)schedules the timer.
    private func replan(restartTimer: Bool, deliverDue: Bool, prime: Bool = false) {
        let newPlan = makePlan()
        guard newPlan != plan else { return }
        plan = newPlan
        // A metric that leaves the plan forgets when it was last read, so one that re-enters
        // (the process list when the panel reopens) is due at once instead of waiting out a
        // cadence measured from before the close (RESEARCH Pitfall 5).
        lastSampled = lastSampled.filter { plan.cadence[$0.key] != nil }
        onPlanChange?(plan)
        guard plan.baseInterval != nil else {
            primePending = false
            ticks.stop()
            return
        }
        if prime {
            beginRunning()
            return
        }
        if restartTimer { startTimer() }
        if deliverDue {
            let now = Self.uptime()
            let due = plan.dueMetrics(now: now, lastSampled: lastSampled)
            if !due.isEmpty {
                deliver(due: due, elapsed: lastDelivery.map { now - $0 } ?? 0, priming: false)
            }
        }
    }

    /// Start or resume: an immediate tick of the plan's own metrics takes the baselines, then a
    /// short priming fire (cpu only) delivers the first real CPU delta before the normal cadence.
    /// Only metrics in the plan are delivered, so an idle start or wake never reads processes (D-20).
    private func beginRunning() {
        onBaseline?()
        primePending = true
        deliver(due: Set(plan.cadence.keys), elapsed: 0, priming: false)
        startTimer()
    }

    private func startTimer() {
        guard let base = plan.baseInterval else { return }
        if primePending {
            // The priming fire is a one-shot on its own short timer: TickSource scales leeway by
            // the interval, so reusing the 2 s idle timer would let it slip by up to 0.4 s.
            // The first fire restarts the timer at the tier's base interval.
            ticks.start(interval: SamplingPlan.primingDelay * plan.cadenceScale) { [self] dt in
                fire(dt: dt)
            }
        } else {
            ticks.start(interval: base) { [self] dt in
                fire(dt: dt)
            }
        }
    }

    private func fire(dt: Double) {
        guard started, suspendReasons.isEmpty, plan.baseInterval != nil else { return }
        if primePending {
            primePending = false
            deliver(due: [.cpu], elapsed: dt, priming: true)
            startTimer()
            return
        }
        let due = plan.dueMetrics(now: Self.uptime(), lastSampled: lastSampled)
        guard !due.isEmpty else { return }
        deliver(due: due, elapsed: dt, priming: false)
    }

    private func deliver(due: Set<Metric>, elapsed: Double, priming: Bool) {
        let now = Self.uptime()
        for metric in due { lastSampled[metric] = now }
        lastDelivery = now
        onTick?(due, elapsed, priming)
    }
}
