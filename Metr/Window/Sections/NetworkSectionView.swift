import Charts
import MetrCore
import MetrRender
import SwiftUI

/// The Network section of the window (NET-01, WIN-02; UI-SPEC "Metric Section Contracts > Network",
/// D-18): how fast data is coming in and going out right now, and the last five minutes as a
/// mirrored chart, Download above the zero line and Upload below it.
///
/// Rates are the aggregate over the physical interfaces (03-06). Nothing here is tinted and nothing
/// animates; the section is gated by `scripts/perf/window-cost.sh`.
struct NetworkSectionView: View {
    let store: MetricsStore

    @Environment(\.colorSchemeContrast) private var contrast
    private let text = MetricText(locale: .current)

    var body: some View {
        let failed = { if case .unavailable = store.network { return true } else { return false } }()
        let reading = store.network.value
        let tone = ChartTone(contrast: contrast)
        return Form {
            Section {
                VStack(alignment: .leading, spacing: 0) {
                    // 32 pt between the two heroes (UI-SPEC); the values are 22 pt semibold digits.
                    HStack(alignment: .top, spacing: 32) {
                        RateHero(
                            symbol: "arrow.down", title: String(localized: "Download"),
                            value: text.rate(reading?.downBytesPerSec))
                        RateHero(
                            symbol: "arrow.up", title: String(localized: "Upload"),
                            value: text.rate(reading?.upBytesPerSec))
                    }
                    if failed {
                        Text("Unavailable")
                            .font(.subheadline)
                            .foregroundStyle(Color.secondary)
                            .padding(.top, 4)
                    }
                    NetworkHistoryChart(store: store, tone: tone, text: text)
                        .padding(.top, 8)
                    ChartLegendRow(items: [
                        (String(localized: "Download"), tone.seriesA),
                        (String(localized: "Upload"), tone.seriesB),
                    ])
                    .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
    }
}

/// One hero value: a symbol and its label over the rate. The rate is `—` until the second sample and
/// when the counters cannot be read.
private struct RateHero: View {
    let symbol: String
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label {
                Text(verbatim: title)
            } icon: {
                Image(systemName: symbol)
            }
            .font(.subheadline)
            .foregroundStyle(Color.secondary)
            Text(verbatim: value)
                .font(.title)
                .fontWeight(.semibold)
                .monospacedDigit()
                .lineLimit(1)
                .padding(.top, 4)
        }
    }
}

/// The plot identifiers of the mirrored chart. Plain strings, not UI text (the chart is hidden from
/// VoiceOver unless its summary layer is on), so the compiler does not extract them as keys.
private enum NetworkChartLabel {
    static let download: String = "Download"
    static let upload: String = "Upload"
    static let zero: String = "Zero"
}

/// One contiguous run of network samples, ready to plot: every point has a value.
private struct NetworkRun: Identifiable {
    struct Point: Identifiable {
        let id: Int
        let date: Date
        /// Bytes per second received.
        let down: Double
        /// Bytes per second sent, positive; the chart plots it negated.
        let up: Double
    }

    let id: Int
    let points: [Point]
}

/// The mirrored chart over the store's network history: Download above the zero rule, Upload below
/// it, on a symmetric scale. Built only while the Network section is on screen, so a hidden chart
/// costs nothing.
private struct NetworkHistoryChart: View {
    let store: MetricsStore
    let tone: ChartTone
    let text: MetricText

    /// The quietest axis the chart shows on each side of zero, so idle noise does not fill the plot
    /// (UI-SPEC Chart Contract, Network: 100 kB/s).
    private static let floor: Double = 100_000

    /// The pointer's position over the plot, nil while it is away (the hover readout).
    @State private var selection: Date? = initialChartSelection()
    /// The history as it was when the pointer entered; see `CPUHistoryChart`.
    @State private var frozen: HistoryBuffer<SeriesPair>?

