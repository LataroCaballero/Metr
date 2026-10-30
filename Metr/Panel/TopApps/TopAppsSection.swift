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
                    AppRow(data: row, effectiveSort: display.effectiveSort, text: text)
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
/// gap 4, action 20. The gutter and the action slot are reserved and empty for now, so numbers
/// and icons keep their columns when those fill in later.
private struct AppRow: View {
    let data: TopAppRowData
    let effectiveSort: SortColumn
    let text: MetricText

    var body: some View {
        let cpu = data.cpuPercent.map { text.percent($0 / 100) } ?? "—"
        let memory = data.footprintBytes.map { text.memoryBytes($0) } ?? "—"
        HStack(spacing: 0) {
            Color.clear.frame(width: 12)
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(data.name), CPU \(cpu), memory \(memory)"))
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
