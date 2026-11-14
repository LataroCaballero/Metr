import MetrCore
import Observation
import ServiceManagement

/// What the model needs from the system, so a fixture can stand in for the live login item (the
/// Settings snapshots never touch it).
@MainActor
protocol LoginItemService {
    /// `SMAppService.Status` as its raw value: 0 notRegistered, 1 enabled, 2 requiresApproval, 3 notFound.
    var rawStatus: Int { get }
    /// Whether this copy of Metr runs from /Applications (D-13).
    var runsFromApplications: Bool { get }
    func register() throws
    func unregister() throws
    func openLoginItemsSettings()
}

/// The live service: `SMAppService.mainApp`, the login item of this very app.
@MainActor
struct SystemLoginItemService: LoginItemService {
    var rawStatus: Int { SMAppService.mainApp.status.rawValue }

    var runsFromApplications: Bool {
        ApplicationsFolder.contains(bundlePath: Bundle.main.bundleURL.path)
    }

    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }

    /// Returns nothing, so a failure to open the pane cannot be detected; the approval and failure
    /// lines name the full path in words.
    func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// The Open at login switch as a projection of what the system holds (D-03, D-04). Nothing is kept
/// between reads: the system is asked again on appear, on activation and after every action, so the
/// switch can never claim a state macOS does not hold. These are the only call sites of register and
/// unregister outside DEBUG code, and they are reached only from the switch.
@Observable
@MainActor
final class LoginItemModel {
    private let service: LoginItemService
    private(set) var projection: LoginItemProjection

    init(service: LoginItemService) {
        self.service = service
        self.projection = LoginItemProjection.project(
            rawStatus: service.rawStatus, actionFailed: false, inApplications: service.runsFromApplications)
    }

    /// Reads the system again. Synchronous: the window paints with the real state, no placeholder.
    func refresh() {
        project(actionFailed: false)
    }

    /// The user flipped the switch. Runs on the main actor and re-reads after the call, so two quick
    /// flips end with the state the system holds after the last one.
    func setEnabled(_ on: Bool) {
        var failed = false
        switch LoginItemAction.decide(requestOn: on, inApplications: service.runsFromApplications) {
        case .register:
            do { try service.register() } catch { failed = true; logFailure(error) }
        case .unregister:
            do { try service.unregister() } catch { failed = true; logFailure(error) }
        case .none:
            break
        }
        project(actionFailed: failed)
    }

    func openLoginItemsSettings() {
        service.openLoginItemsSettings()
    }

    private func project(actionFailed: Bool) {
        projection = LoginItemProjection.project(
            rawStatus: service.rawStatus, actionFailed: actionFailed,
            inApplications: service.runsFromApplications)
    }

    private func logFailure(_ error: Error) {
        #if DEBUG
        let nsError = error as NSError
        DebugHooks.log(
            "settings login error=\(nsError.domain)#\(nsError.code) "
                + nsError.localizedDescription.replacingOccurrences(of: "\n", with: " "))
        #endif
    }

    #if DEBUG
    /// The window-script line for a `login:<on|off>` step.
    var debugDescription: String {
        let message: String
        switch projection.message {
        case .none: message = "none"
        case .approval: message = "approval"
        case .failure: message = "failure"
        case .location: message = "location"
        }
        return "status=\(service.rawStatus) shown=\(projection.isOn ? "on" : "off") message=\(message)"
    }
    #endif
}
