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
    /// The window's state is cheap and the commands in `MetrApp` read it, so it exists from launch.
    let windowModel = WindowModel()
    /// Created on the first open and kept (the window object is reused; its content is not).
    private var windowController: WindowController?

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
        let statusItemController = StatusItemController(store: store, sampler: sampler)
        statusItemController.openWindow = { [weak self] route in self?.showWindow(route) }
        self.statusItemController = statusItemController
        // Register BEFORE start so the first plan already reflects the override.
        for consumer in DebugHooks.demandOverride { sampler.register(consumer) }
        sampler.start(onBatch: Self.makeBatchSink(store: store), diagnostics: DebugHooks.diagnostics)
        let monitor = SystemLifecycleMonitor(sampler: sampler)
        lifecycleMonitor = monitor
        monitor.start()
        presentWelcomeIfFirstLaunch()
        runWindowScriptIfRequested()
    }

    /// Closing the window returns Metr to menu-bar-only; it never quits (WIN-01).
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// The one entry point for opening the window: the panel button, the right-click item and the
    /// main menu all land here.
    func showWindow(_ route: WindowRoute) {
        guard let store, let sampler else { return }
        let controller = windowController ?? WindowController(
            store: store, sampler: sampler, model: windowModel,
            closePanel: { [weak self] in self?.statusItemController?.closePanel() })
        windowController = controller
        controller.show(route)
    }

    /// DEBUG only: drives the window from METR_DEBUG_WINDOW_SCRIPT, `step@seconds` pairs separated
    /// by `;`. A step is a section name, `last` or `close`. Release has no script and no environment name.
    private func runWindowScriptIfRequested() {
        #if DEBUG
        for (step, seconds) in DebugHooks.windowScript {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if step == "last" {
                        self.showWindow(.lastVisited)
                    } else if step == "close" {
                        self.windowController?.closeWindow()
                    } else if let section = WindowSection(rawValue: step) {
                        self.showWindow(.section(section))
                    } else {
                        DebugHooks.log("window script unknown step")
                    }
                }
            }
        }
        #endif
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
