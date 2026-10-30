/// The Mac's thermal state as the panel shows it (PANEL-05, D-19).
///
/// Fair counts as Normal so ordinary load never cries wolf; serious means the Mac is throttling.
/// Pure mapping from the raw `ProcessInfo.ThermalState` value so MetrCore stays free of Foundation.
public enum ThermalLevel: String, Sendable, Equatable {
    case normal
    case elevated
    case critical

    /// `ProcessInfo.ThermalState.rawValue`: 0 nominal and 1 fair are Normal, 2 serious is Elevated,
    /// 3 critical is Critical. Any other value (a future macOS may add states) is Normal, so the
    /// line never shows a fabricated alarm (T-02-04).
    public init(thermalStateRawValue raw: Int) {
        switch raw {
        case 2: self = .elevated
        case 3: self = .critical
        default: self = .normal
        }
    }

    /// The tint of the state word. Normal stays neutral (D-05).
    public var tint: RingTint {
        switch self {
        case .normal: .none
        case .elevated: .warning
        case .critical: .critical
        }
    }
}
