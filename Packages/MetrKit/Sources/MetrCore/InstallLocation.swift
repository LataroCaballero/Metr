import Foundation

/// Where the running Metr bundle lives, as far as the Move to Applications offer cares (D-13).
public enum InstallLocationClass: String, Sendable, CaseIterable {
    /// Under `/Applications/`: the place Open at login needs (the same rule as the Settings switch).
    case applications
    /// An App Translocation path: a quarantined download launched straight from where it landed.
    case translocated
    /// A mounted disk image, or any read-only volume.
    case diskImage
    /// A build run by a developer or by the verification scripts: never offered a move.
    case development
    /// Any other folder (Downloads, the Desktop, ...).
    case elsewhere

    /// Checks, in order: development, applications, translocated, disk image, elsewhere.
    ///
    /// Development is a path component named `DerivedData` or `metr-build` (every build path the
    /// scripts use lies under a `metr-build` directory), so no volume name of the developer's Mac is
    /// needed here. Applications is `ApplicationsFolder.contains`, the rule Settings uses for the
    /// Open at login switch, so the offer and the switch always agree on where Metr runs.
    public static func classify(path: String, volumeIsReadOnly: Bool) -> InstallLocationClass {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        if components.contains(where: { $0 == "DerivedData" || $0 == "metr-build" }) {
            return .development
        }
        if ApplicationsFolder.contains(bundlePath: path) { return .applications }
        if components.contains("AppTranslocation") { return .translocated }
        if volumeIsReadOnly || path.hasPrefix("/Volumes/") { return .diskImage }
        return .elsewhere
    }
}

/// A Metr version as the offer compares it: the build number first, then the short version.
public struct BundleVersion: Sendable, Comparable, Equatable {
    /// `CFBundleVersion` as an integer; nil when absent or not a number (sorts lowest).
    public let build: Int?
    /// `CFBundleShortVersionString`, compared numerically by dot components.
    public let short: String

    public init(build: Int?, short: String) {
        self.build = build
        self.short = short
    }

    /// From the two Info.plist strings; a missing short version reads as "0".
    public init(shortVersion: String?, buildNumber: String?) {
        self.init(
            build: buildNumber.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) },
            short: shortVersion ?? "0")
    }

    /// The identity the Not Now record stores: `"<short> (<build>)"`.
    public var id: String { "\(short) (\(build.map(String.init) ?? "?"))" }

    /// -1, 0 or 1. Build first (nil lowest), then the dot components of `short` as numbers.
    private func order(_ other: BundleVersion) -> Int {
        switch (build, other.build) {
        case let (a?, b?) where a != b: return a < b ? -1 : 1
        case (nil, _?): return -1
        case (_?, nil): return 1
        default: break
        }
        let left = Self.components(short)
        let right = Self.components(other.short)
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b ? -1 : 1 }
        }
        return 0
    }

    private static func components(_ text: String) -> [Int] {
        text.split(separator: ".").map { part in
            Int(part.prefix(while: \.isNumber)) ?? 0
        }
    }

    public static func < (lhs: BundleVersion, rhs: BundleVersion) -> Bool { lhs.order(rhs) < 0 }

    /// Equal when neither is lower, so `==` and `<` can never disagree ("1.0" equals "1.0.0").
    public static func == (lhs: BundleVersion, rhs: BundleVersion) -> Bool { lhs.order(rhs) == 0 }
}

/// What sits at the destination (`/Applications/Metr.app`) when the offer is decided.
public enum InstalledCopy: Sendable, Equatable {
    case none
    /// A bundle with Metr's identifier, at this version.
    case metr(BundleVersion)
    /// Anything else: another identifier, or something that cannot be read as a bundle.
    case foreign
}

/// What the move does about an existing item at the destination.
public enum ReplacePlan: String, Sendable {
    case nothing
    case trash
    case refuse
}

public enum MoveOfferDecision: Sendable, Equatable {
    case skip(reason: String)
    case offer(replace: ReplacePlan)
}

public enum MoveOffer {
    /// Precedence: development and applications skip; then a decline recorded for this version
    /// skips; then a newer installed copy skips (a move would downgrade); then the offer, with the
    /// replace plan for whatever sits at the destination.
    public static func decide(
        location: InstallLocationClass, running: BundleVersion, installed: InstalledCopy,
        declinedVersionID: String?
    ) -> MoveOfferDecision {
        switch location {
        case .development: return .skip(reason: "development")
        case .applications: return .skip(reason: "in-applications")
        case .translocated, .diskImage, .elsewhere: break
        }
        if declinedVersionID == running.id { return .skip(reason: "declined") }
        guard let plan = replacePlan(running: running, installed: installed) else {
            return .skip(reason: "newer-installed")
        }
        return .offer(replace: plan)
    }

    /// What to do about the installed item, or nil when it is a newer Metr (never replace it).
    /// A same-version or older Metr is trashed; another app or an unreadable item is refused.
    public static func replacePlan(running: BundleVersion, installed: InstalledCopy) -> ReplacePlan? {
        switch installed {
        case .none: return .nothing
        case .foreign: return .refuse
        case .metr(let version): return version > running ? nil : .trash
        }
    }

    /// True when the item at the destination, read again right before acting, may still be moved
    /// over: nothing there, or a same-version or older Metr. A newer Metr or a foreign item that
    /// appeared after the decision makes it false and nothing is touched.
    public static func stillReplaceable(running: BundleVersion, installed: InstalledCopy) -> Bool {
        guard let plan = replacePlan(running: running, installed: installed) else { return false }
        return plan != .refuse
    }
}

/// The "Not Now" record: one version id per location class, so a translocated path that changes on
/// every launch cannot defeat it, and the alert stays quiet until the app version changes.
public struct MoveOfferRecord {
    public static let key = "MoveOfferDeclined"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func declinedVersionID(for location: InstallLocationClass) -> String? {
        (defaults.dictionary(forKey: Self.key) as? [String: String])?[location.rawValue]
    }

    public func recordDecline(_ location: InstallLocationClass, version: String) {
        var record = (defaults.dictionary(forKey: Self.key) as? [String: String]) ?? [:]
        record[location.rawValue] = version
        defaults.set(record, forKey: Self.key)
    }
}
