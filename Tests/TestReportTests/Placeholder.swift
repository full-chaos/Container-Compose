import Testing
@testable import TestReport

@Suite("TestReport scaffolding")
struct PlaceholderTests {
    @Test("library is importable")
    func libraryImportable() {
        _ = ReportFormat.json
    }
}
