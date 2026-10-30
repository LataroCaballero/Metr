import AppKit
import MetrCore
import MetrRender
import SwiftUI

/// Decides what Esc does while the panel is open (D-14, RESEARCH Pitfall 9). The Top Apps section
/// hands it a closure that cancels an open Force Quit confirmation; Esc closes the panel only when
/// there was nothing to cancel. One router per presentation of the panel.
@MainActor
final class PanelEscapeRouter {
    /// Cancels the open confirmation and returns true, or returns false when none is open.
    var cancelConfirmation: (() -> Bool)?

    /// True when Esc was used up by a confirmation, so the panel must stay open.
    func handleEscape() -> Bool {
        cancelConfirmation?() ?? false
    }
}

/// Popover content (D-08): three rings with exact numbers, a divider and the Quit footer (D-09).
/// No custom background, material or glass: the Liquid Glass comes from NSPopover (CLAUDE.md).
struct PanelView: View {
    let store: MetricsStore
    /// Closes the panel. Called on Esc (`onExitCommand`); the default keeps `PanelView(store:)` compiling.
    var onClose: () -> Void = {}
    /// Esc priority: an open confirmation is cancelled before the panel closes. A fresh router by
    /// default, so `PanelView(store:)` keeps compiling.
    var escape = PanelEscapeRouter()

    /// True while the other-users half of the process list cannot be read (E5 partial): the panel
    /// says so instead of silently showing an incomplete list. Clears on the next successful read.
    private var systemProcessesMissing: Bool {
        store.processes.value?.otherUsers == .unavailable
    }

    var body: some View {
        VStack(spacing: 0) {
            RingsSection(store: store)
                .padding(24)
            Divider()
            StatusLine(store: store)
            Divider()
            TopAppsSection(store: store, escape: escape)
            Divider()
            HStack {
                // The leading side holds the partial-state line; Phase 3 adds "Open Window" here.
                // The footer height is set by the Quit button, so the line never resizes the panel.
                if systemProcessesMissing {
                    Text("System processes not shown.")
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                #if DEBUG
                if DebugHooks.shellSpikeEnabled {
                    Button {
                        onClose()
                        ShellSpikeWindow.bringToFront()
                    } label: {
                        Text(verbatim: "Bring Window to Front")
                    }
                    .buttonStyle(.bordered)
                }
                #endif
                Spacer()
                Button("Quit Metr") { NSApp.terminate(nil) }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .keyboardShortcut("q", modifiers: .command)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 320)
        .onExitCommand { if !escape.handleEscape() { onClose() } }
    }
}

/// The rings row, isolated so Phase 2 can add sections below it and above the footer
/// without touching it.
private struct RingsSection: View {
    let store: MetricsStore

    private let text = MetricText(locale: .current)

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            cpuColumn
            memoryColumn
            diskColumn
        }
    }

