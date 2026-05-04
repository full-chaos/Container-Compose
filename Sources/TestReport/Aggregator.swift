public enum Aggregator {
    public static func aggregate(records: [EventStreamRecord], malformedLineCount: Int) -> TestRun {
        var catalog: [String: EventStream.TestCatalogPayload] = [:]
        var testStartTimes: [String: Double] = [:]
        var testDurations: [String: Double] = [:]
        var passedTestIDs: Set<String> = []
        var failedTestIDs: Set<String> = []
        var skippedTestIDs: Set<String> = []
        var issuesByTestID: [String: [TestRun.IssueRef]] = [:]
        var skipReasonByTestID: [String: String] = [:]
        var knownIssueCount = 0
        var runStartedAt: Double?
        var runEndedAt: Double?
        var unknownEventKinds: Set<String> = []
        var toolchainVersion: String?

        for record in records {
            switch record {
            case .test(let env):
                catalog[env.payload.id] = env.payload
                if toolchainVersion == nil { toolchainVersion = env.version }
            case .event(let env):
                if toolchainVersion == nil { toolchainVersion = env.version }
                let p = env.payload
                switch p.kind {
                case .runStarted:
                    runStartedAt = p.instant.absolute
                case .runEnded:
                    runEndedAt = p.instant.absolute
                case .testStarted:
                    if let id = p.testID, isLeafTestID(id, catalog: catalog) {
                        testStartTimes[id] = p.instant.absolute
                    }
                case .testEnded:
                    guard let id = p.testID, isLeafTestID(id, catalog: catalog) else { continue }
                    if let start = testStartTimes[id] {
                        testDurations[id] = p.instant.absolute - start
                    }
                    if issuesByTestID[id]?.contains(where: { !$0.isKnown }) == true {
                        failedTestIDs.insert(id)
                    } else {
                        passedTestIDs.insert(id)
                    }
                case .testSkipped:
                    if let id = p.testID, isLeafTestID(id, catalog: catalog) {
                        skippedTestIDs.insert(id)
                        skipReasonByTestID[id] = p.messages.first?.text
                    }
                case .issueRecorded:
                    guard let id = p.testID, let issue = p.issue else { continue }
                    let ref = TestRun.IssueRef(
                        severity: issue.severity,
                        isKnown: issue.isKnown,
                        message: p.messages.first?.text ?? "",
                        sourceLocation: issue.sourceLocation.map {
                            TestRun.SourceLocation(fileID: $0.fileID, line: $0.line, column: $0.column)
                        }
                    )
                    issuesByTestID[id, default: []].append(ref)
                    if issue.isKnown { knownIssueCount += 1 }
                case .unknown(let raw):
                    unknownEventKinds.insert(raw)
                }
            case .unknown(let kind, _):
                unknownEventKinds.insert("record:\(kind)")
            }
        }

        // Make failure listings deterministic for snapshot tests.
        let failureList: [TestRun.FailedTest] = failedTestIDs
            .sorted()
            .map { id in
                TestRun.FailedTest(
                    testID: id,
                    displayName: catalog[id]?.displayName,
                    sourceLocation: catalog[id].map {
                        TestRun.SourceLocation(fileID: $0.sourceLocation.fileID, line: $0.sourceLocation.line, column: $0.sourceLocation.column)
                    },
                    issues: issuesByTestID[id] ?? [],
                    durationSeconds: testDurations[id]
                )
            }

        let skipList: [TestRun.SkippedTest] = skippedTestIDs
            .sorted()
            .map { id in
                TestRun.SkippedTest(
                    testID: id,
                    displayName: catalog[id]?.displayName,
                    reason: skipReasonByTestID[id]
                )
            }

        let totalTests = passedTestIDs.count + failedTestIDs.count + skippedTestIDs.count
        let durationSeconds: Double = {
            guard let s = runStartedAt, let e = runEndedAt else { return 0 }
            return max(0, e - s)
        }()

        return TestRun(
            schemaVersion: 1,
            toolchainVersion: toolchainVersion,
            summary: .init(
                totalTests: totalTests,
                passed: passedTestIDs.count,
                failed: failedTestIDs.count,
                skipped: skippedTestIDs.count,
                knownIssues: knownIssueCount,
                durationSeconds: durationSeconds,
                runCompleted: runEndedAt != nil,
                malformedLineCount: malformedLineCount
            ),
            failures: failureList,
            skipped: skipList,
            unknownEventKinds: unknownEventKinds.sorted()
        )
    }

    /// Suite-level testStarted/testEnded events also carry a testID. We only
    /// want to count individual leaf functions, not the suite frames.
    private static func isLeafTestID(_ id: String, catalog: [String: EventStream.TestCatalogPayload]) -> Bool {
        if let entry = catalog[id] { return entry.kind == .function }
        // If we haven't seen a catalog entry yet, fall back to a heuristic:
        // function IDs include a parenthesized call like `someName()`. Suite
        // IDs do not.
        return id.contains("()")
    }
}
