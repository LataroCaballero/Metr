import Foundation

/// One helper process of a group, as the table's search sees it (D-13).
public struct ProcessSearchHelper: Sendable, Equatable {
    public var id: String
    public var name: String
    public var pid: Int32

    public init(id: String, name: String, pid: Int32) {
        self.id = id
        self.name = name
        self.pid = pid
    }
}

/// What the search compares a query against for one table group: the group's id and name, its main
/// process's PID (nil when no process represents it) and its helpers.
public struct ProcessSearchFields: Sendable, Equatable {
    public var groupID: String
    public var name: String
    public var pid: Int32?
    public var helpers: [ProcessSearchHelper]

    public init(groupID: String, name: String, pid: Int32?, helpers: [ProcessSearchHelper]) {
        self.groupID = groupID
        self.name = name
        self.pid = pid
        self.helpers = helpers
    }
}

/// How a query matched one group: the group itself (by name or PID) and which of its helpers.
public struct ProcessSearchMatch: Sendable, Equatable {
    public var groupMatches: Bool
    public var helperIDs: Set<String>

    public init(groupMatches: Bool, helperIDs: Set<String>) {
        self.groupMatches = groupMatches
        self.helperIDs = helperIDs
    }
}

public enum ProcessSearch {
    public static let maximumLength = 128

    public static func normalize(_ query: String) -> String? {
        query
    }

    public static func match(_ query: String, _ fields: ProcessSearchFields) -> ProcessSearchMatch? {
        nil
    }
}
