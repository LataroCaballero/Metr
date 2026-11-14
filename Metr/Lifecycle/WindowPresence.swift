import AppKit

/// The one coordinator that decides when Metr shows its Dock icon and its main menu (D-25): they show
/// exactly while any Metr window (main, Settings, welcome) is open.
///
/// Each window controller reports `opened` and `closed`; none of them sets the activation policy
/// itself, so closing one window under another that is still open can never drop the policy to
/// accessory (RESEARCH Pitfall 1).
@MainActor
final class WindowPresence {
    enum Kind: Hashable {
        case main, settings, welcome
    }

    private var open: Set<Kind> = []

    var isEmpty: Bool { open.isEmpty }

    /// Records the window as open and keeps (or sets) the regular policy.
    func opened(_ kind: Kind) {
        open.insert(kind)
        NSApp.setActivationPolicy(.regular)
    }

    /// Records the window as closed. Only an empty set returns Metr to the accessory policy, and only
    /// if it is still empty on the next main-queue turn: the window finishes closing as a regular
    /// app's window, and a reopen in between keeps the regular policy.
    func closed(_ kind: Kind) {
        open.remove(kind)
        guard open.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.open.isEmpty else { return }
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}
