/// One point of a chart history: a time and a value. A nil value is a gap (a pending or failed
/// sample), never a zero.
public struct HistorySample<Value: Sendable & Equatable>: Sendable, Equatable {
    /// Seconds on any monotone clock; only differences matter.
    public var time: Double
    public var value: Value?

    public init(time: Double, value: Value?) {
        self.time = time
        self.value = value
    }
}

/// The in-memory history behind one window chart (WIN-02, D-06, D-07).
///
/// Time-trimmed, not count-trimmed (RESEARCH Pattern 4): a sample stays while it is at most
/// `trimAge` older than the newest one, so five minutes stay five minutes when Low Power Mode
/// doubles the sampling cadence. The 5 s of slack over `span` keeps the sample just left of the
/// left edge, so the line enters the plot instead of starting inside it. `capacity` is a hard
/// bound on top of that (T-03-06). Samples keep arrival order; equal timestamps stay in the order
/// they arrived.
public struct HistoryBuffer<Value: Sendable & Equatable>: Sendable, Equatable {
    /// What a chart shows: the 300 s ending at the newest sample.
    public static var span: Double { 300 }
    /// How far behind the newest sample a sample is kept.
    public static var trimAge: Double { 305 }
    /// The most samples ever held.
    public static var capacity: Int { 400 }

    public private(set) var samples: [HistorySample<Value>] = []

    public init() {}

    /// The time of the newest sample, nil while empty.
    public var latestTime: Double? { samples.last?.time }

    /// Adds a sample (a nil value is a gap), then drops what is older than `trimAge` relative to
    /// it and what exceeds `capacity`, oldest first.
    public mutating func append(time: Double, value: Value?) {
        samples.append(HistorySample(time: time, value: value))
        let cutoff = time - Self.trimAge
        if let first = samples.firstIndex(where: { $0.time >= cutoff }), first > 0 {
            samples.removeFirst(first)
        }
        if samples.count > Self.capacity {
            samples.removeFirst(samples.count - Self.capacity)
        }
    }

    /// Discards everything: the window closed (D-06).
    public mutating func removeAll() {
        samples.removeAll()
    }
}

/// Two stacked series sampled together (CPU: user at the base, system above it).
public struct SeriesPair: Sendable, Equatable {
    public var first: Double
    public var second: Double

    public init(first: Double, second: Double) {
        self.first = first
        self.second = second
    }
}

/// A contiguous run of present samples that a chart draws as one connected series. Swift Charts
/// cannot plot an `Optional` in this SDK, so a gap is a break between runs, each with its own
/// `series:` value (RESEARCH Pattern 4).
public struct ChartRun<Value: Sendable & Equatable, Key: Sendable & Equatable>: Identifiable, Sendable, Equatable {
    public var id: Int
    public var key: Key
    public var samples: [HistorySample<Value>]

    public init(id: Int, key: Key, samples: [HistorySample<Value>]) {
        self.id = id
        self.key = key
        self.samples = samples
    }
}

/// Splits a history into the runs a chart draws (RESEARCH Pattern 4).
public enum ChartSegments {
    /// A run ends at a nil value, at a time gap above `maxGap`, and at a change of `key`. On a key
    /// change the new run begins with a copy of the previous run's last sample, so two segments of
    /// different keys touch instead of leaving a hole. Every sample in a run has a value.
    public static func runs<Value: Sendable & Equatable, Key: Sendable & Equatable>(
        _ samples: [HistorySample<Value>], maxGap: Double, key: (Value) -> Key
    ) -> [ChartRun<Value, Key>] {
        var runs: [ChartRun<Value, Key>] = []
        var current: [HistorySample<Value>] = []
        var currentKey: Key?

        func flush() {
            guard let currentKey, !current.isEmpty else { return }
            runs.append(ChartRun(id: runs.count, key: currentKey, samples: current))
        }

        for sample in samples {
            guard let value = sample.value else {
                flush()
                current = []
                currentKey = nil
                continue
            }
            let sampleKey = key(value)
            if let last = current.last, let runKey = currentKey {
                if sample.time - last.time > maxGap {
                    flush()
                    current = [sample]
                    currentKey = sampleKey
                } else if sampleKey != runKey {
                    flush()
                    current = [last, sample]
                    currentKey = sampleKey
                } else {
                    current.append(sample)
                }
            } else {
                current = [sample]
                currentKey = sampleKey
            }
        }
        flush()
        return runs
    }

    /// The same split without a key: gaps and nils only.
    public static func runs<Value: Sendable & Equatable>(
        _ samples: [HistorySample<Value>], maxGap: Double
    ) -> [ChartRun<Value, Int>] {
        runs(samples, maxGap: maxGap, key: { _ in 0 })
    }
}

/// The fixed time axis of a window chart (D-07).
public enum ChartTimeAxis {
    /// Gridline times counted back from the domain `end`, oldest first, so they slide with the
    /// data. A fixed minute stride would snap to wall-clock minutes and jump (RESEARCH Pattern 4).
    public static func gridTimes(end: Double, span: Double = 300, step: Double = 60) -> [Double] {
        guard step > 0, span > 0 else { return [end] }
        let count = Int((span / step).rounded(.down))
        return (0...count).map { end - span + Double($0) * step }
    }

    /// The two labelled ends: the left edge ("5 min ago") and the right edge ("Now").
    public static func ends(end: Double, span: Double = 300) -> [Double] {
        [end - span, end]
    }
}
