import AppKit
import MetrCore
import MetrRender
import SwiftUI

/// The Processes section (WIN-04): every process on the Mac in a native outline table, grouped by
/// app the way the panel groups them, with a standard outline disclosure that lists all of a
/// group's helpers (D-14). The table fills the detail area edge to edge: system column headers,
/// alternating rows and selection are drawn by the system, and nothing here adds a background
/// (UI-SPEC Processes).
///
/// Rows come from `ProcessTableModel`, which orders them; the table never sorts its own data. The
/// host is an `NSOutlineView` (`ProcessOutlineView`) because SwiftUI's `Table` cannot mark a leaf
/// row as not expandable; a group without helpers has no triangle (the DEBUG outline probe checks
/// that).
///
/// Columns: Name, CPU, Memory, Disk Read and Disk Write. The disk rates are the user's own
/// processes only; a system row shows a quiet "—" with a tooltip saying why (PROC-04, D-11).
struct ProcessesSectionView: View {
    let store: MetricsStore
    let model: ProcessTableModel

    private let text = MetricText(locale: .current)

    var body: some View {
        content
            .navigationSubtitle(partialNotice)
            // The system's toolbar search field, on this section only (D-13). Cmd-F focuses it and the
            // system field scrolls long text; there are no scopes and no suggestions.
            .searchable(text: Bindable(model).searchText, placement: .toolbar, prompt: "Search processes")
            // Esc steps back: the focused field clears its own text first, then the selection ends.
            .onExitCommand { model.clearSelection() }
            .toolbar { quitControl }
    }

    // MARK: Quit and Force Quit (WIN-04, D-15)

    /// The toolbar control of the selected row: one menu with an ⓧ, never an action by itself and
    /// with no keyboard shortcut, so a click cannot quit anything (UI-SPEC "Toolbar control"). It is
    /// disabled with nothing selected, and for a protected, other-user or un-signalable row it is
    /// disabled and its tooltip says why.
    @ToolbarContentBuilder
    private var quitControl: some ToolbarContent {
        let menu = model.selectedActionMenu
        let usable = menu?.enabled == true && menu?.items.isEmpty == false
        let defaultHelp = String(localized: "Quit or force quit the selected process")
        ToolbarItem {
            Menu {
                if let menu, let id = model.selection.first, !menu.items.isEmpty {
                    ForEach(menu.items, id: \.kind) { item in
                        Button(item.title) { model.perform(item.kind, on: id) }
                    }
                } else {
                    // Never an empty menu: the system drops a toolbar menu with nothing in it.
                    Button("Quit") {}.disabled(true)
                }
            } label: {
                Image(systemName: "xmark.circle")
            }
            .disabled(!usable)
            .help((usable ? nil : menu?.reason) ?? defaultHelp)
            .accessibilityLabel(defaultHelp)
        }
    }

    /// "System processes not shown." while the other-users half is failing; the user's own
    /// processes keep ranking (UI-SPEC W9 partial).
    private var partialNotice: String {
        store.processes.value?.otherUsers == .unavailable ? String(localized: "System processes not shown.") : ""
    }

    @ViewBuilder
    private var content: some View {
        switch store.processes {
        case .unavailable:
            unavailable
        case .pending:
            // Rows arrive with the first reading; nothing is drawn meanwhile, never a spinner.
            Color.clear
        case .value(let snapshot):
            if snapshot.processes.isEmpty {
                unavailable
            } else {
                table(for: snapshot)
            }
        }
    }

    private var unavailable: some View {
        Text("Process list unavailable.")
            .font(.system(size: 13))
            .foregroundStyle(Color.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func table(for snapshot: ProcessSnapshot) -> some View {
        let rows = model.rows(for: snapshot)
        if rows.isEmpty && model.hasQuery {
            // Nothing matches: the system's "No Results" view fills the table area (D-13).
            ContentUnavailableView.search(text: model.searchText)
                .onChange(of: model.searchText) { prune() }
        } else {
            outline(rows: rows, for: snapshot)
        }
    }

    private func prune() {
        model.prune()
        model.applyPendingFocus()
    }

    private func outline(rows: [ProcessTableRow], for snapshot: ProcessSnapshot) -> some View {
        let active = ProcessTableOrdering.effectiveColumn(model.column, cpuReady: snapshot.cpuReady)
        let ascending = active == model.column ? model.ascending : ProcessTableOrdering.defaultAscending(active)
        return ProcessOutlineView(
            model: model, rows: rows, active: active, activeAscending: ascending, text: text)
        .background { frameReader }
        .onAppear { model.applyPendingFocus() }
        // A new reading, or a new search, ends what no longer exists and applies a waiting deep link;
        // the watchdog releases a hover whose end was never delivered.
        .onChange(of: snapshot.sequence) {
            prune()
            model.runFreezeWatchdog()
        }
        .onChange(of: model.searchText) { prune() }
        #if DEBUG
        .task(id: rows.isEmpty) {
            guard !rows.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(500))
            OutlineProbe.log(model: model)
        }
        #endif
    }
}

extension ProcessesSectionView {
    /// Reports the table's frame in screen coordinates, for the freeze watchdog. The fixtures render the
    /// table through `cacheDisplay`, where an empty AppKit view draws nothing, so no DEBUG guard is needed.
    fileprivate var frameReader: some View {
        ScreenFrameReader { model.tableScreenFrame = $0 }
    }
}

#if DEBUG
/// The Table fitness check (RESEARCH Open Question 1, plan 03-10 decision gate): finds the outline
/// the table is backed by and counts the leaf rows that are expandable. The gate needs zero.
@MainActor
private enum OutlineProbe {
    static func log(model: ProcessTableModel) {
        guard
            let content = NSApp.windows.first(where: {
                $0.identifier?.rawValue == WindowController.windowIdentifier
            })?.contentView
        else { return }
        let rows = model.debugRows
        if let outline = find(NSOutlineView.self, in: content) {
            var leaves = 0
            var root = 0
            for index in 0..<outline.numberOfRows {
                guard let item = outline.item(atRow: index), outline.level(forItem: item) == 0 else { continue }
                if root < rows.count, rows[root].children.isEmpty, outline.isExpandable(item) { leaves += 1 }
                root += 1
            }
            DebugHooks.log("table outline=1 leaves-expandable=\(leaves) rows=\(outline.numberOfRows)")
        } else if let table = find(NSTableView.self, in: content) {
            DebugHooks.log("table outline=0 leaves-expandable=0 rows=\(table.numberOfRows)")
        } else {
            DebugHooks.log("table outline=0 leaves-expandable=0 rows=0")
        }
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews {
            if let found = find(type, in: child) { return found }
        }
        return nil
    }
}
#endif
