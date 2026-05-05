/// Aggregated summary of an event-stream run. The `Encodable` shape is the
/// contract surfaced to `--format json` consumers. Fields are intentionally
/// flat scalars where possible so callers can answer "did everything pass?"
/// without descending into arrays.
public struct TestRun: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let toolchainVersion: String?
    public let summary: Summary
    public let failures: [FailedTest]
    public let skipped: [SkippedTest]
    public let unknownEventKinds: [String]

    public init(
        schemaVersion: Int,
        toolchainVersion: String?,
        summary: Summary,
        failures: [FailedTest],
        skipped: [SkippedTest],
        unknownEventKinds: [String]
    ) {
        self.schemaVersion = schemaVersion
        self.toolchainVersion = toolchainVersion
        self.summary = summary
        self.failures = failures
        self.skipped = skipped
        self.unknownEventKinds = unknownEventKinds
    }

    public struct Summary: Codable, Equatable, Sendable {
        public let totalTests: Int
        public let passed: Int
        public let failed: Int
        public let skipped: Int
        public let knownIssues: Int
        public let durationSeconds: Double
        public let runCompleted: Bool
        public let malformedLineCount: Int

        public init(
            totalTests: Int,
            passed: Int,
            failed: Int,
            skipped: Int,
            knownIssues: Int,
            durationSeconds: Double,
            runCompleted: Bool,
            malformedLineCount: Int
        ) {
            self.totalTests = totalTests
            self.passed = passed
            self.failed = failed
            self.skipped = skipped
            self.knownIssues = knownIssues
            self.durationSeconds = durationSeconds
            self.runCompleted = runCompleted
            self.malformedLineCount = malformedLineCount
        }
    }

    public struct FailedTest: Codable, Equatable, Sendable {
        public let testID: String
        public let displayName: String?
        public let sourceLocation: TestRun.SourceLocation?
        public let issues: [TestRun.IssueRef]
        public let durationSeconds: Double?

        public init(
            testID: String,
            displayName: String?,
            sourceLocation: TestRun.SourceLocation?,
            issues: [TestRun.IssueRef],
            durationSeconds: Double?
        ) {
            self.testID = testID
            self.displayName = displayName
            self.sourceLocation = sourceLocation
            self.issues = issues
            self.durationSeconds = durationSeconds
        }
    }

    public struct SkippedTest: Codable, Equatable, Sendable {
        public let testID: String
        public let displayName: String?
        public let reason: String?

        public init(testID: String, displayName: String?, reason: String?) {
            self.testID = testID
            self.displayName = displayName
            self.reason = reason
        }
    }

    public struct IssueRef: Codable, Equatable, Sendable {
        public let severity: String
        public let isKnown: Bool
        public let message: String
        public let sourceLocation: TestRun.SourceLocation?

        public init(severity: String, isKnown: Bool, message: String, sourceLocation: TestRun.SourceLocation?) {
            self.severity = severity
            self.isKnown = isKnown
            self.message = message
            self.sourceLocation = sourceLocation
        }
    }

    public struct SourceLocation: Codable, Equatable, Sendable {
        public let fileID: String
        public let line: Int
        public let column: Int

        public init(fileID: String, line: Int, column: Int) {
            self.fileID = fileID
            self.line = line
            self.column = column
        }
    }
}
