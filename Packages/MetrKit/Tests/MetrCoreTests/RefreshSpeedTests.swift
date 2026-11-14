import Testing

@testable import MetrCore

@Suite struct RefreshSpeedTests {
    @Test func anAbsentValueReadsAsNormal() {
        #expect(RefreshSpeed(storedValue: nil) == .normal)
    }

    @Test func theStoredRawValuesRoundTrip() {
        #expect(RefreshSpeed(storedValue: "energySaver") == .energySaver)
        #expect(RefreshSpeed(storedValue: "normal") == .normal)
        for speed in RefreshSpeed.allCases {
            #expect(RefreshSpeed(storedValue: speed.rawValue) == speed)
        }
    }

    @Test func anUnknownValueReadsAsNormal() {
        #expect(RefreshSpeed(storedValue: "bogus") == .normal)
        #expect(RefreshSpeed(storedValue: "") == .normal)
    }

    @Test func theKeyIsStable() {
        #expect(RefreshSpeed.defaultsKey == "refreshSpeed")
    }

    @Test func normalFollowsTheSystem() {
        #expect(ConstrainedResolver.resolve(speed: .normal, systemConstrained: false) == false)
        #expect(ConstrainedResolver.resolve(speed: .normal, systemConstrained: true) == true)
    }

    @Test func energySaverIsAlwaysConstrained() {
        #expect(ConstrainedResolver.resolve(speed: .energySaver, systemConstrained: false) == true)
        #expect(ConstrainedResolver.resolve(speed: .energySaver, systemConstrained: true) == true)
    }
}
