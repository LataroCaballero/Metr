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

/// The Processes table's search (D-13, T-03-26). Pure: it compares one query with one group's
/// names and PIDs. A name matches when it contains the query, ignoring case and diacritics (the
/// system's `localizedStandardContains`); a PID matches only when the whole query is that integer,
/// so "123" never finds 1234. There is no regular expression and the work is linear in the length
/// of the names, so a pathological query costs nothing.
public enum ProcessSearch {
    /// The longest query that is used. The system field scrolls longer text, and the rest is ignored.
    public static let maximumLength = 128

    /// The query to match with: trimmed, at most `maximumLength` characters, or nil when nothing is
    /// left, which means "no filter" and shows the whole table.
    public static func normalize(_ query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > maximumLength else { return trimmed }
        let capped = String(trimmed.prefix(maximumLength)).trimmingCharacters(in: .whitespacesAndNewlines)
        return capped.isEmpty ? nil : capped
    }

    /// How `query` matches one group, or nil when it matches neither the group nor a helper. The
    /// query is normalized here, so a caller can pass the field's text as it is; an empty one
    /// matches nothing (the caller skips filtering when `normalize` gives nil).
    public static func match(_ query: String, _ fields: ProcessSearchFields) -> ProcessSearchMatch? {
        guard let query = normalize(query) else { return nil }
        let pid = Int32(query)
        let groupMatches =
            fields.name.localizedStandardContains(query) || (pid != nil && fields.pid == pid)
        var helperIDs: Set<String> = []
        for helper in fields.helpers
        where helper.name.localizedStandardContains(query) || (pid != nil && helper.pid == pid) {
            helperIDs.insert(helper.id)
        }
        guard groupMatches || !helperIDs.isEmpty else { return nil }
        return ProcessSearchMatch(groupMatches: groupMatches, helperIDs: helperIDs)
    }
}
