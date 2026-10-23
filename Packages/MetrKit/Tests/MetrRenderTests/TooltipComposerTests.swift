import Foundation
import MetrCore
import Testing

@testable import MetrRender

@Suite struct TooltipComposerTests {
    private static let enTemplates = TooltipTemplates(
        cpu: { "CPU: \($0)" },
        memory: { pressure, used, total in
            switch pressure {
            case .normal: "Memory: Normal pressure · \(used) of \(total)"
            case .warn: "Memory: Elevated pressure · \(used) of \(total)"
            case .critical: "Memory: Critical pressure · \(used) of \(total)"
            }
        },
        swapSuffix: { " · Swap \($0)" },
        disk: { "Disk: \($0) free of \($1)" },
        unavailable: { metric in
            switch metric {
            case .cpu: "CPU: unavailable"
            case .memory: "Memory: unavailable"
            case .disk: "Disk: unavailable"
            }
        })

    private static let esTemplates = TooltipTemplates(
        cpu: { "CPU: \($0)" },
        memory: { pressure, used, total in
            switch pressure {
            case .normal: "Memoria: presión normal · \(used) de \(total)"
            case .warn: "Memoria: presión elevada · \(used) de \(total)"
            case .critical: "Memoria: presión crítica · \(used) de \(total)"
            }
        },
        swapSuffix: { " · Swap \($0)" },
        disk: { "Disco: \($0) libres de \($1)" },
        unavailable: { metric in
            switch metric {
            case .cpu: "CPU: no disponible"
            case .memory: "Memoria: no disponible"
            case .disk: "Disco: no disponible"
            }
        })

    private let en = Locale(identifier: "en_US")
    private let es = Locale(identifier: "es_ES")

    private func memory(swap: UInt64 = 0, pressure: MemoryPressure = .normal) -> MemoryReading {
        MemoryReading(
            usedBytes: 12_025_908_428, totalBytes: 17_179_869_184,
            swapUsedBytes: swap, freePercent: 40, pressure: pressure)
    }

    private let disk = DiskReading(totalBytes: 494_000_000_000, availableBytes: 210_000_000_000)

    private func composer(_ templates: TooltipTemplates, _ locale: Locale) -> TooltipComposer {
        TooltipComposer(templates: templates, text: MetricText(locale: locale))
    }

    @Test func englishOutputMatchesLinesBuiltFromTheSameText() throws {
        let text = MetricText(locale: en)
        let output = try #require(
            composer(Self.enTemplates, en).compose(
                cpu: .value(CPUReading(total: 0.34)), memory: .value(memory()), disk: .value(disk)))
        let expected = [
            "CPU: \(text.percent(0.34))",
            "Memory: Normal pressure · \(text.memoryUsedNumber(12_025_908_428)) of \(text.memoryBytes(17_179_869_184))",
            "Disk: \(text.diskBytes(210_000_000_000)) free of \(text.diskBytes(494_000_000_000))",
        ].joined(separator: "\n")
        #expect(output == expected)
    }

    @Test func spanishOutputMatchesLinesBuiltFromTheSameText() throws {
        let text = MetricText(locale: es)
        let output = try #require(
            composer(Self.esTemplates, es).compose(
                cpu: .value(CPUReading(total: 0.34)), memory: .value(memory(pressure: .critical)),
                disk: .value(disk)))
        let expected = [
            "CPU: \(text.percent(0.34))",
            "Memoria: presión crítica · \(text.memoryUsedNumber(12_025_908_428)) de \(text.memoryBytes(17_179_869_184))",
            "Disco: \(text.diskBytes(210_000_000_000)) libres de \(text.diskBytes(494_000_000_000))",
        ].joined(separator: "\n")
        #expect(output == expected)
        #expect(output.contains("11,2"))
    }

    @Test func zeroSwapGivesNoSwapSuffix() throws {
        let output = try #require(
            composer(Self.enTemplates, en).compose(
                cpu: .value(CPUReading(total: 0.1)), memory: .value(memory(swap: 0)), disk: .value(disk)))
        #expect(!output.contains("Swap"))
    }

    @Test func oneMebibyteOfSwapGivesTheSuffix() throws {
        let output = try #require(
            composer(Self.enTemplates, en).compose(
                cpu: .value(CPUReading(total: 0.1)), memory: .value(memory(swap: 1_048_576)),
                disk: .value(disk)))
        let memoryLine = output.split(separator: "\n")[1]
        #expect(memoryLine.contains(" · Swap "))
        #expect(memoryLine.hasSuffix(MetricText(locale: en).memoryBytes(1_048_576)))
    }

    @Test func unavailableMemoryReplacesOnlyItsOwnLine() throws {
        let text = MetricText(locale: en)
        let output = try #require(
            composer(Self.enTemplates, en).compose(
                cpu: .value(CPUReading(total: 0.34)), memory: .unavailable, disk: .value(disk)))
        let lines = output.split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines[0] == "CPU: \(text.percent(0.34))")
        #expect(lines[1] == "Memory: unavailable")
        #expect(lines[2].hasPrefix("Disk: "))
    }

    @Test func spanishUnavailableReadsNoDisponible() throws {
        let output = try #require(
            composer(Self.esTemplates, es).compose(
                cpu: .unavailable, memory: .unavailable, disk: .unavailable))
        #expect(output == "CPU: no disponible\nMemoria: no disponible\nDisco: no disponible")
        #expect(!output.contains("0"))
    }

    @Test func anyPendingReadingGivesNoTooltip() {
        let c = composer(Self.enTemplates, en)
        let cpu = Reading.value(CPUReading(total: 0.2))
        #expect(c.compose(cpu: .pending, memory: .value(memory()), disk: .value(disk)) == nil)
        #expect(c.compose(cpu: cpu, memory: .pending, disk: .value(disk)) == nil)
        #expect(c.compose(cpu: cpu, memory: .value(memory()), disk: .pending) == nil)
        #expect(c.compose(cpu: .pending, memory: .pending, disk: .pending) == nil)
        // An unavailable reading is an answer, not a wait.
        #expect(c.compose(cpu: .unavailable, memory: .value(memory()), disk: .value(disk)) != nil)
    }

    @Test func linesAreAlwaysCPUThenMemoryThenDisk() throws {
        let output = try #require(
            composer(Self.enTemplates, en).compose(
                cpu: .value(CPUReading(total: 0.5)), memory: .value(memory(swap: 5_000_000_000)),
                disk: .value(disk)))
        let lines = output.split(separator: "\n")
        #expect(lines.count == 3)
        #expect(lines[0].hasPrefix("CPU:"))
        #expect(lines[1].hasPrefix("Memory:"))
        #expect(lines[2].hasPrefix("Disk:"))
    }

    @Test func recomposingTheSameInputGivesAnIdenticalString() {
        let c = composer(Self.enTemplates, en)
        let a = c.compose(cpu: .value(CPUReading(total: 0.34)), memory: .value(memory()), disk: .value(disk))
        let b = c.compose(cpu: .value(CPUReading(total: 0.34)), memory: .value(memory()), disk: .value(disk))
        #expect(a != nil)
        #expect(a == b)
    }

    @Test func accessibilityValueJoinsTheLinesWithCommas() {
        #expect(TooltipComposer.accessibilityValue(for: "a\nb\nc") == "a, b, c")
    }
}
