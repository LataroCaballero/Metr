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

    /// A network rate in decimal bytes per second with the system formatter's own units, as
    /// Finder writes them: "2.1 MB/s" in en, "2,1 MB/s" in es, "kB/s" with a lowercase k (RESEARCH
    /// Pitfall 14; owner decision of 2026-11-02, Open Question 3 resolved). A rate that rounds to
    /// zero reads "0 kB/s": the formatter itself would say "Zero kB" in English, which is never
    /// shown. nil (pending) is the em dash. "/s" is unit notation, identical in EN and ES.
    public func rate(_ bytesPerSecond: Double?) -> String {
        guard let value = bytesPerSecond, value.isFinite else { return "\u{2014}" }
        let bytes = Int64(min(max(0, value), 9e18).rounded())
        guard bytes > 0 else { return zeroRate() }
        return bytes.formatted(rateStyle.locale(locale)) + "/s"
    }

    private var rateStyle: ByteCountFormatStyle {
        .byteCount(style: .file, allowedUnits: [.kb, .mb, .gb])
    }

    /// "0 kB" built from how the formatter writes one kilobyte, so the digit, the separator and the
    /// kilobyte symbol all come from the system in the pinned locale.
    private func zeroRate() -> String {
        let one = Int64(1000).formatted(
            ByteCountFormatStyle(style: .file, allowedUnits: [.kb]).locale(locale))
        let digitOne = 1.formatted(.number.locale(locale))
        let digitZero = 0.formatted(.number.locale(locale))
        return one.replacingOccurrences(of: digitOne, with: digitZero) + "/s"
    }
}
