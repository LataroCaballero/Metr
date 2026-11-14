import AppKit
import MetrCore
import MetrSystem
import SwiftUI

/// Owns the one Metr window (WIN-01). AppKit hosts it, like the welcome window does: a SwiftUI
/// `Window` scene needs an `OpenWindowAction` from a live SwiftUI view, and this app has none
/// (owner decision of 2026-11-02, see 03-01-PLAN). `NSHostingController.sceneBridgingOptions = .all`
/// hands the toolbar, the title and the search field of the SwiftUI content to the window.
///
/// The window exists only while it is open as far as cost goes: the hosting controller is created
/// on open and released on close, because SwiftUI content left alive inside a hidden window keeps
/// observing the store and re-rendering (the `StatusItemController.makePanelContent` lesson, FND-03).
@MainActor
final class WindowController: NSWindowController, NSWindowDelegate {
    static let windowIdentifier = "MetrMainWindow"
    private static let defaultContentSize = NSSize(width: 1000, height: 640)
    private static let minimumContentSize = NSSize(width: 900, height: 520)

    private let store: MetricsStore
    private let sampler: MetricsSampler
    private let model: WindowModel
    private let closePanel: () -> Void
    private let presence: WindowPresence
    /// True from the first `show` until the window closes. The demand follows this, not
    /// `model.isOpen`, because the demand must be in place before the panel closes.
    private var isShown = false
    /// What this controller has registered with the sampler right now.
    private var activeDemand: Set<DemandConsumer> = []

    #if DEBUG
    /// Lets the DEBUG log say whether the hosting controller was released after the close.
    private weak var observedHost: NSHostingController<WindowRootView>?
    #endif

