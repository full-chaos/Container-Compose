import Foundation
import Testing
@testable import TestReport

@Suite("Aggregator")
struct AggregatorTests {
    private func decode(_ json: String) throws -> EventStreamRecord {
        try JSONDecoder().decode(EventStreamRecord.self, from: Data(json.utf8))
    }

    @Test("empty input yields zero counts and runCompleted=false")
    func emptyInput() {
        let run = Aggregator.aggregate(records: [], malformedLineCount: 0)
        #expect(run.summary.totalTests == 0)
        #expect(run.summary.passed == 0)
        #expect(run.summary.failed == 0)
        #expect(run.summary.runCompleted == false)
    }

    @Test("decoded passing fixture aggregates with no failures")
    func passingFixture() throws {
        let url = Bundle.module.url(forResource: "sample-events-pass", withExtension: "jsonl", subdirectory: "Fixtures")
        let result = try Reader.read(from: try #require(url))
        let run = Aggregator.aggregate(records: result.records, malformedLineCount: result.malformedLineCount)
        #expect(run.summary.failed == 0)
        #expect(run.summary.totalTests > 0)
        #expect(run.summary.runCompleted == true)
        #expect(run.failures.isEmpty)
    }

    @Test("decoded failure fixture surfaces issueRecorded as a failure")
    func failureFixture() throws {
        let url = Bundle.module.url(forResource: "sample-events-with-failure", withExtension: "jsonl", subdirectory: "Fixtures")
        let result = try Reader.read(from: try #require(url))
        let run = Aggregator.aggregate(records: result.records, malformedLineCount: result.malformedLineCount)
        #expect(run.summary.failed >= 1)
        #expect(run.failures.count >= 1)
        let first = try #require(run.failures.first)
        #expect(first.issues.count >= 1)
        #expect(first.issues.first?.severity == "error")
    }

    @Test("malformedLineCount flows through to summary")
    func malformedLineFlow() {
        let run = Aggregator.aggregate(records: [], malformedLineCount: 3)
        #expect(run.summary.malformedLineCount == 3)
    }

    @Test("unknown event kinds are collected in unknownEventKinds")
    func unknownEventKinds() throws {
        let json = #"""
        {"kind":"event","payload":{"instant":{"absolute":1,"since1970":2},"kind":"someFutureKind","messages":[]},"version":"6.3.0"}
        """#
        let run = Aggregator.aggregate(records: [try decode(json)], malformedLineCount: 0)
        #expect(run.unknownEventKinds.contains("someFutureKind"))
    }
}
