import AppKit
import MetrCore
import MetrSystem

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: MetricsStore?
    private var statusItemController: StatusItemController?
    private var sampler: MetricsSampler?
    private var lifecycleMonitor: SystemLifecycleMonitor?
    /// Strong reference so the welcome window outlives the launch method (D-14).
    private var welcomeController: WelcomeWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        DebugHooks.runLoginItemSpikeIfRequested()
        #if DEBUG
        if let directory = DebugHooks.renderDirectory {
            DebugSnapshotRenderer.renderAndExit(to: directory)
            return
        }
        #endif
        let store = MetricsStore()
        self.store = store
        let sampler = MetricsSampler(cadenceScale: DebugHooks.cadenceScale)
        self.sampler = sampler
        statusItemController = StatusItemController(store: store, sampler: sampler)
        // Register BEFORE start so the first plan already reflects the override.
        for consumer in DebugHooks.demandOverride { sampler.register(consumer) }
        sampler.start(onBatch: Self.makeBatchSink(store: store), diagnostics: DebugHooks.diagnostics)
        let monitor = SystemLifecycleMonitor(sampler: sampler)
        lifecycleMonitor = monitor
        monitor.start()
        presentWelcomeIfFirstLaunch()
    }

    /// The only place the welcome window is ever presented (D-15): the gate admits one claim per
    /// preferences domain, and the flag is written at claim time so a crash cannot repeat it.
    private func presentWelcomeIfFirstLaunch() {
        guard FirstRunGate().claimWelcomePresentation() else { return }
        let controller = WelcomeWindowController()
        welcomeController = controller
        controller.present()
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
