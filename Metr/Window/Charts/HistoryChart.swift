import Accessibility
import Charts
import MetrCore
import SwiftUI

/// The tones of a window chart: opacities of `Color.primary`, never a hue and never glass
/// (UI-SPEC "Chart and bar tones", Tint rules). Increase Contrast raises them.
struct ChartTone {
    /// The base series of a stacked chart (User, Download, ...).
    let seriesA: Double
    /// The series stacked above it.
    let seriesB: Double
    /// The 1.5 pt line on the total.
    let line: Double
    /// Gridlines.
    let grid: Double

    init(contrast: ColorSchemeContrast) {
        if contrast == .increased {
            seriesA = 0.75; seriesB = 0.45; line = 1.0; grid = 0.30
        } else {
            seriesA = 0.55; seriesB = 0.25; line = 1.0; grid = 0.15
        }
    }

    var colorA: Color { Color.primary.opacity(seriesA) }
    var colorB: Color { Color.primary.opacity(seriesB) }
    var colorLine: Color { Color.primary.opacity(line) }
    var colorGrid: Color { Color.primary.opacity(grid) }
}

extension EnvironmentValues {
    /// The contrast the window's views draw with: the system's Increase Contrast setting. The window
    /// views read this instead of `colorSchemeContrast` so the DEBUG snapshot renderer can show the
    /// increased tones: AppKit offers no high-contrast `NSAppearance` to set on an off-screen window
    /// (`NSAppearance(named:)` returns nil for those names). Release has no override.
    var metrContrast: ColorSchemeContrast {
        #if DEBUG
        if let forced = DebugContrast.forced { return forced }
        #endif
        return colorSchemeContrast
    }
}

#if DEBUG
/// DEBUG only: Increase Contrast forced on by the snapshot renderer for its high-contrast fixtures.
@MainActor
enum DebugContrast {
    static var forced: ColorSchemeContrast?
}
#endif

/// Maps the buffer's clock (seconds since the reference date) to the chart's `Date` axis.
enum HistoryChartTime {
    static func date(_ time: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: time)
    }
}

/// The names Swift Charts wants for its plotted values. They are plot identifiers, not UI text (the
/// chart is hidden from VoiceOver, the numbers beside it speak), so they are plain `String`s and the
/// compiler does not extract them as localizable keys.
enum ChartLabel {
    static let time: String = "Time"
    static let series: String = "Series"
    static let total: String = "Total"
    static let user: String = "User"
    static let system: String = "System"
}

extension View {
    /// The shared scaffolding of every window chart (UI-SPEC "Chart Contract", D-07):
    /// - the X domain is the 300 s ending at `end`, the newest sample (or the session start while
    ///   the history is empty), so the plot moves only when data arrives and never rescales;
    /// - hairline vertical gridlines every 60 s counted back from `end`, labels only at the two
    ///   ends ("5 min ago", "Now");
    /// - a fixed Y domain with trailing labels at `yTicks`; a nil label hides that tick's label;
    /// - no legend (a `ChartLegendRow` sits under the chart), 160 pt tall, never animated;
    /// - the pointer's X position in `selection` (the hover readout; nil while the pointer is away).
    func historyChart(
        end: Date, yDomain: ClosedRange<Double>, yTicks: [Double], selection: Binding<Date?>,
        yLabel: @escaping (Double) -> String?
    ) -> some View {
        modifier(
            HistoryChartStyle(end: end, yDomain: yDomain, yTicks: yTicks, selection: selection, yLabel: yLabel))
    }
}

private struct HistoryChartStyle: ViewModifier {
    let end: Date
    let yDomain: ClosedRange<Double>
    let yTicks: [Double]
    let selection: Binding<Date?>
    let yLabel: (Double) -> String?

    @Environment(\.metrContrast) private var contrast

