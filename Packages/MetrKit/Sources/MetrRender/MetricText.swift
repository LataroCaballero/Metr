import Foundation

/// Locale-aware number text for the panel and the tooltip (D-08, D-11).
/// Uses `FormatStyle` only, with the locale pinned, so a test can assert both EN and ES.
/// Never printf-style: that ignores the user's decimal separator.
public struct MetricText: Sendable {
    public let locale: Locale

    public init(locale: Locale) {
        self.locale = locale
    }

    /// "34%" in en, "34 %" in es.
    public func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }

    /// The used half of "11.2 of 16 GB": gibibytes with one fraction digit, no unit.
    public func memoryUsedNumber(_ bytes: UInt64) -> String {
        (Double(bytes) / 1_073_741_824).formatted(.number.precision(.fractionLength(1)).locale(locale))
    }

    /// Binary (memory) byte count with unit, e.g. "16 GB".
    public func memoryBytes(_ bytes: UInt64) -> String {
        Int64(clamping: bytes).formatted(.byteCount(style: .memory).locale(locale))
    }

    /// Decimal (file) byte count with unit, matching Finder, e.g. "210 GB".
    public func diskBytes(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file).locale(locale))
    }
}
