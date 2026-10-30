import Foundation
import MetrCore
import Synchronization

// RED skeleton: the API compiles, nothing behaves yet.

public struct TopRow: Sendable, Equatable {
    public var pid: Int32
    public var cpuPercent: Double
    public var footprintBytes: UInt64

    public init(pid: Int32, cpuPercent: Double, footprintBytes: UInt64) {
        self.pid = pid
        self.cpuPercent = cpuPercent
        self.footprintBytes = footprintBytes
    }
}

public struct TopBlock: Sendable, Equatable {
    public var sequence: Int
    public var rows: [Int32: TopRow]
    public var notBeforeMicros: Int64
    public var cpuValid: Bool { false }

    public init(sequence: Int, rows: [Int32: TopRow], notBeforeMicros: Int64) {
        self.sequence = sequence
        self.rows = rows
        self.notBeforeMicros = notBeforeMicros
    }
}

public struct TopBlockParser: Sendable {
    public private(set) var rejectedRows = 0

    public init(startedAtMicros: Int64) {}
    public mutating func feed(_ line: Substring, atMicros: Int64) -> TopBlock? { nil }
    public mutating func reset(startedAtMicros: Int64) {}
    public static func parseRow(_ line: Substring) -> TopRow? { nil }
}

public enum TopStreamState: Sendable, Equatable {
    case stopped, starting, running, failed
}

public protocol TopSnapshotSource: AnyObject, Sendable {
    func start()
    func stop()
    func latest() -> TopBlock?
    var state: TopStreamState { get }
}

public struct TopChild: Sendable {
    public var pid: Int32
    public var output: FileHandle
    public var terminate: @Sendable () -> Void

    public init(pid: Int32, output: FileHandle, terminate: @escaping @Sendable () -> Void) {
        self.pid = pid
        self.output = output
        self.terminate = terminate
    }
}

public struct TopLauncher: Sendable {
    public var launch: @Sendable () throws -> TopChild

    public init(launch: @escaping @Sendable () throws -> TopChild) {
        self.launch = launch
    }
}

public final class TopStream: TopSnapshotSource, @unchecked Sendable {
    public init(launcher: TopLauncher? = nil) {}
    public func setBlockHandler(_ handler: (@Sendable (TopBlock) -> Void)?) {}
    public var childPID: Int32? { nil }
    public func start() {}
    public func stop() {}
    public func latest() -> TopBlock? { nil }
    public var state: TopStreamState { .stopped }
}
