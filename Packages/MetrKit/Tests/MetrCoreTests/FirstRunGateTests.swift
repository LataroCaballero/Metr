import Foundation
import Testing

@testable import MetrCore

@Suite struct FirstRunGateTests {
    /// A throwaway preferences domain, removed again when `cleanup` runs.
    private struct Domain {
        let name = "io.github.latarocaballero.Metr.tests.\(UUID().uuidString)"
        let defaults: UserDefaults

        init() {
            defaults = UserDefaults(suiteName: name)!
            defaults.removePersistentDomain(forName: name)
        }

        func cleanup() { defaults.removePersistentDomain(forName: name) }
    }

    @Test func firstClaimSucceedsAndSecondIsRefused() {
        let domain = Domain()
        defer { domain.cleanup() }
        let gate = FirstRunGate(defaults: domain.defaults)
        #expect(gate.claimWelcomePresentation())
        #expect(!gate.claimWelcomePresentation())
    }

    @Test func aNewGateOnTheSameDomainIsRefused() {
        let domain = Domain()
        defer { domain.cleanup() }
        #expect(FirstRunGate(defaults: domain.defaults).claimWelcomePresentation())
        #expect(!FirstRunGate(defaults: domain.defaults).claimWelcomePresentation())
    }

    @Test func aGateOnAFreshDomainSucceeds() {
        let first = Domain()
        let second = Domain()
        defer {
            first.cleanup()
            second.cleanup()
        }
        #expect(FirstRunGate(defaults: first.defaults).claimWelcomePresentation())
        #expect(FirstRunGate(defaults: second.defaults).claimWelcomePresentation())
    }

    @Test func theClaimIsRecordedUnderTheDocumentedKey() {
        let domain = Domain()
        defer { domain.cleanup() }
        #expect(FirstRunGate.welcomeKey == "MetrDidPresentWelcome")
        _ = FirstRunGate(defaults: domain.defaults).claimWelcomePresentation()
        #expect(domain.defaults.bool(forKey: "MetrDidPresentWelcome"))
    }
}
