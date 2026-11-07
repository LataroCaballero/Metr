import Foundation
import MetrCore
import Observation
import SwiftUI

/// Where an open request wants the window to land (D-01, D-03).
enum WindowRoute: Equatable {
    /// The footer button, the right-click item and Cmd-0: the last-visited section, CPU on first open.
    case lastVisited
    /// A View menu item.
    case section(WindowSection)
    /// The "and N more…" link of an open Top Apps group: Processes, with that group expanded.
    case processes(focusGroup: String)
}

/// The window's own state: which section is selected and whether the window is open. The section
/// is remembered silently between launches (D-03). That is a convenience, not a setting.
@MainActor
@Observable
final class WindowModel {
    static let sectionKey = "windowSection"

    /// The selected sidebar section. Written through to the preferences when `persistsState`.
    var section: WindowSection {
        didSet {
            guard section != oldValue else { return }
            if persistsState { UserDefaults.standard.set(section.rawValue, forKey: Self.sectionKey) }
            onSectionChange?(section)
        }
    }

    private(set) var isOpen = false

    /// The Processes table's state: expansion, selection and the sort. It lives exactly as long as
    /// the window session, so section switches keep it and closing the window discards it.
    private(set) var processTable: ProcessTableModel?

    /// Release always persists. A scripted DEBUG run never does, so the verification runs leave the
    /// owner's preferences domain untouched.
    let persistsState: Bool

    /// Called after the selected section changed. Not observed; 03-02 uses it to move the demand.
    @ObservationIgnored var onSectionChange: ((WindowSection) -> Void)?

    init() {
        #if DEBUG
        persistsState = !DebugHooks.windowScriptActive
        #else
        persistsState = true
        #endif
        section = .cpu
        if persistsState { section = Self.storedSection() ?? .cpu }
    }

    /// A model for the DEBUG snapshot renderer: a fixed section, nothing persisted.
    init(persistsState: Bool, section: WindowSection) {
        self.persistsState = persistsState
        self.section = section
    }

    func setOpen(_ open: Bool) {
        isOpen = open
        processTable = open ? ProcessTableModel(persistsState: persistsState) : nil
    }

    /// The section a "last visited" open shows: the stored one, else CPU (D-03). Without
    /// persistence the section of this session stands in for the stored one.
    func restoredSection() -> WindowSection {
        guard persistsState else { return section }
        return Self.storedSection() ?? .cpu
    }

    private static func storedSection() -> WindowSection? {
        UserDefaults.standard.string(forKey: sectionKey).flatMap(WindowSection.init(rawValue:))
    }
}

extension EnvironmentValues {
    /// Opens the Metr window from inside SwiftUI content, for example the panel's "and N more…" link.
    @Entry var openMetrWindow: (WindowRoute) -> Void = { _ in }
}
