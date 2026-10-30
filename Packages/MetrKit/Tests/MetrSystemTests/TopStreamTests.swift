import Darwin
import Foundation
import MetrCore
import Synchronization
import Testing

@testable import MetrSystem

/// Canned `top -l 0 -s 2 -stats pid,cpu,mem` text, in the shape the real tool prints (verified on
/// this Mac, RESEARCH Pattern 3): a `Processes:` header, other header lines, a blank line, the
/// column header and one row per process.
private func canned(total: Int, rows: [String]) -> [Substring] {
    var text = "Processes: \(total) total, 2 running, 1 sleeping, 10 threads \n"
    text += "2026/10/30 11:36:04\n"
    text += "Load Avg: 1.24, 1.47, 1.55 \n"
    text += "CPU usage: 2.61% user, 8.90% sys, 88.48% idle \n"
    text += "PhysMem: 15G used (2545M wired, 2023M compressor), 747M unused.\n"
    text += "\n"
    text += "PID    %CPU MEM  \n"
    for row in rows { text += row + "\n" }
    return Array(text.split(separator: "\n", omittingEmptySubsequences: false).dropLast())
}

private final class Counter: Sendable {
    private let value = Mutex(0)
    func increment() { value.withLock { $0 += 1 } }
    var count: Int { value.withLock { $0 } }
}

