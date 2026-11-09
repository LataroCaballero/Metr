import AppKit
import Charts
import MetrCore
import MetrRender
import SwiftUI

/// The Disk section of the window (WIN-02, DISK-01, DISK-02; UI-SPEC "Metric Section Contracts >
/// Disk"). Above the list, how fast the Mac reads and writes right now (system-wide, D-08) and over
/// the last five minutes as a mirrored chart, Read above the zero line and Write below it; free space
/// is not charted. Below it, every real drive the Mac has, the startup disk first, each with its
/// free space and a used / free bar. One row per APFS container, so the six system volumes of the
/// startup disk are one row.
///
/// The rows are read-only: there is no Eject button and no other action on a volume (D-17). The
/// list is read when the window opens, on the Disk cadence and whenever a drive is mounted,
/// unmounted or renamed, with no spinner: until the first reading there are simply no rows. Rows
/// come and go with a short smooth transition (instant under Reduce Motion); nothing else here
/// animates, and the section is gated by `scripts/perf/window-cost.sh`. Only the startup disk's bar
/// ever tints (the Disk ring's own tint, one source); a full archive drive is not an alarm.
struct DiskSectionView: View {
    let store: MetricsStore

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilitySwitchControlEnabled) private var switchControl
    /// The system's `colorSchemeContrast`, read through `metrContrast` (see HistoryChart.swift).
    @Environment(\.metrContrast) private var contrast

    private let text = MetricText(locale: .current)

    var body: some View {
        let rows = store.volumes.value ?? []
        let unreadable = store.volumes == .unavailable
        let ioFailed = store.diskIO == .unavailable
        let io = store.diskIO.value
        let tone = ChartTone(contrast: contrast)
        return Form {
            Section {
                VStack(alignment: .leading, spacing: 0) {
                    // 32 pt between the two heroes (UI-SPEC); the values are 22 pt semibold digits.
                    HStack(alignment: .top, spacing: 32) {
                        RateHero(symbol: nil, title: String(localized: "Read"), value: text.rate(io?.readBytesPerSec))
                        RateHero(symbol: nil, title: String(localized: "Write"), value: text.rate(io?.writeBytesPerSec))
                    }
                    if ioFailed {
                        Text("Unavailable")
                            .font(.subheadline)
                            .foregroundStyle(Color.secondary)
                            .padding(.top, 4)
                    }
                    DiskIOHistoryChart(store: store, tone: tone, text: text)
                        .padding(.top, 8)
                    ChartLegendRow(items: [
                        (String(localized: "Read"), tone.seriesA),
                        (String(localized: "Write"), tone.seriesB),
                    ])
                    .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                if unreadable {
                    // Calm, and it recovers by itself: the read is retried on the Disk cadence and
                    // on every mount event, and the list returns when one succeeds.
                    Text("Volumes unavailable. Metr will try again automatically.")
                        .font(.body)
                        .foregroundStyle(Color.secondary)
                } else {
                    ForEach(rows) { volume in
                        VolumeRow(
                            volume: volume, text: text,
                            tint: volume.role == .startup ? store.diskTint : .none,
                            speaks: voiceOver || switchControl
                        )
                        .transition(.opacity)
                    }
                }
            } header: {
                Text("Volumes")
            }
        }
        .formStyle(.grouped)
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: rows.map(\.id))
    }
}

