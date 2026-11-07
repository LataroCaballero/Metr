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

    // MARK: Axis

    @Test func gridTimes() {
        #expect(ChartTimeAxis.gridTimes(end: 1000) == [700, 760, 820, 880, 940, 1000])
        #expect(ChartTimeAxis.ends(end: 1000) == [700, 1000])
    }
}
