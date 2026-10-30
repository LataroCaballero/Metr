import Foundation

/// Display-safe text from untrusted sources (D-12, T-02-11). A process name, executable path or
/// bundle name belongs to an arbitrary local program, so every string that reaches a row, a
/// tooltip or a VoiceOver label goes through here first.
public enum ProcessText {
    /// Removes control characters (C0 and C1) and the bidirectional controls U+202A to U+202E and
    /// U+2066 to U+2069 (so a name cannot reorder the text around it), trims surrounding
    /// whitespace and caps the result at `limit` characters.
    public static func sanitize(_ text: String, limit: Int = 128) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where !isStripped(scalar) {
            scalars.append(scalar)
        }
        let trimmed = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isStripped(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.generalCategory == .control { return true }
        switch scalar.value {
        case 0x202A...0x202E, 0x2066...0x2069: return true
        default: return false
        }
    }
}

/// Path rules for grouping processes under their app (D-12, RESEARCH Pattern 4).
public enum ProcessPaths {
    /// The path up to and including the first component that ends in ".app" and has at least one
    /// component after it, or nil. "/Applications/Foo.app" alone is a bundle, not an executable
    /// inside one, so it gives nil; so does a directory such as "my.application".
    public static func outermostAppBundle(of path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        for (index, component) in components.enumerated() {
            guard component.count > 4, component.hasSuffix(".app") else { continue }
            guard index + 1 < components.count else { return nil }
            return "/" + components[0...index].joined(separator: "/")
        }
        return nil
    }
}
