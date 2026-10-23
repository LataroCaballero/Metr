import AppKit
import MetrCore
import MetrSystem

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: MetricsStore?
    private var statusItemController: StatusItemController?
    private var sampler: MetricsSampler?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = MetricsStore()
        self.store = store
        let sampler = MetricsSampler(cadenceScale: DebugHooks.cadenceScale)
        self.sampler = sampler
        statusItemController = StatusItemController(store: store, sampler: sampler)
        // Register BEFORE start so the first plan already reflects the override.
        for consumer in DebugHooks.demandOverride { sampler.register(consumer) }
        sampler.start(onBatch: Self.makeBatchSink(store: store), diagnostics: DebugHooks.diagnostics)
    }

    /// The sink the sampler calls on its own queue. It must be built in a nonisolated context:
    /// a closure literal written inside a MainActor method would inherit MainActor isolation and
    /// trap on the first tick (RESEARCH Pitfall 1). It hops to the MainActor once per batch.
    nonisolated static func makeBatchSink(store: MetricsStore) -> @Sendable (MetricsBatch) -> Void {
        return { batch in
            Task { @MainActor in
                store.apply(batch)
            }
        }
    }
}
