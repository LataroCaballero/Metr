import Charts
import MetrCore
import MetrRender
import SwiftUI

/// The GPU section of the window (GPU-01, WIN-02; UI-SPEC "Metric Section Contracts > GPU"): how busy
/// the GPU is right now, the chip line from the system, and the last five minutes as a single-series
/// chart. There is no GPU memory figure (D-20).
///
/// When the value cannot be read the whole body is one centered line: no chart, no hero and no "—",
/// because a hero that never fills reads as a bug (D-20). A real 0 % is a reading and is shown.
/// Nothing here is tinted and nothing animates; the section is gated by `scripts/perf/window-cost.sh`.
struct GPUSectionView: View {
    let store: MetricsStore

    @Environment(\.metrContrast) private var contrast
    private let text = MetricText(locale: .current)

    var body: some View {
        if case .unavailable = store.gpu {
            unavailable
        } else {
            readable
        }
    }

    /// W8 error: the single line, centered in the detail column.
    private var unavailable: some View {
        Text("GPU usage isn't available on this Mac.")
            .font(.body)
            .foregroundStyle(Color.secondary)
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var readable: some View {
        let reading = store.gpu.value
        let tone = ChartTone(contrast: contrast)
        return Form {
            Section {
                VStack(alignment: .leading, spacing: 0) {
                    Text("GPU")
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                    Text(verbatim: reading.map { text.percent($0.utilization) } ?? "—")
                        .font(.title)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                        .padding(.top, 4)
                        // What the number means (RESEARCH Pitfall 12).
                        .help("How busy the GPU was recently, as the graphics driver reports it.")
                    if let line = chipLine(reading) {
                        Text(verbatim: line)
                            .font(.subheadline)
                            .foregroundStyle(Color.secondary)
                    }
                    GPUHistoryChart(store: store, tone: tone, text: text)
                        .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
    }

    /// "Apple M4 · 8-core GPU", omitted when either part is unknown.
    private func chipLine(_ reading: GPUReading?) -> String? {
        guard let name = reading?.chipName, let cores = reading?.coreCount else { return nil }
        return String(localized: "\(name) · \(cores)-core GPU")
    }
}

/// One contiguous run of GPU samples, ready to plot: every point has a value.
private struct GPURun: Identifiable {
    struct Point: Identifiable {
        let id: Int
        let date: Date
        let utilization: Double
    }

    let id: Int
    let points: [Point]
}

/// The single-series chart over the store's GPU history. Built only while the GPU section is on
/// screen, so a hidden chart costs nothing.
private struct GPUHistoryChart: View {
    let store: MetricsStore
    let tone: ChartTone
    let text: MetricText

    /// The pointer's position over the plot, nil while it is away (the hover readout).
    @State private var selection: Date? = initialChartSelection()
    /// The history as it was when the pointer entered; see `CPUHistoryChart`.
    @State private var frozen: HistoryBuffer<Double>?

    var body: some View {
        let history = frozen ?? store.gpuHistory
        // A pending or failed sample is a gap, never a plotted zero.
        let runs: [GPURun] = ChartSegments.runs(history.samples, maxGap: 3.5).map { run in
            GPURun(
                id: run.id,
                points: run.samples.enumerated().compactMap { index, sample in
                    sample.value.map {
                        GPURun.Point(id: index, date: HistoryChartTime.date(sample.time), utilization: $0)
                    }
                })
        }
        // One sample draws a point, not a line. Pre-filtered because the Charts builder must not
        // hold an `if` while the deployment target is below 27.
        let singles = runs.filter { $0.points.count == 1 }
        let end = HistoryChartTime.date(
            history.latestTime ?? store.windowSessionStart ?? Date.now.timeIntervalSinceReferenceDate)

        let readouts = ChartHoverReadout.at(selection, in: history.samples) { value in
            [.init(id: 0, swatch: tone.colorA, text: text.percent(value))]
        }

        return Chart {
            ForEach(runs) { run in
                ForEach(run.points) { point in
                    AreaMark(
                        x: .value(ChartLabel.time, point.date), y: .value(ChartLabel.total, point.utilization),
                        series: .value(ChartLabel.series, "area-\(run.id)")
                    )
                    .interpolationMethod(.linear)
                    .foregroundStyle(tone.colorA)
                    LineMark(
                        x: .value(ChartLabel.time, point.date), y: .value(ChartLabel.total, point.utilization),
                        series: .value(ChartLabel.series, "line-\(run.id)")
                    )
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .foregroundStyle(tone.colorLine)
                }
            }
            ForEach(singles) { run in
                ForEach(run.points) { point in
                    PointMark(x: .value(ChartLabel.time, point.date), y: .value(ChartLabel.total, point.utilization))
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
            frozen = new == nil ? nil : (frozen ?? store.gpuHistory)
        }
        .onDisappear {
            selection = nil
            frozen = nil
        }
        .chartAccessibility(
            metric: String(localized: "GPU"), summary: ChartSummary.make(history.samples.map(\.value)),
            series: [history.descriptorSeries(named: String(localized: "GPU")) { $0 }],
            format: { text.percent($0) })
    }
}