/// One drive: icon, name and free space, the kind of drive, the used fraction as a bar and the
/// figures that add up (used + free = total).
private struct VolumeRow: View {
    let volume: VolumeInfo
    let text: MetricText
    /// The bar's tint: the Disk ring's own, passed for the startup row only.
    let tint: RingTint
    /// VoiceOver or Switch Control runs: the row is built as one explicit accessibility element.
    let speaks: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: volume.role == .external ? "externaldrive" : "internaldrive")
                .font(.body)
                .imageScale(.large)
                .foregroundStyle(Color.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: volume.name)
                        .font(.body)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        // The full name for a long one that was cut (the name is already sanitized).
                        .help(volume.name)
                    Spacer(minLength: 8)
                    Text(verbatim: freeText)
                        .font(.body)
                        .monospacedDigit()
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                Text(verbatim: subtitleText)
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                if let fraction = volume.usedFraction {
                    UsageBar(fraction: fraction, tint: tint)
                        .accessibilityHidden(true)
                }
                if let caption = usedCaption {
                    Text(verbatim: caption)
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                        .monospacedDigit()
                }
            }
        }
        .padding(.vertical, 8)
        .modifier(VolumeRowAccessibility(enabled: speaks, label: spokenLabel))
    }

    /// "Macintosh HD, Startup disk, 210 GB free of 494 GB"; without capacity figures, the name and
    /// the kind only (no half-empty sentence).
    private var spokenLabel: String {
        guard let free = volume.freeBytes, let total = volume.totalBytes else {
            return "\(volume.name), \(subtitleText)"
        }
        return String(
            localized:
                "\(volume.name), \(subtitleText), \(text.byteTotal(UInt64(max(0, free)))) free of \(text.byteTotal(UInt64(max(0, total))))"
        )
    }

    /// "210 GB free", or the em dash when the volume reported no capacity.
    private var freeText: String {
        guard let free = volume.freeBytes else { return "—" }
        return String(localized: "\(text.byteTotal(UInt64(max(0, free)))) free")
    }

    /// "250 GB used of 460 GB". nil when the volume reported no capacity: no half-empty line.
    private var usedCaption: String? {
        guard let used = volume.usedBytes, let total = volume.totalBytes else { return nil }
        return String(localized: "\(text.byteTotal(UInt64(max(0, used)))) used of \(text.byteTotal(UInt64(max(0, total))))")
    }

    private var subtitleText: String {
        switch volume.role {
        case .startup: String(localized: "Startup disk")
        case .internal: String(localized: "Internal")
        case .external: String(localized: "External")
        }
    }
}

/// The spoken form of a volume row, applied only while VoiceOver or Switch Control runs (the same
/// rule as the CPU core rows: an explicit element built on every row is wasted work for everyone
/// else, and the plain texts stay readable without it).
private struct VolumeRowAccessibility: ViewModifier {
    let enabled: Bool
    let label: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
        } else {
            content
        }
    }
}

/// The used fraction of a drive: an 8 pt capsule on a quiet track. The fill is the primary color;
/// only the startup disk's bar takes the Disk ring's tint (orange, then red), through `TintPalette`.
private struct UsageBar: View {
    let fraction: Double
    let tint: RingTint

    /// Increase Contrast raises the quiet track from 0.15 to 0.30 (UI-SPEC Contrast adaptations).
    @Environment(\.metrContrast) private var contrast

    private var fill: Color {
        TintPalette.color(for: tint).map(Color.init(nsColor:)) ?? Color.primary
    }

    var body: some View {
        Capsule()
            .fill(Color.primary.opacity(contrast == .increased ? 0.30 : 0.15))
            .frame(height: 8)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(fill)
                        .frame(width: proxy.size.width * min(1, max(0, fraction)))
                }
            }
    }
}

/// The plot identifiers of the mirrored chart. Plain strings, not UI text (the chart is hidden from
/// VoiceOver unless its summary layer is on), so the compiler does not extract them as keys.
private enum DiskChartLabel {
    static let read: String = "Read"
    static let write: String = "Write"
    static let zero: String = "Zero"
}

/// One contiguous run of disk I/O samples, ready to plot: every point has a value.
private struct DiskIORun: Identifiable {
    struct Point: Identifiable {
        let id: Int
        let date: Date
        /// Bytes per second read.
        let read: Double
        /// Bytes per second written, positive; the chart plots it negated.
        let write: Double
    }

    let id: Int
    let points: [Point]
}

/// The mirrored chart over the store's disk I/O history: Read above the zero rule, Write below it,
/// on a symmetric scale. Built only while the Disk section is on screen, so a hidden chart costs
/// nothing.
private struct DiskIOHistoryChart: View {
    let store: MetricsStore
    let tone: ChartTone
    let text: MetricText

    /// The quietest axis the chart shows on each side of zero, so idle noise does not fill the plot
    /// (UI-SPEC Chart Contract, Disk: 1 MB/s).
    private static let floor: Double = 1_000_000

