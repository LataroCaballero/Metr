import Foundation
import MetrCore
import Synchronization

// Other-uid and root processes come from one streamed `top` child (owner decision Q1,
// RESEARCH Pattern 3): `libproc` cannot read another user's process, and `ps` reports RSS where
// Activity Monitor shows the physical footprint. top's MEM column equals `ri_phys_footprint`.
//
// This file holds the whole pipeline: the strict text grammar (`TopBlockParser`), the child
// process behind a launcher seam (`TopLauncher`, `TopChild`), and the stream that owns the child
// (`TopStream`). `ProcessCollector` reads it through `TopSnapshotSource`.

/// One process row of a top block.
public struct TopRow: Sendable, Equatable {
    public var pid: Int32
    /// Percent of one core over top's sampling interval. Meaningful only in a block with `cpuValid`.
    public var cpuPercent: Double
    /// `MEM` in bytes: the physical footprint, not RSS.
    public var footprintBytes: UInt64

    public init(pid: Int32, cpuPercent: Double, footprintBytes: UInt64) {
        self.pid = pid
        self.cpuPercent = cpuPercent
        self.footprintBytes = footprintBytes
    }
}

/// One complete sample from top.
public struct TopBlock: Sendable, Equatable {
    /// 1 for the first sample of a child, then 2, 3, ... (counted at each `Processes:` header).
    public var sequence: Int
    public var rows: [Int32: TopRow]
    /// Wall-clock microseconds at which this block's sampling window began: the child's launch
    /// time for block 1, the arrival of the previous block's header for later blocks. A row may be
    /// applied only to a process that started earlier, so a reused pid never borrows the numbers
    /// of the process that held it when top sampled (T-02-15).
    public var notBeforeMicros: Int64

    /// The first block has no CPU baseline: every `%CPU` in it is 0.0 (RESEARCH Pitfall 2).
    public var cpuValid: Bool { sequence >= 2 }

    public init(sequence: Int, rows: [Int32: TopRow], notBeforeMicros: Int64) {
        self.sequence = sequence
        self.rows = rows
        self.notBeforeMicros = notBeforeMicros
    }
}

/// Turns top's text, one line at a time, into blocks. A value type driven by the stream under a
/// lock; it never reads a clock itself (the caller passes the arrival time), so it is testable.
public struct TopBlockParser: Sendable {
    /// A longer line is not top output: it is dropped and counted, never parsed (T-02-14).
    public static let maxLineBytes = 512

    /// Lines that did not match the grammar: row lines with a wrong shape, over-long lines and
    /// partial lines dropped when the read buffer overflowed (T-02-14).
    public private(set) var rejectedRows = 0
    /// Consecutive completed blocks with fewer than half their announced rows parsed. Two in a row
    /// mean the output format changed (RESEARCH A2): the stream fails rather than serve a fraction.
    public private(set) var underParsedStreak = 0

    private var startedAtMicros: Int64
    private var lastHeaderMicros: Int64?
    /// Number of `Processes:` headers seen since the last reset.
    private var blockIndex = 0
    private var inBlock = false
    private var inRows = false
    private var expected = Int.max
    private var rowLines = 0
    private var rows: [Int32: TopRow] = [:]
    private var notBefore: Int64 = 0

    public init(startedAtMicros: Int64) {
        self.startedAtMicros = startedAtMicros
    }

    public mutating func reset(startedAtMicros: Int64) {
        self = TopBlockParser(startedAtMicros: startedAtMicros)
    }

    /// Counts a line the caller had to drop before it reached `feed`.
    public mutating func noteRejected() {
        rejectedRows += 1
    }

    /// Feeds one line (without its newline). Returns a block when this line completed one.
    public mutating func feed(_ line: Substring, atMicros: Int64) -> TopBlock? {
        if line.utf8.count > Self.maxLineBytes {
            rejectedRows += 1
            // An over-long line in the row section still occupies a row position.
            guard inRows else { return nil }
            rowLines += 1
            return rowLines >= expected ? finishBlock() : nil
        }
        if line.hasPrefix("Processes:") {
            let finished = finishBlock()
            beginBlock(header: line, atMicros: atMicros)
            return finished
        }
        guard inBlock else { return nil }
        if !inRows {
            // Rows start after the column header line.
            if line.contains("PID"), line.contains("%CPU"), line.contains("MEM") { inRows = true }
            return nil
        }
        if line.allSatisfy(\.isWhitespace) { return nil }
        rowLines += 1
        if let row = Self.parseRow(line) {
            rows[row.pid] = row
        } else {
            rejectedRows += 1
        }
        return rowLines >= expected ? finishBlock() : nil
    }

    private mutating func beginBlock(header: Substring, atMicros: Int64) {
        blockIndex += 1
        notBefore = lastHeaderMicros ?? startedAtMicros
        lastHeaderMicros = atMicros
        expected = Self.expectedCount(header) ?? Int.max
        inBlock = true
        inRows = false
        rowLines = 0
        rows.removeAll(keepingCapacity: true)
    }

