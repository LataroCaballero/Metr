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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        // The watchdog runs after the update, never inside body: it may change the freeze state.
        .onChange(of: store.processes.value?.sequence) { _, _ in model.runFreezeWatchdog() }
        // The model dies with the popover; this also covers a window that closes with the pointer inside.
        .onDisappear { model.setPointerInList(false) }
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
        // Rows are keyed by their stable id, so a reorder moves them instead of fading (D-10). The
        // animation sits on the rows container only, and Reduce Motion makes it instant.
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: display.rowIDs)
        // While the pointer is over the rows nothing moves under it (D-10, T-02-23).
        .onContinuousHover { phase in
            switch phase {
            case .active: model.setPointerInList(true)
            case .ended: model.setPointerInList(false)
            }
        }
        .background { frameReader }
        .padding(.bottom, 8)
    }

    /// The frame reader is an AppKit view, which `ImageRenderer` draws as a "prohibited" badge,
    /// so the debug renderer gets a clear view instead. Compiled out of Release.
    @ViewBuilder
    private var frameReader: some View {
        #if DEBUG
        if DebugSnapshotRenderer.isRendering {
            Color.clear
        } else {
            ScreenFrameReader { model.listScreenFrame = $0 }
        }
        #else
        ScreenFrameReader { model.listScreenFrame = $0 }
        #endif
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
        let cpu = text.processCPU(data.cpuPercent)
        let memory = text.processMemory(data.footprintBytes)
        let expandsLabel =
            data.isExpanded
            ? String(localized: "Collapse \(data.name)") : String(localized: "Expand \(data.name)")
        let reading = String(localized: "\(data.name), CPU \(cpu), memory \(memory)")
        // A system row adds "System process" for VoiceOver (D-09).
        let spoken = data.kind == .system ? reading + ", " + String(localized: "System process") : reading
        HStack(spacing: 0) {
            gutter(label: expandsLabel)
            Color.clear.frame(width: 4)
            Image(nsImage: data.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            Color.clear.frame(width: 8)
            nameSlot
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
        .accessibilityLabel(spoken)
        .accessibilityActions {
            if data.helperCount > 0 {
                Button(expandsLabel) { animatedToggle() }
            }
        }
    }

    /// The name, then the lock of a system row right after it. Both sit inside the flexible name
    /// slot, so the number columns never move (D-09, UI-SPEC "Lock marker"). Other-user rows get
    /// no lock; their actions are disabled by plan 02-10.
    private var nameSlot: some View {
        HStack(spacing: 4) {
            Text(verbatim: data.name)
                .font(.body)
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            if data.kind == .system {
                Image(systemName: "lock.fill")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                    .layoutPriority(1)
                    .accessibilityHidden(true)
            }
        }
        .frame(minWidth: 112, maxWidth: .infinity, alignment: .leading)
        .help(data.name)
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
        let cpu = text.processCPU(data.cpuPercent)
        let memory = text.processMemory(data.footprintBytes)
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

/// Reports its own frame in screen coordinates, so the freeze watchdog can tell whether the
/// pointer is still over the list when the hover end was never delivered (RESEARCH Pitfall 10, A8).
private struct ScreenFrameReader: NSViewRepresentable {
    let onChange: (CGRect?) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onChange = onChange
        view.report()
    }

    final class ReaderView: NSView {
        var onChange: ((CGRect?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            report()
        }

        override func layout() {
            super.layout()
            report()
        }

        func report() {
            guard let window else {
                onChange?(nil)
                return
            }
            onChange?(window.convertToScreen(convert(bounds, to: nil)))
        }
    }
}
