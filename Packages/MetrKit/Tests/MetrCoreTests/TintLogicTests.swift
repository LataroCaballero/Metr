import Testing

@testable import MetrCore

@Suite struct TintLogicTests {
    @Test func memoryMapsPressureToTint() {
        #expect(TintLogic.memory(.normal) == .none)
        #expect(TintLogic.memory(nil) == .none)
        #expect(TintLogic.memory(.warn) == .warning)
        #expect(TintLogic.memory(.critical) == .critical)
    }

    @Test func cpuNeverTints() {
        #expect(TintLogic.cpu() == .none)
    }

    @Test func nilFreeFractionIsNeutralFromAnyState() {
        for previous in [RingTint.none, .warning, .critical] {
            #expect(TintLogic.disk(freeFraction: nil, previous: previous) == .none)
        }
    }

    @Test func diskEnteringFromNeutral() {
        #expect(TintLogic.disk(freeFraction: 0.10, previous: .none) == .none)
        #expect(TintLogic.disk(freeFraction: 0.0999, previous: .none) == .warning)
        #expect(TintLogic.disk(freeFraction: 0.05, previous: .none) == .warning)
        #expect(TintLogic.disk(freeFraction: 0.0499, previous: .none) == .critical)
    }

    @Test func diskLeavingWarningNeedsElevenPercent() {
        #expect(TintLogic.disk(freeFraction: 0.105, previous: .warning) == .warning)
        #expect(TintLogic.disk(freeFraction: 0.11, previous: .warning) == .none)
        #expect(TintLogic.disk(freeFraction: 0.049, previous: .warning) == .critical)
    }

    @Test func diskLeavingCriticalNeedsSixPercentThenEleven() {
        #expect(TintLogic.disk(freeFraction: 0.059, previous: .critical) == .critical)
        #expect(TintLogic.disk(freeFraction: 0.06, previous: .critical) == .warning)
        #expect(TintLogic.disk(freeFraction: 0.11, previous: .critical) == .none)
    }

    @Test func quantizerSnapsToTwoPercentSteps() {
        #expect(RingQuantizer.quantize(nil) == nil)
        #expect(RingQuantizer.quantize(0.005) == 0)
        let snapped = try! #require(RingQuantizer.quantize(0.33))
        #expect(abs(snapped - 0.34) < 1e-9)
        #expect(RingQuantizer.quantize(0.995) == 1)
        #expect(RingQuantizer.quantize(1.2) == 1)
    }
}
