/// Dispatch memory-pressure level as reported by `kern.memorystatus_vm_pressure_level`.
public enum MemoryPressure: Int, Sendable {
    case normal = 1
    case warn = 2
    case critical = 4

    /// 1 is normal, 2 and 3 are warn, 4 and above are critical. Anything else is unknown (nil).
    public init?(rawLevel: Int) {
        switch rawLevel {
        case 1: self = .normal
        case 2, 3: self = .warn
        case 4...: self = .critical
        default: return nil
        }
    }
}

/// Raw page counters from `host_statistics64(HOST_VM_INFO64)` plus the runtime page size.
public struct MemoryCounters: Sendable, Equatable {
    public var internalPages: UInt64
    public var purgeablePages: UInt64
    public var wiredPages: UInt64
    public var compressorPages: UInt64
    public var pageSize: UInt64

    public init(
        internalPages: UInt64,
        purgeablePages: UInt64,
        wiredPages: UInt64,
        compressorPages: UInt64,
        pageSize: UInt64
    ) {
        self.internalPages = internalPages
        self.purgeablePages = purgeablePages
        self.wiredPages = wiredPages
        self.compressorPages = compressorPages
        self.pageSize = pageSize
    }
}

/// One memory sample. The menu bar ring shows pressure (`ringFill`), not used/total (D-01).
public struct MemoryReading: Sendable, Equatable {
    public var usedBytes: UInt64
    public var totalBytes: UInt64
    public var swapUsedBytes: UInt64
    /// `kern.memorystatus_level`, 0...100.
    public var freePercent: Int
    public var pressure: MemoryPressure

    public init(
        usedBytes: UInt64,
        totalBytes: UInt64,
        swapUsedBytes: UInt64,
        freePercent: Int,
        pressure: MemoryPressure
    ) {
        self.usedBytes = usedBytes
        self.totalBytes = totalBytes
        self.swapUsedBytes = swapUsedBytes
        self.freePercent = freePercent
        self.pressure = pressure
    }

    /// Ring fill 0...1 derived from the free percentage.
    public var ringFill: Double { MemoryMath.ringFill(freePercent: freePercent) }
}

public enum MemoryMath {
    /// App (internal minus purgeable, saturating at 0) + wired + compressed, in bytes.
    public static func usedBytes(_ c: MemoryCounters) -> UInt64 {
        let app = c.internalPages > c.purgeablePages ? c.internalPages - c.purgeablePages : 0
        let pages = app &+ c.wiredPages &+ c.compressorPages
        return pages &* c.pageSize
    }

    /// (100 - freePercent) / 100, clamped to 0...1.
    public static func ringFill(freePercent: Int) -> Double {
        min(1, max(0, Double(100 - freePercent) / 100))
    }
}
