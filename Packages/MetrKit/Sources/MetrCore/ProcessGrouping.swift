import Foundation

/// Display-safe text from untrusted sources (D-12, T-02-11). A process name, executable path or
/// bundle name belongs to an arbitrary local program, so every string that reaches a row, a
/// tooltip or a VoiceOver label goes through here first.
public enum ProcessText {
    /// Removes control characters (C0 and C1) and the bidirectional controls U+202A to U+202E and
    /// U+2066 to U+2069 (so a name cannot reorder the text around it), trims surrounding
    /// whitespace and caps the result at `limit` characters.
    public static func sanitize(_ text: String, limit: Int = 128) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where !isStripped(scalar) {
            scalars.append(scalar)
        }
        let trimmed = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isStripped(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.generalCategory == .control { return true }
        switch scalar.value {
        case 0x202A...0x202E, 0x2066...0x2069: return true
        default: return false
        }
    }
}

/// Path rules for grouping processes under their app (D-12, RESEARCH Pattern 4).
public enum ProcessPaths {
    /// The path up to and including the first component that ends in ".app" and has at least one
    /// component after it, or nil. "/Applications/Foo.app" alone is a bundle, not an executable
    /// inside one, so it gives nil; so does a directory such as "my.application".
    public static func outermostAppBundle(of path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        for (index, component) in components.enumerated() {
            guard component.count > 4, component.hasSuffix(".app") else { continue }
            guard index + 1 < components.count else { return nil }
            return "/" + components[0...index].joined(separator: "/")
        }
        return nil
    }
}

/// One row's worth of processes: an app with its helpers, or a single standalone process.
public struct ProcessGroup: Sendable, Equatable {
    /// The app bundle path, or `pid:<pid>:<startMicros>` for a standalone process. Stable across
    /// readings, so a row keeps its identity while the numbers change.
    public var id: String
    /// The app bundle this group is named after, nil for a standalone process.
    public var appPath: String?
    /// The process that is the app itself (`<app>/Contents/MacOS/*`), nil when only helpers run.
    public var main: ProcessSample?
    public var helpers: [ProcessSample]
    /// The sum of the members' known CPU values, nil only when no member has one (D-20).
    public var cpuPercent: Double?
    /// The sum of the members' known footprints, nil only when no member has one.
    public var footprintBytes: UInt64?

    public init(
        id: String, appPath: String?, main: ProcessSample?, helpers: [ProcessSample],
        cpuPercent: Double?, footprintBytes: UInt64?
    ) {
        self.id = id
        self.appPath = appPath
        self.main = main
        self.helpers = helpers
        self.cpuPercent = cpuPercent
        self.footprintBytes = footprintBytes
    }
}

/// Rolls helper processes into their app (PROC-02, D-08, D-12; RESEARCH Pattern 4).
///
/// Grouping uses the public executable path only. It never uses the private responsible-PID
/// relation, which would file every `node` and `zsh` under the terminal that launched it
/// (RESEARCH Pitfall 6). It ignores the owner: a root-owned bundle groups like a user app
/// (owner decision Q5, 2026-10-30).
public enum ProcessGrouping {
    /// Groups `samples` in first-seen order.
    ///
    /// The key is the outermost `.app` in the executable path. An inner `.app` that is itself a
    /// running regular app (`regularAppBundlePaths`, from NSWorkspace) takes its own group instead,
    /// so Simulator does not roll into Xcode (assumption A5). A process with no `.app` ancestor, or
    /// no path at all (pid 0), is a standalone group.
    public static func groups(
        from samples: [ProcessSample], regularAppBundlePaths: Set<String>
    ) -> [ProcessGroup] {
        var order: [String] = []
        var members: [String: [ProcessSample]] = [:]
        var appPaths: [String: String] = [:]

        for sample in samples {
            let key: String
            if let path = sample.path, let outer = ProcessPaths.outermostAppBundle(of: path) {
                let app = innermostRegularApp(containing: path, within: outer, in: regularAppBundlePaths) ?? outer
                key = app
                appPaths[key] = app
            } else {
                key = standaloneID(sample.identity)
            }
            if members[key] == nil { order.append(key) }
            members[key, default: []].append(sample)
        }

        return order.map { key in
            let group = members[key] ?? []
            guard let appPath = appPaths[key] else {
                return make(id: key, appPath: nil, main: group.first, helpers: [])
            }
            let mainPrefix = appPath + "/Contents/MacOS/"
            let main = group.filter { $0.path?.hasPrefix(mainPrefix) == true }
                .min { $0.identity.pid < $1.identity.pid }
            let helpers = group.filter { $0.identity != main?.identity }
            return make(id: key, appPath: appPath, main: main, helpers: helpers)
        }
    }

    /// The Finder-style name of a helper: the app prefix stripped, `Helper (X)` reading `X`,
    /// `Helper (GPU)` reading `GPU Process`, a bare `Helper` staying `Helper`. A name that does
    /// not start with the app name is kept unchanged (D-12).
    public static func helperName(executableName: String, appName: String) -> String {
        let prefix = appName + " "
        guard !appName.isEmpty, executableName.hasPrefix(prefix) else { return executableName }
        let rest = String(executableName.dropFirst(prefix.count))
        if rest.hasPrefix("Helper ("), rest.hasSuffix(")") {
            let inner = String(rest.dropFirst("Helper (".count).dropLast())
            if inner == "GPU" { return "GPU Process" }
            if !inner.isEmpty { return inner }
        }
        return rest.isEmpty ? executableName : rest
    }

    private static func standaloneID(_ identity: ProcessIdentity) -> String {
        "pid:\(identity.pid):\(identity.startMicros)"
    }

    /// The longest regular-app bundle that contains `path` and sits inside `outer`, if any.
    private static func innermostRegularApp(
        containing path: String, within outer: String, in regular: Set<String>
    ) -> String? {
        var best: String?
        for candidate in regular
        where candidate.count > outer.count && candidate.hasPrefix(outer + "/") && path.hasPrefix(candidate + "/") {
            if best == nil || candidate.count > best!.count { best = candidate }
        }
        return best
    }

    private static func make(
        id: String, appPath: String?, main: ProcessSample?, helpers: [ProcessSample]
    ) -> ProcessGroup {
        let all = (main.map { [$0] } ?? []) + helpers
        let cpu = all.compactMap(\.cpuPercent)
        let footprint = all.compactMap(\.footprintBytes)
        return ProcessGroup(
            id: id, appPath: appPath, main: main, helpers: helpers,
            cpuPercent: cpu.isEmpty ? nil : cpu.reduce(0, +),
            footprintBytes: footprint.isEmpty ? nil : footprint.reduce(0, +))
    }
}
