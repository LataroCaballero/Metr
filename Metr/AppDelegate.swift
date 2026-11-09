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
    /// by `;`. A step is a section name, `last`, `miniaturize`, `deminiaturize`, `close`,
    /// `sort:<column>:<asc|desc>` (the Processes table sorts as if its header had been clicked) or
    /// `expand:<groupID>` (opens a Processes group) or `processes:<groupID>` (the panel's "and N more…"
    /// link: opens the window on Processes with that group in view), `search:<text>` (types into the
    /// Processes search), `select:<groupID>`, `deselect` and `hover:<0|1>` (the pointer over the
    /// table), and `quit:<pid>` (Quit on the app or standalone row of that pid, through the shared action
    /// controller; only for a process the run's author spawned). Release has no script and no environment name.
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
                    } else if step == "miniaturize" {
                        self.windowController?.miniaturizeForScript()
                    } else if step == "deminiaturize" {
                        self.windowController?.deminiaturizeForScript()
                    } else if step.hasPrefix("sort:") {
                        self.scriptSort(String(step.dropFirst("sort:".count)))
                    } else if step.hasPrefix("expand:") {
                        self.windowModel.processTable?.expanded.insert(String(step.dropFirst("expand:".count)))
                    } else if step.hasPrefix("search:") {
                        self.windowModel.processTable?.searchText = String(step.dropFirst("search:".count))
                    } else if step.hasPrefix("select:") {
                        self.windowModel.processTable?.selection = [String(step.dropFirst("select:".count))]
                    } else if step == "deselect" {
                        self.windowModel.processTable?.clearSelection()
                    } else if step.hasPrefix("hover:") {
                        self.windowModel.processTable?.scriptPointer(step == "hover:1")
                    } else if step.hasPrefix("quit:") {
                        // Quit on the row of a process the script's author spawned, by pid.
                        let pid = Int32(step.dropFirst("quit:".count)) ?? 0
                        let matched = pid > 1 && (self.windowModel.processTable?.scriptQuit(pid: pid) ?? false)
                        DebugHooks.log("window script quit matched=\(matched ? 1 : 0)")
                    } else if step.hasPrefix("processes:") {
                        self.showWindow(.processes(focusGroup: String(step.dropFirst("processes:".count))))
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

    #if DEBUG
    /// `<column>:<asc|desc>` from a window script `sort:` step.
    private func scriptSort(_ spec: String) {
        let parts = spec.split(separator: ":")
        guard parts.count == 2, let column = ProcessTableColumn(rawValue: String(parts[0])),
            parts[1] == "asc" || parts[1] == "desc"
        else {
            DebugHooks.log("window script bad sort step")
            return
        }
        windowModel.processTable?.setSort(column, ascending: parts[1] == "asc")
    }
    #endif

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