    private var cpuColumn: some View {
        let title = String(localized: "CPU")
        let reading = store.cpu.value
        let value = reading.map { text.percent($0.total) }
        let user = reading.map { text.percent($0.user) }
        let system = reading.map { text.percent($0.system) }
        var failed = false
        if case .unavailable = store.cpu { failed = true }
        // One block per perflevel. A value carries the cluster figures; while pending or failed the
        // names come from the system so the bars can draw their track (E1). If the layout does not
        // add up there are no clusters and the blocks are omitted, never invented (E1 partial).
        let clusters: [ClusterBarModel]
        if let reading {
            clusters = reading.clusters.map {
                ClusterBarModel(name: $0.name, fraction: $0.usage, percent: text.percent($0.usage))
            }
        } else {
            clusters = store.coreLevelNames.map { ClusterBarModel(name: $0, fraction: nil, percent: nil) }
        }
        let spoken: String
        if let value, let user, let system {
            var parts = ["\(value). " + String(localized: "User \(user), system \(system).")]
            if !clusters.isEmpty {
                parts.append(clusters.map { Self.spokenCluster($0) }.joined(separator: ", ") + ".")
            }
            spoken = parts.joined(separator: " ")
        } else {
            spoken = unavailable
        }
        return MetricColumn(
            symbol: "cpu",
            title: title,
            fill: reading?.total,
            tint: TintLogic.cpu(),
            value: valueText(value),
            // Pending shows the em dash alone; only a failed read says "Unavailable" (E1).
            detail: failed ? unavailable : nil,
            accessibilityReading: spoken
        ) {
            VStack(spacing: 0) {
                VStack(spacing: 4) {
                    KeyValueRow(label: String(localized: "User"), value: user)
                    KeyValueRow(label: String(localized: "System"), value: system)
                }
                if !clusters.isEmpty {
                    VStack(spacing: 4) {
                        ForEach(clusters, id: \.name) { cluster in
                            ClusterBlock(
                                label: Self.clusterLabel(cluster.name), fullName: cluster.name,
                                fraction: cluster.fraction, percent: cluster.percent)
                        }
                    }
                    .padding(.top, 8)
                }
            }
            .padding(.top, 4)
        }
    }

    /// The displayed cluster label: the system tier name through a localized abbreviation table,
    /// the raw name for any tier this table does not know (CPU-02). Never a hard-coded letter pair.
    private static func clusterLabel(_ systemName: String) -> String {
        switch systemName {
        case "Performance": String(localized: "Perf")
        case "Efficiency": String(localized: "Eff")
        case "Super": String(localized: "Super")
        default: systemName
        }
    }

    private static func spokenCluster(_ cluster: ClusterBarModel) -> String {
        let percent = cluster.percent ?? "—"
        switch cluster.name {
        case "Performance": return String(localized: "Performance cores \(percent)")
        case "Efficiency": return String(localized: "Efficiency cores \(percent)")
        case "Super": return String(localized: "Super cores \(percent)")
        default: return String(localized: "\(cluster.name) cores \(percent)")
        }
    }

    private var memoryColumn: some View {
        let title = String(localized: "Memory")
        guard let memory = store.memory.value else {
            return MetricColumn(
                symbol: "memorychip", title: title, fill: nil, tint: .none,
                value: valueText(nil), detail: unavailable, accessibilityReading: unavailable
            ) { Self.extraLine(nil) }
        }
        let used = text.memoryUsedNumber(memory.usedBytes)
        let total = text.memoryBytes(memory.totalBytes)
        let detail = String(localized: "\(used) of \(total)")
        let word = pressureWord(memory.pressure)
        var spoken = "\(pressureReading(memory.pressure)), \(detail)"
        // Swap appears only while it is in use, and takes no reserved line otherwise (D-03).
        var swapLine: String?
        if memory.swapUsedBytes > 0 {
            let swap = text.memoryBytes(memory.swapUsedBytes)
            swapLine = String(localized: "Swap \(swap)")
            spoken += String(
                localized: "Memory.SwapSpoken", defaultValue: ", swap \(swap)",
                comment: "VoiceOver suffix of the Memory column, only while swap is in use")
        }
        return MetricColumn(
            symbol: "memorychip",
            title: title,
            fill: memory.ringFill,
            tint: store.memoryTint,
            value: valueText(word),
            detail: detail,
            accessibilityReading: spoken
        ) { Self.extraLine(swapLine) }
    }

    private var diskColumn: some View {
        let title = String(localized: "Disk")
        guard let disk = store.disk.value else {
            return MetricColumn(
                symbol: "internaldrive", title: title, fill: nil, tint: .none,
                value: valueText(nil), detail: unavailable, accessibilityReading: unavailable
            ) { Self.extraLine(nil) }
        }
        let free = text.diskBytes(disk.availableBytes)
        let detail = String(localized: "free")
        // Used = total minus the important-usage free figure, so the two lines add up to the
        // total shown in the tooltip (D-04). Clamped so a transient odd reading never goes negative.
        let used = String(localized: "\(text.diskBytes(max(0, disk.totalBytes - disk.availableBytes))) used")
        return MetricColumn(
            symbol: "internaldrive",
            title: title,
            fill: disk.usedFraction,
            tint: store.diskTint,
            value: valueText(free),
            detail: detail,
            accessibilityReading: "\(free) \(detail), \(used)"
        ) { Self.extraLine(used) }
    }

