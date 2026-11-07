import Charts
import MetrCore
import MetrRender
import SwiftUI

/// The CPU section of the window (WIN-02, WIN-03; UI-SPEC "Metric Section Contracts > CPU"): the live
/// whole-Mac total, the last five minutes as a stacked User + System chart (D-07, D-08), the same
/// User and System numbers as the panel, then the cores grouped by cluster.
///
/// Nothing here is tinted, and nothing animates: a value that changes every second kept the Debug
/// window at about 14 % of a core when it used `.numericText()` (03-02), so the window gates every
/// section with `scripts/perf/window-cost.sh`.
struct CPUSectionView: View {
    let store: MetricsStore

    @Environment(\.colorSchemeContrast) private var contrast
    private let text = MetricText(locale: .current)

    var body: some View {
        let failed = { if case .unavailable = store.cpu { return true } else { return false } }()
        let total = store.cpu.value.map { text.percent($0.total) }
        let tone = ChartTone(contrast: contrast)
        return Form {
            Section {
                VStack(alignment: .leading, spacing: 0) {
                    Text("CPU")
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                    Text(verbatim: total ?? "—")
                        .font(.title)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                        .padding(.top, 4)
                    if failed {
                        Text("Unavailable")
                            .font(.subheadline)
                            .foregroundStyle(Color.secondary)
                    }
                    CPUHistoryChart(store: store, tone: tone, text: text)
                        .padding(.top, 8)
                    ChartLegendRow(items: [
                        (String(localized: "User"), tone.seriesA),
                        (String(localized: "System"), tone.seriesB),
                    ])
                    .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                LabeledContent("User", value: store.cpu.value.map { text.percent($0.user) } ?? "—")
                    .monospacedDigit()
                LabeledContent("System", value: store.cpu.value.map { text.percent($0.system) } ?? "—")
                    .monospacedDigit()
            }
            // One section per core cluster, in hw.perflevelN order (WIN-03, D-09).
            ForEach(clusters) { cluster in
                ClusterSection(cluster: cluster, text: text)
            }
        }
        .formStyle(.grouped)
    }

    /// The cluster sections to draw. With a reading they come from its clusters; before the first
    /// sample or after a failed read they come from the system's tiers with track-only bars, so the
    /// names and counts are there at open. A split that cannot be read gives none: no invented P/E.
    private var clusters: [CoreCluster] {
        let levels = store.coreLevels
        if let reading = store.cpu.value {
            return reading.clusters.enumerated().compactMap { index, cluster in
                let count = levels.first { $0.name == cluster.name }?.logicalCPUs ?? cluster.coreUsage.count
                guard count > 0 else { return nil }
                let usage: [Double?] =
                    cluster.coreUsage.count == count ? cluster.coreUsage : Array(repeating: nil, count: count)
                return CoreCluster(id: index, name: cluster.name, usage: usage)
            }
        }
        return levels.enumerated().map { index, level in
            CoreCluster(id: index, name: level.name, usage: Array(repeating: nil, count: level.logicalCPUs))
        }
    }
}

/// One core cluster as the view draws it: the system's tier name and one fraction per core, nil
/// while there is none to show.
private struct CoreCluster: Identifiable {
    let id: Int
    let name: String
    let usage: [Double?]
}

/// A cluster's Form section: a header with the tier name and core count, then the per-core grid.
private struct ClusterSection: View {
    let cluster: CoreCluster
    let text: MetricText

    var body: some View {
        Section {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 24)], spacing: 8) {
                ForEach(Array(cluster.usage.enumerated()), id: \.offset) { index, fraction in
                    CoreBarRow(
                        number: index + 1, tier: cluster.name, fraction: fraction,
                        percent: fraction.map { text.percent($0) })
                }
            }
        } header: {
            Text(verbatim: Self.title(for: cluster.name, count: cluster.usage.count))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(cluster.name)
        }
    }

    /// The tier name through the localized table for the names this app knows; any other system
    /// name is shown raw (UI-SPEC "Cores"). Plural variations live in the catalog.
    static func title(for name: String, count: Int) -> String {
        switch name {
        case "Performance": String(localized: "Performance · \(count) cores")
        case "Efficiency": String(localized: "Efficiency · \(count) cores")
        case "Super": String(localized: "Super · \(count) cores")
        default: String(localized: "\(name) · \(count) cores")
        }
    }
}

/// One core: its number within the cluster, an 8 pt capsule bar and the percent. Never tinted, and
/// never animated (the width changes once per second; a spring would blur the exact number).
private struct CoreBarRow: View {
    let number: Int
    let tier: String
    let fraction: Double?
    let percent: String?

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilitySwitchControlEnabled) private var switchControl

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: String(number))
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
                .monospacedDigit()
                .frame(width: 20, alignment: .trailing)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(contrast == .increased ? 0.30 : 0.15))
                // Under 1 % the track only, so no stray cap shows; at 99.5 % and over a full capsule.
                if let fraction, fraction >= 0.01 {
                    Capsule()
                        .fill(Color.primary)
                        .scaleEffect(x: fraction >= 0.995 ? 1 : fraction, y: 1, anchor: .leading)
                }
            }
            .frame(height: 8)
            Text(verbatim: percent ?? "—")
                .font(.subheadline)
                .foregroundStyle(Color.primary)
                .monospacedDigit()
                .frame(width: 36, alignment: .trailing)
        }
        .frame(height: 20)
        .modifier(RowAccessibility(enabled: voiceOver || switchControl, label: spokenName, value: percent ?? ""))
    }

    /// "Performance core 1": the tier through the localized table, any other tier by its raw name.
    private var spokenName: String {
        switch tier {
        case "Performance": String(localized: "Performance core \(number)")
        case "Efficiency": String(localized: "Efficiency core \(number)")
        case "Super": String(localized: "Super core \(number)")
        default: String(localized: "\(tier) core \(number)")
        }
    }
}