    var body: some View {
        let history = frozen ?? store.networkHistory
        // A pending or failed sample is a gap, never a plotted zero.
        let runs: [NetworkRun] = ChartSegments.runs(history.samples, maxGap: 3.5).map { run in
            NetworkRun(
                id: run.id,
                points: run.samples.enumerated().compactMap { index, sample in
                    sample.value.map {
                        NetworkRun.Point(
                            id: index, date: HistoryChartTime.date(sample.time), down: $0.first, up: $0.second)
                    }
                })
        }
        // One sample draws a point, not a line. Pre-filtered because the Charts builder must not
        // hold an `if` while the deployment target is below 27.
        let singles = runs.filter { $0.points.count == 1 }
        let end = HistoryChartTime.date(
            history.latestTime ?? store.windowSessionStart ?? Date.now.timeIntervalSinceReferenceDate)

        // The scale follows the visible peak of both series, rounded up to a step: ±M.
        let peak = history.samples.reduce(0.0) { max($0, $1.value.map { max($0.first, $0.second) } ?? 0) }
        let limit = RateAxis.ceiling(peak: peak, floor: Self.floor)

        let readouts = ChartHoverReadout.at(selection, in: history.samples) { value in
            [
                .init(
                    id: 0, swatch: tone.colorA,
                    text: "\(String(localized: "Download")) \(text.rate(value.first))"),
                .init(
                    id: 1, swatch: tone.colorB,
                    text: "\(String(localized: "Upload")) \(text.rate(value.second))"),
            ]
        }

        return Chart {
            ForEach(runs) { run in
                ForEach(run.points) { point in
                    AreaMark(
                        x: .value(ChartLabel.time, point.date), y: .value(NetworkChartLabel.download, point.down),
                        series: .value(ChartLabel.series, "down-\(run.id)"), stacking: .unstacked
                    )
                    .interpolationMethod(.linear)
                    .foregroundStyle(tone.colorA)
                    LineMark(
                        x: .value(ChartLabel.time, point.date), y: .value(NetworkChartLabel.download, point.down),
                        series: .value(ChartLabel.series, "down-line-\(run.id)")
                    )
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .foregroundStyle(tone.colorLine)
                    AreaMark(
                        x: .value(ChartLabel.time, point.date), y: .value(NetworkChartLabel.upload, -point.up),
                        series: .value(ChartLabel.series, "up-\(run.id)"), stacking: .unstacked
                    )
                    .interpolationMethod(.linear)
                    .foregroundStyle(tone.colorB)
                    LineMark(
                        x: .value(ChartLabel.time, point.date), y: .value(NetworkChartLabel.upload, -point.up),
                        series: .value(ChartLabel.series, "up-line-\(run.id)")
                    )
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .foregroundStyle(Color.primary.opacity(0.55))
                }
            }
            ForEach(singles) { run in
                ForEach(run.points) { point in
                    PointMark(x: .value(ChartLabel.time, point.date), y: .value(NetworkChartLabel.download, point.down))
                        .symbolSize(24)
                        .foregroundStyle(tone.colorLine)
                    PointMark(x: .value(ChartLabel.time, point.date), y: .value(NetworkChartLabel.upload, -point.up))
                        .symbolSize(24)
                        .foregroundStyle(Color.primary.opacity(0.55))
                }
            }
            // The zero line both series start from, in the grid tone.
            RuleMark(y: .value(NetworkChartLabel.zero, 0))
                .lineStyle(StrokeStyle(lineWidth: 1))
                .foregroundStyle(tone.colorGrid)
            ChartReadoutRule(readouts: readouts, tone: tone)
        }
        // Ticks at -M, 0 and +M; the labels are absolute values with the unit, "0" at the line.
        .historyChart(end: end, yDomain: -limit...limit, yTicks: [-limit, 0, limit], selection: $selection) { tick in
            tick == 0 ? "0" : text.rate(abs(tick))
        }
        .onChange(of: selection) { _, new in
            frozen = new == nil ? nil : (frozen ?? store.networkHistory)
        }
        .onDisappear {
            selection = nil
            frozen = nil
        }
        // The audio graph and the summary work on fractions of the axis (0...1); the formatter turns
        // them back into rates. The summary is the traffic in both directions together.
        .chartAccessibility(
            metric: String(localized: "Network"),
            summary: ChartSummary.make(history.samples.map { $0.value.map { ($0.first + $0.second) / limit } }),
            series: [
                history.descriptorSeries(named: String(localized: "Download")) { $0.first / limit },
                history.descriptorSeries(named: String(localized: "Upload")) { $0.second / limit },
            ],
            format: { text.rate($0 * limit) })
    }
}
