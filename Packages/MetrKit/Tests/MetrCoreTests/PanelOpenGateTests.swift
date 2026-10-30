import Testing

@testable import MetrCore

@Suite struct PanelOpenGateTests {
    @Test func decisions() {
        // Everything answered: show at once.
        #expect(PanelOpenGate.decide(ringsReady: true, processesReady: true) == .showNow)
        // Rings still pending (cold start): the long bound, whatever the processes say.
        #expect(PanelOpenGate.decide(ringsReady: false, processesReady: false) == .wait(1.5))
        #expect(PanelOpenGate.decide(ringsReady: false, processesReady: true) == .wait(1.5))
        // Only the process reading is missing: a short hold so the list is filled on the first frame.
        #expect(PanelOpenGate.decide(ringsReady: true, processesReady: false) == .wait(0.15))
    }

    @Test func boundsAreTheDocumentedOnes() {
        #expect(PanelOpenGate.processWait == 0.15)
        #expect(PanelOpenGate.coldStartWait == 1.5)
    }
}
