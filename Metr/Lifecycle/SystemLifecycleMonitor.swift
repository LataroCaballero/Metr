import AppKit
import MetrCore
import MetrSystem

/// Turns system sleep, display sleep, session changes and power/thermal pressure into
/// suspend/resume/constrained calls on the sampler (FND-02).
///
/// Every observer is a block on `OperationQueue.main` wrapped in `MainActor.assumeIsolated`.
/// ProcessInfo notifications can be posted from other threads, and a MainActor `@objc`
/// selector invoked off-main traps under Swift 6 (T-01-08).
@MainActor
final class SystemLifecycleMonitor {
    private let sampler: MetricsSampler
    private var tokens: [any NSObjectProtocol] = []

    init(sampler: MetricsSampler) {
        self.sampler = sampler
    }

    func start() {
        guard tokens.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let pairs: [(NSNotification.Name, NSNotification.Name, SuspendReason)] = [
            (NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, .systemSleep),
            (NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification, .displaySleep),
            (NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification, .sessionInactive),
        ]
        for (down, up, reason) in pairs {
            observe(workspace, down) { sampler in sampler.suspend(reason: reason) }
            observe(workspace, up) { sampler in sampler.resume(reason: reason) }
        }

        // Drives coming and going (DISK-02). Registering these once is cheap: with the window
        // closed `refreshVolumes` delivers nothing, because the plan carries no volumes.
        observe(workspace, NSWorkspace.didMountNotification) { sampler in sampler.refreshVolumes(reason: "mount") }
        observe(workspace, NSWorkspace.didUnmountNotification) { sampler in sampler.refreshVolumes(reason: "unmount") }
        observe(workspace, NSWorkspace.didRenameVolumeNotification) { sampler in sampler.refreshVolumes(reason: "rename") }
        // The volume is still listed when the will-unmount notice arrives, so read again shortly
        // after as well, once it has gone.
        observe(workspace, NSWorkspace.willUnmountNotification) { sampler in
            sampler.refreshVolumes(reason: "willUnmount")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { sampler.refreshVolumes(reason: "willUnmount") }
        }

        let center = NotificationCenter.default
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            observe(center, name) { sampler in sampler.setConstrained(Self.isConstrained()) }
        }
        sampler.setConstrained(Self.isConstrained())
    }

    private func observe(
        _ center: NotificationCenter,
        _ name: NSNotification.Name,
        _ body: @escaping @MainActor (MetricsSampler) -> Void
    ) {
        let sampler = self.sampler
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { body(sampler) }
        }
        tokens.append(token)
    }

    /// Low Power Mode or a serious/critical thermal state halves every cadence.
    nonisolated static func isConstrained() -> Bool {
        let info = ProcessInfo.processInfo
        return info.isLowPowerModeEnabled || info.thermalState == .serious || info.thermalState == .critical
    }
}
