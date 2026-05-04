import Foundation
import Testing
@testable import TestReport

@Suite("Reader")
struct ReaderTests {
    private func writeTempFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("reader-\(UUID().uuidString).jsonl")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("missing file throws .fileNotFound")
    func missingFile() {
        let url = URL(fileURLWithPath: "/tmp/definitely-does-not-exist-\(UUID().uuidString).jsonl")
        do {
            _ = try Reader.read(from: url)
            Issue.record("expected throw")
        } catch let err as Reader.Error {
            #expect(err == .fileNotFound)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("empty file returns empty result with no warnings")
    func emptyFile() throws {
        let url = try writeTempFile("")
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try Reader.read(from: url)
        #expect(result.records.isEmpty)
        #expect(result.malformedLineCount == 0)
    }

    @Test("happy-path file decodes all lines")
    func happyPath() throws {
        let lines = [
            #"{"kind":"event","payload":{"instant":{"absolute":1,"since1970":2},"kind":"runStarted","messages":[]},"version":"6.3.0"}"#,
            #"{"kind":"event","payload":{"instant":{"absolute":3,"since1970":4},"kind":"runEnded","messages":[]},"version":"6.3.0"}"#,
        ].joined(separator: "\n")
        let url = try writeTempFile(lines + "\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try Reader.read(from: url)
        #expect(result.records.count == 2)
        #expect(result.malformedLineCount == 0)
    }

    @Test("malformed line is skipped, surrounding lines decode")
    func malformedLine() throws {
        let lines = [
            #"{"kind":"event","payload":{"instant":{"absolute":1,"since1970":2},"kind":"runStarted","messages":[]},"version":"6.3.0"}"#,
            "this is not json",
            #"{"kind":"event","payload":{"instant":{"absolute":3,"since1970":4},"kind":"runEnded","messages":[]},"version":"6.3.0"}"#,
        ].joined(separator: "\n")
        let url = try writeTempFile(lines + "\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try Reader.read(from: url)
        #expect(result.records.count == 2)
        #expect(result.malformedLineCount == 1)
    }

    @Test("blank lines are tolerated, not counted as malformed")
    func blankLines() throws {
        let lines = #"""

        {"kind":"event","payload":{"instant":{"absolute":1,"since1970":2},"kind":"runStarted","messages":[]},"version":"6.3.0"}

        """#
        let url = try writeTempFile(lines)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try Reader.read(from: url)
        #expect(result.records.count == 1)
        #expect(result.malformedLineCount == 0)
    }
}
