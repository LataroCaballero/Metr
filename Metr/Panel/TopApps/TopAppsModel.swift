import AppKit
import MetrCore
import Observation
import UniformTypeIdentifiers

/// What the Top Apps area shows (D-20, E5).
struct TopAppsDisplay: Equatable {
    enum Content: Equatable {
        /// Up to five rows, in display order.
        case rows([TopAppRowData])
        /// No reading yet: the reserved area stays empty (no spinner, no skeleton).
        case waiting
        /// The process list cannot be read at all (E5 error).
        case unavailable
    }

    var content: Content
    /// The column the list is actually ranked by: memory until CPU is known, then the selection (D-20).
    var effectiveSort: SortColumn

    /// The ids of the rows on screen, in order.
    var rowIDs: [String] {
        if case .rows(let rows) = content { return rows.map(\.id) }
        return []
    }
}

/// One visible app or standalone-process row. Identifiable by the app path or the process key,
/// so a row keeps its identity across readings.
struct TopAppRowData: Identifiable, Equatable {
    let id: String
    let name: String
    let icon: NSImage
    let cpuPercent: Double?
    let footprintBytes: UInt64?
    /// Who owns the row, from pid, uid and canonical path only (D-09). `.system` rows show a lock.
    let kind: ProcessKind
    /// How many helpers the group has. Above zero the row has a disclosure chevron.
    let helperCount: Int
    /// Present only while this group is the open one: its three heaviest helpers (D-08).
    let helpers: [HelperRowData]
    /// Helpers beyond the three shown; above zero draws the "and N more…" line.
    let moreCount: Int

    var isExpanded: Bool { helperCount > 0 && !helpers.isEmpty }
}

/// One helper under an open group.
struct HelperRowData: Identifiable, Equatable {
    let id: String
    /// The cleaned name (D-12).
    let name: String
    /// The name and PID, for the tooltip (D-12).
    let help: String
    let cpuPercent: Double?
    let footprintBytes: UInt64?
}

/// The display model behind the Top Apps list (PANEL-04, PROC-02, PROC-03; D-06, D-07, D-08, D-12, D-20).
///
/// It lives in `@State` inside the panel content, so it is created when the popover opens and
/// destroyed when it closes; the name and icon caches go with it (RESEARCH Pitfall 11, T-02-12).
/// The init does nothing, because `@State` may evaluate it more than once.
@MainActor
@Observable
final class TopAppsModel {
    /// Rows shown in the list (D-07).
    static let rowLimit = 5
    /// Helpers listed under an open group (D-08).
    static let helperLimit = 3
    /// Bound of the name and icon caches. On overflow they are dropped whole (T-02-12).
    static let cacheLimit = 64

    /// The group that is open, if any. Opening one closes the other (D-08).
    private(set) var expandedGroupID: String?

    /// Groups of the newest reading, computed once per snapshot sequence on the MainActor
    /// (about 600 paths, a few ms every 2 s, only while the panel is open).
    @ObservationIgnored private var grouped: (sequence: UInt64, groups: [ProcessGroup])?
    @ObservationIgnored private var nameCache: [String: String] = [:]
    @ObservationIgnored private var iconCache: [String: NSImage] = [:]

    init() {}

    /// Opens a group, or closes it when it is already open.
    func toggle(_ id: String) {
        expandedGroupID = expandedGroupID == id ? nil : id
    }

    /// Closes the open group once it is no longer on screen (it exited, or ranks out of the list).
    func collapse(unlessVisible visible: [String]) {
        if let id = expandedGroupID, !visible.contains(id) { expandedGroupID = nil }
    }

    /// The rows for one reading. Grouping runs once per sequence; ranking and row building only
    /// touch the groups, so a re-render costs five rows of work.
    func display(for reading: Reading<ProcessSnapshot>, sort: SortColumn) -> TopAppsDisplay {
        switch reading {
        case .pending:
            return TopAppsDisplay(content: .waiting, effectiveSort: .memory)
        case .unavailable:
            return TopAppsDisplay(content: .unavailable, effectiveSort: sort)
        case .value(let snapshot):
            guard !snapshot.processes.isEmpty else {
                return TopAppsDisplay(content: .unavailable, effectiveSort: sort)
            }
            let effective: SortColumn = snapshot.cpuReady ? sort : .memory
            let ranked = groups(for: snapshot).sorted { Self.precedes($0, $1, by: effective) }
            let rows = ranked.prefix(Self.rowLimit).map { row(for: $0, sort: effective) }
            return TopAppsDisplay(content: .rows(Array(rows)), effectiveSort: effective)
        }
    }

    private func groups(for snapshot: ProcessSnapshot) -> [ProcessGroup] {
        if let grouped, grouped.sequence == snapshot.sequence { return grouped.groups }
        // Reads the running apps' bundle paths only, never their icons (RESEARCH Pitfall 11).
        let regular = Set(
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap { $0.bundleURL?.path })
        let groups = ProcessGrouping.groups(from: snapshot.processes, regularAppBundlePaths: regular)
        grouped = (snapshot.sequence, groups)
        return groups
    }

    // MARK: Ranking

