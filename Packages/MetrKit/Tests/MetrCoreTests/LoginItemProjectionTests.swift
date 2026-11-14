import Testing

@testable import MetrCore

@Suite struct LoginItemProjectionTests {
    private func p(_ raw: Int, _ failed: Bool, _ inApps: Bool) -> LoginItemProjection {
        LoginItemProjection.project(rawStatus: raw, actionFailed: failed, inApplications: inApps)
    }

    @Test func notRegisteredInApplicationsIsOffWithNoLine() {
        #expect(p(0, false, true) == LoginItemProjection(isOn: false, isEnabled: true, message: nil))
        #expect(p(0, true, true) == LoginItemProjection(isOn: false, isEnabled: true, message: .failure))
    }

    @Test func enabledIsOnAndAFailedActionStillShowsTheFailureLine() {
        #expect(p(1, false, true) == LoginItemProjection(isOn: true, isEnabled: true, message: nil))
        #expect(p(1, true, true) == LoginItemProjection(isOn: true, isEnabled: true, message: .failure))
    }

    @Test func requiresApprovalIsOffWithTheApprovalLineEvenWhenTheActionFailed() {
        #expect(p(2, false, true) == LoginItemProjection(isOn: false, isEnabled: true, message: .approval))
        #expect(p(2, true, true) == LoginItemProjection(isOn: false, isEnabled: true, message: .approval))
    }

    @Test func notFoundAndUnknownRawValuesAreOffWithTheFailureLine() {
        #expect(p(3, false, true) == LoginItemProjection(isOn: false, isEnabled: true, message: .failure))
        #expect(p(99, false, true) == LoginItemProjection(isOn: false, isEnabled: true, message: .failure))
        #expect(p(-1, false, true) == LoginItemProjection(isOn: false, isEnabled: true, message: .failure))
    }

    @Test func outsideApplicationsTheSwitchCannotBeTurnedOnAndTheLocationLineShows() {
        #expect(p(0, false, false) == LoginItemProjection(isOn: false, isEnabled: false, message: .location))
        #expect(p(2, false, false) == LoginItemProjection(isOn: false, isEnabled: false, message: .location))
        #expect(p(3, true, false) == LoginItemProjection(isOn: false, isEnabled: false, message: .location))
    }

    @Test func anExistingRegistrationOutsideApplicationsCanStillBeTurnedOff() {
        #expect(p(1, false, false) == LoginItemProjection(isOn: true, isEnabled: true, message: .location))
    }

    @Test func applicationsFolderAcceptsOnlyPathsUnderApplications() {
        #expect(ApplicationsFolder.contains(bundlePath: "/Applications/Metr.app"))
        #expect(ApplicationsFolder.contains(bundlePath: "/Applications/Utilities/Metr.app"))
        #expect(!ApplicationsFolder.contains(bundlePath: "/Users/u/Downloads/Metr.app"))
        #expect(!ApplicationsFolder.contains(bundlePath: "/private/var/folders/x/AppTranslocation/ABC/d/Metr.app"))
        #expect(!ApplicationsFolder.contains(bundlePath: "/Volumes/Metr/Metr.app"))
        #expect(!ApplicationsFolder.contains(bundlePath: "/ApplicationsOld/Metr.app"))
        #expect(
            !ApplicationsFolder.contains(
                bundlePath: "/Users/u/Library/Developer/Xcode/DerivedData/x/Build/Products/Debug/Metr.app"))
    }

    @Test func neverRegistersOutsideApplications() {
        #expect(LoginItemAction.decide(requestOn: true, inApplications: true) == .register)
        #expect(LoginItemAction.decide(requestOn: true, inApplications: false) == .none)
        #expect(LoginItemAction.decide(requestOn: false, inApplications: true) == .unregister)
        #expect(LoginItemAction.decide(requestOn: false, inApplications: false) == .unregister)
    }
}
