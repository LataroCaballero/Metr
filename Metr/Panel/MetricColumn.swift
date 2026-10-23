import MetrCore
import SwiftUI

/// One 80 pt panel column: ring, title, value, detail (UI-SPEC "Panel Contract").
/// The value arrives as a `Text` so the caller decides between a formatted number and the
/// verbatim em dash for a missing reading.
struct MetricColumn: View {
    let symbol: String
    let title: String
    let fill: Double?
    let tint: RingTint
    let value: Text
    /// Empty for the CPU column. The line is still reserved so the three columns stay level.
    let detail: String
    /// The full reading for VoiceOver, e.g. "Normal pressure, 11.2 of 16 GB".
    let accessibilityReading: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            RingView(fill: fill, tint: tint, symbol: symbol)
            Text(verbatim: title)
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
                .padding(.top, 8)
            value
                .font(.title.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .contentTransition(reduceMotion ? .identity : .numericText())
                .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: accessibilityReading)
                .padding(.top, 4)
            // A space keeps the line's height when the detail is empty, so the columns stay level.
            Text(verbatim: detail.isEmpty ? " " : detail)
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .padding(.top, 4)
        }
        .frame(width: 80)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityReading)
    }
}
