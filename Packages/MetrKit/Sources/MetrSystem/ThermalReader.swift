import Foundation
import MetrCore

/// The single place the app reads the thermal state (RESEARCH Architectural Responsibility Map:
/// MetrSystem reads the OS, the MainActor store observes). Event-driven: the store reads once at
/// init and again on `didChangeNotification`, never on a timer (D-19).
public enum ThermalReader {
    /// The current level, mapped from `ProcessInfo.thermalState` (D-19).
    public static func current() -> ThermalLevel {
        ThermalLevel(thermalStateRawValue: ProcessInfo.processInfo.thermalState.rawValue)
    }

    /// Posted by the system when the thermal state changes. It may arrive on any thread.
    public static var didChangeNotification: Notification.Name {
        ProcessInfo.thermalStateDidChangeNotification
    }
}
