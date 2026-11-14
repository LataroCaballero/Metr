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

        // The running bundle IS the destination reached by another path (a firmlink or a symbolic link
        // into /Applications): it is installed, and the move would trash the very copy it runs from.
        if isSameItem(bundleURL, destination) {
            DebugHooks.log("move-offer class=\(location.rawValue) decision=skip replace=nothing reason=already-installed")
            return false
        }

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

        let answer: Answer
        #if DEBUG
        // A DEBUG build never presents an alert on its own: the hook answers, or asks for the real alert.
        switch hooks.confirm {
        case "move": answer = .move
        case "notnow": answer = .notNow
        case "present": answer = presentOfferAlert()
        case "present-failure":
            presentFailureAlert(revealing: bundleURL)
            return false
        default: return false
        }
        #else
        answer = presentOfferAlert()
        #endif

        switch answer {
        case .notNow:
            // Once per location class per app version: the next launch of this version stays quiet.
            record.recordDecline(location, version: running.id)
            DebugHooks.log("move declined class=\(location.rawValue)")
            return false
        case .move:
            if move(from: bundleURL, to: destination, running: running) { return true }
            DebugHooks.log("move result=failed relaunch=0")
            #if DEBUG
            if hooks.confirm == "present" { presentFailureAlert(revealing: bundleURL) }
            #else
            presentFailureAlert(revealing: bundleURL)
            #endif
            return false
        }
    }

    private enum Answer { case move, notNow }

    /// The offer (D-13): app icon, title and one-paragraph body, [Move to Applications] as the default
    /// (Return) and [Not Now] with Esc set explicitly (AppKit gives Esc only to a button titled Cancel).
    private static func presentOfferAlert() -> Answer {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = String(localized: "Move Metr to Applications?")
        alert.informativeText = String(
            localized: "Metr works best from your Applications folder, and Open at login needs it there.")
        let moveButton = alert.addButton(withTitle: String(localized: "Move to Applications"))
        moveButton.keyEquivalent = "\r"
        let notNowButton = alert.addButton(withTitle: String(localized: "Not Now"))
        notNowButton.keyEquivalent = "\u{1b}"
        NSApp.activate()
        DebugHooks.log("move alert shown kind=offer")
        return alert.runModal() == .alertFirstButtonReturn ? .move : .notNow
    }

    /// The failure (copy, trash or relaunch threw, or the destination holds something that is not an
    /// older Metr): one warning, [Show in Finder] as the default and [Not Now] with Esc. Metr keeps
    /// running from where it is; there is no retry.
    private static func presentFailureAlert(revealing bundleURL: URL) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Metr couldn't be moved.")
        alert.informativeText = String(
            localized: "Drag Metr into your Applications folder yourself, then open it from there.")
        let showButton = alert.addButton(withTitle: String(localized: "Show in Finder"))
        showButton.keyEquivalent = "\r"
        let notNowButton = alert.addButton(withTitle: String(localized: "Not Now"))
        notNowButton.keyEquivalent = "\u{1b}"
        NSApp.activate()
        DebugHooks.log("move alert shown kind=failure")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([bundleURL])
        }
    }

    private struct MoveError: Error {}

    /// Copies the running bundle to `destination` and relaunches from there. An older or same-version
    /// Metr already at the destination goes to the Trash first (never deleted outright); a newer Metr,
    /// another app or an unreadable item is left alone and the move fails. The destination is read again
    /// right before acting, because the decision may be stale. The copy keeps every extended attribute
    /// and the signature of the original: nothing here touches the quarantine attribute or Gatekeeper.
    /// Returns true when the relaunch is under way and Metr is terminating.
    private static func move(from source: URL, to destination: URL, running: BundleVersion) -> Bool {
        let fileManager = FileManager.default
        do {
            let installed = installedCopy(at: destination)
            guard MoveOffer.stillReplaceable(running: running, installed: installed) else { throw MoveError() }
            if case .metr = installed {
                var trashed: NSURL?
                try fileManager.trashItem(at: destination, resultingItemURL: &trashed)
                DebugHooks.log("move trashed=\(trashed?.path ?? "unknown")")
            }
            try fileManager.copyItem(at: source, to: destination)
            try relaunch(from: destination)
        } catch {
            return false
        }
        DebugHooks.log("move result=moved relaunch=1")
        NSApp.terminate(nil)
        return true
    }

    /// Starts a detached shell that waits for this process to exit, then opens the new copy as a new
    /// instance. The pid and the path are separate argv entries after a fixed script: no path text is
    /// ever part of the script string.
    private static func relaunch(from destination: URL) throws {
        let script = """
            i=0
            while /bin/kill -0 "$1" 2>/dev/null && [ "$i" -lt 100 ]; do /bin/sleep 0.2; i=$((i + 1)); done
            shift
            exec /usr/bin/open -n "$@"
            """
        var arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier), destination.path]
        #if DEBUG
        // The scripted copy must not claim the welcome window in the owner's domain.
        arguments += ["--args", "-MetrDidPresentWelcome", "YES"]
        #endif
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = arguments
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        try helper.run()
    }

    /// True when both URLs name the same file-system item, whatever path reaches it.
    private static func isSameItem(_ first: URL, _ second: URL) -> Bool {
        guard let a = try? first.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
            let b = try? second.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        else { return false }
        return a.isEqual(b)
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
