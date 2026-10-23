import Darwin
import MetrCore
import Testing

@testable import MetrSystem

@Suite struct MemoryCollectorTests {
    @Test func sampleReturnsValueMatchingHwMemsize() throws {
        var memsize: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        #expect(sysctlbyname("hw.memsize", &memsize, &size, nil, 0) == 0)
        let reading = try #require(MemoryCollector().sample().value)
        #expect(reading.totalBytes == memsize)
    }

    @Test func freePercentAndUsedAreInRange() throws {
        let reading = try #require(MemoryCollector().sample().value)
        #expect((0...100).contains(reading.freePercent))
        #expect(reading.usedBytes > 0)
        #expect(reading.usedBytes <= reading.totalBytes)
        #expect((0.0...1.0).contains(reading.ringFill))
    }

    @Test func pageSizeIsReadAtRuntime() throws {
        var ps: vm_size_t = 0
        #expect(host_page_size(mach_host_self(), &ps) == KERN_SUCCESS)
        let counters = try #require(MemoryCollector.readCounters(pageSize: UInt64(ps)))
        #expect(counters.pageSize == UInt64(ps))
        #expect(counters.pageSize.isMultiple(of: 4096))
    }
}
