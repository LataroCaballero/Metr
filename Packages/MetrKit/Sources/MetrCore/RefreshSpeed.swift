import Foundation

/// The one sampling preference (SET-02, D-05, D-06): Normal, or Energy Saver, which doubles every
/// sampling cadence at once. The stored value is the raw string under `defaultsKey`; an absent or
/// unknown value reads as Normal, so a damaged preference can never leave Metr in a surprising state.
public enum RefreshSpeed: String, Sendable, CaseIterable {
    case normal
    case energySaver

    /// The preferences key the Settings pop-up writes and the lifecycle monitor observes.
    public static let defaultsKey = "refreshSpeed"

    public init(storedValue: String?) {
        self = storedValue.flatMap(RefreshSpeed.init(rawValue:)) ?? .normal
    }
}

/// D-05: the cadence is constrained (every interval doubled) when the user chose Energy Saver OR the
/// system is constrained (Low Power Mode, a serious or critical thermal state). Choosing Normal never
/// overrides the system.
public enum ConstrainedResolver {
    public static func resolve(speed: RefreshSpeed, systemConstrained: Bool) -> Bool {
        speed == .energySaver || systemConstrained
    }
}
