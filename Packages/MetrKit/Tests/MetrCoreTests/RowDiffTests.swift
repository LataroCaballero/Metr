import Testing

@testable import MetrCore

@Suite struct RowDiffTests {
    private func check(_ old: [String], _ new: [String], sourceLocation: SourceLocation = #_sourceLocation) {
        let diff = RowDiff.between(old: old, new: new)
        #expect(diff.applied(to: old, inserting: new) == new, sourceLocation: sourceLocation)
    }

    @Test func sameListNeedsNothing() {
        #expect(RowDiff.between(old: ["a", "b", "c"], new: ["a", "b", "c"]).isEmpty)
    }

    @Test func oneRowJumpingFarIsOneMove() {
        let diff = RowDiff.between(old: ["a", "b", "c", "d"], new: ["d", "a", "b", "c"])
        #expect(diff.moves == [RowDiff.Move(from: 3, to: 0)])
        #expect(diff.removed.isEmpty && diff.inserted.isEmpty)
    }

    @Test func removalsAndInsertionsAreReportedByIndex() {
        let diff = RowDiff.between(old: ["a", "b", "c"], new: ["a", "x", "c", "y"])
        #expect(Array(diff.removed) == [1])
        #expect(Array(diff.inserted) == [1, 3])
        #expect(diff.moves.isEmpty)
    }

    @Test func everyShapeAppliesBackToTheNewList() {
        check([], ["a", "b"])
        check(["a", "b"], [])
        check(["a", "b", "c", "d", "e"], ["e", "d", "c", "b", "a"])
        check(["a", "b", "c", "d", "e"], ["c", "x", "a", "e", "y", "b"])
        check(["a", "b", "c"], ["x", "y", "z"])
        var shuffled = (0..<60).map(String.init)
        let original = shuffled
        var seed: UInt64 = 42
        for index in stride(from: shuffled.count - 1, to: 0, by: -1) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            shuffled.swapAt(index, Int(seed >> 33) % (index + 1))
        }
        check(original, shuffled)
        check(original, Array(shuffled.dropFirst(7)) + ["new1", "new2"])
    }
}
