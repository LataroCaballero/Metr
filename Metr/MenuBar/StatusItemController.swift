import AppKit
import MetrCore
import MetrRender
import MetrSystem
import SwiftUI

/// Owns the single menu bar item and its popover (D-04).
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate, NSMenuDelegate, RightClickMenuActions {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let store: MetricsStore
    private let sampler: MetricsSampler

    /// Opens the Metr window (PANEL-06, D-01). Set by the app delegate, which owns the window.
    var openWindow: ((WindowRoute) -> Void)?
    /// Opens the Settings window (D-01); AppDelegate closes the panel first.
    var openSettings: (() -> Void)?

    /// Last state assigned to the button. The image is rebuilt only when this changes (T-01-20).
    private var lastAssigned: GlyphState?
    /// Builds the three-line hover tooltip from the store (D-11 through D-13).
    private let tooltipComposer = TooltipComposer(templates: .app(), text: MetricText(locale: .current))
    /// Last tooltip assigned to the button, so it is reassigned only when the text changed.
    private var lastTooltip: String?
    private var appearanceObservation: NSKeyValueObservation?
    /// Held for the app lifetime; the controller is never deallocated while the app runs.
    private var contrastObserver: (any NSObjectProtocol)?

    /// Rejects an open request that arrives right after a close, so a click on the rings while the
    /// panel is open closes it without reopening it (RESEARCH A8).
    private var toggleGuard = PopoverToggleGuard()
    /// True while a click is waiting for the first readings (at most `PanelOpenGate`'s bound).
    private var pendingOpen = false
    /// Identifies the current pending open, so a stale deadline cannot complete a newer one.
    private var pendingOpenToken = 0

    init(store: MetricsStore, sampler: MetricsSampler) {
        self.store = store
        self.sampler = sampler
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "MetrStatusItem"

        // The popover has no content while it is closed: `showPanel()` installs a fresh hosting
        // controller and `popoverDidClose` removes it (FND-03, see `makePanelContent`).
        popover = NSPopover()
        popover.behavior = .transient

        super.init()

        popover.delegate = self

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("Metr")
        }
        store.didApply = { [weak self] in
            self?.refresh()
            self?.completePendingOpenIfReady()
        }

        // The tinted (non-template) glyph bakes in the resolved label colour, so it must be
        // redrawn when the button's appearance changes (D-07).
        appearanceObservation = statusItem.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refresh(force: true) }
        }
        contrastObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(force: true) }
        }
        refresh()
    }

    /// Rebuilds the glyph state from the store and reassigns `button.image` only when it changed
    /// (or `force` is set after an appearance or contrast change). Pending or unavailable readings
    /// give nil, so the ring stays a track and never an arc. The CPU ring never tints (D-02); the
    /// memory ring is pressure (D-01); the disk ring is the used fraction, tinted by free space (D-03).
    func refresh(force: Bool = false) {
        updateTooltip()
        let state = GlyphState(
            cpu: RingQuantizer.quantize(store.cpu.value?.total),
            memory: RingQuantizer.quantize(store.memory.value?.ringFill),
            disk: RingQuantizer.quantize(store.disk.value?.usedFraction),
            memoryTint: store.memoryTint,
            diskTint: store.diskTint,
            increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        )
        guard force || state != lastAssigned else { return }
        lastAssigned = state
        statusItem.button?.image = RingGlyph.image(for: state, neutral: resolvedNeutral())
        DebugHooks.log(Self.describe(state))
    }

    /// Recomposes the tooltip on every applied tick and assigns it only when it changed. While any
    /// metric is still pending the result is nil and the button keeps no tooltip. The accessibility
    /// value carries the same three lines on one line (D-13).
    private func updateTooltip() {
        let tooltip = tooltipComposer.compose(cpu: store.cpu, memory: store.memory, disk: store.disk)
        guard tooltip != lastTooltip else { return }
        lastTooltip = tooltip
        guard let button = statusItem.button else { return }
        button.toolTip = tooltip
        button.setAccessibilityValue(tooltip.map(TooltipComposer.accessibilityValue(for:)))
        if let tooltip {
            DebugHooks.log("tooltip=" + tooltip.replacingOccurrences(of: "\n", with: " | "))
        }
    }

    /// The button's label colour as a concrete sRGB colour, resolved in its own appearance.
    private func resolvedNeutral() -> NSColor {
        var resolved = NSColor.black
        let appearance = statusItem.button?.effectiveAppearance ?? NSApp.effectiveAppearance
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor.labelColor.usingColorSpace(.sRGB) ?? .black
        }
        return resolved
    }

    private static func describe(_ state: GlyphState) -> String {
        func fill(_ value: Double?) -> String { value.map { String(format: "%.2f", $0) } ?? "-" }
        func tint(_ value: RingTint) -> String {
            switch value {
            case .none: "none"
            case .warning: "warning"
            case .critical: "critical"
            }
        }
        return "glyph cpu=\(fill(state.cpu)) mem=\(fill(state.memory)) disk=\(fill(state.disk))"
            + " tint=mem:\(tint(state.memoryTint)),disk:\(tint(state.diskTint))"
            + " template=\(state.isTinted ? 0 : 1)"
    }

    /// Routes the click: right or control-click shows the menu, a left click toggles the panel.
    @objc func statusItemClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
            || (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true)
        if isRightClick {
            showMenu()
        } else {
            togglePanel()
        }
    }

    private func togglePanel() {
        if popover.isShown {
            popover.performClose(nil)
        } else if pendingOpen {
            // A second click while waiting for data cancels the pending open.
            abandonPendingOpen()
        } else if toggleGuard.shouldOpen(at: ProcessInfo.processInfo.systemUptime) {
            openPanel()
        }
    }

    /// Opens the panel through `PanelOpenGate` (D-20): shows it now when the rings and the first
    /// process reading are in, otherwise holds the open for the gate's bound and then shows it
    /// whatever has arrived. The wait is a timer, never a block. Demand is registered at click
    /// time, so the process baseline is taken while the click is held and the list is filled on the
    /// first frame. A reading still missing when the bound ends shows the unavailable line in the
    /// reserved list area, never an empty area and never a spinner.
    private func openPanel() {
        sampler.register(.panel)
        switch PanelOpenGate.decide(ringsReady: store.isReadyForPanel, processesReady: store.processes != .pending) {
        case .showNow:
            showPanel()
        case .wait(let seconds):
            pendingOpen = true
            pendingOpenToken += 1
            let token = pendingOpenToken
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.pendingOpen, self.pendingOpenToken == token else { return }
                    self.pendingOpen = false
                    self.showPanel()
                }
            }
        }
    }

    private func completePendingOpenIfReady() {
        guard pendingOpen, store.isReadyForPanel, store.processes != .pending else { return }
        pendingOpen = false
        showPanel()
    }

    /// Drops a pending open that will not show (a second click, the right-click menu) and releases
    /// the demand it registered, so no process sampling lingers without a panel (T-02-24).
    private func abandonPendingOpen() {
        guard pendingOpen else { return }
        pendingOpen = false
        if !popover.isShown { sampler.cancel(.panel) }
    }

    /// Builds the panel content for one presentation. SwiftUI content that stays alive inside a
    /// closed popover keeps observing the store and re-rendering on every tick, with its 0.4 s
    /// numeric-text animations driven by a window that is never on screen. That settled into a
    /// layout loop at about 60 Hz with a growing footprint (about 6 % of a core and 100 MB seen in
    /// the first 300 s idle measurement, FND-03). So the content exists only while the panel is shown.
    private func makePanelContent() -> PanelHostingController {
        let close: () -> Void = { [weak self] in self?.popover.performClose(nil) }
        // One router per presentation: it dies with the panel content, so nothing stays half-confirmed.
        let escape = PanelEscapeRouter()
        let open: (WindowRoute) -> Void = { [weak self] route in self?.openWindow?(route) }
        let hosting = PanelHostingController(
            rootView: PanelView(
                store: store, onClose: close, onOpenWindow: open,
                onOpenSettings: { [weak self] in self?.openSettings?() }, escape: escape))
        hosting.sizingOptions = .preferredContentSize
        // Esc reaches the panel by two paths: the responder chain (cancelOperation) and the
        // SwiftUI exit command inside the view. Both cancel an open confirmation first and close
        // the panel only when there was none (D-14, RESEARCH Pitfall 9).
        hosting.onCancel = { if !escape.handleEscape() { close() } }
        return hosting
    }

    /// Closes the panel on behalf of the window (D-02). The window registers its own demand first, so
    /// the `.panel` cancel in `popoverDidClose` never empties the registry. Also drops a click that
    /// is still waiting for its first readings.
    func closePanel() {
        abandonPendingOpen()
        if popover.isShown { popover.performClose(nil) }
        DebugHooks.log("panel close requested")
    }

    private func showPanel() {
        guard !popover.isShown, let button = statusItem.button else { return }
        popover.contentViewController = makePanelContent()
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    /// Temporarily assigns the menu so the button presents it, then clears it in `menuDidClose`
    /// so left clicks keep reaching the action (RESEARCH A4).
    private func showMenu() {
        abandonPendingOpen()
        if popover.isShown { popover.performClose(nil) }
        guard let button = statusItem.button else { return }
        let menu = RightClickMenu.make(target: self)
        menu.delegate = self
        statusItem.menu = menu
        button.performClick(nil)
    }

    #if DEBUG
    // MARK: Scripted DEBUG entry points (METR_DEBUG_WINDOW_SCRIPT steps `panel`, `gear`, `menu`)

    /// Opens the panel the way a click on the rings does.
    func openPanelForScript() {
        guard !popover.isShown, !pendingOpen else { return }
        openPanel()
    }

    /// Presses the panel gear: the closure the gear is bound to.
    func pressGearForScript() {
        openSettings?()
    }

    /// Opens the real right-click menu through the private `showMenu()` a right click takes. Menu
    /// tracking blocks the main run loop, so a one-shot timer in the `.common` modes cancels the
    /// tracking after 4 s, which lets a capture script photograph the open menu and the run go on.
    func showMenuForScript() {
        let timer = Timer(timeInterval: 4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.statusItem.menu?.cancelTracking() }
        }
        RunLoop.main.add(timer, forMode: .common)
        showMenu()
    }
    #endif

    // MARK: RightClickMenuActions

    @objc func showAbout(_ sender: Any?) {
        RightClickMenu.showAbout()
    }

    @objc func openSettings(_ sender: Any?) {
        openSettings?()
    }

    @objc func openWindow(_ sender: Any?) {
        openWindow?(.lastVisited)
    }

    // MARK: NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        DebugHooks.log("menu shown items=\(menu.items.filter { !$0.isSeparatorItem }.count)")
    }

    func menuDidClose(_ menu: NSMenu) {
        DebugHooks.log("menu closed")
        // Clear on the next turn: the chosen item's action is delivered after this callback.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.statusItem.menu = nil }
        }
    }

    // MARK: NSPopoverDelegate

    /// The only source of panel demand. Window occlusion is deliberately not used: it is
    /// unreliable for status items (CLAUDE.md, macOS 27 forum reports).
    func popoverWillShow(_ notification: Notification) {
        sampler.register(.panel)
    }

    func popoverDidShow(_ notification: Notification) {
        statusItem.button?.highlight(true)
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
        statusItem.button?.highlight(false)
        toggleGuard.noteClosed(at: ProcessInfo.processInfo.systemUptime)
        sampler.cancel(.panel)
    }
}
