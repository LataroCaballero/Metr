import AppKit
import MetrCore
import MetrRender
import SwiftUI

/// The Top Apps area under the status line: header with the CPU | Memory control, then five rows
/// of icon, name, CPU and memory (PANEL-04, PROC-03; UI-SPEC "Top Apps section", D-06, D-07).
///
/// The rows area reserves five 32 pt rows from the first frame, so rows arriving never resize
/// the popover (UI-SPEC Pitfall 8). No custom background: the glass comes from NSPopover.
struct TopAppsSection: View {
    let store: MetricsStore

    /// The selected segment, remembered across openings (D-06). Stored as the column's raw value.
    @AppStorage("topAppsSort") private var sortRaw = SortColumn.cpu.rawValue
    @State private var model = TopAppsModel()

    private let text = MetricText(locale: .current)

    static let rowHeight: CGFloat = 32

    private var sort: SortColumn { SortColumn(rawValue: sortRaw) ?? .cpu }

    var body: some View {
        let display = model.display(for: store.processes, sort: sort)
        VStack(spacing: 0) {
            header
            list(display)
        }
        .padding(.horizontal, 8)
        // An open group that left the list closes, so it cannot reopen by surprise (D-08).
        .onChange(of: display.rowIDs) { _, visible in model.collapse(unlessVisible: visible) }
    }