    init(
        store: MetricsStore, sampler: MetricsSampler, model: WindowModel, presence: WindowPresence,
        closePanel: @escaping () -> Void
    ) {
        self.store = store
        self.presence = presence
        self.sampler = sampler
        self.model = model
        self.closePanel = closePanel
        super.init(window: nil)
        model.onSectionChange = { [weak self] _ in
            MainActor.assumeIsolated { self?.applyDemand() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Opens the window, or brings the one that is open forward (never a second one).
    ///
    /// Order matters (RESEARCH Pattern 1, Pitfall 1): the window's demand is registered BEFORE the
    /// panel closes, so the demand registry never empties in between and the process baseline the
    /// panel built is not thrown away. When the route lands on Processes the process pass is
    /// registered in the same step, so the panel's top child carries straight over.
    func show(_ route: WindowRoute) {
        // History starts empty on every open and exists only while the window does (D-06). It begins
        // before the demand is registered, so the first sample after the open is the first one kept.
        if !model.isOpen { store.beginWindowSession() }
        isShown = true
        model.section = resolve(route)
        applyDemand()
        closePanel()

        let window = existingOrNewWindow()
        if !model.isOpen {
            presence.opened(.main)
            let frame = window.frame
            let host = NSHostingController(rootView: WindowRootView(store: store, model: model))
            // The window is resizable and owns its size; the content never resizes it.
            host.sizingOptions = []
            host.sceneBridgingOptions = .all
            window.contentViewController = host
            window.setFrame(frame, display: false)
            #if DEBUG
            observedHost = host
            #endif
            model.setOpen(true)
        }

        // The deep link (D-01): the table exists now, so the group can be opened, selected and scrolled
        // to. A second link while the window is open lands here too and moves the same window.
        if case .processes(let groupID) = route { model.processTable?.focus(groupID: groupID) }

        NSApp.activate()
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        logShown(window)
    }

    /// Moves the sampler's demand to what the window needs now (D-05): the cheap metrics while the
    /// window is open, plus the process pass only while Processes is selected and the window is not
    /// minimized. A covered or hidden window counts as visible: Metr does not observe the window's
    /// occlusion (owner decision of 2026-11-02, CLAUDE.md). Every new consumer is registered BEFORE
    /// a dropped one is cancelled, so the registry never empties during a switch.
    private func applyDemand() {
        let target: Set<DemandConsumer> =
            isShown ? WindowDemand.consumers(section: model.section, processesVisible: !isMinimized) : []
        let change = WindowDemand.transition(from: activeDemand, to: target)
        guard !change.register.isEmpty || !change.cancel.isEmpty else { return }
        for consumer in change.register { sampler.register(consumer) }
        for consumer in change.cancel { sampler.cancel(consumer) }
        activeDemand = target
        #if DEBUG
        let list = target.map(\.rawValue).sorted().joined(separator: ",")
        DebugHooks.log("window demand=\(list.isEmpty ? "none" : list)")
        #endif
    }

    private var isMinimized: Bool { window?.isMiniaturized ?? false }

    /// Closes the window the way the red button does, so the same delegate path runs.
    func closeWindow() {
        window?.performClose(nil)
    }

    #if DEBUG
    func miniaturizeForScript() { window?.miniaturize(nil) }
    func deminiaturizeForScript() { window?.deminiaturize(nil) }
    #endif

    private func resolve(_ route: WindowRoute) -> WindowSection {
        switch route {
        case .lastVisited: model.restoredSection()
        case .section(let section): section
        case .processes: .processes
        }
    }

    /// 1000 x 640 content, at least 900 x 520. The frame is remembered between launches by the
    /// system autosave when the model allows it (a silent convenience, not a setting).
    private func existingOrNewWindow() -> NSWindow {
        if let window { return window }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier(Self.windowIdentifier)
        window.title = "Metr"
        window.contentMinSize = Self.minimumContentSize
        window.delegate = self
        model.hostWindow = window
        var restored = false
        if model.persistsState {
            restored = window.setFrameUsingName(Self.windowIdentifier)
            window.setFrameAutosaveName(Self.windowIdentifier)
        }
        if !restored { window.center() }
        self.window = window
        return window
    }

    // MARK: NSWindowDelegate

    /// Minimizing drops only the process pass (and with it the top child); the cheap window metrics
    /// keep running so the charts keep filling (D-05, D-06). No other visibility signal is observed
    /// (owner decision of 2026-11-02).
    func windowDidMiniaturize(_ notification: Notification) {
        applyDemand()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        applyDemand()
    }

    func windowWillClose(_ notification: Notification) {
        isShown = false
        applyDemand()
        store.endWindowSession()
        // A hosting controller left on a closed window keeps observing the store (FND-03).
        window?.contentViewController = nil
        model.setOpen(false)
        // The coordinator returns Metr to accessory only when this was the last Metr window, on the
        // next turn. The log line follows one turn later and reads the real policy; its accessory
        // form is the literal window-cost.sh greps. A reopen in between logs nothing.
        presence.closed(.main)
        DispatchQueue.main.async {
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.model.isOpen else { return }
                    let policy = NSApp.activationPolicy() == .regular ? "regular" : "accessory"
                    DebugHooks.log("window closed policy=\(policy)")
                    #if DEBUG
                    DebugHooks.log("window content released=\(self.observedHost == nil ? 1 : 0)")
                    #endif
                }
            }
        }
    }

    // MARK: DEBUG logging

    private func logShown(_ window: NSWindow) {
        #if DEBUG
        let count = NSApp.windows.filter {
            $0.identifier?.rawValue == Self.windowIdentifier && $0.isVisible
        }.count
        DebugHooks.log("window shown section=\(model.section.rawValue) count=\(count)")
        // Same 0.3 s check as the shell spike: a scripted launch cannot prove focus from a real
        // click (RESEARCH Pitfall 2), but it shows whether the window is visible and what policy holds.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            MainActor.assumeIsolated {
                let policy = NSApp.activationPolicy() == .regular ? "regular" : "accessory"
                DebugHooks.log(
                    "window visible=\(window.isVisible ? 1 : 0) key=\(window.isKeyWindow ? 1 : 0)"
                        + " active=\(NSApp.isActive ? 1 : 0) policy=\(policy)")
            }
        }
        // The main menu and (on request) the toolbar, half a second after the window shows.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                self?.logMenuProbe()
                if DebugHooks.chromeProbeEnabled, self?.model.section == .processes {
                    self?.logChromeProbe(window)
                }
            }
        }
        #endif
    }

    #if DEBUG
    /// Counts the Command-key items of the main menu, recursively: Settings (","), Close ("w"),
    /// Window > Metr ("0") and the six View sections ("1" to "6"). Exactly one Close, one Metr and one
    /// Settings (the app menu's Metr > Settings…, Phase 4 D-01) must exist (RESEARCH Pitfall 3, assumption A3).
    private func logMenuProbe() {
        var settings = 0, close = 0, metr = 0, sections = 0
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if item.keyEquivalentModifierMask == .command {
                    switch item.keyEquivalent {
                    case ",": settings += 1
                    case "w": close += 1
                    case "0": metr += 1
                    case "1", "2", "3", "4", "5", "6": sections += 1
                    default: break
                    }
                }
                if let submenu = item.submenu { walk(submenu) }
            }
        }
        if let main = NSApp.mainMenu { walk(main) }
        DebugHooks.log("menu settings=\(settings) close=\(close) metr=\(metr) sections=\(sections)")
    }

    /// What the AppKit host bridged from the SwiftUI content: the toolbar, its search field and its menu
    /// (the execution-time gate of the owner-approved host, RESEARCH Open Question 2, assumption A1).
    private func logChromeProbe(_ window: NSWindow) {
        let items = window.toolbar?.items ?? []
        let search = items.contains { $0 is NSSearchToolbarItem }
        let menu = items.contains { item in
            item is NSMenuToolbarItem || item.view is NSPopUpButton || (item.view as? NSButton)?.menu != nil
                // SwiftUI bridges a toolbar Menu as a toolbar item whose menu form is a submenu.
                || item.menuFormRepresentation?.submenu != nil
        }
        DebugHooks.log(
            "chrome toolbar=\(window.toolbar == nil ? 0 : 1) items=\(items.count)"
                + " search=\(search ? 1 : 0) menu=\(menu ? 1 : 0)"
                + " style=\(window.toolbarStyle.rawValue)")
        DebugHooks.log(
            "chrome classes=" + items.map {
                "\(type(of: $0))[view=\($0.view.map { String(describing: type(of: $0)) } ?? "nil"),"
                    + "menu=\($0.menuFormRepresentation?.submenu == nil ? 0 : 1)]"
            }.joined(separator: ","))
    }
    #endif
}