    private static func precedes(_ a: ProcessGroup, _ b: ProcessGroup, by sort: SortColumn) -> Bool {
        precedes(
            (a.cpuPercent, a.footprintBytes, sortName(of: a)), (b.cpuPercent, b.footprintBytes, sortName(of: b)),
            by: sort)
    }

    private static func precedes(_ a: ProcessSample, _ b: ProcessSample, by sort: SortColumn) -> Bool {
        precedes(
            (a.cpuPercent, a.footprintBytes, executableName(of: a)),
            (b.cpuPercent, b.footprintBytes, executableName(of: b)), by: sort)
    }

    /// The active value descending (nil last), then footprint descending, then name (D-07).
    private static func precedes(
        _ a: (cpu: Double?, footprint: UInt64?, name: String),
        _ b: (cpu: Double?, footprint: UInt64?, name: String), by sort: SortColumn
    ) -> Bool {
        let (x, y): (Double?, Double?) =
            switch sort {
            case .cpu: (a.cpu, b.cpu)
            case .memory: (a.footprint.map(Double.init), b.footprint.map(Double.init))
            }
        if x != y {
            guard let x else { return false }
            guard let y else { return true }
            return x > y
        }
        let fa = a.footprint ?? 0
        let fb = b.footprint ?? 0
        if fa != fb { return fa > fb }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    /// A cheap, unsanitized name used only to break ties.
    private static func sortName(of group: ProcessGroup) -> String {
        if let appPath = group.appPath { return (appPath as NSString).lastPathComponent }
        return group.main.map(executableName(of:)) ?? group.id
    }

    /// The executable's last path component, or the kernel short name for pid 0 and path-less
    /// processes. Never the kernel name when a path exists (T-02-11).
    private static func executableName(of sample: ProcessSample) -> String {
        if sample.identity.pid != 0, let path = sample.path {
            return (path as NSString).lastPathComponent
        }
        return sample.command
    }

    // MARK: Rows

    private func row(for group: ProcessGroup, sort: SortColumn) -> TopAppRowData {
        let appName = group.appPath.map(appDisplayName(atPath:))
        let open = expandedGroupID == group.id && !group.helpers.isEmpty
        var helpers: [HelperRowData] = []
        var more = 0
        if open {
            let heaviest = group.helpers.sorted { Self.precedes($0, $1, by: sort) }
            helpers = heaviest.prefix(Self.helperLimit).map { helperRow(for: $0, appName: appName ?? "") }
            more = max(0, group.helpers.count - Self.helperLimit)
        }
        return TopAppRowData(
            id: group.id,
            name: appName ?? standaloneName(of: group),
            icon: icon(forAppAt: group.appPath),
            cpuPercent: group.cpuPercent,
            footprintBytes: group.footprintBytes,
            kind: ProcessClassifier.kind(of: group, selfPID: getpid(), selfUID: getuid()),
            helperCount: group.helpers.count,
            helpers: helpers,
            moreCount: more)
    }

    private func helperRow(for sample: ProcessSample, appName: String) -> HelperRowData {
        let raw = Self.executableName(of: sample)
        var name = ProcessText.sanitize(ProcessGrouping.helperName(executableName: raw, appName: appName))
        if name.isEmpty { name = "—" }
        let pid = Int(sample.identity.pid)
        return HelperRowData(
            id: "pid:\(sample.identity.pid):\(sample.identity.startMicros)",
            name: name,
            help: String(localized: "\(name) · PID \(pid)"),
            cpuPercent: sample.cpuPercent,
            footprintBytes: sample.footprintBytes)
    }

    /// The Finder name of an app bundle, `.app` stripped, sanitized, cached by path.
    private func appDisplayName(atPath path: String) -> String {
        if let cached = nameCache[path] { return cached }
        var name = FileManager.default.displayName(atPath: path)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        var text = ProcessText.sanitize(name)
        if text.isEmpty { text = "—" }
        remember(name: text, forKey: path)
        return text
    }

    /// A standalone process: the executable name, or the kernel name for pid 0 and path-less ones.
    private func standaloneName(of group: ProcessGroup) -> String {
        guard let sample = group.main else { return "—" }
        let key = sample.path.map { "exe:" + $0 } ?? "cmd:" + sample.command
        if let cached = nameCache[key] { return cached }
        var text = ProcessText.sanitize(Self.executableName(of: sample))
        if text.isEmpty { text = ProcessText.sanitize(sample.command) }
        if text.isEmpty { text = "—" }
        remember(name: text, forKey: key)
        return text
    }

    private func remember(name: String, forKey key: String) {
        if nameCache.count >= Self.cacheLimit { nameCache.removeAll() }
        nameCache[key] = name
    }

    private func icon(forAppAt appPath: String?) -> NSImage {
        let key = appPath ?? "unixExecutable"
        if let cached = iconCache[key] { return cached }
        let image =
            appPath.map { NSWorkspace.shared.icon(forFile: $0) }
            ?? NSWorkspace.shared.icon(for: .unixExecutable)
        if iconCache.count >= Self.cacheLimit { iconCache.removeAll() }
        iconCache[key] = image
        return image
    }
}