    private mutating func finishBlock() -> TopBlock? {
        guard inBlock else { return nil }
        inBlock = false
        inRows = false
        if expected != Int.max, expected > 0, rows.count * 2 < expected {
            underParsedStreak += 1
        } else {
            underParsedStreak = 0
        }
        guard !rows.isEmpty else { return nil }
        let block = TopBlock(sequence: blockIndex, rows: rows, notBeforeMicros: notBefore)
        rows.removeAll(keepingCapacity: true)
        return block
    }

    /// The integer in "Processes: 720 total, ...".
    private static func expectedCount(_ header: Substring) -> Int? {
        let tail = header.dropFirst("Processes:".count)
        guard let end = tail.range(of: " total") else { return nil }
        return Int(tail[..<end.lowerBound].trimmingCharacters(in: .whitespaces))
    }

    /// `PID %CPU MEM` for one process: exactly three space-separated fields, an integer pid, a
    /// '.'-decimal percentage (the child runs with LC_ALL=C) and a memory figure with an optional
    /// trailing '+' or '-' trend mark and a unit K, M, G or B in powers of 1024. Anything else is nil.
    public static func parseRow(_ line: Substring) -> TopRow? {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count == 3 else { return nil }
        guard isDigits(fields[0]), let pid = Int32(fields[0]) else { return nil }
        guard let cpu = decimal(fields[1]) else { return nil }
        guard let bytes = memory(fields[2]) else { return nil }
        return TopRow(pid: pid, cpuPercent: cpu, footprintBytes: bytes)
    }

    private static func isDigits(_ text: Substring) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
    }

    /// Digits with at most one '.', so "nan", "inf", exponents and comma decimals are rejected.
    private static func decimal(_ text: Substring) -> Double? {
        var dots = 0
        var digits = 0
        for byte in text.utf8 {
            if byte == 0x2E {
                dots += 1
            } else if byte >= 0x30 && byte <= 0x39 {
                digits += 1
            } else {
                return nil
            }
        }
        guard dots <= 1, digits > 0 else { return nil }
        return Double(text)
    }

    private static func memory(_ field: Substring) -> UInt64? {
        var text = field
        if let last = text.last, last == "+" || last == "-" { text = text.dropLast() }
        guard let unit = text.last else { return nil }
        let scale: UInt64
        switch unit {
        case "B": scale = 1
        case "K": scale = 1 << 10
        case "M": scale = 1 << 20
        case "G": scale = 1 << 30
        default: return nil
        }
        let number = text.dropLast()
        guard isDigits(number), let value = UInt64(number) else { return nil }
        let (bytes, overflow) = value.multipliedReportingOverflow(by: scale)
        return overflow ? nil : bytes
    }
}

public enum TopStreamState: Sendable, Equatable {
    /// No child. The collector starts it on the next sample.
    case stopped
    /// A child was launched and has not completed a block yet.
    case starting
    /// At least one block has arrived.
    case running
    /// The child could not be launched, ended on its own, or printed output that stopped parsing.
    /// The stream keeps no block in this state; `start()` relaunches it.
    case failed
}

/// What `ProcessCollector` needs from the other-uid source.
public protocol TopSnapshotSource: AnyObject, Sendable {
    func start()
    func stop()
    /// The most recent complete block, nil when none has arrived since the last start.
    func latest() -> TopBlock?
    var state: TopStreamState { get }
}

/// A launched top: its pid, the read end of its stdout and a way to end it.
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

/// How a child is started. Tests inject a pipe-backed fake; the app uses `.system`.
public struct TopLauncher: Sendable {
    public var launch: @Sendable () throws -> TopChild

    public init(launch: @escaping @Sendable () throws -> TopChild) {
        self.launch = launch
    }

    /// `/usr/bin/top -l 0 -s 2 -stats pid,cpu,mem`: an absolute path, a fixed argument array, an
    /// environment of exactly LC_ALL=C (no inherited PATH or DYLD variables), stdin and stderr to
    /// /dev/null and no shell (T-02-13).
    public static let system = TopLauncher(launch: {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        process.arguments = ["-l", "0", "-s", "2", "-stats", "pid,cpu,mem"]
        process.environment = ["LC_ALL": "C"]
        let pipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardOutput = pipe
        try process.run()
        let handle = ProcessHandle(process)
        return TopChild(
            pid: process.processIdentifier, output: pipe.fileHandleForReading,
            terminate: { handle.terminate() })
    })
}

/// `Process` is not Sendable. `terminate()` is the only call made through this box, and
/// Foundation documents it as safe to call from any thread.
private final class ProcessHandle: @unchecked Sendable {
    private let process: Process
    init(_ process: Process) { self.process = process }
    func terminate() {
        if process.isRunning { process.terminate() }
    }
}

/// Owns at most one top child, reads its output off the main thread and keeps the latest block.
///
/// `@unchecked Sendable`: every mutable field lives in one `Mutex`; the readability handler and
/// the callers of `start()`, `stop()` and `latest()` all go through it. The block handler runs
/// outside the lock.
public final class TopStream: TopSnapshotSource, @unchecked Sendable {
    private struct Inner {
        var state: TopStreamState = .stopped
        var parser = TopBlockParser(startedAtMicros: 0)
        var latest: TopBlock?
        var child: TopChild?
        var buffer = Data()
        var handler: (@Sendable (TopBlock) -> Void)?
        /// Bumped by every start and stop, so a late callback from an older child is ignored.
        var generation = 0
    }

