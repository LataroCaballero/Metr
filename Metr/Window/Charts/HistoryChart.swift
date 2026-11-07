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
    /// - no legend (a `ChartLegendRow` sits under the chart), 160 pt tall, never animated.
    func historyChart(
        end: Date, yDomain: ClosedRange<Double>, yTicks: [Double], yLabel: @escaping (Double) -> String?
    ) -> some View {
        modifier(HistoryChartStyle(end: end, yDomain: yDomain, yTicks: yTicks, yLabel: yLabel))
    }
}

private struct HistoryChartStyle: ViewModifier {
    let end: Date
    let yDomain: ClosedRange<Double>
    let yTicks: [Double]
    let yLabel: (Double) -> String?

    @Environment(\.colorSchemeContrast) private var contrast

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
            .frame(height: 160)
            // Charts never animate: the plot is data arriving at the right edge, nothing else.
            .transaction { $0.animation = nil }
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
