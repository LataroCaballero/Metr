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
        }
        store.didApply = { [weak self] in self?.refresh() }
        refresh()
    }

    /// Rebuilds the glyph from the store. Pending or unavailable readings give nil,
    /// so the ring stays a track and never an arc. The CPU ring never tints (D-02).
    /// Memory and disk have no reading yet, so they draw tracks only.
    func refresh() {
        let state = GlyphState(cpu: store.cpu.value?.total, memory: nil, disk: nil)
        statusItem.button?.image = RingGlyph.image(for: state)
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
