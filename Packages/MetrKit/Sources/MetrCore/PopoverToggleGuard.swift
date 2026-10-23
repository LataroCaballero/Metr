/// Suppresses the close-then-reopen race on a transient popover (RESEARCH A8).
///
/// Mouse-down on the status button counts as an outside interaction, so AppKit may close the
/// popover before the mouse-up action runs; without a guard that action would reopen it at once.
/// Times are monotonic seconds (for example `ProcessInfo.systemUptime`), supplied by the caller
/// so the rule stays pure and testable.
public struct PopoverToggleGuard: Sendable {
    /// Seconds after a close during which an open request is rejected.
    public var suppression: Double
    private var lastClose: Double?

    public init(suppression: Double = 0.2) {
        self.suppression = suppression
    }

    public mutating func noteClosed(at time: Double) {
        lastClose = time
    }

    /// True when no close was noted, or the last close was at least `suppression` seconds ago.
    /// A one-nanosecond tolerance keeps a request exactly at the boundary from failing on
    /// floating-point subtraction error.
    public func shouldOpen(at time: Double) -> Bool {
        guard let lastClose else { return true }
        return time - lastClose >= suppression - 1e-9
    }
}
