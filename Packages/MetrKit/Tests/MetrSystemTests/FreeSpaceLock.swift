import Foundation

/// The suites run in parallel, and two tests that allocate a 64 MiB file on the startup volume
/// would see each other's allocation in the free figure they compare. Every such test takes this
/// lock for its whole body, so only one allocates at a time.
enum FreeSpaceLock {
    private static let lock = NSLock()

    static func exclusive<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
