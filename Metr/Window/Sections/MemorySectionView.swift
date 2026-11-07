import Charts
import MetrCore
import MetrRender
import SwiftUI

/// The Memory section of the window (WIN-02; UI-SPEC "Metric Section Contracts > Memory", D-08): the
/// pressure word, the plain-language sentence from the panel, the last five minutes of pressure as a
/// chart tinted per sample, and how much memory and swap are in use. It is the spirit of Activity
/// Monitor's pressure graph, with the number that matters spelled out.
///
/// Only the chart's samples carry the tint (orange at Elevated, red at Critical). The hero word is
/// never tinted, as only the ring arc is in the panel. Nothing here animates; the section is gated
/// by `scripts/perf/window-cost.sh`.
struct MemorySectionView: View {
    let store: MetricsStore

    @Environment(\.colorSchemeContrast) private var contrast
    private let text = MetricText(locale: .current)

    var body: some View {
        let reading = store.memory.value
        let failed = { if case .unavailable = store.memory { return true } else { return false } }()
        let tone = ChartTone(contrast: contrast)
        return Form {
            Section {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Memory pressure")
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                    Text(verbatim: reading.map { Self.word($0.pressure) } ?? "—")
                        .font(.title)
                        .fontWeight(.semibold)
                        .padding(.top, 4)
                    if let reading {
                        Text(Self.sentence(reading.pressure))
                            .font(.body)
                            .foregroundStyle(Color.secondary)
                            .lineLimit(2)
                    } else if failed {
                        Text("Unavailable")
                            .font(.subheadline)
                            .foregroundStyle(Color.secondary)
                    }
                    MemoryHistoryChart(store: store, tone: tone)
                        .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Unreadable memory shows no rows at all (W5 error); before the first sample they read "—".
            if !failed {
                Section {
                    LabeledContent("Memory used", value: usedText(reading))
                        .monospacedDigit()
                    // Swap takes no row, and no placeholder, while it is not in use (Phase 2 D-03).
                    if let reading, reading.swapUsedBytes > 0 {
                        LabeledContent("Swap used", value: text.memoryBytes(reading.swapUsedBytes))
                            .monospacedDigit()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// "11.2 of 16 GB", the panel's own formatters and key; "—" until the first sample.
    private func usedText(_ reading: MemoryReading?) -> String {
        guard let reading else { return "—" }
        let used = text.memoryUsedNumber(reading.usedBytes)
        let total = text.memoryBytes(reading.totalBytes)
        return String(localized: "\(used) of \(total)")
    }

    /// The pressure word, the same keys as the sidebar and the panel.
    static func word(_ pressure: MemoryPressure) -> String {
        switch pressure {
        case .normal: String(localized: "Normal")
        case .warn: String(localized: "Elevated")
        case .critical: String(localized: "Critical")
        }
    }

    /// The Phase 2 pressure sentence, the panel's keys.
    static func sentence(_ pressure: MemoryPressure) -> String {
        switch pressure {
        case .normal: String(localized: "Plenty of memory available.")
        case .warn: String(localized: "Memory is getting tight.")
        case .critical: String(localized: "Memory is very low. Quit apps you don't need.")
        }
    }
}

/// One run of memory samples at one pressure level, ready to plot, with the style of its level.
/// The tint is a property of the run, so no `if` sits inside the `Chart { }` builder.
private struct MemoryRun: Identifiable {
    struct Point: Identifiable {
        let id: Int
        let date: Date
        let fill: Double
    }

    let id: Int
    let points: [Point]
    let area: Color
    let line: Color

    /// The colour of a level for the readout's swatch: the line colour of its runs.
    static func swatch(_ pressure: MemoryPressure, tone: ChartTone) -> Color {
        switch pressure {
        case .normal: tone.colorA
        case .warn: Color(nsColor: TintPalette.elevated)
        case .critical: Color(nsColor: TintPalette.critical)
        }
    }

    /// Normal keeps the neutral series A and a primary line; Elevated and Critical use the single
    /// palette definition at 0.55 with a full-strength line (UI-SPEC "Chart and bar tones").
    init(id: Int, points: [Point], pressure: MemoryPressure, tone: ChartTone) {
        self.id = id
        self.points = points
        switch pressure {
        case .normal:
            area = tone.colorA
            line = tone.colorLine
        case .warn:
            area = Color(nsColor: TintPalette.elevated).opacity(0.55)
            line = Color(nsColor: TintPalette.elevated)
        case .critical:
            area = Color(nsColor: TintPalette.critical).opacity(0.55)
            line = Color(nsColor: TintPalette.critical)
        }
    }
}

/// The pressure chart over the store's memory history. Built only while the Memory section is on
/// screen, so a hidden chart costs nothing.
private struct MemoryHistoryChart: View {
    let store: MetricsStore
    let tone: ChartTone

    private let text = MetricText(locale: .current)
    /// The pointer's position over the plot, nil while it is away (the hover readout).
    @State private var selection: Date? = initialChartSelection()
    /// The history as it was when the pointer entered; see `CPUHistoryChart`.
    @State private var frozen: HistoryBuffer<MemoryHistoryValue>?

    var body: some View {
        let history = frozen ?? store.memoryHistory
        // A pending or failed sample is a gap, never a plotted zero. A new pressure level begins a
        // new run on the previous run's last sample, so the tinted segments touch (WIN-02).
        let runs: [MemoryRun] = ChartSegments.runs(history.samples, maxGap: 3.5, key: { $0.pressure }).map { run in
            MemoryRun(
                id: run.id,
                points: run.samples.enumerated().compactMap { index, sample in
                    sample.value.map {
                        MemoryRun.Point(id: index, date: HistoryChartTime.date(sample.time), fill: $0.fill)
                    }
                },
                pressure: run.key, tone: tone)
        }
        // One sample draws a point, not a line. Pre-filtered because the Charts builder must not
        // hold an `if` while the deployment target is below 27.
        let singles = runs.filter { $0.points.count == 1 }
        let end = HistoryChartTime.date(
            history.latestTime ?? store.windowSessionStart ?? Date.now.timeIntervalSinceReferenceDate)

        // The readout names the pressure level, as the hero does; the swatch carries its tint.
        let readouts = ChartHoverReadout.at(selection, in: history.samples) { value in
            [.init(id: 0, swatch: MemoryRun.swatch(value.pressure, tone: tone), text: MemorySectionView.word(value.pressure))]
        }

        return Chart {
            ForEach(runs) { run in
                ForEach(run.points) { point in
                    // Unstacked: two runs share a boundary sample, and stacking would add them there.
                    AreaMark(
                        x: .value(ChartLabel.time, point.date), y: .value(ChartLabel.total, point.fill),
                        series: .value(ChartLabel.series, "area-\(run.id)"), stacking: .unstacked
                    )
                    .interpolationMethod(.linear)
                    .foregroundStyle(run.area)
                    LineMark(
                        x: .value(ChartLabel.time, point.date), y: .value(ChartLabel.total, point.fill),
                        series: .value(ChartLabel.series, "line-\(run.id)")
                    )
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .foregroundStyle(run.line)
                }
            }
            ForEach(singles) { run in
                ForEach(run.points) { point in
                    PointMark(x: .value(ChartLabel.time, point.date), y: .value(ChartLabel.total, point.fill))
                        .symbolSize(24)
                        .foregroundStyle(run.line)
                }
            }
            ChartReadoutRule(readouts: readouts, tone: tone)
        }
        // Gridlines at 0 / 50 / 100 with the labels hidden: the figure is a kernel free-percentage
        // inverse, not a number the user can check; the hero word is the reading.
        .historyChart(end: end, yDomain: 0...1, yTicks: [0, 0.5, 1], selection: $selection) { _ in nil }
        .onChange(of: selection) { _, new in
            frozen = new == nil ? nil : (frozen ?? store.memoryHistory)
        }
        .onDisappear {
            selection = nil
            frozen = nil
        }
        // VoiceOver hears the same ring signal the panel's ring shows, as a percent.
        .chartAccessibility(
            metric: String(localized: "Memory"), summary: ChartSummary.make(history.samples.map { $0.value?.fill }),
            series: [history.descriptorSeries(named: String(localized: "Memory")) { $0.fill }],
            format: { text.percent($0) })
    }
}
