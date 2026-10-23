import Testing

@testable import MetrCore

@Suite struct DemandRegistryTests {
    @Test func registerAndCancelReportChanges() {
        var registry = DemandRegistry()
        let added = registry.register(.panel)
        #expect(added)
        #expect(registry.active == [.panel])
        let removed = registry.cancel(.panel)
        #expect(removed)
        #expect(registry.active.isEmpty)
    }

    @Test func operationsAreIdempotent() {
        var registry = DemandRegistry()
        let first = registry.register(.panel)
        let second = registry.register(.panel)
        #expect(first)
        #expect(!second)
        let cancelled = registry.cancel(.panel)
        let cancelledAgain = registry.cancel(.panel)
        let absent = registry.cancel(.window)
        #expect(cancelled)
        #expect(!cancelledAgain)
        #expect(!absent)
    }

    @Test func panelAndWindowCoexist() {
        var registry = DemandRegistry()
        _ = registry.register(.panel)
        _ = registry.register(.window)
        #expect(registry.active == [.panel, .window])
        _ = registry.cancel(.window)
        #expect(registry.active == [.panel])
    }
}
