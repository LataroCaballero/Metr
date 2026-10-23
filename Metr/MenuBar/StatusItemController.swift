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
    /// True while a click is waiting for the first readings (cold start, at most `coldStartWait`).
    private var pendingOpen = false
    /// Identifies the current pending open, so a stale deadline cannot complete a newer one.
    private var pendingOpenToken = 0
    private static let coldStartWait: TimeInterval = 1.5

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
            pendingOpen = false
        } else if toggleGuard.shouldOpen(at: ProcessInfo.processInfo.systemUptime) {
            openPanel()
        }
    }

    /// Shows the panel now when every metric has answered, otherwise waits for the first ready
    /// batch or `coldStartWait`, whichever comes first. The wait is a timer, never a block, and the
    /// panel shows an em dash for anything still missing (never 0 and never a spinner).
    private func openPanel() {
        if store.isReadyForPanel {
            showPanel()
            return
        }
        pendingOpen = true
        pendingOpenToken += 1
        let token = pendingOpenToken
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.coldStartWait) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.pendingOpen, self.pendingOpenToken == token else { return }
                self.pendingOpen = false
                self.showPanel()
            }
        }
    }

    private func completePendingOpenIfReady() {
        guard pendingOpen, store.isReadyForPanel else { return }
        pendingOpen = false
        showPanel()
    }

    /// Builds the panel content for one presentation. SwiftUI content that stays alive inside a
    /// closed popover keeps observing the store and re-rendering on every tick, with its 0.4 s
    /// numeric-text animations driven by a window that is never on screen. That settled into a
    /// layout loop at about 60 Hz with a growing footprint (about 6 % of a core and 100 MB seen in
    /// the first 300 s idle measurement, FND-03). So the content exists only while the panel is shown.
    private func makePanelContent() -> PanelHostingController {
        let close: () -> Void = { [weak self] in self?.popover.performClose(nil) }
        let hosting = PanelHostingController(rootView: PanelView(store: store, onClose: close))
        hosting.sizingOptions = .preferredContentSize
        // Esc closes the panel by two paths: the responder chain (cancelOperation) and the
        // SwiftUI exit command inside the view.
        hosting.onCancel = close
        return hosting
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
        pendingOpen = false
        if popover.isShown { popover.performClose(nil) }
        guard let button = statusItem.button else { return }
        let menu = RightClickMenu.make(target: self)
        menu.delegate = self
        statusItem.menu = menu
        button.performClick(nil)
    }

    // MARK: RightClickMenuActions

    @objc func showAbout(_ sender: Any?) {
        RightClickMenu.showAbout()
    }

    // MARK: NSMenuDelegate

    func menuDidClose(_ menu: NSMenu) {
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
