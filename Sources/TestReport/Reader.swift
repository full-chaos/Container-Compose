import Foundation

public enum Reader {
    public enum Error: Swift.Error, Equatable {
        case fileNotFound
    }

    public struct Result {
        public let records: [EventStreamRecord]
        public let malformedLineCount: Int
        public let malformedLines: [(index: Int, snippet: String)]

        public init(records: [EventStreamRecord], malformedLineCount: Int, malformedLines: [(index: Int, snippet: String)]) {
            self.records = records
            self.malformedLineCount = malformedLineCount
            self.malformedLines = malformedLines
        }
    }

    public static func read(from url: URL) throws -> Result {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw Error.fileNotFound
        }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8) else {
            // Treat as malformed file rather than crashing.
            return Result(records: [], malformedLineCount: 1, malformedLines: [(0, "<non-utf8>")])
        }

        let decoder = JSONDecoder()
        var records: [EventStreamRecord] = []
        var malformed: [(Int, String)] = []

        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            do {
                let record = try decoder.decode(EventStreamRecord.self, from: Data(trimmed.utf8))
                records.append(record)
            } catch {
                let snippet = trimmed.prefix(120) + (trimmed.count > 120 ? "..." : "")
                malformed.append((index, String(snippet)))
            }
        }

        return Result(records: records, malformedLineCount: malformed.count, malformedLines: malformed)
    }
}
