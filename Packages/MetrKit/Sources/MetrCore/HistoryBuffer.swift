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

/// One memory sample of the window chart: the fill the ring shows (100 - kern.memorystatus_level,
/// the same signal as the ring, D-08) and the pressure level the sample is tinted by.
public struct MemoryHistoryValue: Sendable, Equatable {
    public var fill: Double
    public var pressure: MemoryPressure

    public init(fill: Double, pressure: MemoryPressure) {
        self.fill = fill
        self.pressure = pressure
    }

    public init(_ reading: MemoryReading) {
        self.init(fill: reading.ringFill, pressure: reading.pressure)
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

/// Which sample a hovering pointer is at.
public enum ChartReadout {
    /// The present sample nearest to `time`; a tie goes to the earlier sample, gaps are skipped, nil
    /// for an empty or all-gap history.
    public static func nearest<Value: Sendable & Equatable>(
        time: Double, in samples: [HistorySample<Value>]
    ) -> HistorySample<Value>? {
        var best: HistorySample<Value>?
        var bestDistance = Double.infinity
        // Samples arrive in time order, so a strict comparison keeps the earlier one on a tie.
        for sample in samples where sample.value != nil {
            let distance = abs(sample.time - time)
            if distance < bestDistance {
                best = sample
                bestDistance = distance
            }
        }
        return best
    }
}

/// The four numbers VoiceOver hears for a chart: the latest value and the range and mean of the
/// window.
public struct ChartSummary: Sendable, Equatable {
    public var now: Double
    public var lowest: Double
    public var highest: Double
    public var average: Double

    public init(now: Double, lowest: Double, highest: Double, average: Double) {
        self.now = now
        self.lowest = lowest
        self.highest = highest
        self.average = average
    }

    /// Over the present values, in order; the latest present value is `now`. nil when there is none.
    public static func make(_ values: [Double?]) -> ChartSummary? {
        var latest: Double?
        var lowest = Double.infinity
        var highest = -Double.infinity
        var sum = 0.0
        var count = 0
        for case let value? in values {
            latest = value
            lowest = min(lowest, value)
            highest = max(highest, value)
            sum += value
            count += 1
        }
        guard let latest, count > 0 else { return nil }
        return ChartSummary(now: latest, lowest: lowest, highest: highest, average: sum / Double(count))
    }
}

/// The symmetric Y scale of a rate chart (Network, and Disk read / write).
public enum RateAxis {
    /// The largest rate the chart's axis shows on each side of zero: the smallest 1, 2 or 5 times a
    /// power of ten at or above the larger of `peak` and `floor`. The steps keep the tick labels round
    /// ("2 MB/s", not "1.7 MB/s"), and the floor stops idle noise from filling the plot. A peak that
    /// is not a finite number is no peak.
    public static func ceiling(peak: Double, floor: Double) -> Double {
        // A floor that cannot anchor a scale falls back to one byte per second.
        let base = floor.isFinite && floor > 0 ? floor : 1
        let target = peak.isFinite ? max(peak, base) : base
        var decade = 1.0
        // Decades from below: a loop, so no logarithm rounding can put a step on the wrong side.
        while decade * 10 <= target { decade *= 10 }
        while decade > target { decade /= 10 }
        for step in [1.0, 2.0, 5.0, 10.0] where decade * step >= target {
            return decade * step
        }
        return decade * 10
    }
}
