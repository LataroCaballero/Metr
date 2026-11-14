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

    var body: some View {
        NavigationSplitView {
            WindowSidebar(store: store, model: model)
                // 220 pt is the width the longest row needs in English ("Network" beside "↓128.4 MB/s");
                // narrower, the label truncated (found by the L10N-01 render gate, 04-06).
                .navigationSplitViewColumnWidth(min: 220, ideal: 220, max: 280)
        } detail: {
            detail
                .navigationTitle(model.section.title)
        }
    }

    // MARK: Detail

    /// The process table of this window session. It exists from the moment the window opens.
    @ViewBuilder
    private var processes: some View {
        if let table = model.processTable {
            ProcessesSectionView(store: store, model: table)
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.section {
        case .cpu:
            CPUSectionView(store: store)
        case .processes:
            processes
        case .gpu:
            GPUSectionView(store: store)
        case .memory:
            MemorySectionView(store: store)
        case .network:
            NetworkSectionView(store: store)
        case .disk:
            DiskSectionView(store: store)
        }
    }
}

/// The sidebar: the six sections as a system source list, each with its quiet trailing value. A
/// struct of its own so the DEBUG snapshot renderer can draw the real rows (the full split view
/// does not draw off screen, 03-03 A7).
struct WindowSidebar: View {
    let store: MetricsStore
    let model: WindowModel

    private let text = MetricText(locale: .current)

    var body: some View {
        sidebar
    }

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

    /// The quiet trailing value of a row (D-04) and what VoiceOver says for it. nil draws and says
    /// nothing: an unreadable metric hides only its own value, and a failed read is never shown as a
    /// number. Pending shows a dash and says only the title.
    private func sidebarValue(for section: WindowSection) -> SidebarValue {
        switch section {
        case .cpu:
            switch store.cpu {
            case .value(let reading):
                let percent = text.percent(reading.total)
                return SidebarValue(text: percent, spoken: String(localized: "CPU \(percent)"))
            case .pending: return SidebarValue(text: "—", spoken: nil)
            case .unavailable: return SidebarValue(text: nil, spoken: nil)
            }
        case .memory:
            guard let memory = store.memory.value else { return SidebarValue(text: nil, spoken: nil) }
            let word =
                switch memory.pressure {
                case .normal: String(localized: "Normal")
                case .warn: String(localized: "Elevated")
                case .critical: String(localized: "Critical")
                }
            return SidebarValue(text: word, spoken: String(localized: "Memory \(word)"))
        case .disk:
            guard let disk = store.disk.value else { return SidebarValue(text: nil, spoken: nil) }
            let free = text.diskBytes(disk.availableBytes)
            return SidebarValue(
                text: String(localized: "\(free) free"), spoken: String(localized: "Disk, \(free) free"))
        case .gpu:
            // Nothing while pending or unreadable: never a fake 0 (D-04, D-20).
            guard let gpu = store.gpu.value else { return SidebarValue(text: nil, spoken: nil) }
            let percent = text.percent(gpu.utilization)
            return SidebarValue(text: percent, spoken: String(localized: "GPU \(percent)"))
        case .network:
            // The download rate alone (D-04), in the system's units. "—" until the second sample;
            // nothing when the counters cannot be read: never a fake 0. The arrow is for the eye only.
            switch store.network {
            case .value(let reading):
                let rate = text.rate(reading.downBytesPerSec)
                return SidebarValue(
                    text: "\u{2193}" + rate, spoken: String(localized: "Network, download \(rate)"))
            case .pending: return SidebarValue(text: "—", spoken: nil)
            case .unavailable: return SidebarValue(text: nil, spoken: nil)
            }
        case .processes:
            // Processes never has a sidebar value.
            return SidebarValue(text: nil, spoken: nil)
        }
    }
}

/// What a sidebar row shows at its trailing edge and what VoiceOver says for the whole row. A nil
/// `spoken` leaves the title alone ("Network").
private struct SidebarValue {
    let text: String?
    let spoken: String?
}

/// One sidebar row: symbol, label, flexible space, then the quiet value. For VoiceOver it is one
/// element: the title and the value spoken as a phrase ("Network, download 2.1 megabytes per second"),
/// without the arrow that is only for the eye.
private struct SidebarRow: View {
    let section: WindowSection
    let value: SidebarValue

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilitySwitchControlEnabled) private var switchControl

    var body: some View {
        let row = HStack(spacing: 8) {
            Label(section.title, systemImage: section.symbol)
            Spacer(minLength: 4)
            if let text = value.text {
                Text(verbatim: text)
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
        }
        // The explicit phrase exists only while VoiceOver or Switch Control runs (the rule of the
        // core and volume rows); otherwise the system's own combination of the row's texts stands.
        if voiceOver || switchControl {
            row
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(value.spoken ?? section.title)
        } else {
            row.accessibilityElement(children: .combine)
        }
    }
}
