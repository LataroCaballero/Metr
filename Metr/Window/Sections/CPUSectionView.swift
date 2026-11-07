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
        }
        .formStyle(.grouped)
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

    var body: some View {
        let history = store.cpuHistory
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
        }
        .historyChart(end: end, yDomain: 0...1, yTicks: [0, 0.5, 1]) { tick in
            text.percent(tick)
        }
        // The numbers under the chart carry the same information for VoiceOver.
        .accessibilityHidden(true)
    }
}