    /// The pointer's position over the plot, nil while it is away (the hover readout).
    @State private var selection: Date? = initialChartSelection()
    /// The history as it was when the pointer entered; see `CPUHistoryChart`.
    @State private var frozen: HistoryBuffer<SeriesPair>?

    var body: some View {
        let history = frozen ?? store.diskIOHistory
        // A pending or failed sample is a gap, never a plotted zero.
        let runs: [DiskIORun] = ChartSegments.runs(history.samples, maxGap: 3.5).map { run in
            DiskIORun(
                id: run.id,
                points: run.samples.enumerated().compactMap { index, sample in
                    sample.value.map {
                        DiskIORun.Point(
                            id: index, date: HistoryChartTime.date(sample.time), read: $0.first, write: $0.second)
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
                    text: "\(String(localized: "Read")) \(text.rate(value.first))"),
                .init(
                    id: 1, swatch: tone.colorB,
                    text: "\(String(localized: "Write")) \(text.rate(value.second))"),
            ]
        }

        return Chart {
            ForEach(runs) { run in
                ForEach(run.points) { point in
                    AreaMark(
                        x: .value(ChartLabel.time, point.date), y: .value(DiskChartLabel.read, point.read),
                        series: .value(ChartLabel.series, "read-\(run.id)"), stacking: .unstacked
                    )
                    .interpolationMethod(.linear)
                    .foregroundStyle(tone.colorA)
                    LineMark(
                        x: .value(ChartLabel.time, point.date), y: .value(DiskChartLabel.read, point.read),
                        series: .value(ChartLabel.series, "read-line-\(run.id)")
                    )
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .foregroundStyle(tone.colorLine)
                    AreaMark(
                        x: .value(ChartLabel.time, point.date), y: .value(DiskChartLabel.write, -point.write),
                        series: .value(ChartLabel.series, "write-\(run.id)"), stacking: .unstacked
                    )
                    .interpolationMethod(.linear)
                    .foregroundStyle(tone.colorB)
                    LineMark(
                        x: .value(ChartLabel.time, point.date), y: .value(DiskChartLabel.write, -point.write),
                        series: .value(ChartLabel.series, "write-line-\(run.id)")
                    )
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .foregroundStyle(tone.colorA)
                }
            }
            ForEach(singles) { run in
                ForEach(run.points) { point in
                    PointMark(x: .value(ChartLabel.time, point.date), y: .value(DiskChartLabel.read, point.read))
                        .symbolSize(24)
                        .foregroundStyle(tone.colorLine)
                    PointMark(x: .value(ChartLabel.time, point.date), y: .value(DiskChartLabel.write, -point.write))
                        .symbolSize(24)
                        .foregroundStyle(tone.colorA)
                }
            }
            // The zero line both series start from, in the grid tone.
            RuleMark(y: .value(DiskChartLabel.zero, 0))
                .lineStyle(StrokeStyle(lineWidth: 1))
                .foregroundStyle(tone.colorGrid)
            ChartReadoutRule(readouts: readouts, tone: tone)
        }
        // Ticks at -M, 0 and +M; the labels are absolute values with the unit, "0" at the line.
        .historyChart(end: end, yDomain: -limit...limit, yTicks: [-limit, 0, limit], selection: $selection) { tick in
            tick == 0 ? "0" : text.rate(abs(tick))
        }
        .onChange(of: selection) { _, new in
            frozen = new == nil ? nil : (frozen ?? store.diskIOHistory)
        }
        .onDisappear {
            selection = nil
            frozen = nil
        }
        // The audio graph and the summary work on fractions of the axis (0...1); the formatter turns
        // them back into rates. The summary is the I/O in both directions together.
        .chartAccessibility(
            metric: String(localized: "Disk"),
            summary: ChartSummary.make(history.samples.map { $0.value.map { ($0.first + $0.second) / limit } }),
            series: [
                history.descriptorSeries(named: String(localized: "Read")) { $0.first / limit },
                history.descriptorSeries(named: String(localized: "Write")) { $0.second / limit },
            ],
            format: { text.rate($0 * limit) })
    }
}
