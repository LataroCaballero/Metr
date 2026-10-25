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

    /// CR-01: Foundation caches resource values per URL instance, and the sampler queue has no
    /// run loop to flush them. One long-lived collector must still see free space change.
    @Test func repeatedSamplesOnOneCollectorSeeAFileAllocation() throws {
        let directory = FileManager.default.temporaryDirectory
        let collector = DiskCollector(volume: directory)
        let before = try #require(collector.sample().value)

        let file = directory.appending(path: "metr-disk-collector-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: file) }
        let size = 64 * 1024 * 1024
        try #require(FileManager.default.createFile(atPath: file.path(percentEncoded: false), contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        // 1 MiB chunks: a single 64 MiB buffer would inflate this process's footprint and trip
        // CPUCollectorTests.tenThousandReadsDoNotGrowFootprint when the suites run in parallel.
        let chunk = Data(repeating: 0xA5, count: 1024 * 1024)
        for _ in 0..<(size / chunk.count) { try handle.write(contentsOf: chunk) }
        try handle.synchronize()
        try handle.close()

        let after = try #require(collector.sample().value)
        let fresh = try #require(DiskCollector(volume: directory).sample().value)
        let half = Int64(size / 2)
        #expect(before.availableBytes - after.availableBytes >= half)
        #expect(abs(after.availableBytes - fresh.availableBytes) < half)
    }

    @Test func repeatedSamplesOfAMissingVolumeStayUnavailable() {
        let collector = DiskCollector(volume: URL(fileURLWithPath: "/Volumes/metr-does-not-exist-XYZ"))
        #expect(collector.sample() == .unavailable)
        #expect(collector.sample() == .unavailable)
    }
}
