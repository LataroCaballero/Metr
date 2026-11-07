/// How busy the Apple Silicon GPU is, as the graphics driver reports it (GPU-01). Utilization is
/// 0...1; the chip name and core count come from the system and are nil when not readable.
public struct GPUReading: Sendable, Equatable {
    public var utilization: Double
    public var chipName: String?
    public var coreCount: Int?

    public init(utilization: Double, chipName: String? = nil, coreCount: Int? = nil) {
        self.utilization = utilization
        self.chipName = chipName
        self.coreCount = coreCount
    }
}
