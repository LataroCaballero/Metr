import Testing

@testable import MetrCore

@Suite struct HistoryBufferTests {
    // MARK: Buffer

    @Test func keepsArrivalOrder() {
        var buffer = HistoryBuffer<Int>()
        buffer.append(time: 1, value: 10)
        buffer.append(time: 2, value: 20)
        buffer.append(time: 2, value: 21)
        buffer.append(time: 3, value: 30)
        #expect(buffer.samples.map(\.time) == [1, 2, 2, 3])
        // The two samples at time 2 keep their insertion order (stable).
        #expect(buffer.samples.map(\.value) == [10, 20, 21, 30])
    }

    @Test func trimsByTime() {
        var buffer = HistoryBuffer<Int>()
        for t in 0...310 { buffer.append(time: Double(t), value: t) }
        #expect(buffer.samples.first?.time == 5)
        #expect(buffer.latestTime == 310)
        // A sample exactly 300 s older than the newest stays on the chart.
        #expect(buffer.samples.contains { $0.time == 10 })
        // Older than 305 s is gone.
        #expect(!buffer.samples.contains { $0.time == 4 })
    }

    @Test func capsAt400() {
        var buffer = HistoryBuffer<Int>()
        for i in 0..<450 { buffer.append(time: Double(i) * 0.1, value: i) }
        #expect(buffer.samples.count == 400)
        #expect(buffer.samples.last?.value == 449)
        #expect(buffer.samples.first?.value == 50)
    }

    @Test func removeAllEmpties() {
        var buffer = HistoryBuffer<Int>()
        buffer.append(time: 1, value: 1)
        buffer.append(time: 2, value: nil)
        buffer.removeAll()
        #expect(buffer.samples.isEmpty)
        #expect(buffer.latestTime == nil)
    }

    // MARK: Runs

    private func samples(_ values: [Int?], times: [Double]) -> [HistorySample<Int>] {
        zip(times, values).map { HistorySample(time: $0, value: $1) }
    }

    @Test func runsSplitAtGapsAndNils() {
        let withNil = ChartSegments.runs(samples([1, 2, nil, 3], times: [0, 1, 2, 3]), maxGap: 2.5)
        #expect(withNil.count == 2)
        guard withNil.count == 2 else { return }
        #expect(withNil[0].samples.map(\.time) == [0, 1])
        #expect(withNil[1].samples.map(\.time) == [3])

        let withGap = ChartSegments.runs(samples([1, 2, 3], times: [0, 1, 5]), maxGap: 2.5)
        #expect(withGap.count == 2)
        guard withGap.count == 2 else { return }
        #expect(withGap[0].samples.map(\.time) == [0, 1])
        #expect(withGap[1].samples.map(\.time) == [5])

        let single = ChartSegments.runs(samples([7], times: [4]), maxGap: 2.5)
        #expect(single.count == 1)
        guard single.count == 1 else { return }
        #expect(single[0].samples.count == 1)

        let empty = ChartSegments.runs([HistorySample<Int>](), maxGap: 2.5)
        #expect(empty.isEmpty)
    }

    @Test func runsSplitOnKeyChangeAndTouch() {
        let input: [HistorySample<String>] = [
            HistorySample(time: 0, value: "a"), HistorySample(time: 1, value: "a"),
            HistorySample(time: 2, value: "b"), HistorySample(time: 3, value: "b"),
        ]
        let runs = ChartSegments.runs(input, maxGap: 2.5, key: { $0 })
        #expect(runs.count == 2)
        guard runs.count == 2 else { return }
        #expect(runs[0].key == "a")
        #expect(runs[0].samples.map(\.time) == [0, 1])
        #expect(runs[1].key == "b")
        // The second run starts with a copy of the last `a` sample, so the segments touch.
        #expect(runs[1].samples.map(\.time) == [1, 2, 3])
        #expect(runs[1].samples.first?.value == "a")
    }

    // MARK: Memory runs

    private func memoryReading(free: Int, _ pressure: MemoryPressure) -> MemoryReading {
        MemoryReading(
            usedBytes: 8_000_000_000, totalBytes: 16_000_000_000, swapUsedBytes: 0, freePercent: free,
            pressure: pressure)
    }

    private func memorySamples(_ levels: [MemoryPressure?]) -> [HistorySample<MemoryHistoryValue>] {
        levels.enumerated().map { index, level in
            HistorySample(
                time: Double(index), value: level.map { MemoryHistoryValue(memoryReading(free: 40, $0)) })
        }
    }

