import MetrCore
import SwiftUI

/// One 80 pt panel column: ring, title, value, detail and an optional extra slot
/// (UI-SPEC "Panel Contract"). The value arrives as a `Text` so the caller decides between a
/// formatted number and the verbatim em dash for a missing reading.
struct MetricColumn<Extra: View>: View {
    let symbol: String
    let title: String
    let fill: Double?
    let tint: RingTint
    let value: Text
    /// nil draws no detail line. Columns may differ in height; they stay top-aligned.
    let detail: String?
    /// The full reading for VoiceOver, e.g. "Normal pressure, 11.2 of 16 GB".
    let accessibilityReading: String
    /// Content below the detail line (the CPU column's User, System and cluster rows).
    let extra: Extra

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        symbol: String, title: String, fill: Double?, tint: RingTint, value: Text,
        detail: String?, accessibilityReading: String, @ViewBuilder extra: () -> Extra
    ) {
        self.symbol = symbol
        self.title = title
        self.fill = fill
        self.tint = tint
        self.value = value
        self.detail = detail
        self.accessibilityReading = accessibilityReading
        self.extra = extra()
    }

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
            if let detail {
                Text(verbatim: detail)
                    .font(.subheadline)
                    .foregroundStyle(Color.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .padding(.top, 4)
            }
            extra
        }
        .frame(width: 80)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityReading)
    }
}

extension MetricColumn where Extra == EmptyView {
    /// The Phase 1 call shape: no extra content (Memory and Disk).
    init(
        symbol: String, title: String, fill: Double?, tint: RingTint, value: Text,
        detail: String?, accessibilityReading: String
    ) {
        self.init(
            symbol: symbol, title: title, fill: fill, tint: tint, value: value,
            detail: detail, accessibilityReading: accessibilityReading
        ) { EmptyView() }
    }
}
