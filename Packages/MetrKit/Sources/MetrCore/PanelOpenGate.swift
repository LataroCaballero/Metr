/// When a click on the rings may show the panel (D-20, Phase 1 MENU-04).
///
/// Data is present on open and the panel never shows a spinner, so a click holds the open until the
/// first readings are in. The hold is always bounded and is a timer the controller schedules, never
/// a block: an unbounded hold would let a click never open the panel. A pure rule plus controller
/// glue, in the shape of `PopoverToggleGuard`.
public enum PanelOpenGate {
    /// The longest a click waits for the first process reading when the rings are ready. The
    /// process pass is a few milliseconds of libproc work, so this fills the list on the first frame.
    public static let processWait: Double = 0.15
    /// The longest a click waits at cold start, while the rings have not answered yet.
    public static let coldStartWait: Double = 1.5

    public enum Decision: Equatable, Sendable {
        case showNow
        /// Show after at most this many seconds, or as soon as both are ready.
        case wait(Double)
    }

    public static func decide(ringsReady: Bool, processesReady: Bool) -> Decision {
        if !ringsReady { return .wait(coldStartWait) }
        if !processesReady { return .wait(processWait) }
        return .showNow
    }
}
