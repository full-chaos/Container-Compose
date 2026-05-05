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

    /// Payload of a `kind:"event"` record. The `kind` field discriminates
    /// between lifecycle events. Forward-compatible: unrecognized kinds are
    /// preserved as `.unknown(rawValue)` rather than rejected.
    public struct EventPayload: Decodable, Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case runStarted
            case runEnded
            case testStarted
            case testEnded
            case testSkipped
            case issueRecorded
            case unknown(String)

            init(rawValue: String) {
                switch rawValue {
                case "runStarted": self = .runStarted
                case "runEnded": self = .runEnded
                case "testStarted": self = .testStarted
                case "testEnded": self = .testEnded
                case "testSkipped": self = .testSkipped
                case "issueRecorded": self = .issueRecorded
                default: self = .unknown(rawValue)
                }
            }
        }

        public let kind: Kind
        public let instant: Instant
        public let messages: [Message]
        public let testID: String?
        public let issue: Issue?

        private enum CodingKeys: String, CodingKey {
            case kind, instant, messages, testID, issue
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.kind = Kind(rawValue: try c.decode(String.self, forKey: .kind))
            self.instant = try c.decode(Instant.self, forKey: .instant)
            self.messages = try c.decode([Message].self, forKey: .messages)
            self.testID = try c.decodeIfPresent(String.self, forKey: .testID)
            self.issue = try c.decodeIfPresent(Issue.self, forKey: .issue)
        }
    }
}

/// One line of `swift test --experimental-event-stream-output` JSONL.
/// Forward-compatible: unrecognized top-level `kind` values become `.unknown`.
public enum EventStreamRecord: Decodable, Sendable {
    case event(EventEnvelope)
    case test(TestEnvelope)
    case unknown(kind: String, version: String)

    public struct EventEnvelope: Decodable, Sendable {
        public let version: String
        public let payload: EventStream.EventPayload
    }

    public struct TestEnvelope: Decodable, Sendable {
        public let version: String
        public let payload: EventStream.TestCatalogPayload
    }

    private enum CodingKeys: String, CodingKey {
        case kind, version
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        let version = try c.decode(String.self, forKey: .version)
        switch kind {
        case "event":
            self = .event(try EventEnvelope(from: decoder))
        case "test":
            self = .test(try TestEnvelope(from: decoder))
        default:
            self = .unknown(kind: kind, version: version)
        }
    }
}
