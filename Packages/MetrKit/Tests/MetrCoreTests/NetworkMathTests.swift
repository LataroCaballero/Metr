import Testing

@testable import MetrCore

@Suite struct NetworkMathTests {
    @Test func countersAreDeltaPerKey() {
        // Key 3 is new and contributes 0; key 2 vanished from nothing; a vanished key is ignored.
        let total = CounterDeltas.total(
            previous: [1: 100, 2: 50], current: [1: 160, 2: 70, 3: 9_000_000])
        #expect(total == 80)

        // A counter that went backwards contributes 0, it is not a huge unsigned wrap.
        #expect(CounterDeltas.total(previous: [1: 500], current: [1: 20]) == 0)

        // A vanished key is ignored.
        #expect(CounterDeltas.total(previous: [1: 10, 2: 10], current: [1: 15]) == 5)

        // Never a delta of sums: key 1 backwards must not cancel key 2's growth.
        #expect(CounterDeltas.total(previous: [1: 1_000, 2: 0], current: [1: 0, 2: 400]) == 400)
    }

    @Test func countersCrossThirtyTwoBits() {
        #expect(CounterDeltas.total(previous: [1: 4_294_967_295], current: [1: 4_294_967_396]) == 101)
        #expect(CounterDeltas.total(previous: [1: UInt64.max - 10], current: [1: UInt64.max]) == 10)
    }

    @Test func totalSaturatesInsteadOfTrapping() {
        let total = CounterDeltas.total(
            previous: [1: 0, 2: 0], current: [1: UInt64.max, 2: UInt64.max])
        #expect(total == UInt64.max)
    }

    @Test func onlyPhysicalInterfaces() {
        for name in ["en0", "en1", "en7", "en12"] {
            #expect(NetworkMath.isPhysical(interfaceName: name), "\(name) should be physical")
        }
        for name in [
            "en", "enx", "en0x", "lo0", "utun0", "utun3", "ipsec0", "awdl0", "llw0", "bridge0",
            "anpi0", "ap1", "gif0", "stf0", "",
        ] {
            #expect(!NetworkMath.isPhysical(interfaceName: name), "\(name) should not be physical")
        }
    }

    @Test func rateRejectsNonsense() {
        #expect(NetworkMath.rate(bytes: 2_000_000, seconds: 1) == 2_000_000)
        #expect(NetworkMath.rate(bytes: 1_000, seconds: 0) == nil)
        #expect(NetworkMath.rate(bytes: 1_000, seconds: -1) == nil)
        #expect(NetworkMath.rate(bytes: 200_000_000_000, seconds: 1) == nil)
        #expect(NetworkMath.rate(bytes: 0, seconds: 1) == 0)
    }

    // MARK: Connection name

    @Test func connectionNamePrefersTheServiceThenTheDisplayNameThenTheBSDName() {
        #expect(NetworkMath.connectionName(userDefined: "Casa", displayName: "Wi-Fi", bsdName: "en0") == "Casa")
        #expect(NetworkMath.connectionName(userDefined: nil, displayName: "Wi-Fi", bsdName: "en0") == "Wi-Fi")
        #expect(NetworkMath.connectionName(userDefined: nil, displayName: nil, bsdName: "en5") == "en5")
        // An empty or all-control name is no name.
        #expect(NetworkMath.connectionName(userDefined: "  \u{0007} ", displayName: "", bsdName: "en0") == "en0")
        #expect(NetworkMath.connectionName(userDefined: nil, displayName: nil, bsdName: nil) == nil)
    }

    /// T-03-13: the service name is text the user typed, so controls and bidirectional overrides are
    /// stripped and the length is capped.
    @Test func connectionNameIsSanitized() {
        let spoofed = "Wi\u{202E}-Fi\u{0000}\n"
        #expect(NetworkMath.connectionName(userDefined: spoofed, displayName: nil, bsdName: nil) == "Wi-Fi")
        let long = String(repeating: "a", count: 500)
        let name = NetworkMath.connectionName(userDefined: long, displayName: nil, bsdName: nil)
        #expect(name?.count == NetworkMath.maximumNameLength)
    }
}