    func body(content: Content) -> some View {
        let tone = ChartTone(contrast: contrast)
        let endTime = end.timeIntervalSinceReferenceDate
        let grid = ChartTimeAxis.gridTimes(end: endTime).map(HistoryChartTime.date)
        let ends = ChartTimeAxis.ends(end: endTime).map(HistoryChartTime.date)
        return content
            .chartXScale(domain: HistoryChartTime.date(endTime - HistoryBuffer<SeriesPair>.span)...end)
            .chartXAxis {
                AxisMarks(values: grid) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(tone.colorGrid)
                }
                AxisMarks(values: [ends[0]]) { _ in
                    AxisValueLabel(anchor: .topLeading) {
                        Text("5 min ago").font(.subheadline).foregroundStyle(Color.secondary)
                    }
                }
                AxisMarks(values: [ends[1]]) { _ in
                    AxisValueLabel(anchor: .topTrailing) {
                        Text("Now").font(.subheadline).foregroundStyle(Color.secondary)
                    }
                }
            }
            .chartYScale(domain: yDomain)
            .chartYAxis {
                AxisMarks(position: .trailing, values: yTicks) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(tone.colorGrid)
                    AxisValueLabel {
                        if let tick = value.as(Double.self), let label = yLabel(tick) {
                            Text(verbatim: label)
                                .font(.subheadline)
                                .monospacedDigit()
                                .foregroundStyle(Color.secondary)
                        }
                    }
                }
            }
            .chartLegend(.hidden)
            .chartXSelection(value: selection)
            .frame(height: 160)
            // Charts never animate: the plot is data arriving at the right edge, nothing else.
            .transaction { $0.animation = nil }
    }
}

// MARK: Hover readout

/// What the readout of a hovered chart says: the time of the nearest sample and one row per series.
struct ChartHoverReadout: Identifiable {
    struct Row: Identifiable {
        let id: Int
        /// The series' tone, drawn as a small rounded swatch.
        let swatch: Color
        let text: String
    }

    /// There is at most one readout, so the id never needs to differ.
    var id: Int { 0 }
    let date: Date
    let rows: [Row]

    /// The readout for the pointer at `selection`: the nearest present sample, or none. The returned
    /// array holds zero or one element so the rule is drawn from a `ForEach`, never an `if` inside a
    /// `Chart { }` (the Swift Charts trap while the deployment target is below 27).
    static func at<Value: Sendable & Equatable>(
        _ selection: Date?, in samples: [HistorySample<Value>], rows: (Value) -> [Row]
    ) -> [ChartHoverReadout] {
        guard let selection,
            let sample = ChartReadout.nearest(time: selection.timeIntervalSinceReferenceDate, in: samples),
            let value = sample.value
        else { return [] }
        return [ChartHoverReadout(date: HistoryChartTime.date(sample.time), rows: rows(value))]
    }
}

/// The vertical rule at the hovered sample, with the readout above it. Drawn from a `ForEach` over
/// zero or one readout (UI-SPEC Chart Contract "Hover readout").
struct ChartReadoutRule: ChartContent {
    let readouts: [ChartHoverReadout]
    let tone: ChartTone

    var body: some ChartContent {
        ForEach(readouts) { readout in
            RuleMark(x: .value(ChartLabel.time, readout.date))
                .lineStyle(StrokeStyle(lineWidth: 1))
                .foregroundStyle(tone.colorGrid)
                .annotation(
                    position: .top, alignment: .center, spacing: 0,
                    overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
                ) {
                    ChartReadoutBubble(readout: readout)
                }
        }
    }
}

/// The readout itself: the time on top (11 pt) and one 13 pt line per series with its swatch, on
/// regular material in a rounded rectangle (UI-SPEC). The material is the system's; nothing custom.
private struct ChartReadoutBubble: View {
    let readout: ChartHoverReadout

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(readout.date.formatted(date: .omitted, time: .standard))
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
            ForEach(readout.rows) { row in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(row.swatch)
                        .frame(width: 8, height: 8)
                    Text(verbatim: row.text)
                        .font(.body)
                        .monospacedDigit()
                }
            }
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

#if DEBUG
/// DEBUG only: a hover position the snapshot renderer presets, so the readout can be seen in a PNG
/// without a pointer. Release has no such state.
@MainActor
enum DebugChartHover {
    static var preset: Date?
}
#endif

/// The pointer's position over a chart: the preset one while a DEBUG render sets it, nil otherwise.
@MainActor
func initialChartSelection() -> Date? {
    #if DEBUG
    return DebugChartHover.preset
    #else
    return nil
    #endif
}

// MARK: Accessibility

