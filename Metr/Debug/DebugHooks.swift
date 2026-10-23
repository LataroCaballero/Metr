import Foundation
import MetrCore
import Synchronization

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

    /// Scheduler diagnostics sink, present only when the log hook is active.
    static var diagnostics: (@Sendable (String) -> Void)? {
        #if DEBUG
        guard let path = ProcessInfo.processInfo.environment["METR_DEBUG_LOG"], !path.isEmpty else { return nil }
        return { line in DebugHooks.log(line) }
        #else
        return nil
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
