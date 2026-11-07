import Testing

@testable import MetrCore

@Suite struct WindowDemandTests {
    @Test func metricSectionsCarryOnlyTheWindow() {
        #expect(WindowDemand.consumers(section: .cpu, processesVisible: true) == [.window])
        #expect(WindowDemand.consumers(section: .memory, processesVisible: true) == [.window])
        #expect(WindowDemand.consumers(section: .disk, processesVisible: true) == [.window])
        #expect(WindowDemand.consumers(section: .network, processesVisible: true) == [.window])
        #expect(WindowDemand.consumers(section: .gpu, processesVisible: true) == [.window])
    }

    @Test func processesSectionAddsTheProcessPassWhileNotMinimized() {
        #expect(WindowDemand.consumers(section: .processes, processesVisible: true) == [.window, .windowProcesses])
        #expect(WindowDemand.consumers(section: .processes, processesVisible: false) == [.window])
    }

    @Test func transitionRegistersNewConsumersAndCancelsDroppedOnes() {
        let open = WindowDemand.transition(from: [], to: [.window, .windowProcesses])
        #expect(open.register == [.window, .windowProcesses])
        #expect(open.cancel.isEmpty)

        let leaveProcesses = WindowDemand.transition(from: [.window, .windowProcesses], to: [.window])
        #expect(leaveProcesses.register.isEmpty)
        #expect(leaveProcesses.cancel == [.windowProcesses])

        let close = WindowDemand.transition(from: [.window], to: [])
        #expect(close.register.isEmpty)
        #expect(close.cancel == [.window])
    }

    @Test func equalSetsTransitionToNothing() {
        let same = WindowDemand.transition(from: [.window, .windowProcesses], to: [.window, .windowProcesses])
        #expect(same.register.isEmpty)
        #expect(same.cancel.isEmpty)
    }
}
