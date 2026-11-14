import Foundation
import Testing

@testable import MetrCore

@Suite struct InstallLocationTests {
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

    private let v100 = BundleVersion(build: 40, short: "1.0.0")

    // MARK: classify

    @Test func applicationsFolderIsApplications() {
        #expect(InstallLocationClass.classify(path: "/Applications/Metr.app", volumeIsReadOnly: false) == .applications)
    }

    @Test func translocatedPathIsTranslocated() {
        let path = "/private/var/folders/x/AppTranslocation/ABC/d/Metr.app"
        #expect(InstallLocationClass.classify(path: path, volumeIsReadOnly: true) == .translocated)
    }

    @Test func mountedVolumesAreDiskImages() {
        #expect(InstallLocationClass.classify(path: "/Volumes/Metr/Metr.app", volumeIsReadOnly: true) == .diskImage)
        #expect(InstallLocationClass.classify(path: "/Volumes/Data/Metr.app", volumeIsReadOnly: false) == .diskImage)
        #expect(InstallLocationClass.classify(path: "/Users/u/Metr.app", volumeIsReadOnly: true) == .diskImage)
    }

    @Test func developmentPathsAreDevelopment() {
        let paths = [
            "/Volumes/Dev/metr-build/abc/DerivedData/Build/Products/Release/Metr.app",
            "/Volumes/Dev/metr-build/abc/shipped/1.0.0/Metr.app",
            "/Users/u/Library/Developer/Xcode/DerivedData/x/Metr.app",
        ]
        for path in paths {
            #expect(InstallLocationClass.classify(path: path, volumeIsReadOnly: false) == .development)
            #expect(InstallLocationClass.classify(path: path, volumeIsReadOnly: true) == .development)
        }
    }

    @Test func otherFoldersAreElsewhere() {
        #expect(InstallLocationClass.classify(path: "/Users/u/Downloads/Metr.app", volumeIsReadOnly: false) == .elsewhere)
    }

    @Test func aComponentNameMustMatchWholly() {
        // "metr-build-notes" and "MyDerivedData" are not the development components.
        #expect(InstallLocationClass.classify(path: "/Users/u/metr-build-notes/Metr.app", volumeIsReadOnly: false) == .elsewhere)
        #expect(InstallLocationClass.classify(path: "/Users/u/MyDerivedData/Metr.app", volumeIsReadOnly: false) == .elsewhere)
    }

    @Test func applicationsClassAgreesWithTheSettingsSwitchRule() {
        let paths = [
            "/Applications/Metr.app", "/Applications/Utilities/Metr.app", "/Applications",
            "/Applications.app/Metr.app", "/Users/u/Applications/Metr.app",
            "/private/var/folders/x/AppTranslocation/ABC/d/Metr.app", "/Volumes/Metr/Metr.app",
            "/Users/u/Downloads/Metr.app", "/Volumes/Dev/metr-build/abc/DerivedData/Build/Products/Release/Metr.app",
            "/Volumes/Dev/metr-build/abc/shipped/1.0.0/Metr.app",
        ]
        for path in paths {
            for readOnly in [false, true] {
                let isApplications = InstallLocationClass.classify(path: path, volumeIsReadOnly: readOnly) == .applications
                // Development paths are classified first and are never under /Applications.
                #expect(isApplications == ApplicationsFolder.contains(bundlePath: path), "\(path)")
            }
        }
    }

    // MARK: BundleVersion

    @Test func buildDecidesBeforeShortVersion() {
        #expect(BundleVersion(build: 41, short: "0.9.0") > BundleVersion(build: 40, short: "1.0.0"))
        #expect(BundleVersion(build: nil, short: "9.9") < BundleVersion(build: 1, short: "0.1"))
    }

    @Test func shortVersionComparesNumericallyByComponent() {
        #expect(BundleVersion(build: 1, short: "1.10.0") > BundleVersion(build: 1, short: "1.9.0"))
        #expect(BundleVersion(build: 1, short: "1.0") == BundleVersion(build: 1, short: "1.0.0"))
        #expect(BundleVersion(build: 1, short: "2.0") > BundleVersion(build: 1, short: "1.99.99"))
    }

    @Test func versionIDIsShortPlusBuild() {
        #expect(v100.id == "1.0.0 (40)")
        #expect(BundleVersion(shortVersion: "0.1.0", buildNumber: "1").id == "0.1.0 (1)")
    }

    @Test func versionFromPlistStrings() {
        let version = BundleVersion(shortVersion: nil, buildNumber: "abc")
        #expect(version.build == nil)
        #expect(version.short == "0")
    }

    // MARK: decide

