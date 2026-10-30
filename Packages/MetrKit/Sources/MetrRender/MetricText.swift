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

    /// A process row's CPU in Activity Monitor scale, percent of ONE core, so a process busy on
    /// several cores reads above 100: "182%" in en, "182 %" in es. Above 0 and below 1 reads
    /// "<1%" so a live process never looks idle; nil (pending) is the em dash (D-11, D-20).
    public func processCPU(_ percentOfOneCore: Double?) -> String {
        guard let value = percentOfOneCore else { return "\u{2014}" }
        if value > 0, value < 1 { return "<" + percent(0.01) }
        return percent(max(0, value) / 100)
    }

    /// A process row's memory in the memory byte style; nil (pending) is the em dash.
    public func processMemory(_ bytes: UInt64?) -> String {
        guard let bytes else { return "\u{2014}" }
        return memoryBytes(bytes)
    }

    /// Decimal (file) byte count with unit, matching Finder, e.g. "210 GB".
    public func diskBytes(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file).locale(locale))
    }
}
