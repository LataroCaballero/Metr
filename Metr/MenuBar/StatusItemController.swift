import AppKit
import MetrCore
import MetrRender
import MetrSystem
import SwiftUI

/// Owns the single menu bar item and its popover (D-04).
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
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

    init(store: MetricsStore, sampler: MetricsSampler) {
        self.store = store
        self.sampler = sampler
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "MetrStatusItem"

        popover = NSPopover()
        popover.behavior = .transient
        let hosting = NSHostingController(rootView: PanelView(store: store))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting

        super.init()

        popover.delegate = self

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel(_:))
            button.sendAction(on: [.leftMouseUp])
            button.setAccessibilityLabel("Metr")
        }
        store.didApply = { [weak self] in self?.refresh() }

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

    @objc func togglePanel(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        guard let button = statusItem.button else { return }
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    // MARK: NSPopoverDelegate

    /// The only source of panel demand. Window occlusion is deliberately not used: it is
    /// unreliable for status items (CLAUDE.md, macOS 27 forum reports).
    func popoverWillShow(_ notification: Notification) {
        sampler.register(.panel)
    }

    func popoverDidClose(_ notification: Notification) {
        sampler.cancel(.panel)
    }
}
