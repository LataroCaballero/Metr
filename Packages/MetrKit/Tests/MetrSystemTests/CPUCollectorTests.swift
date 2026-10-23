import Darwin
import Foundation
import MetrCore
import Testing

@testable import MetrSystem

private func footprint() -> UInt64 {
    var info = rusage_info_v4()
    let rc = withUnsafeMutablePointer(to: &info) { p in
        p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
        }
    }
    return rc == 0 ? info.ri_phys_footprint : 0
}

@Suite struct CPUCollectorTests {
    @Test func readTicksCountMatchesLogicalCPUs() throws {
        let ticks = try #require(CPUCollector.readTicks())
        var logical: Int32 = 0
        var size = MemoryLayout<Int32>.size
        #expect(sysctlbyname("hw.logicalcpu", &logical, &size, nil, 0) == 0)
        #expect(ticks.count >= 1)
        #expect(ticks.count == Int(logical))
    }

    @Test func sampleIsPendingThenValue() async throws {
        let collector = CPUCollector()
        #expect(collector.sample() == .pending)
        try await Task.sleep(for: .milliseconds(200))
        let second = collector.sample()
        #expect(second.value != nil)
    }

    /// Guards the vm_deallocate in readTicks (T-01-03): a leak of the kernel array
    /// would grow the footprint by many MiB over 10,000 calls.
    @Test func tenThousandReadsDoNotGrowFootprint() throws {
        _ = CPUCollector.readTicks()  // warm up
        let before = footprint()
        #expect(before > 0)
        for _ in 0..<10_000 {
            _ = CPUCollector.readTicks()
        }
        let after = footprint()
        let growth = after > before ? after - before : 0
        #expect(growth < 1_048_576, "footprint grew by \(growth) bytes")
    }
}
