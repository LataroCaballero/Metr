import Foundation
import MetrCore
import Testing

@testable import MetrSystem

@Suite struct VolumeCollectorTests {
    @Test func startupVolumeIsFirst() throws {
        let rows = try #require(VolumeCollector().sample().value)
        let first = try #require(rows.first)
        #expect(first.role == .startup)
        #expect(try #require(first.totalBytes) > 0)
        #expect(try #require(first.freeBytes) >= 0)
        #expect(rows.filter { $0.role == .startup }.count == 1)
    }

    @Test func noRowIsADiskImageOrDuplicated() throws {
        let rows = try #require(VolumeCollector().sample().value)
        #expect(Set(rows.map(\.id)).count == rows.count)
        for row in rows {
            #expect(!row.name.isEmpty)
            if let used = row.usedBytes, let total = row.totalBytes { #expect(used <= total) }
        }
    }

    /// CR-01: Foundation caches resource values per URL instance, and the sampler queue has no run
    /// loop to flush them. One long-lived collector must still see free space change.
    @Test func repeatedSamplesSeeAFileAllocation() throws {
        let collector = VolumeCollector()
        let before = try #require(collector.sample().value?.first?.freeBytes)

        let directory = FileManager.default.temporaryDirectory
        let file = directory.appending(path: "metr-volume-collector-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: file) }
        let size = 64 * 1024 * 1024
        try #require(FileManager.default.createFile(atPath: file.path(percentEncoded: false), contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        // 1 MiB chunks, so the test process's footprint stays flat for the other suites.
        let chunk = Data(repeating: 0xA5, count: 1024 * 1024)
        for _ in 0..<(size / chunk.count) { try handle.write(contentsOf: chunk) }
        try handle.synchronize()
        try handle.close()

        let after = try #require(collector.sample().value?.first?.freeBytes)
        #expect(before - after >= Int64(size / 2))
    }
}
