import Foundation
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
