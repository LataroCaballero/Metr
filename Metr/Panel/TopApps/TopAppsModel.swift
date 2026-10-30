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
        /// The process list could not be read at all (E5 error).
        case unavailable
    }

    var content: Content
    /// The column the list is actually ranked by: memory until CPU is known, then the selection (D-20).
    var effectiveSort: SortColumn
}

/// One visible row. Identifiable by a stable key so a row keeps its identity across readings.
struct TopAppRowData: Identifiable, Equatable {
    let id: String
    let name: String
    let icon: NSImage
    let cpuPercent: Double?
    let footprintBytes: UInt64?
}

/// The display model behind the Top Apps list (PANEL-04, PROC-03, D-06, D-07, D-20).
///
/// It lives in `@State` inside the panel content, so it is created when the popover opens and
/// destroyed when it closes; the name and icon caches go with it (RESEARCH Pitfall 11, T-02-12).
/// The init does nothing, because `@State` may evaluate it more than once.
@MainActor
@Observable
final class TopAppsModel {
    /// Rows shown in the list (D-07).
    static let rowLimit = 5
    /// Bound of the name and icon caches. On overflow they are dropped whole (T-02-12).
    static let cacheLimit = 64

    @ObservationIgnored private var memo: (sequence: UInt64, sort: SortColumn, display: TopAppsDisplay)?
    @ObservationIgnored private var nameCache: [String: String] = [:]
    @ObservationIgnored private var iconCache: [String: NSImage] = [:]

    init() {}

    /// The rows for one reading. Memoized by (sequence, sort), so a re-render of the same reading
    /// costs nothing; every process is ranked once per new reading.
    func display(for reading: Reading<ProcessSnapshot>, sort: SortColumn) -> TopAppsDisplay {
        switch reading {
        case .pending:
            return TopAppsDisplay(content: .waiting, effectiveSort: .memory)
        case .unavailable:
            return TopAppsDisplay(content: .unavailable, effectiveSort: sort)
        case .value(let snapshot):
            if let memo, memo.sequence == snapshot.sequence, memo.sort == sort { return memo.display }
            let display = build(snapshot, sort: sort)
            memo = (snapshot.sequence, sort, display)
            return display
        }
    }

    private func build(_ snapshot: ProcessSnapshot, sort: SortColumn) -> TopAppsDisplay {
        guard !snapshot.processes.isEmpty else {
            return TopAppsDisplay(content: .unavailable, effectiveSort: sort)
        }
        let effective: SortColumn = snapshot.cpuReady ? sort : .memory
        let ranked = snapshot.processes.sorted { Self.precedes($0, $1, by: effective) }
        let rows = ranked.prefix(Self.rowLimit).map { sample in
            TopAppRowData(
                id: "pid:\(sample.identity.pid):\(sample.identity.startMicros)",
                name: name(of: sample),
                icon: icon(of: sample),
                cpuPercent: sample.cpuPercent,
                footprintBytes: sample.footprintBytes)
        }
        return TopAppsDisplay(content: .rows(Array(rows)), effectiveSort: effective)
    }

    /// The active value descending (nil last), then footprint descending, then name (D-07).
    private static func precedes(_ a: ProcessSample, _ b: ProcessSample, by sort: SortColumn) -> Bool {
        let (x, y): (Double?, Double?) =
            switch sort {
            case .cpu: (a.cpuPercent, b.cpuPercent)
            case .memory: (a.footprintBytes.map(Double.init), b.footprintBytes.map(Double.init))
            }
        if x != y {
            guard let x else { return false }
            guard let y else { return true }
            return x > y
        }
        let fa = a.footprintBytes ?? 0
        let fb = b.footprintBytes ?? 0
        if fa != fb { return fa > fb }
        return rawName(of: a).localizedStandardCompare(rawName(of: b)) == .orderedAscending
    }

    /// The executable's last path component, or the kernel short name for pid 0 and path-less
    /// processes. Never the kernel name when a path exists (T-02-11).
    private static func rawName(of sample: ProcessSample) -> String {
        if sample.identity.pid != 0, let path = sample.path {
            return (path as NSString).lastPathComponent
        }
        return sample.command
    }

    private func name(of sample: ProcessSample) -> String {
        let key = sample.identity.pid == 0 ? "cmd:" + sample.command : sample.path ?? "cmd:" + sample.command
        if let cached = nameCache[key] { return cached }
        var text = ProcessText.sanitize(Self.rawName(of: sample))
        if text.isEmpty { text = ProcessText.sanitize(sample.command) }
        if text.isEmpty { text = "—" }
        if nameCache.count >= Self.cacheLimit { nameCache.removeAll() }
        nameCache[key] = text
        return text
    }

    private func icon(of sample: ProcessSample) -> NSImage {
        let appPath = sample.path.flatMap(ProcessPaths.outermostAppBundle(of:))
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
