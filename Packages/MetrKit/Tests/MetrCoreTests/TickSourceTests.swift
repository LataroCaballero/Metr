import Dispatch
import Synchronization
import Testing

@testable import MetrCore

final class TickRecorder: Sendable {
    let values = Mutex<[Double]>([])
    func add(_ v: Double) { values.withLock { $0.append(v) } }
    var snapshot: [Double] { values.withLock { $0 } }
}

@Suite struct TickSourceTests {
    @Test func intervalProducesRepeatedTicksNearTheInterval() async throws {
        let queue = DispatchQueue(label: "test.tick.interval", qos: .utility)
        let source = TickSource(queue: queue)
        let rec = TickRecorder()
        source.start(interval: 0.05) { rec.add($0) }
        try await Task.sleep(for: .milliseconds(400))
        source.stop()
        let values = rec.snapshot
        #expect(values.count >= 4)
        let sorted = values.sorted()
        let median = sorted[sorted.count / 2]
        #expect(median > 0.025 && median < 0.1, "median elapsed \(median)")
    }

    @Test func firstFireAfterDelaysTheFirstTick() async throws {
        let queue = DispatchQueue(label: "test.tick.first", qos: .utility)
        let source = TickSource(queue: queue)
        let rec = TickRecorder()
        source.start(interval: 0.5, firstFireAfter: 0.15) { rec.add($0) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(rec.snapshot.isEmpty)
        try await Task.sleep(for: .milliseconds(300))
        source.stop()
        let values = rec.snapshot
        #expect(values.count == 1)
        if let first = values.first { #expect(first >= 0.12, "first elapsed \(first)") }
    }

    @Test func stopSilencesTheTimer() async throws {
        let queue = DispatchQueue(label: "test.tick.stop", qos: .utility)
        let source = TickSource(queue: queue)
        let rec = TickRecorder()
        source.start(interval: 0.04) { rec.add($0) }
        try await Task.sleep(for: .milliseconds(150))
        source.stop()
        try await Task.sleep(for: .milliseconds(60))
        let countAtStop = rec.snapshot.count
        #expect(countAtStop > 0)
        try await Task.sleep(for: .milliseconds(200))
        #expect(rec.snapshot.count == countAtStop)
    }
}
