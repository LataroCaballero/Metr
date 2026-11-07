import Darwin
import Testing

import MetrCore

@testable import MetrSystem

@Suite struct NetworkCollectorTests {
    @Test func firstSampleIsPendingThenAValueOrPending() {
        let collector = NetworkCollector()
        guard case .pending = collector.sample() else {
            Issue.record("the first sample must store the baseline and be pending")
            return
        }
        usleep(50_000)  // a realistic interval, so a burst of traffic cannot read as an impossible rate
        switch collector.sample() {
        case .value(let reading):
            #expect(reading.downBytesPerSec >= 0)
            #expect(reading.upBytesPerSec >= 0)
            #expect(reading.downBytesPerSec <= NetworkMath.maximumBytesPerSecond)
            #expect(!reading.hasPrimary && reading.primaryInterface == nil)
        case .pending, .unavailable:
            Issue.record("a second sample over a live kernel read must be a value")
        }
    }

    @Test func resetBaselineMakesTheNextSamplePending() {
        let collector = NetworkCollector()
        _ = collector.sample()
        collector.resetBaseline()
        guard case .pending = collector.sample() else {
            Issue.record("a sample right after resetBaseline must be pending")
            return
        }
    }

    @Test func kernelReadFindsPhysicalInterfacesOnly() throws {
        let counters = try #require(NetworkCollector.readCounters())
        #expect(counters.received.keys.sorted() == counters.sent.keys.sorted())
    }

    /// T-03-12: a hostile or truncated buffer must stop the walk, never read past `length`.
    @Test func parseStopsOnZeroTruncatedAndShortRecords() {
        #expect(NetworkCollector.parse([], length: 0) == .init())
        #expect(NetworkCollector.parse([0, 0, 0, 0, 0, 0, 0, 0], length: 8) == .init())
        // Declares 200 bytes but only 16 are present.
        var truncated = [UInt8](repeating: 0, count: 16)
        truncated[0] = 200
        truncated[3] = 0x12
        #expect(NetworkCollector.parse(truncated, length: 16) == .init())
        // A short record of type IFINFO2 (smaller than if_msghdr2) is skipped, not read.
        var short = [UInt8](repeating: 0, count: 8)
        short[0] = 8
        short[3] = 0x12
        #expect(NetworkCollector.parse(short, length: 8) == .init())
    }
}