    @Test func memoryRunsByLevel() {
        let samples = memorySamples([.normal, .normal, .warn, .warn, .normal])
        let runs = ChartSegments.runs(samples, maxGap: 3.5, key: { $0.pressure })
        #expect(runs.count == 3)
        guard runs.count == 3 else { return }
        #expect(runs.map(\.key) == [.normal, .warn, .normal])
        #expect(runs[0].samples.map(\.time) == [0, 1])
        // Each new level begins with the previous run's last sample, so the segments touch.
        #expect(runs[1].samples.map(\.time) == [1, 2, 3])
        #expect(runs[2].samples.map(\.time) == [3, 4])
    }

    @Test func memoryNilSplitsRegardlessOfKey() {
        let samples = memorySamples([.normal, nil, .normal])
        let runs = ChartSegments.runs(samples, maxGap: 3.5, key: { $0.pressure })
        #expect(runs.count == 2)
        guard runs.count == 2 else { return }
        #expect(runs[0].samples.map(\.time) == [0])
        #expect(runs[1].samples.map(\.time) == [2])
        // The same key on both sides does not join them: no sample is invented across the gap.
        #expect(runs.map(\.key) == [.normal, .normal])
    }

    @Test func memoryValueIsTheRingSignal() {
        let value = MemoryHistoryValue(memoryReading(free: 40, .warn))
        #expect(value.fill == 0.6)
        #expect(value.pressure == .warn)
    }

    // MARK: Axis

    @Test func gridTimes() {
        #expect(ChartTimeAxis.gridTimes(end: 1000) == [700, 760, 820, 880, 940, 1000])
        #expect(ChartTimeAxis.ends(end: 1000) == [700, 1000])
    }

    // MARK: Readout and summary

    @Test func readoutPicksTheNearestSample() {
        let samples = [
            HistorySample(time: 1, value: 10), HistorySample(time: 2, value: 20),
            HistorySample(time: 3, value: 30),
        ]
        #expect(ChartReadout.nearest(time: 2.4, in: samples)?.time == 2)
        // Exactly between two samples: the earlier one.
        #expect(ChartReadout.nearest(time: 2.5, in: samples)?.time == 2)
        #expect(ChartReadout.nearest(time: 2.6, in: samples)?.time == 3)
        // Outside the history: the end it is nearest to.
        #expect(ChartReadout.nearest(time: -5, in: samples)?.time == 1)
        #expect(ChartReadout.nearest(time: 99, in: samples)?.time == 3)
        #expect(ChartReadout.nearest(time: 2, in: [HistorySample<Int>]()) == nil)

        // A gap is not a sample: the pointer over it reads the nearest present one, the earlier on a tie.
        let withGap = [
            HistorySample(time: 1, value: 10), HistorySample(time: 2, value: nil),
            HistorySample(time: 3, value: 30),
        ]
        #expect(ChartReadout.nearest(time: 2, in: withGap)?.time == 1)
        #expect(ChartReadout.nearest(time: 2.2, in: withGap)?.time == 3)
        #expect(ChartReadout.nearest(time: 2, in: [HistorySample<Int>(time: 1, value: nil)]) == nil)
    }

    @Test func summaryIgnoresGaps() {
        let summary = ChartSummary.make([0.2, nil, 0.6, 0.4])
        #expect(summary?.now == 0.4)
        #expect(summary?.lowest == 0.2)
        #expect(summary?.highest == 0.6)
        #expect(abs((summary?.average ?? -1) - 0.4) < 1e-9)
        // The latest present value is `now`, even when the newest sample is a gap.
        #expect(ChartSummary.make([0.5, 0.1, nil])?.now == 0.1)
        #expect(ChartSummary.make([nil, nil]) == nil)
        #expect(ChartSummary.make([]) == nil)
    }

    // MARK: Rate axis

    @Test func rateAxisRoundsUp() {
        #expect(RateAxis.ceiling(peak: 0, floor: 100_000) == 100_000)
        #expect(RateAxis.ceiling(peak: 120_000, floor: 100_000) == 200_000)
        #expect(RateAxis.ceiling(peak: 1_400_000, floor: 100_000) == 2_000_000)
        #expect(RateAxis.ceiling(peak: 3_000_000, floor: 100_000) == 5_000_000)
        #expect(RateAxis.ceiling(peak: 7_000_000, floor: 100_000) == 10_000_000)
        // A peak exactly on a step stays on it.
        #expect(RateAxis.ceiling(peak: 2_000_000, floor: 100_000) == 2_000_000)
        // The floor wins over a smaller peak, and rounds up like any other value.
        #expect(RateAxis.ceiling(peak: 500_000, floor: 1_000_000) == 1_000_000)
    }

    @Test func rateAxisIgnoresNonsense() {
        // A NaN or infinite peak is no peak: the floor stays, so a bad sample never blows up the scale.
        #expect(RateAxis.ceiling(peak: .nan, floor: 100_000) == 100_000)
        #expect(RateAxis.ceiling(peak: .infinity, floor: 100_000) == 100_000)
        #expect(RateAxis.ceiling(peak: -5, floor: 100_000) == 100_000)
    }
}
