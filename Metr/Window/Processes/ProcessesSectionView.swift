import AppKit
import MetrCore
import MetrRender
import SwiftUI

/// The Processes section (WIN-04): every process on the Mac in a native `Table`, grouped by app the
/// way the panel groups them, with a standard outline disclosure that lists all of a group's helpers
/// (D-14). The table fills the detail area edge to edge: system column headers, alternating rows
/// and selection are drawn by the system, and nothing here adds a background (UI-SPEC Processes).
///
/// Rows come from `ProcessTableModel`, which orders them; the table never sorts its own data. Every
/// row is a `DisclosureTableRow` because the rows builder has no conditionals; a group without
/// helpers has an empty child list and so no triangle (the DEBUG outline probe checks that).
struct ProcessesSectionView: View {
    let store: MetricsStore
    let model: ProcessTableModel

    private let text = MetricText(locale: .current)

    var body: some View {
        content
            .navigationSubtitle(partialNotice)
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

    private func table(for snapshot: ProcessSnapshot) -> some View {
        let rows = model.rows(for: snapshot)
        let active = ProcessTableOrdering.effectiveColumn(model.column, cpuReady: snapshot.cpuReady)
        let selection = Binding<Set<String>>(
            get: { model.selection }, set: { model.selection = $0 })
        return Table(of: ProcessTableRow.self, selection: selection) {
            TableColumn("Name") { row in
                nameCell(row)
            }
            .width(min: 200)
            TableColumn("CPU") { row in
                numberCell(text.processCPU(row.cpuPercent), active: active == .cpu)
            }
            .width(72)
            TableColumn("Memory") { row in
                numberCell(text.processMemory(row.footprintBytes), active: active == .memory)
            }
            .width(88)
        } rows: {
            ForEach(rows) { row in
                DisclosureTableRow(row, isExpanded: model.binding(expandedFor: row.id)) {
                    ForEach(row.children) { TableRow($0) }
                }
            }
        }
        .onChange(of: snapshot.sequence) { model.prune() }
        #if DEBUG
        .task(id: rows.isEmpty) {
            guard !rows.isEmpty else { return }
            try? await Task.sleep(for: .milliseconds(500))
            OutlineProbe.log(model: model)
        }
        #endif
    }

    /// 20 pt icon · 8 · name (13 pt, tail truncation) · 4 · lock on system rows. The full name and
    /// the PID are in the `.help`; a helper's name is secondary so the apps read first.
    private func nameCell(_ row: ProcessTableRow) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: row.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            HStack(spacing: 4) {
                Text(verbatim: row.name)
                    .font(.system(size: 13))
                    .foregroundStyle(row.isHelper ? Color.secondary : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if row.kind == .system {
                    Image(systemName: "lock.fill")
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                        .layoutPriority(1)
                        .accessibilityHidden(true)
                }
            }
        }
        .help(row.help)
    }

    /// A trailing number that never truncates. The sorted column is semibold primary and the others
    /// regular secondary, following the effective sort (UI-SPEC Typography).
    private func numberCell(_ value: String, active: Bool) -> some View {
        Text(verbatim: value)
            .font(.system(size: 13, weight: active ? .semibold : .regular))
            .foregroundStyle(active ? Color.primary : Color.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: .infinity, alignment: .trailing)
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
