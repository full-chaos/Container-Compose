/// Codable types for swift-testing's `--experimental-event-stream-output` JSONL records.
///
/// The schema is derived from observing real output of swift-testing 1743 (Swift 6.3.1).
/// The `version` field on every record carries the swift-testing release string
/// (e.g. `"6.3.0"`) — we surface unknown versions as warnings but proceed best-effort.
public enum EventStream {

    /// A 2D source location emitted on test catalog records and on issues.
    /// `_filePath` and `filePath` are duplicates carrying the absolute path
    /// — only `fileID` is portable, so `filePath` is intentionally ignored.
    public struct SourceLocation: Decodable, Equatable, Sendable {
        public let fileID: String
        public let line: Int
        public let column: Int

        private enum CodingKeys: String, CodingKey {
            case fileID, line, column
        }
    }

    /// Timestamp pair: monotonic (`absolute`) plus wall-clock (`since1970`).
    public struct Instant: Decodable, Equatable, Sendable {
        public let absolute: Double
        public let since1970: Double
    }

    /// A pre-rendered console message. `symbol` is a free-form tag
    /// (`"pass"`, `"fail"`, `"default"`, `"details"`, `"skip"`) used for
    /// console glyphs; `text` is the human string.
    public struct Message: Decodable, Equatable, Sendable {
        public let symbol: String
        public let text: String
    }

    /// Detail attached to an `issueRecorded` event.
    public struct Issue: Decodable, Equatable, Sendable {
        public let isFailure: Bool
        public let isKnown: Bool
        public let severity: String
        public let sourceLocation: SourceLocation?
    }

    /// Payload of a `kind:"test"` record. Emitted once per `@Suite` and once
    /// per `@Test` discovered. The `kind` discriminates between the two.
    public struct TestCatalogPayload: Decodable, Equatable, Sendable {
        public enum Kind: String, Decodable, Sendable {
            case suite
            case function
        }

        public let kind: Kind
        public let id: String
        public let name: String
        public let displayName: String
        public let isParameterized: Bool?
        public let sourceLocation: SourceLocation
    }
}
