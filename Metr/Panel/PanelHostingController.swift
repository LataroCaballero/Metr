import AppKit
import SwiftUI

/// Hosts the panel and closes it on Esc. A transient popover is not promised to dismiss on Esc,
/// so the key is handled explicitly through `cancelOperation` (RESEARCH Pattern 6, Pitfall 8).
final class PanelHostingController: NSHostingController<PanelView> {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        guard let onCancel else {
            super.cancelOperation(sender)
            return
        }
        onCancel()
    }
}
