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
    /// would grow the footprint by many MiB over 10,000 calls (each leaked array is at least one
    /// 16 KiB page, so a real leak is well over 100 MiB). The footprint is process-wide and the
    /// other suites run in parallel (MetricsSamplerTests runs two live samplers and adds up to ~10 MiB),
    /// so the threshold leaves room for their allocations: 32 MiB is still five times below a leak.
    @Test func tenThousandReadsDoNotGrowFootprint() throws {
        _ = CPUCollector.readTicks()  // warm up
        let before = footprint()
        #expect(before > 0)
        for _ in 0..<10_000 {
            _ = CPUCollector.readTicks()
        }
        let after = footprint()
        let growth = after > before ? after - before : 0
        #expect(growth < 33_554_432, "footprint grew by \(growth) bytes")
    }

    private func sysctlInt(_ name: String) -> Int {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return -1 }
        return Int(value)
    }

    /// CPU-02: the layout comes from hw.perflevelN, and its counts add up to the real core count.
    @Test func layoutMatchesThisMac() throws {
        let layout = try #require(CPUCollector.readLayout())
        #expect(layout.levels.count == sysctlInt("hw.nperflevels"))
        #expect(layout.levels.allSatisfy { !$0.name.isEmpty })
        #expect(layout.levels.map(\.logicalCPUs).reduce(0, +) == sysctlInt("hw.logicalcpu"))
    }

    @Test func secondSampleCarriesOneClusterPerLevel() async throws {
        let layout = try #require(CPUCollector.readLayout())
        let collector = CPUCollector()
        _ = collector.sample()
        try await Task.sleep(for: .milliseconds(200))
        let reading = try #require(collector.sample().value)
        #expect(reading.clusters.count == layout.levels.count)
    }
}