/// Polls until the condition holds or the timeout passes.
private func eventually(
    timeout: Duration = .seconds(3), _ condition: @Sendable () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

@Suite struct TopStreamTests {
    // MARK: Task 1: the row grammar

    @Test func parseRowUnitsAndTrend() {
        let full = TopBlockParser.parseRow("670    22.7  21M+")
        #expect(full == TopRow(pid: 670, cpuPercent: 22.7, footprintBytes: 22_020_096))
        let kib = TopBlockParser.parseRow("88 0.0 4016K-")
        #expect(kib?.pid == 88)
        #expect(kib?.footprintBytes == 4_112_384)  // 4016 * 1024
        let mib = TopBlockParser.parseRow("1 3.1 1397M")
        #expect(mib?.footprintBytes == 1_464_860_672)  // 1397 * 1048576
        let gib = TopBlockParser.parseRow("5 0.5 2G")
        #expect(gib?.footprintBytes == 2_147_483_648)
        let plain = TopBlockParser.parseRow("9 1.0 512B")
        #expect(plain?.footprintBytes == 512)
        // The real tool pads rows with trailing spaces.
        let padded = TopBlockParser.parseRow("96470  0.0  39M  ")
        #expect(padded?.footprintBytes == 40_894_464)  // 39 * 1048576
        let comma = TopBlockParser.parseRow("12 22,7 21M")
        #expect(comma == nil)
        let header = TopBlockParser.parseRow("PID %CPU MEM")
        #expect(header == nil)
    }

    @Test func blocksCompleteByCountOrNextHeader() {
        var parser = TopBlockParser(startedAtMicros: 0)
        var blocks: [TopBlock] = []

        // Block 1: three rows for three processes completes on the third row.
        for line in canned(total: 3, rows: ["10 0.0 4M", "11 0.0 5M", "12 0.0 6M"]) {
            if let block = parser.feed(line, atMicros: 100) { blocks.append(block) }
        }
        #expect(blocks.count == 1)
        guard blocks.count == 1 else { return }
        #expect(blocks[0].rows.count == 3)
        #expect(blocks[0].sequence == 1)
        #expect(!blocks[0].cpuValid)

        // Block 2: three expected but only two rows; it completes when the next header arrives.
        for line in canned(total: 3, rows: ["10 1.5 4M", "11 2.5 5M"]) {
            if let block = parser.feed(line, atMicros: 200) { blocks.append(block) }
        }
        #expect(blocks.count == 1, "an incomplete block must wait for the next header")
        if let block = parser.feed("Processes: 3 total, 1 running", atMicros: 300) { blocks.append(block) }
        #expect(blocks.count == 2)
        guard blocks.count == 2 else { return }
        #expect(blocks[1].rows.count == 2)
        #expect(blocks[1].sequence == 2)
        #expect(blocks[1].cpuValid)
        #expect(blocks[1].rows[11]?.cpuPercent == 2.5)
    }

    @Test func blocksCarryTheirSamplingBound() {
        var parser = TopBlockParser(startedAtMicros: 1_000_000)
        var blocks: [TopBlock] = []
        let rows = ["10 0.0 4M", "11 0.0 5M", "12 0.0 6M"]
        for line in canned(total: 3, rows: rows) {
            if let block = parser.feed(line, atMicros: 5_000_000) { blocks.append(block) }
        }
        for line in canned(total: 3, rows: rows) {
            if let block = parser.feed(line, atMicros: 7_000_000) { blocks.append(block) }
        }
        #expect(blocks.count == 2)
        guard blocks.count == 2 else { return }
        #expect(blocks[0].notBeforeMicros == 1_000_000)
        #expect(blocks[1].notBeforeMicros == 5_000_000)
    }

    @Test func fakeLauncherStream() async throws {
        let pipe = Pipe()
        let terminated = Counter()
        let launcher = TopLauncher(launch: {
            TopChild(pid: 4242, output: pipe.fileHandleForReading, terminate: { terminated.increment() })
        })
        let stream = TopStream(launcher: launcher)
        let delivered = Counter()
        stream.setBlockHandler { _ in delivered.increment() }
        stream.start()
        #expect(stream.childPID == 4242)

        let rows = ["10 0.0 4M", "11 0.0 5M", "12 0.0 6M"]
        var text = ""
        for _ in 0..<2 {
            text += canned(total: 3, rows: rows).joined(separator: "\n") + "\n"
        }
        try pipe.fileHandleForWriting.write(contentsOf: Data(text.utf8))
        #expect(await eventually { stream.latest()?.sequence == 2 })
        #expect(stream.latest()?.cpuValid == true)
        #expect(stream.latest()?.rows.count == 3)
        #expect(delivered.count == 2)

        stream.stop()
        #expect(terminated.count == 1)
        #expect(stream.latest() == nil)
        #expect(stream.state == .stopped)
        #expect(stream.childPID == nil)
        stream.stop()
        #expect(terminated.count == 1, "stop() must terminate the child exactly once")
    }

    // MARK: Task 2: hostile or changed output

    @Test func junkAndCommaRowsAreRejected() {
        var parser = TopBlockParser(startedAtMicros: 0)
        var blocks: [TopBlock] = []
        let rows = ["10 1,5 4M", "11 0.0 4M extra", "12 0.0 6M", "13 2.0 7M"]
        for line in canned(total: 4, rows: rows) {
            if let block = parser.feed(line, atMicros: 100) { blocks.append(block) }
        }
        #expect(blocks.count == 1)
        guard blocks.count == 1 else { return }
        #expect(Set(blocks[0].rows.keys) == [12, 13])
        #expect(parser.rejectedRows == 2)
    }

    @Test func overlongLinesAreDropped() {
        var parser = TopBlockParser(startedAtMicros: 0)
        var blocks: [TopBlock] = []
        // A well-formed row padded to 600 bytes: only the length cap can reject it.
        let overlong = "10 0.0 4M" + String(repeating: " ", count: 591)
        #expect(overlong.utf8.count == 600)
        for line in canned(total: 2, rows: [overlong, "11 0.0 5M"]) {
            if let block = parser.feed(line, atMicros: 100) { blocks.append(block) }
        }
        #expect(blocks.count == 1)
        guard blocks.count == 1 else { return }
        #expect(Set(blocks[0].rows.keys) == [11])
        #expect(parser.rejectedRows == 1)
    }

    @Test func eofWithoutStopFails() async throws {
        let pipe = Pipe()
        let launcher = TopLauncher(launch: {
            TopChild(pid: 4243, output: pipe.fileHandleForReading, terminate: {})
        })
        let stream = TopStream(launcher: launcher)
        stream.start()
        try pipe.fileHandleForWriting.write(
            contentsOf: Data((canned(total: 1, rows: ["10 0.0 4M"]).joined(separator: "\n") + "\n").utf8))
        #expect(await eventually { stream.state == .running })
        try pipe.fileHandleForWriting.close()
        #expect(await eventually { stream.state == .failed })
        #expect(stream.latest() == nil, "a dead stream must not keep serving its last block")
        stream.stop()
        #expect(stream.state == .stopped)
    }

    @Test func twoUnderParsedBlocksFail() async throws {
        let pipe = Pipe()
        let terminated = Counter()
        let launcher = TopLauncher(launch: {
            TopChild(pid: 4244, output: pipe.fileHandleForReading, terminate: { terminated.increment() })
        })
        let stream = TopStream(launcher: launcher)
        stream.start()
        // Ten processes announced, two rows parsed, twice: a format change (RESEARCH A2).
        var text = ""
        for _ in 0..<2 {
            text += canned(total: 10, rows: ["10 0.0 4M", "11 0.0 5M"]).joined(separator: "\n") + "\n"
        }
        text += "Processes: 10 total, 1 running\n"  // completes the second block
        try pipe.fileHandleForWriting.write(contentsOf: Data(text.utf8))
        #expect(await eventually { stream.state == .failed })
        #expect(terminated.count == 1)
        #expect(stream.latest() == nil)
        stream.stop()
        #expect(terminated.count == 1, "the child was already ended when the stream failed")
    }

    /// The real tool: a block with the whole process table arrives, and stop() really ends the child.
    @Test func realTopStartsAndStops() async throws {
        let stream = TopStream()
        stream.start()
        #expect(await eventually(timeout: .seconds(5)) { (stream.latest()?.rows.count ?? 0) >= 50 })
        let block = stream.latest()
        #expect(block?.rows[1] != nil, "launchd (pid 1) must be in the block")
        let pid = try #require(stream.childPID)
        stream.stop()
        #expect(stream.state == .stopped)
        #expect(stream.latest() == nil)
        // The specific child is gone (other suites may run their own top: never count all of them).
        // A live setuid-root child answers EPERM; a gone one answers ESRCH.
        #expect(await eventually(timeout: .seconds(1)) { kill(pid, 0) != 0 && errno == ESRCH })
    }
}
