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
    /// Esc asks this first, so it cancels an open Force Quit confirmation before the panel closes.
    let escape: PanelEscapeRouter

    /// The selected segment, remembered across openings (D-06). Stored as the column's raw value.
    @AppStorage("topAppsSort") private var sortRaw = SortColumn.cpu.rawValue
    @State private var model: TopAppsModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `model` is nil in the app. The debug renderer passes a preset one so every row state can be
    /// drawn without a click; the production call sites pass nothing.
    init(store: MetricsStore, escape: PanelEscapeRouter, model: TopAppsModel? = nil) {
        self.store = store
        self.escape = escape
        _model = State(initialValue: model ?? TopAppsModel())
    }

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
        // Esc steps back one level: an open confirmation first, the panel second (D-14, Pitfall 9).
        .onAppear { escape.cancelConfirmation = { [weak model] in model?.cancelConfirmation() ?? false } }
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
                    AppRow(
                        data: row, effectiveSort: display.effectiveSort, text: text,
                        toggle: { model.toggle(row.id) }, quit: { model.quit(row.id) },
                        requestForceQuit: { model.requestForceQuit(row.id) },
                        confirmForceQuit: { model.confirmForceQuit(row.id) },
                        cancelForceQuit: { model.cancelForceQuit(row.id) })
                    if row.isExpanded {
                        ForEach(row.helpers) { helper in
                            HelperRow(
                                data: helper, appName: row.name, effectiveSort: display.effectiveSort,
                                text: text,
                                requestForceQuit: { model.requestForceQuit(helper.id) },
                                confirmForceQuit: { model.confirmForceQuit(helper.id) },
                                cancelForceQuit: { model.cancelForceQuit(helper.id) })
                        }
                        if row.moreCount > 0 { MoreLine(count: row.moreCount, groupID: row.id) }
                    }
                }
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