    /// The read buffer holds at most one partial line between reads; beyond this it is dropped.
    static let maxBufferBytes = 1 << 20

    private let inner = Mutex(Inner())
    private let launcher: TopLauncher
    private let wallMicros: @Sendable () -> Int64

    public init(
        launcher: TopLauncher = .system,
        wallMicros: @escaping @Sendable () -> Int64 = TopStream.currentWallMicros
    ) {
        self.launcher = launcher
        self.wallMicros = wallMicros
    }

    /// Wall-clock microseconds since the epoch, the same clock as the kernel's `p_starttime`.
    public static let currentWallMicros: @Sendable () -> Int64 = {
        var tv = timeval()
        gettimeofday(&tv, nil)
        return Int64(tv.tv_sec) * 1_000_000 + Int64(tv.tv_usec)
    }

    /// Called on the stream's reader queue for every complete block.
    public func setBlockHandler(_ handler: (@Sendable (TopBlock) -> Void)?) {
        inner.withLock { $0.handler = handler }
    }

    public var childPID: Int32? { inner.withLock { $0.child?.pid } }
    public var state: TopStreamState { inner.withLock { $0.state } }
    public func latest() -> TopBlock? { inner.withLock { $0.latest } }

    public func start() {
        let startedAt = wallMicros()
        let generation: Int? = inner.withLock { s in
            guard s.state == .stopped || s.state == .failed else { return nil }
            s.state = .starting
            s.generation += 1
            s.parser.reset(startedAtMicros: startedAt)
            s.buffer.removeAll()
            s.latest = nil
            return s.generation
        }
        guard let generation else { return }
        let child: TopChild
        do {
            child = try launcher.launch()
        } catch {
            inner.withLock { s in
                if s.generation == generation { s.state = .failed }
            }
            return
        }
        let adopted = inner.withLock { s -> Bool in
            guard s.generation == generation, s.state == .starting else { return false }
            s.child = child
            return true
        }
        guard adopted else {
            // stop() ran while the child was launching: it never saw this child, so end it here.
            child.terminate()
            return
        }
        child.output.readabilityHandler = { [weak self] handle in
            // `availableData` returns what is there now (`read(upToCount:)` would wait for the
            // full count on a pipe). The handle is never closed explicitly: stop() clears this
            // handler and drops the child, so the descriptor closes when the last reference goes,
            // and an in-flight callback can never read a recycled descriptor.
            self?.ingest(handle.availableData, generation: generation, handle: handle)
        }
    }

    public func stop() {
        let child: TopChild? = inner.withLock { s in
            let child = s.child
            s.child = nil
            s.generation += 1
            s.state = .stopped
            s.latest = nil
            s.buffer.removeAll()
            s.parser.reset(startedAtMicros: 0)
            return child
        }
        guard let child else { return }
        child.output.readabilityHandler = nil
        child.terminate()
    }

    private func ingest(_ data: Data, generation: Int, handle: FileHandle) {
        if data.isEmpty {
            // End of file: nothing more will arrive on this handle. Unless stop() got here first,
            // the child ended on its own.
            handle.readabilityHandler = nil
            endCurrentChild(generation: generation)
            return
        }
        let now = wallMicros()
        var completed: [TopBlock] = []
        var underParsed = false
        let handler: (@Sendable (TopBlock) -> Void)? = inner.withLock { s in
            guard s.generation == generation, s.child != nil else { return nil }
            s.buffer.append(data)
            while let newline = s.buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: s.buffer[s.buffer.startIndex..<newline], as: UTF8.self)
                s.buffer.removeSubrange(s.buffer.startIndex...newline)
                if let block = s.parser.feed(Substring(line), atMicros: now) {
                    if s.parser.underParsedStreak >= 2 {
                        underParsed = true
                        break
                    }
                    s.latest = block
                    s.state = .running
                    completed.append(block)
                } else if s.parser.underParsedStreak >= 2 {
                    underParsed = true
                    break
                }
            }
            if s.buffer.count > Self.maxBufferBytes {
                s.buffer.removeAll()
                s.parser.noteRejected()
            }
            return s.handler
        }
        if let handler {
            for block in completed { handler(block) }
        }
        if underParsed {
            handle.readabilityHandler = nil
            endCurrentChild(generation: generation)
        }
    }

    /// Fails the stream and ends its child, unless stop() or a newer start() already replaced it.
    private func endCurrentChild(generation: Int) {
        let child: TopChild? = inner.withLock { s in
            guard s.generation == generation, let child = s.child else { return nil }
            s.child = nil
            s.generation += 1
            s.state = .failed
            s.latest = nil
            s.buffer.removeAll()
            return child
        }
        guard let child else { return }
        child.output.readabilityHandler = nil
        child.terminate()
    }
}
