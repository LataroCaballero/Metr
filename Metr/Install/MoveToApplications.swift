import AppKit
import MetrCore

/// The launch-time Move to Applications offer (D-13). A copy that runs from a disk image, an App
/// Translocation path or any folder other than /Applications offers once to move itself there, so
/// Open at login has a stable bundle to register. The rules live in `MoveOffer` (MetrCore, tested);
/// this file reads the facts, shows the alerts and does the move.
@MainActor
enum MoveToApplications {
    /// The bundle name at the destination.
    private static let bundleName = "Metr.app"

    #if DEBUG
    /// DEBUG-only hooks, so the decision and the move can be proven without touching /Applications.
    /// `METR_DEBUG_MOVE_PROBE=1` logs the decision and offers nothing; `METR_DEBUG_MOVE_DESTINATION`
    /// is a directory standing in for /Applications; `METR_DEBUG_MOVE_CONFIRM` answers the alert
    /// (`move`, `notnow`) or presents the real alerts (`present`, `present-failure`). Without any of
    /// them a DEBUG build offers nothing. Release has none of these names.
    private struct DebugMove {
        let probe: Bool
        let destinationDirectory: URL?
        let confirm: String?

        init() {
            let env = ProcessInfo.processInfo.environment
            probe = env["METR_DEBUG_MOVE_PROBE"] == "1"
            destinationDirectory = env["METR_DEBUG_MOVE_DESTINATION"].flatMap {
                $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true)
            }
            confirm = env["METR_DEBUG_MOVE_CONFIRM"].flatMap { $0.isEmpty ? nil : $0 }
        }

        var isActive: Bool { probe || destinationDirectory != nil || confirm != nil }
    }

    /// True when any move hook is set: a scripted move run keeps its Not Now record in the throwaway
    /// preferences suite, never in the owner's domain.
    static var debugHookActive: Bool { DebugMove().isActive }
    #endif

    /// True when a move run is scripted (DEBUG only; always false in Release).
    static var scriptedRun: Bool {
        #if DEBUG
        return debugHookActive
        #else
        return false
        #endif
    }

    /// Decides and, when the offer stands, asks. Returns true when a relaunch from the destination
    /// is under way: the caller stops launching.
    static func checkAtLaunch(preferences: UserDefaults) -> Bool {
        #if DEBUG
        let hooks = DebugMove()
        guard hooks.isActive else { return false }
        #endif

        let bundleURL = Bundle.main.bundleURL
        let readOnly = (try? bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        let location = InstallLocationClass.classify(path: bundleURL.path, volumeIsReadOnly: readOnly)
        let running = BundleVersion(
            shortVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            buildNumber: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)

        #if DEBUG
        let destination = (hooks.destinationDirectory ?? URL(fileURLWithPath: "/Applications", isDirectory: true))
            .appending(path: bundleName, directoryHint: .isDirectory)
        #else
        let destination = URL(fileURLWithPath: "/Applications", isDirectory: true)
            .appending(path: bundleName, directoryHint: .isDirectory)
        #endif

        let record = MoveOfferRecord(defaults: preferences)
        let decision = MoveOffer.decide(
            location: location, running: running, installed: installedCopy(at: destination),
            declinedVersionID: record.declinedVersionID(for: location))

        #if DEBUG
        switch decision {
        case .skip(let reason):
            DebugHooks.log("move-offer class=\(location.rawValue) decision=skip replace=nothing reason=\(reason)")
        case .offer(let plan):
            DebugHooks.log("move-offer class=\(location.rawValue) decision=offer replace=\(plan.rawValue) reason=none")
        }
        #endif

        guard case .offer = decision else { return false }
        // The alert and the move arrive with the next task: a decision alone moves nothing.
        return false
    }

    /// What sits at `url` right now: nothing, a Metr bundle (with its version), or anything else.
    /// A symbolic link, a plain file and a bundle with another identifier are all foreign.
    static func installedCopy(at url: URL) -> InstalledCopy {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return .none }
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
            let bundle = Bundle(url: url),
            let identifier = bundle.bundleIdentifier,
            identifier == Bundle.main.bundleIdentifier
        else { return .foreign }
        return .metr(
            BundleVersion(
                shortVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                buildNumber: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String))
    }
}
