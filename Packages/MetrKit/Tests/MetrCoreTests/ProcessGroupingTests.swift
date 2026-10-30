import Testing

@testable import MetrCore

@Suite struct ProcessGroupingTests {
    // MARK: Text and paths (Task 1)

    @Test func outermostBundle() {
        let brave =
            "/Applications/Brave Browser.app/Contents/Frameworks/Brave Browser Framework.framework"
            + "/Versions/1/Helpers/Brave Browser Helper (Renderer).app/Contents/MacOS/Brave Browser Helper (Renderer)"
        #expect(ProcessPaths.outermostAppBundle(of: brave) == "/Applications/Brave Browser.app")
        #expect(ProcessPaths.outermostAppBundle(of: "/usr/libexec/trustd") == nil)
        #expect(ProcessPaths.outermostAppBundle(of: "/Users/x/my.application/bin/tool") == nil)
        // A bundle path with nothing after it is not an executable inside a bundle.
        #expect(ProcessPaths.outermostAppBundle(of: "/Applications/Foo.app") == nil)
    }

    @Test func sanitize() {
        // C0, C1 and bidi controls go; ordinary text stays.
        #expect(ProcessText.sanitize("Safe\u{0007}Name\u{0085}") == "SafeName")
        #expect(ProcessText.sanitize("a\u{202E}b\u{2066}c\u{2069}d") == "abcd")
        #expect(ProcessText.sanitize("  padded name \n") == "padded name")
        let long = String(repeating: "x", count: 300)
        #expect(ProcessText.sanitize(long).count == 128)
        #expect(ProcessText.sanitize(long, limit: 10).count == 10)
        #expect(ProcessText.sanitize("Café — 日本語") == "Café — 日本語")
    }
}
