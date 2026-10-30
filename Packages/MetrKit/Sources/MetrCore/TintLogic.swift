/// Ring tint state. Only the arc takes the tint (UI-SPEC "Ring tint rules").
public enum RingTint: Sendable, Equatable {
    case none
    case warning
    case critical
}

/// Which rings tint, and when (D-01, D-02, D-03).
public enum TintLogic {
    /// The CPU ring never tints: high CPU is often normal (D-02).
    public static func cpu() -> RingTint { .none }

    /// Memory pressure drives the tint (D-01). Unknown pressure stays neutral.
    public static func memory(_ pressure: MemoryPressure?) -> RingTint {
        switch pressure {
        case .warn: .warning
        case .critical: .critical
        case .normal, nil: .none
        }
    }

    /// Disk tint from the free fraction with 1-point hysteresis (D-03).
    /// Enter: warning (the Elevated orange) below 10 % free, critical (red) below 5 %.
    /// Leave: critical falls to warning at 6 % or more, anything returns to neutral at 11 % or more.
    public static func disk(freeFraction: Double?, previous: RingTint) -> RingTint {
        guard let free = freeFraction else { return .none }
        switch previous {
        case .none:
            if free < 0.05 { return .critical }
            if free < 0.10 { return .warning }
            return .none
        case .warning:
            if free < 0.05 { return .critical }
            if free >= 0.11 { return .none }
            return .warning
        case .critical:
            if free >= 0.11 { return .none }
            if free >= 0.06 { return .warning }
            return .critical
        }
    }
}

/// Quantizes ring fills so the status item image is rebuilt only on visible change.
public enum RingQuantizer {
    /// nil stays nil; below 1 % is 0 (track only); 99.5 % or more is 1 (full circle);
    /// otherwise the nearest 2 % step.
    public static func quantize(_ fill: Double?) -> Double? {
        guard let fill else { return nil }
        if fill < 0.01 { return 0 }
        if fill >= 0.995 { return 1 }
        return (fill / 0.02).rounded() * 0.02
    }
}
