import DiskArbitration
import Foundation
import MetrCore

/// Reads every mounted volume for the Disk section (DISK-01). Each read costs about 16.6 ms per
/// volume, so it runs only on the window's Disk cadence, never on the 1 s path. Confined to the
/// sampler queue.
///
/// Like `DiskCollector`, it never reuses a `URL` across samples: Foundation caches resource values
/// per `URL` instance and the sampler queue has no run loop to flush that cache (CR-01). Each
/// sample enumerates the mounts afresh and builds a fresh `URL` from every mount path.
///
/// The container key comes from DiskArbitration: the volumes of one APFS container share one
/// synthesized whole disk (`disk3` for the six system volumes of this Mac). The session is made
/// on the first sample and dropped by `reset()` when the window closes, so nothing is held at
/// idle (RESEARCH Pitfall 16).
public final class VolumeCollector {
    private var session: DASession?

    public init() {}

    private static let keys: Set<URLResourceKey> = [
        .volumeIsLocalKey, .volumeIsInternalKey, .volumeIsRootFileSystemKey, .volumeIsBrowsableKey,
        .volumeLocalizedNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        .volumeAvailableCapacityKey,
    ]

    /// `.unavailable` when the mounts cannot be listed at all. A volume that cannot be read is left
    /// out of the list, one that reports no capacity stays in with no figures.
    public func sample() -> Reading<[VolumeInfo]> {
        guard
            let mounted = FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes])
        else { return .unavailable }
        let all = mounted.compactMap { volumeFacts(forMountPath: $0.path(percentEncoded: false)) }
        return .value(VolumeClassifier.volumes(from: all))
    }

    /// Drops the DiskArbitration session. The next sample makes a new one.
    public func reset() {
        session = nil
    }

    private func volumeFacts(forMountPath path: String) -> VolumeFacts? {
        let fresh = URL(filePath: path, directoryHint: .isDirectory)
        guard let values = try? fresh.resourceValues(forKeys: Self.keys) else { return nil }
        let name = values.volumeLocalizedName ?? fresh.lastPathComponent
        let disk = Self.diskIdentity(of: path, session: &session)
        return VolumeFacts(
            path: path,
            name: name,
            wholeDisk: disk.wholeDisk,
            isLocal: values.volumeIsLocal ?? false,
            isInternal: values.volumeIsInternal ?? false,
            isRoot: values.volumeIsRootFileSystem ?? false,
            isBrowsable: values.volumeIsBrowsable ?? false,
            isTimeMachine: Self.isTimeMachine(path: path, name: name),
            deviceProtocol: disk.deviceProtocol,
            totalBytes: values.volumeTotalCapacity.map(Int64.init),
            importantAvailableBytes: values.volumeAvailableCapacityForImportantUsage,
            availableBytes: values.volumeAvailableCapacity.map(Int64.init))
    }

    /// Time Machine heuristic (RESEARCH Open Question 4, Assumption A4): the volume root holds
    /// `Backups.backupdb`, or the name ends in ".timemachine". Documented limit, low impact.
    private static func isTimeMachine(path: String, name: String) -> Bool {
        if name.hasSuffix(".timemachine") { return true }
        let root = URL(filePath: path, directoryHint: .isDirectory)
        return FileManager.default.fileExists(atPath: root.appending(path: "Backups.backupdb").path(percentEncoded: false))
    }

    /// The mount's device name from `statfs`, read as a bounded C string.
    private static func mountSource(of path: String) -> String? {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return nil }
        return withUnsafePointer(to: &info.f_mntfromname) { tuple in
            tuple.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout.size(ofValue: tuple.pointee)) { bytes in
                let capacity = MemoryLayout.size(ofValue: tuple.pointee)
                let length = (0..<capacity).first { bytes[$0] == 0 } ?? capacity
                return String(decoding: UnsafeBufferPointer(start: bytes, count: length), as: UTF8.self)
            }
        }
    }

    /// The whole disk and bus protocol behind a mount. Both are nil for a network mount or when
    /// DiskArbitration cannot answer.
    private static func diskIdentity(of path: String, session: inout DASession?) -> (wholeDisk: String?, deviceProtocol: String?) {
        guard let source = mountSource(of: path), source.hasPrefix("/dev/") else { return (nil, nil) }
        if session == nil { session = DASessionCreate(kCFAllocatorDefault) }
        guard let session else { return (nil, nil) }
        let bsdName = String(source.dropFirst("/dev/".count))
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsdName) else { return (nil, nil) }
        var wholeName: String?
        if let whole = DADiskCopyWholeDisk(disk), let cName = DADiskGetBSDName(whole) {
            wholeName = String(cString: cName)
        }
        let description = DADiskCopyDescription(disk) as? [String: Any]
        let deviceProtocol = description?[kDADiskDescriptionDeviceProtocolKey as String] as? String
        return (wholeName, deviceProtocol)
    }
}
