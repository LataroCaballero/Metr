import Testing

@testable import MetrCore

@Suite struct MemoryMathTests {
    @Test func usedBytesUsesInternalMinusPurgeablePlusWiredPlusCompressed() {
        let c = MemoryCounters(
            internalPages: 300_000, purgeablePages: 50_000, wiredPages: 100_000,
            compressorPages: 200_000, pageSize: 16_384)
        // (300000 - 50000 + 100000 + 200000) * 16384
        #expect(MemoryMath.usedBytes(c) == 550_000 * 16_384)
        #expect(MemoryMath.usedBytes(c) == 9_011_200_000)
    }

    @Test func purgeableGreaterThanInternalSaturatesAppToZero() {
        let c = MemoryCounters(
            internalPages: 10, purgeablePages: 500, wiredPages: 7, compressorPages: 3,
            pageSize: 16_384)
        #expect(MemoryMath.usedBytes(c) == 10 * 16_384)
    }

    @Test func ringFillIsPressureAndClamps() {
        #expect(abs(MemoryMath.ringFill(freePercent: 58) - 0.42) < 1e-9)
        #expect(MemoryMath.ringFill(freePercent: -5) == 1.0)
        #expect(MemoryMath.ringFill(freePercent: 130) == 0.0)
        #expect(MemoryMath.ringFill(freePercent: 100) == 0.0)
        #expect(MemoryMath.ringFill(freePercent: 0) == 1.0)
    }

    @Test func readingRingFillUsesFreePercent() {
        let r = MemoryReading(
            usedBytes: 1, totalBytes: 2, swapUsedBytes: 0, freePercent: 77, pressure: .normal)
        #expect(abs(r.ringFill - 0.23) < 1e-9)
    }

    @Test func pressureLevelMapping() {
        #expect(MemoryPressure(rawLevel: 1) == .normal)
        #expect(MemoryPressure(rawLevel: 2) == .warn)
        #expect(MemoryPressure(rawLevel: 3) == .warn)
        #expect(MemoryPressure(rawLevel: 4) == .critical)
        #expect(MemoryPressure(rawLevel: 8) == .critical)
        #expect(MemoryPressure(rawLevel: 0) == nil)
        #expect(MemoryPressure(rawLevel: -1) == nil)
    }
}
