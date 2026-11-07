/// One point of a chart history: a time and a value. A nil value is a gap (a pending or failed
/// sample), never a zero.
public struct HistorySample<Value: Sendable & Equatable>: Sendable, Equatable {
    public var time: Double
    public var value: Value?

    public init(time: Double, value: Value?) {
        self.time = time
        self.value = value
    }
}

/// STUB for the RED commit: the API compiles but does not trim, cap, split or space anything.
public struct HistoryBuffer<Value: Sendable & Equatable>: Sendable, Equatable {
    public static var span: Double { 300 }
    public static var trimAge: Double { 305 }
    public static var capacity: Int { 400 }

    public private(set) var samples: [HistorySample<Value>] = []

    public init() {}

    public var latestTime: Double? { samples.last?.time }

    public mutating func append(time: Double, value: Value?) {
        samples.append(HistorySample(time: time, value: value))
    }

    public mutating func removeAll() {}
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

/// A contiguous run of present samples that a chart draws as one connected series.
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

public enum ChartSegments {
    public static func runs<Value: Sendable & Equatable, Key: Sendable & Equatable>(
        _ samples: [HistorySample<Value>], maxGap: Double, key: (Value) -> Key
    ) -> [ChartRun<Value, Key>] {
        []
    }

    public static func runs<Value: Sendable & Equatable>(
        _ samples: [HistorySample<Value>], maxGap: Double
    ) -> [ChartRun<Value, Int>] {
        []
    }
}

public enum ChartTimeAxis {
    public static func gridTimes(end: Double, span: Double = 300, step: Double = 60) -> [Double] { [] }
    public static func ends(end: Double, span: Double = 300) -> [Double] { [] }
}
