import Testing

@testable import MetrCore

@Suite struct PopoverToggleGuardTests {
    @Test func opensWhenNoCloseHasBeenNoted() {
        let guardState = PopoverToggleGuard()
        #expect(guardState.shouldOpen(at: 100))
    }

    @Test func rejectsAnOpenRequestRightAfterAClose() {
        var guardState = PopoverToggleGuard()
        guardState.noteClosed(at: 100)
        #expect(!guardState.shouldOpen(at: 100.1))
        #expect(!guardState.shouldOpen(at: 100))
    }

    @Test func allowsAnOpenRequestAtOrAfterTheSuppressionWindow() {
        var guardState = PopoverToggleGuard()
        guardState.noteClosed(at: 100)
        #expect(guardState.shouldOpen(at: 100.2))
        #expect(guardState.shouldOpen(at: 100.25))
    }

    @Test func aLaterCloseRestartsTheWindow() {
        var guardState = PopoverToggleGuard()
        guardState.noteClosed(at: 100)
        guardState.noteClosed(at: 200)
        #expect(!guardState.shouldOpen(at: 200.1))
        #expect(guardState.shouldOpen(at: 200.2))
    }
}