    /// An 11 pt secondary line below the detail (Swap, used). nil draws nothing, not even a
    /// reserved gap, so columns may differ in height (D-03).
    @ViewBuilder
    private static func extraLine(_ line: String?) -> some View {
        if let line {
            Text(verbatim: line)
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .padding(.top, 4)
        }
    }

    private var unavailable: String { String(localized: "Unavailable") }

    /// A pending or unavailable reading shows an em dash, never a fabricated 0.
    private func valueText(_ value: String?) -> Text {
        if let value { return Text(verbatim: value) }
        return Text(verbatim: "—")
    }

    private func pressureWord(_ pressure: MemoryPressure) -> String {
        switch pressure {
        case .normal: String(localized: "Normal")
        case .warn: String(localized: "Elevated")
        case .critical: String(localized: "Critical")
        }
    }

    private func pressureReading(_ pressure: MemoryPressure) -> String {
        switch pressure {
        case .normal: String(localized: "Normal pressure")
        case .warn: String(localized: "Elevated pressure")
        case .critical: String(localized: "Critical pressure")
        }
    }
}

/// The quiet band under the rings: the plain-language pressure sentence and the always-visible
/// thermal state (D-01, D-05, D-18, D-19; PANEL-02, PANEL-05).
///
/// Two text lines are reserved permanently (44 pt with padding), so a pressure or thermal change
/// while the popover is open never resizes it (E4). The line is built from `Text` interpolation of
/// `Text` values: the `Text + Text` operator is deprecated on macOS 26 (RESEARCH Pitfall 12).
private struct StatusLine: View {
    let store: MetricsStore

    var body: some View {
        let sentence = store.memory.value.map { Self.sentence($0.pressure) }
        let word = Self.thermalWord(store.thermal)
        let text = Self.line(sentence: sentence, thermal: store.thermal)
        // An invisible block of two real lines reserves the height and the visible copy sits centered
        // over it, so a one-line message is vertically centered (UI-SPEC "Status line"). Two real
        // lines, not `lineLimit(2, reservesSpace: true)`: that reserve is 1 pt shorter than two
        // wrapped lines, so a Critical sentence either resized the panel or lost its second line (E4).
        return VStack(spacing: 0) {
            Text(verbatim: "\u{00A0}")
            Text(verbatim: "\u{00A0}")
        }
            .frame(maxWidth: .infinity)
            .opacity(0)
            .overlay { text.lineLimit(2) }
            .font(.subheadline)
            .foregroundStyle(Color.secondary)
            .multilineTextAlignment(.center)
            .padding(.vertical, 8)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.spoken(sentence: sentence, word: word))
    }

    /// `<sentence> · Thermal <state>`, or the thermal phrase alone when the pressure level is
    /// unreadable (E4 error). Only the state word is tinted, Normal stays secondary (D-05).
    private static func line(sentence: String?, thermal: ThermalLevel) -> Text {
        let state: Text = {
            let word = Text(verbatim: thermalWord(thermal))
            guard let color = TintPalette.color(for: thermal.tint) else {
                return word.foregroundStyle(Color.secondary)
            }
            return word.fontWeight(.semibold).foregroundStyle(Color(nsColor: color))
        }()
        // The label and the state word are joined by a no-break space so the phrase never splits
        // across the two lines. One catalog key holds the label, the space and the word slot, so ES
        // can word the whole phrase ("Estado térmico normal").
        let phrase = Text("Thermal\u{00A0}\(state)")
        guard let sentence else { return phrase }
        return Text("\(Text(verbatim: sentence)) · \(phrase)")
    }

    private static func spoken(sentence: String?, word: String) -> String {
        let thermal = String(localized: "Thermal state: \(word)")
        guard let sentence else { return thermal }
        return sentence + " " + thermal
    }

    /// D-18, keyed off the same kernel level as the Memory ring so ring, word and sentence agree.
    private static func sentence(_ pressure: MemoryPressure) -> String {
        switch pressure {
        case .normal: String(localized: "Plenty of memory available.")
        case .warn: String(localized: "Memory is getting tight.")
        case .critical: String(localized: "Memory is very low. Quit apps you don't need.")
        }
    }

    /// Masculine state words, separate keys from the feminine memory-pressure words in ES.
    private static func thermalWord(_ level: ThermalLevel) -> String {
        switch level {
        case .normal:
            String(localized: "Thermal.Normal", defaultValue: "Normal", comment: "Thermal state word after the Thermal label")
        case .elevated:
            String(localized: "Thermal.Elevated", defaultValue: "Elevated", comment: "Thermal state word after the Thermal label")
        case .critical:
            String(localized: "Thermal.Critical", defaultValue: "Critical", comment: "Thermal state word after the Thermal label")
        }
    }
}

