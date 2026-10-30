import AppKit
import MetrCore
import MetrRender
import SwiftUI

/// Popover content (D-08): three rings with exact numbers, a divider and the Quit footer (D-09).
/// No custom background, material or glass: the Liquid Glass comes from NSPopover (CLAUDE.md).
struct PanelView: View {
    let store: MetricsStore
    /// Closes the panel. Called on Esc (`onExitCommand`); the default keeps `PanelView(store:)` compiling.
    var onClose: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            RingsSection(store: store)
                .padding(24)
            Divider()
            HStack {
                // The leading side stays empty; Phase 3 adds "Open Window" here.
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
        .onExitCommand { onClose() }
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
        let spoken: String
        if let value, let user, let system {
            spoken = "\(value). " + String(localized: "User \(user), system \(system).")
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
            VStack(spacing: 4) {
                KeyValueRow(label: String(localized: "User"), value: user)
                KeyValueRow(label: String(localized: "System"), value: system)
            }
            .padding(.top, 4)
        }
    }

    private var memoryColumn: some View {
        let title = String(localized: "Memory")
        guard let memory = store.memory.value else {
            return MetricColumn(
                symbol: "memorychip", title: title, fill: nil, tint: .none,
                value: valueText(nil), detail: unavailable, accessibilityReading: unavailable)
        }
        let used = text.memoryUsedNumber(memory.usedBytes)
        let total = text.memoryBytes(memory.totalBytes)
        let detail = String(localized: "\(used) of \(total)")
        let word = pressureWord(memory.pressure)
        return MetricColumn(
            symbol: "memorychip",
            title: title,
            fill: memory.ringFill,
            tint: store.memoryTint,
            value: valueText(word),
            detail: detail,
            accessibilityReading: "\(pressureReading(memory.pressure)), \(detail)"
        )
    }

    private var diskColumn: some View {
        let title = String(localized: "Disk")
        guard let disk = store.disk.value else {
            return MetricColumn(
                symbol: "internaldrive", title: title, fill: nil, tint: .none,
                value: valueText(nil), detail: unavailable, accessibilityReading: unavailable)
        }
        let free = text.diskBytes(disk.availableBytes)
        let detail = String(localized: "free")
        return MetricColumn(
            symbol: "internaldrive",
            title: title,
            fill: disk.usedFraction,
            tint: store.diskTint,
            value: valueText(free),
            detail: detail,
            accessibilityReading: "\(free) \(detail)"
        )
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

/// One 11 pt row in the CPU column: label leading, number trailing (UI-SPEC "CPU column").
/// A missing value is the em dash, never a fabricated 0.
private struct KeyValueRow: View {
    let label: String
    let value: String?

    var body: some View {
        HStack(spacing: 4) {
            Text(verbatim: label)
                .foregroundStyle(Color.secondary)
            Spacer(minLength: 4)
            Text(verbatim: value ?? "—")
                .foregroundStyle(Color.primary)
                .monospacedDigit()
        }
        .font(.subheadline)
        .lineLimit(1)
    }
}
