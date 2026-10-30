import Testing

@testable import MetrCore

@Suite struct ThermalLevelTests {
    /// D-19: nominal (0) and fair (1) are Normal, serious (2) is Elevated, critical (3) is Critical,
    /// and any value a future macOS adds maps to Normal so the line never shows a fabricated alarm (T-02-04).
    @Test func rawValuesMapPerD19() {
        #expect(ThermalLevel(thermalStateRawValue: 0) == .normal)
        #expect(ThermalLevel(thermalStateRawValue: 1) == .normal)
        #expect(ThermalLevel(thermalStateRawValue: 2) == .elevated)
        #expect(ThermalLevel(thermalStateRawValue: 3) == .critical)
        #expect(ThermalLevel(thermalStateRawValue: 7) == .normal)
        #expect(ThermalLevel(thermalStateRawValue: -1) == .normal)
    }

    @Test func tintFollowsLevel() {
        #expect(ThermalLevel.normal.tint == RingTint.none)
        #expect(ThermalLevel.elevated.tint == .warning)
        #expect(ThermalLevel.critical.tint == .critical)
    }
}