/// One 11 pt row in the CPU column: label leading, number trailing (UI-SPEC "CPU column").
/// A missing value is the em dash, never a fabricated 0.
private struct KeyValueRow: View {
    let label: String
    let value: String?

    var body: some View {
        // 'Sistema 100 %' is wider than 80 pt at full size, so there are two forms. The full-size row
        // is used whenever it fits (every EN row and most ES rows). Only when it does not, the number
        // keeps its size (it is the figure being read) and the label scales to the UI-SPEC floor
        // (0.85), with the gap tightened from 8 to 4 pt, before anything is cut.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                Text(verbatim: label).foregroundStyle(Color.secondary)
                Spacer(minLength: 4)
                Text(verbatim: value ?? "—").foregroundStyle(Color.primary).monospacedDigit()
            }
            HStack(spacing: 2) {
                Text(verbatim: label)
                    .foregroundStyle(Color.secondary)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 2)
                Text(verbatim: value ?? "—")
                    .foregroundStyle(Color.primary)
                    .monospacedDigit()
                    .layoutPriority(1)
            }
        }
        .font(.subheadline)
        .lineLimit(1)
    }
}

/// What one cluster block needs. A nil fraction and percent is the pending or failed state.
private struct ClusterBarModel {
    let name: String
    let fraction: Double?
    let percent: String?
}

/// A cluster's label and percent row with its 4 pt bar stacked beneath (UI-SPEC "CPU column").
private struct ClusterBlock: View {
    let label: String
    let fullName: String
    let fraction: Double?
    let percent: String?

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Text(verbatim: label)
                    .foregroundStyle(Color.secondary)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(verbatim: percent ?? "—")
                    .foregroundStyle(Color.primary)
                    .monospacedDigit()
            }
            .font(.subheadline)
            .lineLimit(1)
            .help(fullName)
            ClusterBar(fraction: fraction)
        }
    }
}

/// The 4 pt capsule bar: neutral track, neutral fill, never tinted (high CPU is often normal).
/// No fraction, or under 1 %, draws the track only so no stray cap shows.
private struct ClusterBar: View {
    let fraction: Double?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.primary.opacity(contrast == .increased ? 0.30 : 0.15))
            if let fraction, fraction >= 0.01 {
                Capsule()
                    .fill(Color.primary)
                    .scaleEffect(x: fraction >= 0.995 ? 1 : fraction, y: 1, anchor: .leading)
            }
        }
        .frame(height: 4)
        .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: fraction)
        .accessibilityHidden(true)
    }
}
