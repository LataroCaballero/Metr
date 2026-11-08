import Foundation

/// The smallest set of row operations that turns one ordered list of ids into another, in the
/// shape an animated outline update wants: first remove, then move, then insert (D-16, UI-SPEC
/// "Rows do not jump": rows move with a smooth transition keyed by identity).
public struct RowDiff: Sendable, Equatable {
    public struct Move: Sendable, Equatable {
        public var from: Int
        public var to: Int

        public init(from: Int, to: Int) {
            self.from = from
            self.to = to
        }
    }

    /// Indexes in the OLD list of ids that are gone.
    public var removed: IndexSet
    /// One move at a time, each against the list as the earlier operations left it.
    public var moves: [Move]
    /// Indexes in the NEW list of ids that were not there before.
    public var inserted: IndexSet

    public init(removed: IndexSet, moves: [Move], inserted: IndexSet) {
        self.removed = removed
        self.moves = moves
        self.inserted = inserted
    }

    public var isEmpty: Bool { removed.isEmpty && moves.isEmpty && inserted.isEmpty }

    /// How much animating there is to do.
    public var operationCount: Int { removed.count + moves.count + inserted.count }

    public static func between(old: [String], new: [String]) -> RowDiff {
        RowDiff(removed: [], moves: [], inserted: [])
    }

    /// Applies the operations to `old` the way an outline would, giving the list they describe.
    /// `new` supplies the ids at the inserted indexes. For tests and the DEBUG consistency check.
    public func applied(to old: [String], inserting new: [String]) -> [String] {
        var list = old
        for index in removed.reversed() { list.remove(at: index) }
        for move in moves {
            let id = list.remove(at: move.from)
            list.insert(id, at: move.to)
        }
        for index in inserted { list.insert(new[index], at: index) }
        return list
    }
}
