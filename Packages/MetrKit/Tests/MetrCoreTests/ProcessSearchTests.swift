import Testing

@testable import MetrCore

@Suite struct ProcessSearchTests {
    private func chrome() -> ProcessSearchFields {
        ProcessSearchFields(
            groupID: "/Applications/Google Chrome.app", name: "Google Chrome", pid: 400,
            helpers: [
                ProcessSearchHelper(id: "helper:501:1", name: "Renderer", pid: 501),
                ProcessSearchHelper(id: "helper:502:1", name: "GPU Process", pid: 502),
            ])
    }

    @Test func matchesAppNames() {
        let hit = ProcessSearch.match("chrome", chrome())
        #expect(hit?.groupMatches == true)
        #expect(ProcessSearch.match("safari", chrome()) == nil)
    }

    @Test func matchesHelperNames() {
        let hit = ProcessSearch.match("renderer", chrome())
        #expect(hit?.groupMatches == false)
        #expect(hit?.helperIDs == ["helper:501:1"])
    }

    @Test func pidIsExact() {
        let group = ProcessSearchFields(
            groupID: "g", name: "Foo", pid: 1234,
            helpers: [ProcessSearchHelper(id: "h", name: "Bar", pid: 1234)])
        let hit = ProcessSearch.match("1234", group)
        #expect(hit?.groupMatches == true)
        #expect(hit?.helperIDs == ["h"])
        #expect(ProcessSearch.match("123", group) == nil)
    }

    @Test func diacriticsAndWhitespace() {
        let cafe = ProcessSearchFields(groupID: "c", name: "Café", pid: 7, helpers: [])
        #expect(ProcessSearch.match("cafe", cafe)?.groupMatches == true)
        #expect(ProcessSearch.normalize("  chrome  ") == "chrome")
        #expect(ProcessSearch.normalize("") == nil)
        #expect(ProcessSearch.normalize("   \n\t ") == nil)
    }

    @Test func lengthCap() {
        let long = String(repeating: "a", count: 500)
        #expect(ProcessSearch.normalize(long)?.count == ProcessSearch.maximumLength)
        #expect(ProcessSearch.maximumLength == 128)
    }
}
