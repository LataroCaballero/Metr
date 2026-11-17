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
        let clock = ContinuousClock()
        let began = clock.now
        source.start(interval: 0.5, firstFireAfter: 0.15) { rec.add($0) }
        try await Task.sleep(for: .milliseconds(100))
        // A loaded machine can oversleep; judge the snapshot against the time that really passed.
        let early = rec.snapshot
        let earlyElapsed = began.duration(to: clock.now)
        if earlyElapsed < .milliseconds(140) { #expect(early.isEmpty, "a tick arrived before the delay") }
        try await Task.sleep(for: .milliseconds(300))
        let values = rec.snapshot
        let lateElapsed = began.duration(to: clock.now)
        source.stop()
        #expect(!values.isEmpty)
        // The second tick is due at 0.65 s (0.15 + the 0.5 s interval); only before that is exactly one expected.
        if lateElapsed < .milliseconds(600) { #expect(values.count == 1) }
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
