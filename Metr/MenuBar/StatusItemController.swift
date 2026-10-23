import AppKit
import MetrRender
import SwiftUI

/// Owns the single menu bar item and its popover (D-04).
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover: NSPopover

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "MetrStatusItem"

        popover = NSPopover()
        popover.behavior = .transient
        let hosting = NSHostingController(rootView: PanelView())
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting

        super.init()

        popover.delegate = self

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePanel(_:))
            button.sendAction(on: [.leftMouseUp])
        }
        refresh()
    }

    /// Reassigns the glyph. Plan 01-02 builds the state from the store;
    /// until then no ring has a reading, so only the three tracks show.
    func refresh() {
        statusItem.button?.image = RingGlyph.image(for: GlyphState(cpu: nil, memory: nil, disk: nil))
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
}