/// One contiguous run of CPU samples, ready to plot: every point has a value.
private struct CPURun: Identifiable {
    struct Point: Identifiable {
        let id: Int
        let date: Date
        let user: Double
        let system: Double
        var total: Double { user + system }
    }

    let id: Int
    let points: [Point]
}

/// The stacked User + System chart over the store's CPU history. The chart is only built while the
/// CPU section is on screen, so a hidden chart costs nothing.
private struct CPUHistoryChart: View {
    let store: MetricsStore
    let tone: ChartTone
    let text: MetricText

    /// The pointer's position over the plot, nil while it is away (the hover readout).
    @State private var selection: Date? = initialChartSelection()
    /// The history as it was when the pointer entered: while the pointer is over the chart the plot
    /// and its domain hold still so the readout does not drift. The hero numbers keep updating.
    @State private var frozen: HistoryBuffer<SeriesPair>?

    var body: some View {
        let history = frozen ?? store.cpuHistory
        // A pending or failed sample is a gap (a break between runs), never a plotted zero. The gap
        // limit lets one missed tick pass but splits at a sleep.
        let runs: [CPURun] = ChartSegments.runs(history.samples, maxGap: 3.5).map { run in
            CPURun(
                id: run.id,
                points: run.samples.enumerated().compactMap { index, sample in
                    sample.value.map {
                        CPURun.Point(
                            id: index, date: HistoryChartTime.date(sample.time),
                            user: $0.first, system: $0.second)
                    }
                })
        }
        // One sample draws a point, not a line. Pre-filtered because the Charts builder must not
        // hold an `if` while the deployment target is below 27.
        let singles = runs.filter { $0.points.count == 1 }
        // The domain ends at the newest sample, or at the session start while there is none, so the
        // empty axes draw at open and the plot moves only when data arrives.
        let end = HistoryChartTime.date(
            history.latestTime ?? store.windowSessionStart ?? Date.now.timeIntervalSinceReferenceDate)

        let readouts = ChartHoverReadout.at(selection, in: history.samples) { value in
            [
                .init(
                    id: 0, swatch: tone.colorA,
                    text: "\(String(localized: "User")) \(text.percent(value.first))"),
                .init(
                    id: 1, swatch: tone.colorB,
                    text: "\(String(localized: "System")) \(text.percent(value.second))"),
            ]
        }

        return Chart {
            ForEach(runs) { run in
                ForEach(run.points) { point in
                    AreaMark(
                        x: .value(ChartLabel.time, point.date), y: .value(ChartLabel.user, point.user),
                        series: .value(ChartLabel.series, "user-\(run.id)"), stacking: .standard
                    )
                    .interpolationMethod(.linear)
                    .foregroundStyle(tone.colorA)
                    AreaMark(
                        x: .value(ChartLabel.time, point.date), y: .value(ChartLabel.system, point.system),
                        series: .value(ChartLabel.series, "system-\(run.id)"), stacking: .standard
                    )
                    .interpolationMethod(.linear)
                    .foregroundStyle(tone.colorB)
                    LineMark(
                        x: .value(ChartLabel.time, point.date), y: .value(ChartLabel.total, point.total),
                        series: .value(ChartLabel.series, "total-\(run.id)")
                    )
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .foregroundStyle(tone.colorLine)
                }
            }
            ForEach(singles) { run in
                ForEach(run.points) { point in
                    PointMark(x: .value(ChartLabel.time, point.date), y: .value(ChartLabel.total, point.total))
                        .symbolSize(24)
                        .foregroundStyle(tone.colorLine)
                }
            }
            ChartReadoutRule(readouts: readouts, tone: tone)
        }
        .historyChart(end: end, yDomain: 0...1, yTicks: [0, 0.5, 1], selection: $selection) { tick in
            text.percent(tick)
        }
        .onChange(of: selection) { _, new in
            frozen = new == nil ? nil : (frozen ?? store.cpuHistory)
        }
        .onDisappear {
            selection = nil
            frozen = nil
        }
        .chartAccessibility(
            metric: String(localized: "CPU"),
            summary: ChartSummary.make(history.samples.map { $0.value.map { $0.first + $0.second } }),
            series: [
                history.descriptorSeries(named: String(localized: "User")) { $0.first },
                history.descriptorSeries(named: String(localized: "System")) { $0.second },
            ],
            format: { text.percent($0) })
    }
}

/// The spoken form of a core row ("Performance core 1, 41 percent"), applied only while VoiceOver or
/// Switch Control runs. An explicit accessibility element on each of the ten-odd rows, whose
/// content changes every second, kept the Debug window at 5 to 9 % of a core against about 2.5 %
/// without (window-cost.sh cpu, 03-03); the rows' plain texts stay readable without it.
private struct RowAccessibility: ViewModifier {
    let enabled: Bool
    let label: String
    let value: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
                .accessibilityValue(value)
        } else {
            content
        }
    }
}