    private var header: some View {
        HStack {
            Text("Top Apps")
                .font(.body.weight(.semibold))
            Spacer(minLength: 8)
            Picker(
                "Sort top apps by",
                selection: Binding(get: { sort }, set: { sortRaw = $0.rawValue })
            ) {
                Text("CPU").tag(SortColumn.cpu)
                Text("Memory").tag(SortColumn.memory)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func list(_ display: TopAppsDisplay) -> some View {
        VStack(spacing: 0) {
            switch display.content {
            case .rows(let rows):
                ForEach(rows) { row in
                    AppRow(data: row, effectiveSort: display.effectiveSort, text: text) { model.toggle(row.id) }
                    if row.isExpanded {
                        ForEach(row.helpers) { helper in
                            HelperRow(data: helper, effectiveSort: display.effectiveSort, text: text)
                        }
                        if row.moreCount > 0 { MoreLine(count: row.moreCount) }
                    }
                }
            case .waiting:
                Color.clear.frame(height: 0)
            case .unavailable:
                Text("App list unavailable.")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                    .frame(maxWidth: .infinity, minHeight: Self.rowHeight, alignment: .leading)
                    .padding(.horizontal, 8)
            }
        }
        .frame(maxWidth: .infinity, minHeight: Self.rowHeight * 5, alignment: .top)
        .padding(.bottom, 8)
    }
}

/// One 32 pt app row. Slots, left to right, sum to the 288 pt content width (UI-SPEC "App row"):
/// gutter 12, gap 4, icon 20, gap 8, name (flex, 112 minimum), gap 8, CPU 44, gap 4, memory 52,
/// gap 4, action 20. The gutter holds the disclosure chevron of a group with helpers and is
/// reserved empty on every other row; the action slot is reserved and empty for now, so numbers
/// and icons keep their columns when it fills in later.
private struct AppRow: View {
    let data: TopAppRowData
    let effectiveSort: SortColumn
    let text: MetricText
    let toggle: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let cpu = data.cpuPercent.map { text.percent($0 / 100) } ?? "—"
        let memory = data.footprintBytes.map { text.memoryBytes($0) } ?? "—"
        let expandsLabel =
            data.isExpanded
            ? String(localized: "Collapse \(data.name)") : String(localized: "Expand \(data.name)")
        HStack(spacing: 0) {
            gutter(label: expandsLabel)
            Color.clear.frame(width: 4)
            Image(nsImage: data.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            Color.clear.frame(width: 8)
            Text(verbatim: data.name)
                .font(.body)
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minWidth: 112, maxWidth: .infinity, alignment: .leading)
                .help(data.name)
            Color.clear.frame(width: 8)
            number(cpu, active: effectiveSort == .cpu)
                .minimumScaleFactor(0.85)
                .frame(width: 44, alignment: .trailing)
            Color.clear.frame(width: 4)
            number(memory, active: effectiveSort == .memory)
                .frame(width: 52, alignment: .trailing)
            Color.clear.frame(width: 4)
            Color.clear.frame(width: 20)
        }
        .padding(.horizontal, 8)
        .frame(height: TopAppsSection.rowHeight)
        .contentShape(Rectangle())
        // Tapping anywhere on a group row toggles it; a row with no helpers is not a control.
        .onTapGesture { if data.helperCount > 0 { animatedToggle() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(data.name), CPU \(cpu), memory \(memory)"))
        .accessibilityActions {
            if data.helperCount > 0 {
                Button(expandsLabel) { animatedToggle() }
            }
        }
    }

    /// The 12 pt disclosure gutter: a chevron on a group with helpers, empty otherwise.
    @ViewBuilder
    private func gutter(label: String) -> some View {
        if data.helperCount > 0 {
            Button(action: animatedToggle) {
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.secondary)
                    .rotationEffect(.degrees(data.isExpanded ? 90 : 0))
                    .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: data.isExpanded)
                    .frame(width: 12, height: TopAppsSection.rowHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
        } else {
            Color.clear.frame(width: 12)
        }
    }

    /// Expand and collapse use one animation; Reduce Motion makes it instant (UI-SPEC Color and motion).
    private func animatedToggle() {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.25)) { toggle() }
    }

    /// 13 pt monospaced digits. The effective column is Semibold primary, the other Regular
    /// secondary: only weight and color change, so the row never reflows (UI-SPEC Typography).
    private func number(_ value: String, active: Bool) -> some View {
        Text(verbatim: value)
            .font(.body)
            .fontWeight(active ? .semibold : .regular)
            .monospacedDigit()
            .foregroundStyle(active ? Color.primary : Color.secondary)
            .lineLimit(1)
    }
}

/// One 24 pt helper row under an open group: no icon, no chevron, the name starting at the app
/// row's name column (x = 44), CPU and memory aligned with the app row, the 20 pt action slot
/// reserved and empty because helpers have no hover button (D-16, UI-SPEC "Helper row").
private struct HelperRow: View {
    let data: HelperRowData
    let effectiveSort: SortColumn
    let text: MetricText

    var body: some View {
        let cpu = data.cpuPercent.map { text.percent($0 / 100) } ?? "—"
        let memory = data.footprintBytes.map { text.memoryBytes($0) } ?? "—"
        HStack(spacing: 0) {
            Color.clear.frame(width: 44)
            Text(verbatim: data.name)
                .font(.body)
                .foregroundStyle(Color.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minWidth: 112, maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: 8)
            number(cpu, active: effectiveSort == .cpu)
                .minimumScaleFactor(0.85)
                .frame(width: 44, alignment: .trailing)
            Color.clear.frame(width: 4)
            number(memory, active: effectiveSort == .memory)
                .frame(width: 52, alignment: .trailing)
            Color.clear.frame(width: 4)
            Color.clear.frame(width: 20)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .help(data.help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(data.name), CPU \(cpu), memory \(memory)"))
    }

    private func number(_ value: String, active: Bool) -> some View {
        Text(verbatim: value)
            .font(.body)
            .fontWeight(active ? .semibold : .regular)
            .monospacedDigit()
            .foregroundStyle(active ? Color.primary : Color.secondary)
            .lineLimit(1)
    }
}

/// "and N more…" under an open group: plain 11 pt secondary text at the name column, not a
/// control (D-08, UI-SPEC "and N more… line").
private struct MoreLine: View {
    let count: Int

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 44)
            Text("and \(count) more…")
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 20)
    }
}
