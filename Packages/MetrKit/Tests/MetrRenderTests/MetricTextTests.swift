import Foundation
import Testing

@testable import MetrRender

@Suite struct MetricTextTests {
    private let en = Locale(identifier: "en_US")
    private let es = Locale(identifier: "es_ES")
    private let usedBytes: UInt64 = 12_025_908_428  // 11.2 GiB
    private let totalBytes: UInt64 = 17_179_869_184  // 16 GiB

    @Test func percentMatchesFormatStyleInBothLocales() {
        #expect(MetricText(locale: en).percent(0.34) == 0.34.formatted(.percent.precision(.fractionLength(0)).locale(en)))
        #expect(MetricText(locale: es).percent(0.34) == 0.34.formatted(.percent.precision(.fractionLength(0)).locale(es)))
    }

    @Test func percentKeepsTheNumber() {
        #expect(MetricText(locale: en).percent(0.34).contains("34"))
        #expect(MetricText(locale: es).percent(0.34).contains("34"))
        #expect(MetricText(locale: en).percent(0.34).contains("%"))
    }

    @Test func memoryUsedNumberUsesTheLocaleDecimalSeparator() {
        let english = MetricText(locale: en).memoryUsedNumber(usedBytes)
        let spanish = MetricText(locale: es).memoryUsedNumber(usedBytes)
        #expect(english.contains("."))
        #expect(spanish.contains(","))
        #expect(!spanish.contains("."))
    }

    @Test func memoryUsedNumberMatchesFormatStyle() {
        let expected = (Double(usedBytes) / 1_073_741_824).formatted(.number.precision(.fractionLength(1)).locale(en))
        #expect(MetricText(locale: en).memoryUsedNumber(usedBytes) == expected)
    }

    @Test func memoryBytesMatchesFormatStyle() {
        let expectedEn = Int64(totalBytes).formatted(.byteCount(style: .memory).locale(en))
        let expectedEs = Int64(totalBytes).formatted(.byteCount(style: .memory).locale(es))
        #expect(MetricText(locale: en).memoryBytes(totalBytes) == expectedEn)
        #expect(MetricText(locale: es).memoryBytes(totalBytes) == expectedEs)
        #expect(expectedEn.contains("16"))
    }

    @Test func diskBytesIsDecimalAndMatchesFormatStyle() {
        let bytes: Int64 = 210_000_000_000
        #expect(MetricText(locale: en).diskBytes(bytes) == bytes.formatted(.byteCount(style: .file).locale(en)))
        #expect(MetricText(locale: es).diskBytes(bytes) == bytes.formatted(.byteCount(style: .file).locale(es)))
        // .file is decimal: 210e9 bytes reads as 210 GB, not 195.6 GB.
        #expect(MetricText(locale: en).diskBytes(bytes).contains("210"))
    }

    @Test func processCPUIsPercentOfOneCoreInBothLocales() {
        for locale in [en, es] {
            let text = MetricText(locale: locale)
            #expect(text.processCPU(182) == text.percent(1.82))
            #expect(text.processCPU(41.4) == text.percent(0.414))
            #expect(text.processCPU(0.4) == "<" + text.percent(0.01))
            #expect(text.processCPU(0) == text.percent(0))
            #expect(text.processCPU(nil) == "\u{2014}")
        }
        #expect(MetricText(locale: en).processCPU(182) == "182%")
        #expect(MetricText(locale: es).processCPU(182).contains("182"))
    }

    @Test func processMemoryIsTheMemoryByteStyleOrAnEmDash() {
        for locale in [en, es] {
            let text = MetricText(locale: locale)
            #expect(text.processMemory(nil) == "\u{2014}")
            #expect(text.processMemory(402_653_184) == text.memoryBytes(402_653_184))
        }
    }
}