    @Test func applicationsAndDevelopmentNeverOffer() {
        #expect(MoveOffer.decide(location: .applications, running: v100, installed: .none, declinedVersionID: nil)
            == .skip(reason: "in-applications"))
        #expect(MoveOffer.decide(location: .development, running: v100, installed: .none, declinedVersionID: nil)
            == .skip(reason: "development"))
        // A development build never offers even over a foreign or older item.
        #expect(MoveOffer.decide(location: .development, running: v100, installed: .foreign, declinedVersionID: nil)
            == .skip(reason: "development"))
    }

    @Test func nothingInstalledOffersWithoutReplacing() {
        #expect(MoveOffer.decide(location: .diskImage, running: v100, installed: .none, declinedVersionID: nil)
            == .offer(replace: .nothing))
    }

    @Test func sameOrOlderMetrIsTrashed() {
        let same = InstalledCopy.metr(v100)
        let older = InstalledCopy.metr(BundleVersion(build: 30, short: "0.9.0"))
        #expect(MoveOffer.decide(location: .elsewhere, running: v100, installed: same, declinedVersionID: nil)
            == .offer(replace: .trash))
        #expect(MoveOffer.decide(location: .elsewhere, running: v100, installed: older, declinedVersionID: nil)
            == .offer(replace: .trash))
    }

    @Test func aNewerInstalledCopyIsNeverReplaced() {
        let newer = InstalledCopy.metr(BundleVersion(build: 41, short: "1.0.0"))
        #expect(MoveOffer.decide(location: .diskImage, running: v100, installed: newer, declinedVersionID: nil)
            == .skip(reason: "newer-installed"))
    }

    @Test func aForeignItemIsRefused() {
        #expect(MoveOffer.decide(location: .diskImage, running: v100, installed: .foreign, declinedVersionID: nil)
            == .offer(replace: .refuse))
    }

    @Test func aDeclineSilencesTheSameVersionOnly() {
        #expect(MoveOffer.decide(location: .translocated, running: v100, installed: .none, declinedVersionID: "1.0.0 (40)")
            == .skip(reason: "declined"))
        #expect(MoveOffer.decide(location: .translocated, running: v100, installed: .none, declinedVersionID: "0.9.0 (30)")
            == .offer(replace: .nothing))
    }

    @Test func aDeclineBeatsTheReplacePlan() {
        #expect(MoveOffer.decide(location: .diskImage, running: v100, installed: .foreign, declinedVersionID: "1.0.0 (40)")
            == .skip(reason: "declined"))
    }

    // MARK: stale-decision re-check

    @Test func stillReplaceableOnlyForNothingOrSameOrOlderMetr() {
        #expect(MoveOffer.stillReplaceable(running: v100, installed: .none))
        #expect(MoveOffer.stillReplaceable(running: v100, installed: .metr(v100)))
        #expect(MoveOffer.stillReplaceable(running: v100, installed: .metr(BundleVersion(build: 1, short: "0.1.0"))))
        #expect(!MoveOffer.stillReplaceable(running: v100, installed: .metr(BundleVersion(build: 41, short: "1.0.0"))))
        #expect(!MoveOffer.stillReplaceable(running: v100, installed: .foreign))
    }

    @Test func aDecisionStaleByANewerCopyNoLongerReplaces() {
        // Decided as .nothing, then a newer Metr appears at the destination before the move acts.
        #expect(MoveOffer.decide(location: .diskImage, running: v100, installed: .none, declinedVersionID: nil)
            == .offer(replace: .nothing))
        #expect(!MoveOffer.stillReplaceable(running: v100, installed: .metr(BundleVersion(build: 99, short: "2.0.0"))))
    }

    // MARK: record

    @Test func theRecordRoundTripsADeclinePerClass() {
        let domain = Domain()
        defer { domain.cleanup() }
        let record = MoveOfferRecord(defaults: domain.defaults)
        #expect(record.declinedVersionID(for: .diskImage) == nil)
        record.recordDecline(.diskImage, version: "1.0.0 (40)")
        #expect(record.declinedVersionID(for: .diskImage) == "1.0.0 (40)")
        #expect(record.declinedVersionID(for: .translocated) == nil)
        record.recordDecline(.translocated, version: "1.0.0 (40)")
        record.recordDecline(.diskImage, version: "1.1.0 (50)")
        #expect(record.declinedVersionID(for: .diskImage) == "1.1.0 (50)")
        #expect(record.declinedVersionID(for: .translocated) == "1.0.0 (40)")
        #expect(MoveOfferRecord(defaults: domain.defaults).declinedVersionID(for: .diskImage) == "1.1.0 (50)")
    }

    @Test func theRecordIsStoredUnderTheDocumentedKey() {
        let domain = Domain()
        defer { domain.cleanup() }
        #expect(MoveOfferRecord.key == "MoveOfferDeclined")
        MoveOfferRecord(defaults: domain.defaults).recordDecline(.elsewhere, version: "1.0.0 (40)")
        let stored = domain.defaults.dictionary(forKey: "MoveOfferDeclined") as? [String: String]
        #expect(stored == ["elsewhere": "1.0.0 (40)"])
    }
}
