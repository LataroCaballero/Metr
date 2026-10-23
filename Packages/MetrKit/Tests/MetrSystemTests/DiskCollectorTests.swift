import Foundation
import MetrCore
import Testing

@testable import MetrSystem

@Suite struct DiskCollectorTests {
    @Test func rootVolumeGivesSaneValue() throws {
        let reading = try #require(DiskCollector().sample().value)
        #expect(reading.totalBytes > 0)
        #expect(reading.availableBytes >= 0)
        #expect(reading.availableBytes <= reading.totalBytes)
    }

    @Test func usedPlusFreeIsOne() throws {
        let reading = try #require(DiskCollector().sample().value)
        #expect(abs(reading.usedFraction + reading.freeFraction - 1) < 1e-9)
        #expect((0.0...1.0).contains(reading.usedFraction))
    }

    @Test func nonexistentVolumeIsUnavailable() {
        let collector = DiskCollector(volume: URL(fileURLWithPath: "/Volumes/metr-does-not-exist-XYZ"))
        #expect(collector.sample() == .unavailable)
    }

    @Test func usedFractionClampsAndHandlesZeroTotal() {
        #expect(DiskReading(totalBytes: 100, availableBytes: 25).usedFraction == 0.75)
        #expect(DiskReading(totalBytes: 100, availableBytes: -5).usedFraction == 1.0)
        #expect(DiskReading(totalBytes: 100, availableBytes: 500).usedFraction == 0.0)
        #expect(DiskReading(totalBytes: 0, availableBytes: 0).usedFraction == 0.0)
    }
}
