import MetrCore
import SwiftUI

/// Popover content: the current CPU percentage from the store.
/// No custom background: the Liquid Glass comes from NSPopover.
struct PanelView: View {
    let store: MetricsStore

    var body: some View {
        Text(verbatim: cpuText)
            .font(.title.weight(.semibold))
            .monospacedDigit()
            .padding(24)
    }

    /// Pending or unavailable shows an em dash, never 0%.
    private var cpuText: String {
        guard let total = store.cpu.value?.total else { return "—" }
        return total.formatted(.percent.precision(.fractionLength(0)))
    }
}
