import SwiftUI

/// Popover content. Plan 01-02 binds the CPU value slot to the store.
/// No custom background: the Liquid Glass comes from NSPopover.
struct PanelView: View {
    var body: some View {
        Text(verbatim: "—")
            .font(.title.weight(.semibold))
            .monospacedDigit()
            .padding(24)
    }
}
