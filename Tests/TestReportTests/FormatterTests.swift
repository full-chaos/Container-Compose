import Foundation
import Testing
@testable import TestReport

@Suite("Formatters")
struct FormatterTests {
    @Test("JSON formatter round-trips: encode → decode equals original TestRun")
    func jsonRoundTrip() throws {
        let url = try #require(Bundle.module.url(forResource: "sample-events-pass", withExtension: "jsonl", subdirectory: "Fixtures"))
        let result = try Reader.read(from: url)
        let run = Aggregator.aggregate(records: result.records, malformedLineCount: result.malformedLineCount)
        let json = try Formatters.render(run, format: .json)
        let decoded = try JSONDecoder().decode(TestRun.self, from: Data(json.utf8))
        #expect(decoded == run)
    }

    @Test("JSON formatter uses sorted keys for stable diffs")
    func jsonSortedKeys() throws {
        let stub = TestRun(
            schemaVersion: 1, toolchainVersion: "6.3.0",
            summary: .init(totalTests: 1, passed: 1, failed: 0, skipped: 0, knownIssues: 0, durationSeconds: 0.5, runCompleted: true, malformedLineCount: 0),
            failures: [], skipped: [], unknownEventKinds: []
        )
        let json = try Formatters.render(stub, format: .json)
        // Sanity: 'summary' appears before 'unknownEventKinds' in output (alphabetical sort).
        let sumRange = try #require(json.range(of: "\"summary\""))
        let unkRange = try #require(json.range(of: "\"unknownEventKinds\""))
        #expect(sumRange.lowerBound < unkRange.lowerBound)
    }

    @Test("human formatter shows failure block when failed > 0")
    func humanFailureBlock() throws {
        let url = try #require(Bundle.module.url(forResource: "sample-events-with-failure", withExtension: "jsonl", subdirectory: "Fixtures"))
        let result = try Reader.read(from: url)
        let run = Aggregator.aggregate(records: result.records, malformedLineCount: result.malformedLineCount)
        let text = try Formatters.render(run, format: .human)
        #expect(text.contains("FAILED"))
        #expect(text.contains("failed"))
    }

    @Test("human formatter omits failure block when all passed")
    func humanAllPassed() throws {
        let url = try #require(Bundle.module.url(forResource: "sample-events-pass", withExtension: "jsonl", subdirectory: "Fixtures"))
        let result = try Reader.read(from: url)
        let run = Aggregator.aggregate(records: result.records, malformedLineCount: result.malformedLineCount)
        let text = try Formatters.render(run, format: .human)
        #expect(!text.contains("FAILED"))
    }
}
