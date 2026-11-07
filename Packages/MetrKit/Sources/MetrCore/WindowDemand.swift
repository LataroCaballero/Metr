/// The sections of the full window's sidebar. The case order is the sidebar order (D-04) and the
/// raw values are the persisted `windowSection` values (D-03): the last-visited section is stored
/// by raw value, so renaming a case would orphan a user's stored choice.
public enum WindowSection: String, Sendable, CaseIterable {
    case cpu, memory, disk, network, gpu, processes
}

/// The sampling demand the window derives from what is on screen (D-05).
///
/// The window always asks for the cheap metrics (`.window`). It adds `.windowProcesses`, which
/// starts the process pass and its `top` child, only while Processes is the selected section and
/// the window is not minimized. "Visible" means not minimized: a window that is covered or hidden
/// counts as visible, because Metr does not observe occlusion (owner decision of 2026-11-02,
/// CLAUDE.md; RESEARCH Pitfall 5 closed). The only process-pass gates are window close, minimize
/// and deminiaturize, and the selected section.
public enum WindowDemand {
    public static func consumers(section: WindowSection, processesVisible: Bool) -> Set<DemandConsumer> {
        if section == .processes && processesVisible { return [.window, .windowProcesses] }
        return [.window]
    }

    /// What to change to get from one demand set to the next. The caller registers `register`
    /// first and cancels `cancel` second, so the registry never empties during a switch and the
    /// scheduler never resets the process collector in between (RESEARCH Pitfalls 1 and 4).
    public static func transition(
        from: Set<DemandConsumer>, to: Set<DemandConsumer>
    ) -> (register: Set<DemandConsumer>, cancel: Set<DemandConsumer>) {
        (to.subtracting(from), from.subtracting(to))
    }
}
