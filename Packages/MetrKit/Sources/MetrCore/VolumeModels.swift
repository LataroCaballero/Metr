import Foundation

/// What the system says about one mounted volume, before any decision is made. Built by
/// `VolumeCollector` (MetrSystem) and turned into rows by `VolumeClassifier`, which is pure.
public struct VolumeFacts: Sendable, Equatable {
    public var path: String
    public var name: String
    /// The BSD name of the whole disk (an APFS container's synthesized disk), the container key.
    public var wholeDisk: String?
    public var isLocal: Bool
    public var isInternal: Bool
    public var isRoot: Bool
    public var isBrowsable: Bool
    public var isTimeMachine: Bool
    /// `DADeviceProtocol`: "Apple Fabric", "USB", "Virtual Interface" (a disk image) and so on.
    public var deviceProtocol: String?
    public var totalBytes: Int64?
    public var importantAvailableBytes: Int64?
    public var availableBytes: Int64?

    public init(
        path: String, name: String, wholeDisk: String? = nil,
        isLocal: Bool = true, isInternal: Bool = false, isRoot: Bool = false,
        isBrowsable: Bool = true, isTimeMachine: Bool = false, deviceProtocol: String? = nil,
        totalBytes: Int64? = nil, importantAvailableBytes: Int64? = nil, availableBytes: Int64? = nil
    ) {
        self.path = path
        self.name = name
        self.wholeDisk = wholeDisk
        self.isLocal = isLocal
        self.isInternal = isInternal
        self.isRoot = isRoot
        self.isBrowsable = isBrowsable
        self.isTimeMachine = isTimeMachine
        self.deviceProtocol = deviceProtocol
        self.totalBytes = totalBytes
        self.importantAvailableBytes = importantAvailableBytes
        self.availableBytes = availableBytes
    }
}

public enum VolumeRole: String, Sendable {
    case startup, `internal`, external
}

/// One row of the Disk section: one APFS container (or one plain disk), named by its main volume.
public struct VolumeInfo: Sendable, Equatable, Identifiable {
    /// The container key: the whole-disk BSD name, or the mount path when that is unknown.
    public var id: String
    public var name: String
    public var role: VolumeRole
    public var totalBytes: Int64?
    public var freeBytes: Int64?

    public init(id: String, name: String, role: VolumeRole, totalBytes: Int64?, freeBytes: Int64?) {
        self.id = id
        self.name = name
        self.role = role
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
    }

    /// total - free, never negative; nil when either figure is unknown.
    public var usedBytes: Int64? {
        guard let totalBytes, let freeBytes else { return nil }
        return max(0, totalBytes - freeBytes)
    }

    /// used / total, clamped to 0...1; nil when there is no figure to draw.
    public var usedFraction: Double? {
        guard let usedBytes, let totalBytes, totalBytes > 0 else { return nil }
        return min(1, max(0, Double(usedBytes) / Double(totalBytes)))
    }
}

/// Turns the facts of every mounted volume into the rows of the Disk section (DISK-01, D-17).
public enum VolumeClassifier {
    /// The `DADeviceProtocol` of a mounted disk image (.dmg, sparsebundle).
    static let diskImageProtocol = "Virtual Interface"

    /// One row per APFS container (or plain disk), the startup volume first, then internal, then
    /// external, each group by name and then by container id, so the order never changes between
    /// refreshes. Skips volumes that are not local, not browsable, Time Machine volumes and disk images.
    public static func volumes(from facts: [VolumeFacts]) -> [VolumeInfo] {
        var groups: [String: [VolumeFacts]] = [:]
        for fact in facts where isListed(fact) {
            groups[fact.wholeDisk ?? fact.path, default: []].append(fact)
        }
        let rows = groups.map { id, members in row(id: id, members: members) }
        return rows.sorted(by: areInOrder)
    }

    /// Finder-consistent free space: the larger of the "important usage" and the plain available
    /// figure. A non-APFS drive (exFAT) reports important-usage capacity as 0, which must never
    /// read as "no space left" (RESEARCH Pitfall 11). Nil when neither figure is known.
    public static func free(important: Int64?, available: Int64?) -> Int64? {
        switch (important, available) {
        case (nil, nil): return nil
        case (let value?, nil), (nil, let value?): return max(0, value)
        case (let a?, let b?): return max(0, a, b)
        }
    }

    private static func isListed(_ fact: VolumeFacts) -> Bool {
        fact.isLocal && fact.isBrowsable && !fact.isTimeMachine && fact.deviceProtocol != diskImageProtocol
    }

    private static func row(id: String, members: [VolumeFacts]) -> VolumeInfo {
        // The main volume names the row: the root volume when the container holds it, otherwise
        // the first by name (then path, so the pick never depends on the input order).
        let byName = members.sorted { lhs, rhs in
            switch lhs.name.localizedStandardCompare(rhs.name) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return lhs.path < rhs.path
            }
        }
        let main = members.first(where: \.isRoot) ?? byName[0]
        let sanitized = ProcessText.sanitize(main.name)
        let name = sanitized.isEmpty ? "—" : sanitized
        let role: VolumeRole = members.contains(where: \.isRoot) ? .startup : (main.isInternal ? .internal : .external)
        // A volume that does not report its size shows its name and no figures.
        guard let total = main.totalBytes, total > 0 else {
            return VolumeInfo(id: id, name: name, role: role, totalBytes: nil, freeBytes: nil)
        }
        let freeBytes = free(important: main.importantAvailableBytes, available: main.availableBytes)
        return VolumeInfo(id: id, name: name, role: role, totalBytes: total, freeBytes: freeBytes)
    }

    private static func areInOrder(_ lhs: VolumeInfo, _ rhs: VolumeInfo) -> Bool {
        if lhs.role != rhs.role { return rank(lhs.role) < rank(rhs.role) }
        switch lhs.name.localizedStandardCompare(rhs.name) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame: return lhs.id.compare(rhs.id, options: [.numeric, .literal]) == .orderedAscending
        }
    }

    private static func rank(_ role: VolumeRole) -> Int {
        switch role {
        case .startup: 0
        case .internal: 1
        case .external: 2
        }
    }
}
