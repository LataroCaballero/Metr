import AppKit
import MetrCore
import MetrRender
import SwiftUI

/// One 32 pt app row. Slots, left to right, sum to the 288 pt content width (UI-SPEC "App row"):
/// gutter 12, gap 4, icon 20, gap 8, name (flex, 112 minimum), gap 8, CPU 44, gap 4, memory 52,
/// gap 4, action 20. The gutter holds the disclosure chevron of a group with helpers and is
/// reserved empty on every other row; the action slot is reserved, empty at rest and filled by the hover Quit, so numbers
/// and icons keep their columns.
struct AppRow: View {
    let data: TopAppRowData
    let effectiveSort: SortColumn
    let text: MetricText
    let toggle: () -> Void
    let quit: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @State private var isOverButton = false
    @FocusState private var buttonFocused: Bool

    /// The hover Quit is offered only for a process the user may quit; never on a disabled row (D-17).
    private var canQuit: Bool { data.availability == .allowed }
    private var showsAction: Bool { canQuit && (isHovering || buttonFocused) }

    var body: some View {
        let cpu = text.processCPU(data.cpuPercent)
        let memory = text.processMemory(data.footprintBytes)
        let expandsLabel =
            data.isExpanded
            ? String(localized: "Collapse \(data.name)") : String(localized: "Expand \(data.name)")
        let quitLabel = String(localized: "Quit \(data.name)")
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
            actionSlot(label: quitLabel)
        }
        .padding(.horizontal, 8)
        .frame(height: TopAppsSection.rowHeight)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(showsAction ? 0.08 : 0))
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: showsAction)
        .onHover { isHovering = $0 }
        .contentShape(Rectangle())
        // Tapping anywhere on a group row toggles it; a row with no helpers is not a control.
        .onTapGesture { if data.helperCount > 0 { animatedToggle() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityActions {
            if data.helperCount > 0 {
                Button(expandsLabel) { animatedToggle() }
            }
            if canQuit {
                Button(quitLabel) { quit() }
            }
        }
    }

    /// The 20 pt action slot: empty at rest, and always empty on a row the user may not act on.
    /// The name of the app appears only in the `.help` and the accessibility label, both drawn by
    /// the system (E7 long-text).
    @ViewBuilder
    private func actionSlot(label: String) -> some View {
        if canQuit {
            Button(action: quit) {
                Image(systemName: "xmark.circle.fill")
                    .font(.body)
                    .imageScale(.large)
                    .foregroundStyle(isOverButton ? Color.primary : Color.secondary)
            }
            .buttonStyle(.plain)
            .onHover { isOverButton = $0 }
            .focused($buttonFocused)
            .opacity(showsAction ? 1 : 0)
            .allowsHitTesting(showsAction)
            .help(label)
            .accessibilityLabel(label)
            .frame(width: 20)
        } else {
            Color.clear.frame(width: 20)
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
struct HelperRow: View {
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
struct MoreLine: View {
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
