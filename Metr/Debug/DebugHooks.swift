import Foundation
import MetrCore
import Synchronization
#if DEBUG
import ServiceManagement
#endif

/// DEBUG-only log hook. In Release the body is empty and no environment-variable
/// names exist in the binary (T-01-02).
/// Explicitly nonisolated: the app target defaults to MainActor, and the sampler queue calls this.
nonisolated enum DebugHooks {
    #if DEBUG
    private static let sink = Mutex<FileHandle?>(DebugHooks.openSink())

    private static func openSink() -> FileHandle? {
        guard let path = ProcessInfo.processInfo.environment["METR_DEBUG_LOG"], !path.isEmpty else { return nil }
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return nil }
        _ = try? handle.seekToEnd()
        return handle
    }
    #endif

    /// Consumers forced active from launch, so a CLI run can exercise the panel tier without a click.
    static var demandOverride: Set<DemandConsumer> {
        #if DEBUG
        guard let raw = ProcessInfo.processInfo.environment["METR_DEBUG_DEMAND"] else { return [] }
        return Set(raw.split(separator: ",").compactMap { DemandConsumer(rawValue: String($0)) })
        #else
        return []
        #endif
    }

    /// Pids whose memory and CPU are logged on every process batch (`probe pid=...` lines), so
    /// `scripts/verify/procs-vs-top.sh` can compare them with top. A comma list of integers.
    /// Release returns an empty set and holds no environment name.
    static var probePIDs: Set<Int32> {
        #if DEBUG
        guard let raw = ProcessInfo.processInfo.environment["METR_DEBUG_PROBE_PIDS"] else { return [] }
        return Set(raw.split(separator: ",").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) })
        #else
        return []
        #endif
    }

    /// Multiplies every sampling interval so timing tests can run quickly. Clamped to 0.01...10.
    static var cadenceScale: Double {
        #if DEBUG
        guard let raw = ProcessInfo.processInfo.environment["METR_DEBUG_CADENCE_SCALE"],
            let value = Double(raw), value.isFinite
        else { return 1 }
        return min(max(value, 0.01), 10)
        #else
        return 1
        #endif
    }

    /// When set, the app renders the panel fixtures to PNG files in this directory and exits.
    static var renderDirectory: URL? {
        #if DEBUG
        guard let path = ProcessInfo.processInfo.environment["METR_DEBUG_RENDER_DIR"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
        #else
        return nil
        #endif
    }

    /// When true, the panel footer gains a "Bring Window to Front" button (shell spike, ROADMAP
    /// criterion 5). Debug only; Release returns false and holds no environment name.
    static var shellSpikeEnabled: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["METR_DEBUG_SHELL_SPIKE"] == "1"
        #else
        return false
        #endif
    }

    /// Scheduler diagnostics sink, present only when the log hook is active.
    static var diagnostics: (@Sendable (String) -> Void)? {
        #if DEBUG
        guard let path = ProcessInfo.processInfo.environment["METR_DEBUG_LOG"], !path.isEmpty else { return nil }
        return { line in DebugHooks.log(line) }
        #else
        return nil
        #endif
    }

    /// Phase-4 spike (ROADMAP Phase 1 notes): what `SMAppService.mainApp` does for an ad-hoc signed
    /// copy in /Applications. DEBUG only; `scripts/spikes/login-item.sh` drives it and cleans up.
    /// METR_DEBUG_LOGIN_ITEM is `status` (read only), `register` or `unregister`. Logs
    /// "loginitem op=<op> status=<raw> error=<text|none>"; raw status: 0 notRegistered, 1 enabled,
    /// 2 requiresApproval, 3 notFound. Release: empty body, no environment name.
    static func runLoginItemSpikeIfRequested() {
        #if DEBUG
        guard let op = ProcessInfo.processInfo.environment["METR_DEBUG_LOGIN_ITEM"], !op.isEmpty else { return }
        let service = SMAppService.mainApp
        var errorText = "none"
        do {
            switch op {
            case "register": try service.register()
            case "unregister": try service.unregister()
            default: break
            }
        } catch {
            let nsError = error as NSError
            errorText = "\(nsError.domain)#\(nsError.code) \(nsError.localizedDescription)"
                .replacingOccurrences(of: "\n", with: " ")
        }
        log("loginitem op=\(op) status=\(service.status.rawValue) error=\(errorText)")
        #endif
    }

    static func log(_ message: @autoclosure () -> String) {
        #if DEBUG
        sink.withLock { handle in
            guard let handle else { return }
            let uptime = String(format: "%.3f", ProcessInfo.processInfo.systemUptime)
            if let data = "\(uptime) \(message())\n".data(using: .utf8) {
                try? handle.write(contentsOf: data)
            }
        }
        #endif
    }
}
