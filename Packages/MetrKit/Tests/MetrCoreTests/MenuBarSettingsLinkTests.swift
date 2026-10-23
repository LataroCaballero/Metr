import Foundation
import Testing

@testable import MetrCore

@Suite struct MenuBarSettingsLinkTests {
    @Test func aDeepLinkThatOpensIsReportedAndTriedOnce() {
        var calls: [URL] = []
        let outcome = MenuBarSettingsLink.open(using: { url in
            calls.append(url)
            return true
        })
        #expect(outcome == .deepLink)
        #expect(calls == [MenuBarSettingsLink.deepLink])
    }

    @Test func aRefusedDeepLinkFallsBackToSystemSettings() {
        var calls: [URL] = []
        let outcome = MenuBarSettingsLink.open(using: { url in
            calls.append(url)
            return url == MenuBarSettingsLink.systemSettingsApp
        })
        #expect(outcome == .systemSettings)
        #expect(calls == [MenuBarSettingsLink.deepLink, MenuBarSettingsLink.systemSettingsApp])
    }

    @Test func whenNothingOpensTheOutcomeIsFailed() {
        var calls: [URL] = []
        let outcome = MenuBarSettingsLink.open(using: { url in
            calls.append(url)
            return false
        })
        #expect(outcome == .failed)
        #expect(calls == [MenuBarSettingsLink.deepLink, MenuBarSettingsLink.systemSettingsApp])
    }

    @Test func theDeepLinkIsTheFixedControlCenterExtension() {
        #expect(
            MenuBarSettingsLink.deepLink.absoluteString
                == "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension")
    }

    @Test func theSystemSettingsAppExistsOnThisMac() {
        #expect(FileManager.default.fileExists(atPath: MenuBarSettingsLink.systemSettingsApp.path))
    }
}