/// The summary and audio graph of one chart for VoiceOver (UI-SPEC Chart Contract "Accessibility"):
/// the chart is one element labelled "<Metric> history, last 5 minutes" whose value is
/// "now x, lowest y, highest z, average a", with a chart descriptor for the audio graph.
///
/// Applied only while VoiceOver or Switch Control runs. An accessibility element that rebuilds every
/// second kept the Debug window several times above its CPU budget (03-03, window-cost.sh), so the
/// layer is not built for a user who does not use it; the plain chart is hidden from accessibility
/// as before.
struct ChartAccessibility: ViewModifier {
    let metric: String
    let summary: ChartSummary?
    let series: [HistoryChartDescriptor.Series]
    let format: (Double) -> String

    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilitySwitchControlEnabled) private var switchControl

    @ViewBuilder
    func body(content: Content) -> some View {
        if voiceOver || switchControl {
            let label = String(localized: "\(metric) history, last 5 minutes")
            let value = summary.map {
                String(
                    localized:
                        "now \(format($0.now)), lowest \(format($0.lowest)), highest \(format($0.highest)), average \(format($0.average))"
                )
            }
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
                .accessibilityValue(value ?? String(localized: "Unavailable"))
                .accessibilityChartDescriptor(
                    HistoryChartDescriptor(title: label, summary: value ?? "", series: series, format: format))
        } else {
            content.accessibilityHidden(true)
        }
    }
}

extension View {
    /// One accessibility element per chart: summary and audio graph while VoiceOver runs.
    func chartAccessibility(
        metric: String, summary: ChartSummary?, series: [HistoryChartDescriptor.Series],
        format: @escaping (Double) -> String
    ) -> some View {
        modifier(ChartAccessibility(metric: metric, summary: summary, series: series, format: format))
    }
}

/// The audio graph of a chart: one data series per plotted series, time on X (seconds before the
/// newest sample) and the 0...1 value on Y.
struct HistoryChartDescriptor: AXChartDescriptorRepresentable {
    struct Series {
        let name: String
        /// (seconds before the newest sample, value); gaps are left out.
        let points: [(x: Double, y: Double)]
    }

    let title: String
    let summary: String
    let series: [Series]
    let format: (Double) -> String

    func makeChartDescriptor() -> AXChartDescriptor {
        let span = HistoryBuffer<SeriesPair>.span
        let time = AXNumericDataAxisDescriptor(
            title: String(localized: "Time"), range: (-span)...0,
            gridlinePositions: ChartTimeAxis.gridTimes(end: 0).dropFirst().dropLast().map { $0 }
        ) { seconds in
            Measurement(value: abs(seconds), unit: UnitDuration.seconds).formatted(.measurement(width: .abbreviated))
        }
        let value = AXNumericDataAxisDescriptor(
            title: title, range: 0...1, gridlinePositions: [0.5]
        ) { fraction in
            format(fraction)
        }
        return AXChartDescriptor(
            title: title, summary: summary, xAxis: time, yAxis: value, additionalAxes: [],
            series: series.map { item in
                AXDataSeriesDescriptor(
                    name: item.name, isContinuous: true,
                    dataPoints: item.points.map { AXDataPoint(x: $0.x, y: $0.y) })
            })
    }

    func updateChartDescriptor(_ descriptor: AXChartDescriptor) {
        let fresh = makeChartDescriptor()
        descriptor.title = fresh.title
        descriptor.summary = fresh.summary
        descriptor.series = fresh.series
    }
}

extension HistoryBuffer {
    /// One descriptor series from this history: seconds before the newest sample and the value
    /// `value` extracts, gaps left out.
    func descriptorSeries(named name: String, _ value: (Value) -> Double) -> HistoryChartDescriptor.Series {
        let newest = latestTime ?? 0
        return HistoryChartDescriptor.Series(
            name: name,
            points: samples.compactMap { sample in
                sample.value.map { (x: sample.time - newest, y: value($0)) }
            })
    }
}

/// The legend under a chart: an 8 pt rounded swatch and an 11 pt secondary label per series.
struct ChartLegendRow: View {
    let items: [(label: String, opacity: Double)]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.primary.opacity(item.opacity))
                        .frame(width: 8, height: 8)
                    Text(verbatim: item.label)
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                }
            }
        }
        .accessibilityHidden(true)
    }
}
