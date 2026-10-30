import Foundation
import MetrCore

/// The three metrics the tooltip speaks about. Narrower than `Metric`, which also names the
/// process list that the hover tooltip never mentions.
public enum TooltipMetric: Sendable {
    case cpu, memory, disk
}

/// The localized sentence shapes of the tooltip. The app supplies them from its String Catalog;
/// tests supply literal EN and ES ones. Every closure receives already formatted numbers.
public struct TooltipTemplates: Sendable {
    /// "CPU: 34%"
    public var cpu: @Sendable (String) -> String
    /// "Memory: Normal pressure · 11.2 of 16 GB" from the pressure, the used number and the total.
    public var memory: @Sendable (MemoryPressure, String, String) -> String
    /// " · Swap 1.2 GB"
    public var swapSuffix: @Sendable (String) -> String
    /// "Disk: 210 GB free of 494 GB" from the free amount and the total.
    public var disk: @Sendable (String, String) -> String
    /// "Memory: unavailable" for a metric whose read failed.
    public var unavailable: @Sendable (TooltipMetric) -> String

    public init(
        cpu: @escaping @Sendable (String) -> String,
        memory: @escaping @Sendable (MemoryPressure, String, String) -> String,
        swapSuffix: @escaping @Sendable (String) -> String,
        disk: @escaping @Sendable (String, String) -> String,
        unavailable: @escaping @Sendable (TooltipMetric) -> String
    ) {
        self.cpu = cpu
        self.memory = memory
        self.swapSuffix = swapSuffix
        self.disk = disk
        self.unavailable = unavailable
    }
}

/// Builds the three-line hover tooltip (D-11, D-12). Pure, so it is tested without AppKit.
public struct TooltipComposer: Sendable {
    private let templates: TooltipTemplates
    private let text: MetricText

    public init(templates: TooltipTemplates, text: MetricText) {
        self.templates = templates
        self.text = text
    }

    /// Three lines in the order CPU, Memory, Disk, joined with "\n".
    /// Returns nil while any reading is still `.pending`: no tooltip is better than a wrong one.
    /// An `.unavailable` reading replaces only its own line; it never shows a zero.
    public func compose(cpu: Reading<CPUReading>, memory: Reading<MemoryReading>, disk: Reading<DiskReading>) -> String? {
        if cpu == .pending || memory == .pending || disk == .pending { return nil }
        return [cpuLine(cpu), memoryLine(memory), diskLine(disk)].joined(separator: "\n")
    }

    /// The accessibility value carries the same three lines on one line (D-13).
    public static func accessibilityValue(for tooltip: String) -> String {
        tooltip.replacingOccurrences(of: "\n", with: ", ")
    }

    private func cpuLine(_ reading: Reading<CPUReading>) -> String {
        guard let value = reading.value else { return templates.unavailable(.cpu) }
        return templates.cpu(text.percent(value.total))
    }

    private func memoryLine(_ reading: Reading<MemoryReading>) -> String {
        guard let value = reading.value else { return templates.unavailable(.memory) }
        var line = templates.memory(
            value.pressure, text.memoryUsedNumber(value.usedBytes), text.memoryBytes(value.totalBytes))
        // Swap is shown only when it is actually in use (D-12).
        if value.swapUsedBytes > 0 {
            line += templates.swapSuffix(text.memoryBytes(value.swapUsedBytes))
        }
        return line
    }

    private func diskLine(_ reading: Reading<DiskReading>) -> String {
        guard let value = reading.value else { return templates.unavailable(.disk) }
        return templates.disk(text.diskBytes(value.availableBytes), text.diskBytes(value.totalBytes))
    }
}
