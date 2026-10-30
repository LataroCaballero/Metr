import MetrCore
import MetrRender
import SwiftUI

/// One large panel ring: a neutral track, an arc that fills clockwise from 12 o'clock, and an SF Symbol.
/// The arc takes the tint, the track and symbol stay neutral (UI-SPEC "Ring tint rules").
struct RingView: View {
    /// 0...1, or nil for "no reading": the track only, never a stray round-cap dot.
    let fill: Double?
    let tint: RingTint
    let symbol: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let diameter: CGFloat = 64
    private let lineWidth: CGFloat = 8

    var body: some View {
        ZStack {
            Circle()
                .inset(by: lineWidth / 2)
                .stroke(Color.primary.opacity(0.15), lineWidth: lineWidth)
            if let fill, fill >= 0.01 {
                Circle()
                    .inset(by: lineWidth / 2)
                    .trim(from: 0, to: min(fill, 1))
                    .stroke(arcColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(Color.secondary)
        }
        .frame(width: diameter, height: diameter)
        .animation(reduceMotion ? nil : .smooth(duration: 0.4), value: fill)
        .accessibilityHidden(true)
    }

    private var arcColor: Color {
        // The palette owns Elevated (orange) and Critical (red); the app draws them, never its own.
        TintPalette.color(for: tint).map { Color(nsColor: $0) } ?? Color.primary
    }
}
