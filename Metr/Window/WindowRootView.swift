import MetrCore
import MetrRender
import SwiftUI

extension WindowSection {
    /// The sidebar label and the window title (UI-SPEC Shell). The section nouns reuse the panel's keys.
    var title: String {
        switch self {
        case .cpu: String(localized: "CPU")
        case .memory: String(localized: "Memory")
        case .disk: String(localized: "Disk")
        case .network: String(localized: "Network")
        case .gpu: String(localized: "GPU")
        case .processes: String(localized: "Processes")
        }
    }

    /// The SF Symbol of the sidebar row (UI-SPEC Design System).
    var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .disk: "internaldrive"
        case .network: "network"
        case .gpu: "square.3.layers.3d"
        case .processes: "list.bullet.rectangle"
        }
    }
}

/// The window's content (WIN-01): a system sidebar with the six sections and, beside it, the detail
/// of the selected one. Standard containers only: no custom background, material or glass, so the
/// system draws the Liquid Glass sidebar, toolbar and scroll edge itself (UI-SPEC Glass policy).
struct WindowRootView: View {
    let store: MetricsStore
    let model: WindowModel

    private let text = MetricText(locale: .current)

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            detail
                .navigationTitle(model.section.title)
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        let selection = Binding<WindowSection?>(
            get: { model.section },
            // A click on empty sidebar space clears the selection; the section stays.
            set: { if let section = $0 { model.section = section } })
        return List(selection: selection) {
            ForEach(WindowSection.allCases, id: \.self) { section in
                SidebarRow(section: section, value: sidebarValue(for: section))
                    .tag(section)
            }
        }
        .listStyle(.sidebar)
    }

    /// The quiet trailing value of a row (D-04). nil draws nothing: an unreadable metric hides only
    /// its own value, and a failed read is never shown as a number.
    private func sidebarValue(for section: WindowSection) -> String? {
        switch section {
        case .cpu:
            switch store.cpu {
            case .value(let reading): return text.percent(reading.total)
            case .pending: return "—"
            case .unavailable: return nil
            }
        case .memory:
            guard let memory = store.memory.value else { return nil }
            switch memory.pressure {
            case .normal: return String(localized: "Normal")
            case .warn: return String(localized: "Elevated")
            case .critical: return String(localized: "Critical")
            }
        case .disk:
            guard let disk = store.disk.value else { return nil }
            return String(localized: "\(text.diskBytes(disk.availableBytes)) free")
        case .network, .gpu, .processes:
            // Network and GPU get their values with their own plans; Processes never has one.
            return nil
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch model.section {
        case .cpu:
            CPUHeroView(store: store)
        case .memory, .disk, .network, .gpu, .processes:
            // Later plans of this phase fill these sections. Until then the column stays empty.
            Color.clear
        }
    }
}

/// One sidebar row: symbol, label, flexible space, then the quiet value.
private struct SidebarRow: View {
    let section: WindowSection
    let value: String?

    var body: some View {
        HStack(spacing: 8) {
            Label(section.title, systemImage: section.symbol)
            Spacer(minLength: 4)
            if let value {
                Text(verbatim: value)
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The CPU detail for now: the live whole-Mac total as the hero value. Plan 03-03 replaces it with
/// the full CPU section (history chart, per-core bars).
private struct CPUHeroView: View {
    let store: MetricsStore

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let text = MetricText(locale: .current)

    var body: some View {
        let total = store.cpu.value.map { text.percent($0.total) }
        var failed = false
        if case .unavailable = store.cpu { failed = true }
        return Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("CPU")
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                    Text(verbatim: total ?? "—")
                        .font(.title)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                        .contentTransition(reduceMotion ? .identity : .numericText())
                        .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: total)
                    if failed {
                        Text("Unavailable")
                            .font(.subheadline)
                            .foregroundStyle(Color.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }
        .formStyle(.grouped)
    }
}
