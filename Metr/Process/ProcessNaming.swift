import AppKit
import MetrCore
import UniformTypeIdentifiers

/// Display names and icons of processes, shared by the panel's Top Apps list and the window's
/// process table so the two can never disagree on a name (Phase 2 D-12). Every name from a process
/// goes through `ProcessText.sanitize` here (T-02-11, T-03-20). Moved unchanged out of
/// `TopAppsModel`; the caches are bounded and live as long as their owner (the panel content, or
/// the window session).
@MainActor
final class ProcessNaming {
    /// The panel's bound of the name and icon caches. On overflow they are dropped whole (T-02-12).
    static let cacheLimit = 64

    private let limit: Int
    private var nameCache: [String: String] = [:]
    private var iconCache: [String: NSImage] = [:]

    /// `cacheLimit` is the bound of each cache. The panel lists five apps and keeps the default; the
    /// window's table names every app on the Mac, so it asks for more, still bounded and dropped
    /// with the window session.
    init(cacheLimit: Int = ProcessNaming.cacheLimit) {
        limit = cacheLimit
    }

    /// The bundle paths of the running regular apps. Reads paths only, never icons (RESEARCH Pitfall 11).
    func regularAppBundlePaths() -> Set<String> {
        Set(
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .compactMap { $0.bundleURL?.path })
    }

    /// The Finder name of an app bundle, `.app` stripped, sanitized, cached by path.
    func appDisplayName(atPath path: String) -> String {
        if let cached = nameCache[path] { return cached }
        var name = FileManager.default.displayName(atPath: path)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        var text = ProcessText.sanitize(name)
        if text.isEmpty { text = "—" }
        remember(name: text, forKey: path)
        return text
    }

    /// A standalone process: the executable name, or the kernel name for pid 0 and path-less ones.
    func standaloneName(of group: ProcessGroup) -> String {
        guard let sample = group.main else { return "—" }
        let key = sample.path.map { "exe:" + $0 } ?? "cmd:" + sample.command
        if let cached = nameCache[key] { return cached }
        var text = ProcessText.sanitize(Self.executableName(of: sample))
        if text.isEmpty { text = ProcessText.sanitize(sample.command) }
        if text.isEmpty { text = "—" }
        remember(name: text, forKey: key)
        return text
    }

    /// The executable's last path component, or the kernel short name for pid 0 and path-less
    /// processes. Never the kernel name when a path exists (T-02-11).
    nonisolated static func executableName(of sample: ProcessSample) -> String {
        if sample.identity.pid != 0, let path = sample.path {
            return (path as NSString).lastPathComponent
        }
        return sample.command
    }

    /// The Finder-style name of a helper under its app (`Renderer`, `GPU Process`, `Helper`), cleaned.
    func helperName(of sample: ProcessSample, appName: String) -> String {
        let raw = Self.executableName(of: sample)
        let name = ProcessText.sanitize(ProcessGrouping.helperName(executableName: raw, appName: appName))
        return name.isEmpty ? "—" : name
    }

    /// The row id of a process that is a row of its own: `pid:<pid>:<startMicros>` (the id a standalone
    /// group carries, so a helper keeps its identity across readings and reused pids never collide).
    nonisolated static func helperID(of sample: ProcessSample) -> String {
        "pid:\(sample.identity.pid):\(sample.identity.startMicros)"
    }

    func icon(forAppAt appPath: String?) -> NSImage {
        let key = appPath ?? "unixExecutable"
        if let cached = iconCache[key] { return cached }
        let image =
            appPath.map { NSWorkspace.shared.icon(forFile: $0) }
            ?? NSWorkspace.shared.icon(for: .unixExecutable)
        if iconCache.count >= limit { iconCache.removeAll() }
        iconCache[key] = image
        return image
    }

    private func remember(name: String, forKey key: String) {
        if nameCache.count >= limit { nameCache.removeAll() }
        nameCache[key] = name
    }
}
