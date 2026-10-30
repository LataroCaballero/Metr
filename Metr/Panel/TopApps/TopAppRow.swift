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
    let requestForceQuit: () -> Void
    let confirmForceQuit: () -> Void
    let cancelForceQuit: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @State private var isOverButton = false
    @State private var isOverOffer = false
    @FocusState private var buttonFocused: Bool

    /// The hover Quit is offered only for a process the user may quit; never on a disabled row (D-17).
    private var canQuit: Bool { data.availability == .allowed && !isWorking }
    /// Quit or Force Quit was sent and the process has not exited yet (D-15).
    private var isWorking: Bool {
        switch data.actionState {
        case .quitting, .forceQuitting: return true
        case .rest, .didNotQuit, .confirming: return false
        }
    }
    private var showsAction: Bool { canQuit && (isHovering || buttonFocused) }

    /// Quit did not end the app: the numbers give way to the Force Quit… offer (D-15).
    private var offersForceQuit: Bool { data.actionState == .didNotQuit && data.availability == .allowed }

    var body: some View {
        if data.actionState == .confirming {
            // The confirmation replaces the row in place; the popover stays open (D-14).
            ConfirmationRow(
                variant: .app(name: data.name), cancel: cancelForceQuit, confirm: confirmForceQuit)
        } else {
            rowContent
        }
    }

    @ViewBuilder
    private var rowContent: some View {
        let cpu = text.processCPU(data.cpuPercent)
        let memory = text.processMemory(data.footprintBytes)
        let expandsLabel =
            data.isExpanded
            ? String(localized: "Collapse \(data.name)") : String(localized: "Expand \(data.name)")
        let quitLabel = String(localized: "Quit \(data.name)")
        let reading = String(localized: "\(data.name), CPU \(cpu), memory \(memory)")
        // A system row adds "System process" for VoiceOver (D-09).
        let base = data.kind == .system ? reading + ", " + String(localized: "System process") : reading
        let didNotQuit = String(localized: "\(data.name) didn't quit. It may be waiting for you.")
        let spoken =
            isWorking
            ? data.name + ", " + String(localized: "Quitting…")
            : offersForceQuit ? didNotQuit : base
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
            if isWorking {
                // The number columns give way to one line while the app closes (UI-SPEC "Row states").
                Text("Quitting…")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                    .frame(width: 100, alignment: .trailing)
            } else if offersForceQuit {
                forceQuitOffer(help: didNotQuit)
            } else {
                number(cpu, active: effectiveSort == .cpu)
                    .minimumScaleFactor(0.85)
                    .frame(width: 44, alignment: .trailing)
                Color.clear.frame(width: 4)
                number(memory, active: effectiveSort == .memory)
                    .frame(width: 52, alignment: .trailing)
            }
            Color.clear.frame(width: 4)
            actionSlot(label: quitLabel)
        }
        .opacity(isWorking ? 0.5 : 1)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: isWorking)
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
        .contextMenu { menu }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
        .accessibilityActions {
            if data.helperCount > 0 {
                Button(expandsLabel) { animatedToggle() }
            }
            if canQuit {
                Button(quitLabel) { quit() }
                Button(String(localized: "Force Quit \(data.name)…")) { requestForceQuit() }
            }
        }
    }

    /// The context menu: system-drawn, text only, sized by its content (UI-SPEC "Context menus").
    /// It is built from the same availability as the hover button. A disabled row keeps both items,
    /// greyed out, and says why on a reason line, so nothing fails silently (PROC-07, D-17).
    @ViewBuilder
    private var menu: some View {
        Button("Quit \(data.name)") { quit() }
            .disabled(!canQuit)
        Button("Force Quit \(data.name)…", role: .destructive) { requestForceQuit() }
            .disabled(!canQuit)
        if case .disabled(let reason) = data.availability {
            Divider()
            Button(reason.menuText) {}
                .disabled(true)
        }
    }

    /// The borderless "Force Quit…" that replaces the numbers after a Quit that did not end the
    /// app. It only opens the confirmation; it never force quits by itself (D-15).
    private func forceQuitOffer(help: String) -> some View {
        Button(action: requestForceQuit) {
            Text("Force Quit…")
                .font(.subheadline)
                .foregroundStyle(isOverOffer ? Color.primary : Color.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(width: 100, alignment: .trailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isOverOffer = $0 }
        .help(help)
    }

    /// The 20 pt action slot: empty at rest, and always empty on a row the user may not act on.
    /// The name of the app appears only in the `.help` and the accessibility label, both drawn by
    /// the system (E7 long-text).
    @ViewBuilder
    private func actionSlot(label: String) -> some View {
        if isWorking {
            ProgressView()
                .controlSize(.small)
                .frame(width: 20)
                .accessibilityHidden(true)
        } else if canQuit {
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
    /// The app the helper belongs to, for the confirmation wording (D-16).
    let appName: String
    let effectiveSort: SortColumn
    let text: MetricText
    let requestForceQuit: () -> Void
    let confirmForceQuit: () -> Void
    let cancelForceQuit: () -> Void

    @State private var isOverOffer = false

    private var isWorking: Bool {
        if case .forceQuitting = data.actionState { return true }
        return false
    }
    private var offersForceQuit: Bool { data.actionState == .didNotQuit && data.availability == .allowed }

    var body: some View {
        if data.actionState == .confirming {
            // The helper variant names the process and its app (D-16).
            ConfirmationRow(
                variant: .helper(name: data.name, app: appName), cancel: cancelForceQuit,
                confirm: confirmForceQuit)
        } else {
            rowContent
        }
    }

    @ViewBuilder
    private var rowContent: some View {
        let cpu = text.processCPU(data.cpuPercent)
        let memory = text.processMemory(data.footprintBytes)
        let didNotQuit = String(localized: "\(data.name) didn't quit. It may be waiting for you.")
        HStack(spacing: 0) {
            Color.clear.frame(width: 44)
            Text(verbatim: data.name)
                .font(.body)
                .foregroundStyle(Color.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minWidth: 112, maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: 8)
            if isWorking {
                Text("Quitting…")
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                    .frame(width: 100, alignment: .trailing)
            } else if offersForceQuit {
                Button(action: requestForceQuit) {
                    Text("Force Quit…")
                        .font(.subheadline)
                        .foregroundStyle(isOverOffer ? Color.primary : Color.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(width: 100, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isOverOffer = $0 }
                .help(didNotQuit)
            } else {
                number(cpu, active: effectiveSort == .cpu)
                    .minimumScaleFactor(0.85)
                    .frame(width: 44, alignment: .trailing)
                Color.clear.frame(width: 4)
                number(memory, active: effectiveSort == .memory)
                    .frame(width: 52, alignment: .trailing)
            }
            Color.clear.frame(width: 4)
            Color.clear.frame(width: 20)
        }
        .opacity(isWorking ? 0.5 : 1)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .help(data.help)
        .contextMenu { menu }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            isWorking
                ? data.name + ", " + String(localized: "Quitting…")
                : String(localized: "\(data.name), CPU \(cpu), memory \(memory)")
        )
        .accessibilityActions {
            if data.availability == .allowed, !isWorking {
                Button(String(localized: "Force Quit Process…")) { requestForceQuit() }
            }
        }
    }

    /// A helper has no graceful Quit: its only item is "Force Quit Process…" (D-16). A disabled
    /// helper shows it greyed out with the reason (D-17).
    @ViewBuilder
    private var menu: some View {
        Button("Force Quit Process…", role: .destructive) { requestForceQuit() }
            .disabled(data.availability != .allowed || isWorking)
        if case .disabled(let reason) = data.availability {
            Divider()
            Button(reason.menuText) {}
                .disabled(true)
        }
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

extension DisabledReason {
    /// The reason line of a disabled row's context menu (PROC-07, D-17).
    var menuText: String {
        switch self {
        case .systemProcess: String(localized: "System process")
        case .otherUser: String(localized: "Owned by another user")
        case .thisIsMetr: String(localized: "This is Metr")
        case .cannotSignal: String(localized: "Metr can't quit this")
        }
    }
}
