import Foundation
import MetrCore
import Testing

@testable import MetrSystem

@Suite struct GPUCollectorTests {
    @Test func parsesUtilization() {
        #expect(GPUCollector.utilization(fromStatistics: ["Device Utilization %": 45]) == 0.45)
        #expect(GPUCollector.utilization(fromStatistics: ["Device Utilization %": 0]) == 0)
        #expect(GPUCollector.utilization(fromStatistics: ["Device Utilization %": 130]) == 1)
        #expect(GPUCollector.utilization(fromStatistics: ["Device Utilization %": -5]) == 0)
        #expect(GPUCollector.utilization(fromStatistics: ["Renderer Utilization %": 45]) == nil)
        #expect(GPUCollector.utilization(fromStatistics: ["Device Utilization %": "45"]) == nil)
    }

    @Test func busiestAcceleratorWins() {
        #expect(GPUCollector.best([0.2, 0.6]) == 0.6)
        #expect(GPUCollector.best([]) == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["METR_CI"] != "1", "reads real hardware"))
    func readsThisMac() throws {
        let reading = try #require(GPUCollector().sample().value)
        #expect((0.0...1.0).contains(reading.utilization))
        #expect((reading.coreCount ?? 0) >= 1)
        #expect(!(reading.chipName ?? "").isEmpty)
    }
}
