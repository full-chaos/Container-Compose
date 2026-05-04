# Structured Swift Testing Output Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `test-report` executable that consumes `swift test --experimental-event-stream-output` JSONL and emits a stable JSON summary for agent consumption (and a human summary by default).

**Architecture:** New SPM library `TestReport` (Codable types + reader + aggregator + formatters) plus a thin CLI wrapper executable `test-report`. Pure parser/formatter — no integration with `container-compose` runtime. Driven via a new `make test-json` target.

**Tech Stack:** Swift 6.3+, Swift Testing (`import Testing`), swift-argument-parser (already a dep), Foundation only — no new SPM dependencies.

**Spec:** `docs/superpowers/specs/2026-05-04-structured-test-output-design.md`

---

## File Structure

**Modified:**
- `Package.swift` — add 3 new targets (library, executable, test target)
- `Makefile` — add `test-json` target

**Created:**
- `Sources/TestReport/EventStream.swift` — Codable types for the JSONL records and payloads
- `Sources/TestReport/Reader.swift` — JSONL file → `[EventStreamRecord]`
- `Sources/TestReport/TestRun.swift` — aggregated summary model
- `Sources/TestReport/Aggregator.swift` — events → `TestRun`
- `Sources/TestReport/Formatters.swift` — `TestRun` → JSON / human text
- `Sources/TestReportCLI/main.swift` — ArgumentParser entry point
- `Tests/TestReportTests/Fixtures/sample-events-pass.jsonl` — captured passing-only fixture
- `Tests/TestReportTests/Fixtures/sample-events-with-failure.jsonl` — captured fixture including a failure
- `Tests/TestReportTests/EventStreamDecodeTests.swift`
- `Tests/TestReportTests/ReaderTests.swift`
- `Tests/TestReportTests/AggregatorTests.swift`
- `Tests/TestReportTests/FormatterTests.swift`
- `Tests/TestReportTests/Fixtures/expected-pass-report.json` — golden output for the JSON formatter

---

## Task 1: Scaffolding — empty SPM targets

**Files:**
- Modify: `Package.swift` (after the existing `.testTarget(name: "Container-Compose-DynamicTests", ...)`)
- Create: `Sources/TestReport/EventStream.swift`
- Create: `Sources/TestReport/Reader.swift`
- Create: `Sources/TestReport/TestRun.swift`
- Create: `Sources/TestReport/Aggregator.swift`
- Create: `Sources/TestReport/Formatters.swift`
- Create: `Sources/TestReportCLI/main.swift`
- Create: `Tests/TestReportTests/Placeholder.swift`
- Create: `Tests/TestReportTests/Fixtures/.gitkeep`

- [ ] **Step 1: Create empty source files**

```bash
mkdir -p Sources/TestReport Sources/TestReportCLI Tests/TestReportTests/Fixtures
touch Tests/TestReportTests/Fixtures/.gitkeep
```

`Sources/TestReport/EventStream.swift`:
```swift
import Foundation

// Stub: types defined in Task 3-6.
public enum EventStream {}
```

`Sources/TestReport/Reader.swift`:
```swift
import Foundation

// Stub: implemented in Task 8.
public struct Reader {
    public init() {}
}
```

`Sources/TestReport/TestRun.swift`:
```swift
import Foundation

// Stub: implemented in Task 9.
public struct TestRun: Sendable {
    public init() {}
}
```

`Sources/TestReport/Aggregator.swift`:
```swift
import Foundation

// Stub: implemented in Task 10.
public struct Aggregator {
    public init() {}
}
```

`Sources/TestReport/Formatters.swift`:
```swift
import Foundation

// Stub: implemented in Task 11-12.
public enum ReportFormat: String, Sendable {
    case json
    case human
}
```

`Sources/TestReportCLI/main.swift`:
```swift
import Foundation
import TestReport

// Stub: implemented in Task 12.
print("test-report stub")
```

`Tests/TestReportTests/Placeholder.swift`:
```swift
import Testing
@testable import TestReport

@Suite("TestReport scaffolding")
struct PlaceholderTests {
    @Test("library is importable")
    func libraryImportable() {
        _ = ReportFormat.json
    }
}
```

- [ ] **Step 2: Wire targets into `Package.swift`**

Add the three targets at the end of the `targets:` array in `Package.swift`, immediately after the existing `Container-Compose-DynamicTests` test target. Insert *before* the closing `])`:

```swift
        // CHAOS-XXXX: structured test output for agent consumption.
        // Library — Codable types, reader, aggregator, formatters.
        .target(
            name: "TestReport",
            path: "Sources/TestReport"
        ),

        // CLI wrapper around TestReport. Consumed via `make test-json` and
        // `swift run test-report ...`.
        .executableTarget(
            name: "test-report",
            dependencies: [
                "TestReport",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/TestReportCLI"
        ),

        .testTarget(
            name: "TestReportTests",
            dependencies: ["TestReport"],
            path: "Tests/TestReportTests",
            resources: [
                .copy("Fixtures"),
            ]
        ),
```

- [ ] **Step 3: Verify build**

Run: `swift build --build-tests`
Expected: `Build complete!` (no errors)

- [ ] **Step 4: Verify scaffolding test runs**

Run: `swift test --filter "TestReport scaffolding"`
Expected: 1 test passed (`libraryImportable`)

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/TestReport Sources/TestReportCLI Tests/TestReportTests
git commit -m "feat(test-report): scaffold TestReport library, CLI, and test target

Empty stubs for the structured test-output reporter. No behavior yet;
just the SPM wiring so subsequent TDD tasks have a place to land.

Spec: docs/superpowers/specs/2026-05-04-structured-test-output-design.md"
```

---

## Task 2: Capture passing-only event fixture

**Files:**
- Create: `Tests/TestReportTests/Fixtures/sample-events-pass.jsonl` (generated)

- [ ] **Step 1: Capture events from a small static-test class**

Run:
```bash
swift test --filter "ScaleTests" --experimental-event-stream-output Tests/TestReportTests/Fixtures/sample-events-pass.jsonl
```
Expected: tests run and pass; `Tests/TestReportTests/Fixtures/sample-events-pass.jsonl` exists with ~25 lines.

- [ ] **Step 2: Scrub host-specific paths from the fixture**

Replace the absolute filesystem path on this host with a placeholder, since the fixture is checked in and host paths leak local user info:

```bash
sed -i '' 's|"\(_filePath\|filePath\)":"/Users/[^"]*"|"\1":"<HOST_PATH_REDACTED>"|g' Tests/TestReportTests/Fixtures/sample-events-pass.jsonl
```

Verify: `grep '/Users/' Tests/TestReportTests/Fixtures/sample-events-pass.jsonl` should return nothing.

- [ ] **Step 3: Sanity check the fixture**

Run:
```bash
jq -r '.payload.kind // .kind' Tests/TestReportTests/Fixtures/sample-events-pass.jsonl | sort -u
```
Expected output should include at least: `function`, `runEnded`, `runStarted`, `suite`, `testEnded`, `testStarted`.

- [ ] **Step 4: Commit**

```bash
git add Tests/TestReportTests/Fixtures/sample-events-pass.jsonl
git commit -m "test(test-report): add captured passing-event fixture

Captured from \`swift test --filter ScaleTests --experimental-event-stream-output\`
on Swift 6.3.1 / swift-testing 1743. Host paths scrubbed."
```

---

## Task 3: Foundational Codable types (`SourceLocation`, `Instant`, `Message`, `Issue`)

**Files:**
- Modify: `Sources/TestReport/EventStream.swift` (replace stub)
- Create: `Tests/TestReportTests/EventStreamDecodeTests.swift`

- [ ] **Step 1: Write failing decode tests for the four foundational types**

`Tests/TestReportTests/EventStreamDecodeTests.swift`:
```swift
import Foundation
import Testing
@testable import TestReport

@Suite("EventStream foundational types")
struct EventStreamFoundationalDecodeTests {
    @Test("SourceLocation decodes")
    func decodeSourceLocation() throws {
        let json = #"""
        {"_filePath":"<HOST_PATH_REDACTED>","column":6,"fileID":"X/Y.swift","filePath":"<HOST_PATH_REDACTED>","line":57}
        """#
        let loc = try JSONDecoder().decode(EventStream.SourceLocation.self, from: Data(json.utf8))
        #expect(loc.fileID == "X/Y.swift")
        #expect(loc.line == 57)
        #expect(loc.column == 6)
    }

    @Test("Instant decodes")
    func decodeInstant() throws {
        let json = #"{"absolute":349431.79,"since1970":1777927810.5}"#
        let inst = try JSONDecoder().decode(EventStream.Instant.self, from: Data(json.utf8))
        #expect(inst.absolute == 349431.79)
        #expect(inst.since1970 == 1777927810.5)
    }

    @Test("Message decodes")
    func decodeMessage() throws {
        let json = #"{"symbol":"pass","text":"Test passed."}"#
        let msg = try JSONDecoder().decode(EventStream.Message.self, from: Data(json.utf8))
        #expect(msg.symbol == "pass")
        #expect(msg.text == "Test passed.")
    }

    @Test("Issue decodes with sourceLocation")
    func decodeIssue() throws {
        let json = #"""
        {"isFailure":true,"isKnown":false,"severity":"error","sourceLocation":{"_filePath":"x","column":9,"fileID":"X/Y.swift","filePath":"x","line":7}}
        """#
        let issue = try JSONDecoder().decode(EventStream.Issue.self, from: Data(json.utf8))
        #expect(issue.isFailure == true)
        #expect(issue.isKnown == false)
        #expect(issue.severity == "error")
        #expect(issue.sourceLocation?.line == 7)
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter "EventStream foundational types"`
Expected: build error — `EventStream.SourceLocation`, `Instant`, `Message`, `Issue` undefined.

- [ ] **Step 3: Implement the types**

Replace the contents of `Sources/TestReport/EventStream.swift` with:

```swift
import Foundation

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
}
```

- [ ] **Step 4: Run tests to verify pass**

Run: `swift test --filter "EventStream foundational types"`
Expected: 4 tests passed.

- [ ] **Step 5: Commit**

```bash
git add Sources/TestReport/EventStream.swift Tests/TestReportTests/EventStreamDecodeTests.swift
git commit -m "feat(test-report): foundational EventStream types

SourceLocation, Instant, Message, Issue Codable types modeling the
shared sub-objects in swift-testing's event stream JSONL."
```

---

## Task 4: Test catalog payload (`suite` and `function` records)

The event stream emits two top-level record kinds: `kind:"event"` (run/test events) and `kind:"test"` (the test catalog — one record per `@Suite` and per `@Test`). This task models the catalog records.

**Files:**
- Modify: `Sources/TestReport/EventStream.swift` (extend)
- Modify: `Tests/TestReportTests/EventStreamDecodeTests.swift` (add tests)

- [ ] **Step 1: Write failing test against the suite/function fixture lines**

Add to `Tests/TestReportTests/EventStreamDecodeTests.swift`:
```swift
@Suite("EventStream test catalog payload")
struct EventStreamCatalogDecodeTests {
    @Test("suite payload decodes")
    func decodeSuite() throws {
        let json = #"""
        {"displayName":"Scale Expansion Tests","id":"Mod.ScaleTests","kind":"suite","name":"ScaleTests","sourceLocation":{"_filePath":"x","column":2,"fileID":"Mod/ScaleTests.swift","filePath":"x","line":27}}
        """#
        let payload = try JSONDecoder().decode(EventStream.TestCatalogPayload.self, from: Data(json.utf8))
        #expect(payload.kind == .suite)
        #expect(payload.id == "Mod.ScaleTests")
        #expect(payload.name == "ScaleTests")
        #expect(payload.displayName == "Scale Expansion Tests")
        #expect(payload.isParameterized == nil)
        #expect(payload.sourceLocation.line == 27)
    }

    @Test("function payload decodes with isParameterized")
    func decodeFunction() throws {
        let json = #"""
        {"displayName":"scale = 1","id":"Mod.ScaleTests/scaleOne()/X.swift:57:6","isParameterized":false,"kind":"function","name":"scaleOne()","sourceLocation":{"_filePath":"x","column":6,"fileID":"Mod/ScaleTests.swift","filePath":"x","line":57}}
        """#
        let payload = try JSONDecoder().decode(EventStream.TestCatalogPayload.self, from: Data(json.utf8))
        #expect(payload.kind == .function)
        #expect(payload.name == "scaleOne()")
        #expect(payload.isParameterized == false)
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter "EventStream test catalog payload"`
Expected: build error — `EventStream.TestCatalogPayload` undefined.

- [ ] **Step 3: Implement the type**

Append inside the `EventStream` enum in `Sources/TestReport/EventStream.swift`:

```swift
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
```

- [ ] **Step 4: Run tests to verify pass**

Run: `swift test --filter "EventStream test catalog payload"`
Expected: 2 tests passed.

- [ ] **Step 5: Commit**

```bash
git add Sources/TestReport/EventStream.swift Tests/TestReportTests/EventStreamDecodeTests.swift
git commit -m "feat(test-report): TestCatalogPayload Codable type

Models the kind:'test' record's payload — suite and function entries
emitted by swift-testing during discovery."
```

---

## Task 5: Event payload (run/test/issue events)

The `kind:"event"` records carry the lifecycle events. Their payload's `kind`
discriminates: `runStarted`, `runEnded`, `testStarted`, `testEnded`,
`issueRecorded`, `testSkipped`, etc. This task models the payload as a Codable
struct keeping all observed fields, with a forward-compatible `unknown` case
for kinds we haven't accounted for.

**Files:**
- Modify: `Sources/TestReport/EventStream.swift` (extend)
- Modify: `Tests/TestReportTests/EventStreamDecodeTests.swift` (add tests)

- [ ] **Step 1: Write failing tests for event-payload decoding**

Add to `Tests/TestReportTests/EventStreamDecodeTests.swift`:
```swift
@Suite("EventStream event payload")
struct EventStreamEventPayloadDecodeTests {
    @Test("runStarted decodes")
    func decodeRunStarted() throws {
        let json = #"""
        {"instant":{"absolute":1.0,"since1970":2.0},"kind":"runStarted","messages":[{"symbol":"default","text":"Test run started."}]}
        """#
        let p = try JSONDecoder().decode(EventStream.EventPayload.self, from: Data(json.utf8))
        #expect(p.kind == .runStarted)
        #expect(p.testID == nil)
        #expect(p.issue == nil)
        #expect(p.messages.count == 1)
    }

    @Test("testStarted decodes with testID")
    func decodeTestStarted() throws {
        let json = #"""
        {"instant":{"absolute":1,"since1970":2},"kind":"testStarted","messages":[],"testID":"Mod.MyTests/myCase()"}
        """#
        let p = try JSONDecoder().decode(EventStream.EventPayload.self, from: Data(json.utf8))
        #expect(p.kind == .testStarted)
        #expect(p.testID == "Mod.MyTests/myCase()")
    }

    @Test("testEnded decodes")
    func decodeTestEnded() throws {
        let json = #"""
        {"instant":{"absolute":1,"since1970":2},"kind":"testEnded","messages":[{"symbol":"pass","text":"x"}],"testID":"Mod.X/y()"}
        """#
        let p = try JSONDecoder().decode(EventStream.EventPayload.self, from: Data(json.utf8))
        #expect(p.kind == .testEnded)
    }

    @Test("issueRecorded decodes with issue and testID")
    func decodeIssueRecorded() throws {
        let json = #"""
        {"instant":{"absolute":1,"since1970":2},"issue":{"isFailure":true,"isKnown":false,"severity":"error","sourceLocation":{"_filePath":"x","column":9,"fileID":"Mod/F.swift","filePath":"x","line":7}},"kind":"issueRecorded","messages":[{"symbol":"fail","text":"Expectation failed"}],"testID":"Mod.X/y()"}
        """#
        let p = try JSONDecoder().decode(EventStream.EventPayload.self, from: Data(json.utf8))
        #expect(p.kind == .issueRecorded)
        #expect(p.issue?.isFailure == true)
        #expect(p.issue?.sourceLocation?.line == 7)
    }

    @Test("runEnded decodes")
    func decodeRunEnded() throws {
        let json = #"""
        {"instant":{"absolute":1,"since1970":2},"kind":"runEnded","messages":[{"symbol":"pass","text":"done"}]}
        """#
        let p = try JSONDecoder().decode(EventStream.EventPayload.self, from: Data(json.utf8))
        #expect(p.kind == .runEnded)
    }

    @Test("unknown event kind decodes as .unknown(...)") 
    func decodeUnknownEventKind() throws {
        let json = #"""
        {"instant":{"absolute":1,"since1970":2},"kind":"someFutureKind","messages":[]}
        """#
        let p = try JSONDecoder().decode(EventStream.EventPayload.self, from: Data(json.utf8))
        #expect(p.kind == .unknown("someFutureKind"))
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter "EventStream event payload"`
Expected: build error — `EventStream.EventPayload` undefined.

- [ ] **Step 3: Implement `EventPayload` and its `Kind` enum**

Append inside the `EventStream` enum in `Sources/TestReport/EventStream.swift`:

```swift
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
```

- [ ] **Step 4: Run tests to verify pass**

Run: `swift test --filter "EventStream event payload"`
Expected: 6 tests passed.

- [ ] **Step 5: Commit**

```bash
git add Sources/TestReport/EventStream.swift Tests/TestReportTests/EventStreamDecodeTests.swift
git commit -m "feat(test-report): EventPayload Codable type

Models the kind:'event' record's payload — runStarted/runEnded/
testStarted/testEnded/issueRecorded/testSkipped — with a forward-
compatible .unknown(String) variant for kinds we haven't seen yet."
```

---

## Task 6: Top-level `EventStreamRecord` discriminated union

Combine the catalog and event payloads behind a single discriminated record
type, so `Reader` can decode any line into one shape.

**Files:**
- Modify: `Sources/TestReport/EventStream.swift` (add the union type)
- Modify: `Tests/TestReportTests/EventStreamDecodeTests.swift` (union tests)

- [ ] **Step 1: Write failing union-decoding tests**

Add to `Tests/TestReportTests/EventStreamDecodeTests.swift`:
```swift
@Suite("EventStreamRecord union")
struct EventStreamRecordDecodeTests {
    @Test("kind:'event' decodes as .event")
    func decodeEventRecord() throws {
        let json = #"""
        {"kind":"event","payload":{"instant":{"absolute":1,"since1970":2},"kind":"runStarted","messages":[]},"version":"6.3.0"}
        """#
        let r = try JSONDecoder().decode(EventStreamRecord.self, from: Data(json.utf8))
        guard case .event(let env) = r else {
            Issue.record("expected .event variant"); return
        }
        #expect(env.version == "6.3.0")
        #expect(env.payload.kind == .runStarted)
    }

    @Test("kind:'test' decodes as .test")
    func decodeTestRecord() throws {
        let json = #"""
        {"kind":"test","payload":{"displayName":"X","id":"a","kind":"suite","name":"X","sourceLocation":{"_filePath":"x","column":1,"fileID":"a/b.swift","filePath":"x","line":1}},"version":"6.3.0"}
        """#
        let r = try JSONDecoder().decode(EventStreamRecord.self, from: Data(json.utf8))
        guard case .test(let env) = r else {
            Issue.record("expected .test variant"); return
        }
        #expect(env.payload.kind == .suite)
    }

    @Test("unknown record kind decodes as .unknown")
    func decodeUnknownRecord() throws {
        let json = #"{"kind":"future","payload":{"x":1},"version":"99.0"}"#
        let r = try JSONDecoder().decode(EventStreamRecord.self, from: Data(json.utf8))
        guard case .unknown(let kind, let version) = r else {
            Issue.record("expected .unknown variant"); return
        }
        #expect(kind == "future")
        #expect(version == "99.0")
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter "EventStreamRecord union"`
Expected: build error — `EventStreamRecord` undefined at top level (or under `TestReport`).

- [ ] **Step 3: Implement the union**

Append at file scope (NOT inside `enum EventStream`) in `Sources/TestReport/EventStream.swift`:

```swift
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
```

- [ ] **Step 4: Run tests to verify pass**

Run: `swift test --filter "EventStreamRecord union"`
Expected: 3 tests passed.

- [ ] **Step 5: Spot-check the real fixture decodes**

Add this test in the same file to make sure the fixture decodes end-to-end:

```swift
@Suite("EventStream fixture round-trip")
struct EventStreamFixtureDecodeTests {
    @Test("every line in sample-events-pass.jsonl decodes")
    func decodeWholePassFixture() throws {
        let url = Bundle.module.url(forResource: "sample-events-pass", withExtension: "jsonl", subdirectory: "Fixtures")
        try #require(url != nil)
        let data = try Data(contentsOf: url!)
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .filter { !$0.isEmpty }
        #expect(lines.count > 0)

        let decoder = JSONDecoder()
        var decoded = 0
        for line in lines {
            _ = try decoder.decode(EventStreamRecord.self, from: Data(line.utf8))
            decoded += 1
        }
        #expect(decoded == lines.count)
    }
}
```

Run: `swift test --filter "EventStream fixture round-trip"`
Expected: 1 test passed.

- [ ] **Step 6: Commit**

```bash
git add Sources/TestReport/EventStream.swift Tests/TestReportTests/EventStreamDecodeTests.swift
git commit -m "feat(test-report): EventStreamRecord union + fixture round-trip

Top-level discriminated union over event/test/unknown records, plus a
test that decodes every line of the captured fixture."
```

---

## Task 7: Capture failure-event fixture

To test `Aggregator` and the JSON formatter against real failure data, we need
a fixture containing `issueRecorded` events. Capture by introducing a tiny
intentionally-failing test, running the event stream, and removing the test.

**Files:**
- Create (then delete): `Tests/Container-Compose-StaticTests/_TempFailingForFixture.swift`
- Create: `Tests/TestReportTests/Fixtures/sample-events-with-failure.jsonl`

- [ ] **Step 1: Add the temporary failing test**

`Tests/Container-Compose-StaticTests/_TempFailingForFixture.swift`:
```swift
import Testing

@Suite("_TempFailingForFixture")
struct _TempFailingForFixture {
    @Test("intentional failure for fixture capture")
    func intentionalFailure() {
        #expect(1 == 2, "intentional fixture-capture failure")
    }
}
```

- [ ] **Step 2: Capture events**

```bash
swift test --filter "_TempFailingForFixture" --experimental-event-stream-output Tests/TestReportTests/Fixtures/sample-events-with-failure.jsonl
```

Expected: command exits non-zero (test fails as intended), but the fixture file is written. Verify:
```bash
jq -r '.payload.kind' Tests/TestReportTests/Fixtures/sample-events-with-failure.jsonl | sort -u
```
Expected output includes `issueRecorded`.

- [ ] **Step 3: Scrub host paths**

```bash
sed -i '' 's|"\(_filePath\|filePath\)":"/Users/[^"]*"|"\1":"<HOST_PATH_REDACTED>"|g' Tests/TestReportTests/Fixtures/sample-events-with-failure.jsonl
grep -c '/Users/' Tests/TestReportTests/Fixtures/sample-events-with-failure.jsonl
```
Expected: 0 matches.

- [ ] **Step 4: Remove the temporary test**

```bash
rm Tests/Container-Compose-StaticTests/_TempFailingForFixture.swift
```

- [ ] **Step 5: Verify the suite still builds clean**

Run: `swift build --build-tests`
Expected: clean build, no errors.

- [ ] **Step 6: Commit**

```bash
git add Tests/TestReportTests/Fixtures/sample-events-with-failure.jsonl
git commit -m "test(test-report): add captured failure-event fixture

Captured by adding a temporary failing test, running the event stream,
then removing the test. Fixture contains a single issueRecorded event
plus the surrounding test/run lifecycle."
```

---

## Task 8: `Reader` — JSONL file → `[EventStreamRecord]`

Reads the file line-by-line, decodes each, surfaces malformed lines as
warnings (not aborts), distinguishes file-missing from file-empty.

**Files:**
- Modify: `Sources/TestReport/Reader.swift` (replace stub)
- Create: `Tests/TestReportTests/ReaderTests.swift`

- [ ] **Step 1: Write failing tests**

`Tests/TestReportTests/ReaderTests.swift`:
```swift
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
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter "Reader"`
Expected: build error — `Reader.read(from:)`, `Reader.Error`, `Reader.Result` undefined.

- [ ] **Step 3: Implement the reader**

Replace `Sources/TestReport/Reader.swift` with:
```swift
import Foundation

public enum Reader {
    public enum Error: Swift.Error, Equatable {
        case fileNotFound
    }

    public struct Result: Sendable {
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
```

- [ ] **Step 4: Run tests to verify pass**

Run: `swift test --filter "Reader"`
Expected: 5 tests passed.

- [ ] **Step 5: Commit**

```bash
git add Sources/TestReport/Reader.swift Tests/TestReportTests/ReaderTests.swift
git commit -m "feat(test-report): Reader — JSONL file decode with malformed-line skip

Reads .jsonl event-stream files. Missing file throws; empty file is
fine; malformed lines are skipped (counted, snippet preserved); blank
lines tolerated."
```

---

## Task 9: `TestRun` summary model

The Codable model that becomes the `--format json` output. Defined here in
isolation; populated by `Aggregator` in the next task.

**Files:**
- Modify: `Sources/TestReport/TestRun.swift` (replace stub)

- [ ] **Step 1: Implement the model**

Replace `Sources/TestReport/TestRun.swift` with:

```swift
import Foundation

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

    public struct Summary: Codable, Equatable, Sendable {
        public let totalTests: Int
        public let passed: Int
        public let failed: Int
        public let skipped: Int
        public let knownIssues: Int
        public let durationSeconds: Double
        public let runCompleted: Bool
        public let malformedLineCount: Int
    }

    public struct FailedTest: Codable, Equatable, Sendable {
        public let testID: String
        public let displayName: String?
        public let sourceLocation: TestRun.SourceLocation?
        public let issues: [TestRun.IssueRef]
        public let durationSeconds: Double?
    }

    public struct SkippedTest: Codable, Equatable, Sendable {
        public let testID: String
        public let displayName: String?
        public let reason: String?
    }

    public struct IssueRef: Codable, Equatable, Sendable {
        public let severity: String
        public let isKnown: Bool
        public let message: String
        public let sourceLocation: TestRun.SourceLocation?
    }

    public struct SourceLocation: Codable, Equatable, Sendable {
        public let fileID: String
        public let line: Int
        public let column: Int
    }
}
```

- [ ] **Step 2: Verify build**

Run: `swift build`
Expected: clean build.

- [ ] **Step 3: Commit**

```bash
git add Sources/TestReport/TestRun.swift
git commit -m "feat(test-report): TestRun summary model

Codable struct that becomes the --format json output contract.
Summary block is flat scalars; failures/skipped carry per-test detail."
```

---

## Task 10: `Aggregator` — events → `TestRun`

Folds an `[EventStreamRecord]` sequence into a `TestRun`. Built test-first
with synthetic event sequences, then validated against the captured fixtures.

**Files:**
- Modify: `Sources/TestReport/Aggregator.swift` (replace stub)
- Create: `Tests/TestReportTests/AggregatorTests.swift`

- [ ] **Step 1: Write failing tests with synthetic event sequences**

`Tests/TestReportTests/AggregatorTests.swift`:
```swift
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
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter "Aggregator"`
Expected: build error — `Aggregator.aggregate(records:malformedLineCount:)` undefined.

- [ ] **Step 3: Implement the aggregator**

Replace `Sources/TestReport/Aggregator.swift` with:
```swift
import Foundation

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
                    sourceLocation: catalog[id]?.sourceLocation.map {
                        TestRun.SourceLocation(fileID: $0.fileID, line: $0.line, column: $0.column)
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
```

- [ ] **Step 4: Run tests to verify pass**

Run: `swift test --filter "Aggregator"`
Expected: 5 tests passed.

- [ ] **Step 5: Commit**

```bash
git add Sources/TestReport/Aggregator.swift Tests/TestReportTests/AggregatorTests.swift
git commit -m "feat(test-report): Aggregator folds events into TestRun

Maintains per-test state across testStarted/testEnded/issueRecorded,
classifies tests as passed/failed/skipped, captures durations, and
surfaces unknown event kinds. Tests cover synthetic sequences plus
both captured fixtures."
```

---

## Task 11: Formatters — JSON + human

Two formatters sharing a single `ReportFormat` switch. JSON is contract-stable
for agents; human is the default for terminal use. Golden-file snapshot test
is added in Task 12 once the CLI exists to (re)generate it.

**Files:**
- Modify: `Sources/TestReport/Formatters.swift` (replace stub)
- Create: `Tests/TestReportTests/FormatterTests.swift`

- [ ] **Step 1: Write failing formatter tests (no golden file dependency)**

`Tests/TestReportTests/FormatterTests.swift`:
```swift
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
        // First object-level key should be the alphabetically-earliest top-level key.
        // Top-level keys: failures, schemaVersion, skipped, summary, toolchainVersion, unknownEventKinds.
        let firstKey = #""failures""#
        let openBraceIdx = try #require(json.firstIndex(of: "{"))
        let after = json[json.index(after: openBraceIdx)...]
        #expect(after.contains(firstKey))
        // Sanity: 'summary' appears before 'unknownEventKinds' in output.
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
```

- [ ] **Step 2: Run tests to verify failure**

Run: `swift test --filter "Formatters"`
Expected: build error — `Formatters.render(_:format:includePassed:)` undefined.

- [ ] **Step 3: Implement formatters**

Replace `Sources/TestReport/Formatters.swift` with:
```swift
import Foundation

public enum ReportFormat: String, Sendable {
    case json
    case human
}

public enum Formatters {
    public static func render(_ run: TestRun, format: ReportFormat, includePassed: Bool = false) throws -> String {
        switch format {
        case .json:
            return try renderJSON(run)
        case .human:
            return renderHuman(run, includePassed: includePassed)
        }
    }

    private static func renderJSON(_ run: TestRun) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(run)
        return String(decoding: data, as: UTF8.self)
    }

    private static func renderHuman(_ run: TestRun, includePassed: Bool) -> String {
        var lines: [String] = []
        let s = run.summary
        let runState = s.runCompleted ? "completed" : "incomplete"
        lines.append("Test run \(runState) — \(s.passed) passed, \(s.failed) failed, \(s.skipped) skipped (in \(String(format: "%.3f", s.durationSeconds))s)")
        if let v = run.toolchainVersion {
            lines.append("  toolchain: swift-testing \(v)")
        }
        if s.malformedLineCount > 0 {
            lines.append("  warning: skipped \(s.malformedLineCount) malformed event line(s)")
        }
        if !run.unknownEventKinds.isEmpty {
            lines.append("  warning: unknown event kinds: \(run.unknownEventKinds.joined(separator: ", "))")
        }

        if !run.failures.isEmpty {
            lines.append("")
            lines.append("FAILED (\(run.failures.count)):")
            for f in run.failures {
                let label = f.displayName ?? f.testID
                lines.append("  ✘ \(label)  [\(f.testID)]")
                if let loc = f.sourceLocation {
                    lines.append("      at \(loc.fileID):\(loc.line):\(loc.column)")
                }
                for issue in f.issues {
                    lines.append("      - \(issue.message)")
                }
            }
        }

        if !run.skipped.isEmpty {
            lines.append("")
            lines.append("SKIPPED (\(run.skipped.count)):")
            for sk in run.skipped {
                lines.append("  - \(sk.displayName ?? sk.testID)")
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }
}
```

- [ ] **Step 4: Run tests to verify pass**

Run: `swift test --filter "Formatters"`
Expected: 4 tests passed.

- [ ] **Step 5: Commit**

```bash
git add Sources/TestReport/Formatters.swift Tests/TestReportTests/FormatterTests.swift
git commit -m "feat(test-report): JSON and human formatters

JSON output uses sorted keys for stable diffs; human output is the
default for TTY use. Snapshot test against a checked-in golden file
follows in Task 12 once the CLI exists to regenerate it."
```

---

## Task 12: CLI executable + golden-file snapshot test

Thin ArgumentParser wrapper. Reads file, aggregates, formats, exits with
appropriate code. Once the CLI exists, capture the JSON output for the
passing fixture as a checked-in golden file and add a snapshot test.

**Files:**
- Modify: `Sources/TestReportCLI/main.swift` (replace stub)
- Create: `Tests/TestReportTests/Fixtures/expected-pass-report.json` (golden, captured)
- Modify: `Tests/TestReportTests/FormatterTests.swift` (add golden-file test)

- [ ] **Step 1: Implement the CLI**

Replace `Sources/TestReportCLI/main.swift` with:

```swift
import ArgumentParser
import Foundation
import TestReport

@main
struct TestReportCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "test-report",
        abstract: "Summarize a swift-testing event-stream JSONL into JSON or human-readable text."
    )

    @Argument(help: "Path to a .jsonl file produced by `swift test --experimental-event-stream-output`.")
    var eventsPath: String

    @Option(name: .long, help: "Output format: 'json' or 'human'.")
    var format: ReportFormat = .human

    @Flag(name: .long, help: "Include passing tests in the human output.")
    var includePassed: Bool = false

    mutating func run() throws {
        let url = URL(fileURLWithPath: eventsPath)
        let readResult: Reader.Result
        do {
            readResult = try Reader.read(from: url)
        } catch Reader.Error.fileNotFound {
            FileHandle.standardError.write(Data("test-report: events file not found at \(url.path) — did 'swift test' fail to start? compile error?\n".utf8))
            throw ExitCode(2)
        }

        if readResult.records.isEmpty && readResult.malformedLineCount == 0 {
            FileHandle.standardError.write(Data("test-report: events file is empty — 'swift test' may have crashed before emitting any events\n".utf8))
            throw ExitCode(2)
        }

        let run = Aggregator.aggregate(records: readResult.records, malformedLineCount: readResult.malformedLineCount)
        let rendered = try Formatters.render(run, format: format, includePassed: includePassed)
        print(rendered, terminator: "")

        if run.summary.failed > 0 {
            throw ExitCode(1)
        }
    }
}

extension ReportFormat: ExpressibleByArgument {}
```

- [ ] **Step 2: Verify build**

Run: `swift build`
Expected: clean build.

- [ ] **Step 3: Smoke-test the CLI against the passing fixture**

Run:
```bash
swift run test-report Tests/TestReportTests/Fixtures/sample-events-pass.jsonl --format human
```
Expected: human-readable summary printed; exit 0.

```bash
swift run test-report Tests/TestReportTests/Fixtures/sample-events-pass.jsonl --format json
```
Expected: JSON object printed.

```bash
swift run test-report Tests/TestReportTests/Fixtures/sample-events-with-failure.jsonl --format human ; echo "exit=$?"
```
Expected: failure block printed; `exit=1`.

```bash
swift run test-report /tmp/does-not-exist.jsonl --format json ; echo "exit=$?"
```
Expected: error printed to stderr; `exit=2`.

- [ ] **Step 4: Capture the golden file**

```bash
swift run test-report Tests/TestReportTests/Fixtures/sample-events-pass.jsonl --format json > Tests/TestReportTests/Fixtures/expected-pass-report.json
```

Quick sanity-check the file is non-empty and well-formed JSON:
```bash
jq '.summary | {totalTests, passed, failed}' Tests/TestReportTests/Fixtures/expected-pass-report.json
```
Expected: an object with the three numeric fields.

- [ ] **Step 5: Add the golden-file snapshot test**

Append to `Tests/TestReportTests/FormatterTests.swift`:
```swift
@Suite("Formatters golden file")
struct FormatterGoldenTests {
    @Test("JSON output for passing fixture matches checked-in golden")
    func jsonGoldenMatch() throws {
        let eventsURL = try #require(Bundle.module.url(forResource: "sample-events-pass", withExtension: "jsonl", subdirectory: "Fixtures"))
        let result = try Reader.read(from: eventsURL)
        let run = Aggregator.aggregate(records: result.records, malformedLineCount: result.malformedLineCount)
        let actual = try Formatters.render(run, format: .json)

        let goldenURL = try #require(Bundle.module.url(forResource: "expected-pass-report", withExtension: "json", subdirectory: "Fixtures"))
        let expected = try String(contentsOf: goldenURL, encoding: .utf8)

        // Compare structurally rather than as raw strings to absorb whitespace
        // differences from regen flows. Drift in shape (added/removed fields)
        // still surfaces because TestRun is the canonical Codable.
        let decoder = JSONDecoder()
        let a = try decoder.decode(TestRun.self, from: Data(actual.utf8))
        let e = try decoder.decode(TestRun.self, from: Data(expected.utf8))
        #expect(a == e, "Run `swift run test-report Tests/TestReportTests/Fixtures/sample-events-pass.jsonl --format json > Tests/TestReportTests/Fixtures/expected-pass-report.json` to regenerate after intentional shape changes.")
    }
}
```

- [ ] **Step 6: Run the new test**

Run: `swift test --filter "Formatters golden file"`
Expected: 1 test passed.

- [ ] **Step 7: Commit**

```bash
git add Sources/TestReportCLI/main.swift Tests/TestReportTests/FormatterTests.swift Tests/TestReportTests/Fixtures/expected-pass-report.json
git commit -m "feat(test-report): CLI + golden-file snapshot

ArgumentParser CLI wires Reader → Aggregator → Formatters with exit
codes 0 (all-passed) / 1 (any-failed) / 2 (events-missing-or-empty).
Golden-file test gates the JSON output shape against drift; regen
command lives in the test's failure message."
```

---

## Task 13: Makefile target + end-to-end smoke

Wires up `make test-json`. Includes a stale-fixture guard so a previous failed
run doesn't poison the next report.

**Files:**
- Modify: `Makefile`

- [ ] **Step 1: Add the target**

Edit `Makefile`. Update the `.PHONY` line and `help` target, and add the new target after `test`:

Change:
```make
.PHONY: all build release debug test build-tests coverage clean install uninstall help
```
to:
```make
.PHONY: all build release debug test test-json build-tests coverage clean install uninstall help
```

After the existing `test:` target block, add:
```make
# Run the suite under swift-testing's event stream and emit a structured
# report. Useful for agent-driven test reading or CI parsing.
# Exit code mirrors the report: 0 = all passed, 1 = any failed, 2 = no events.
test-json:
	rm -f .build/test-events.jsonl
	-swift test --experimental-event-stream-output .build/test-events.jsonl
	swift run test-report .build/test-events.jsonl --format json
```

In the `help:` target, add the line:
```make
	@echo "  test-json         Run tests + emit structured JSON report (for agents/CI)"
```
right after the existing `test` line. Final ordering:
```make
help:
	@echo "Targets:"
	@echo "  build / release   Release build of $(binary_name)"
	@echo "  debug             Debug build of $(binary_name)"
	@echo "  build-tests       Compile tests without running (CI-equivalent)"
	@echo "  test              Run all tests (dynamic ones self-skip without Apple container)"
	@echo "  test-json         Run tests + emit structured JSON report (for agents/CI)"
	@echo "  coverage          Regenerate coverage.json from coverage.html"
	@echo "  clean             Remove .build/"
	@echo "  install           Build + install to \$$(bindir) (default $(bindir))"
	@echo "  uninstall         Remove the installed binary"
```

- [ ] **Step 2: Smoke-test end-to-end**

Run: `make test-json`
Expected: tests run; structured JSON written to stdout; final exit code 0 if all pass, 1 if any fail.

Optional sanity check — pipe through jq:
```bash
make test-json | jq '.summary'
```
Expected: a JSON object with `totalTests`, `passed`, `failed`, etc.

- [ ] **Step 3: Verify `make help` includes the new target**

Run: `make help | grep test-json`
Expected: line `  test-json         ...` printed.

- [ ] **Step 4: Commit**

```bash
git add Makefile
git commit -m "feat(test-report): \`make test-json\` target

Runs the suite under swift-testing's event stream and emits a
structured JSON report via test-report. Stale-fixture guard removes
.build/test-events.jsonl before each run so a prior crash doesn't
poison the next report."
```

---

## Task 14: Final verification + push

- [ ] **Step 1: Full test run on the worktree**

Run: `swift test`
Expected: clean run, 0 unexpected failures. Dynamic tests self-skip if Apple `container` runtime isn't installed — this is fine.

- [ ] **Step 2: End-to-end agent-style consumption check**

```bash
make test-json | jq '{passed: .summary.passed, failed: .summary.failed, completed: .summary.runCompleted, failureCount: (.failures | length)}'
```
Expected: a small JSON object; `failed == 0` and `failureCount == 0` if everything passes.

- [ ] **Step 3: Build artifact check**

Run: `git status`
Expected: clean working tree (no untracked files in `.build/test-events.jsonl` since it lives under `.build/` which is gitignored).

- [ ] **Step 4: Push the branch and open a PR**

```bash
gh pct --title "feat(test-report): structured event-stream output for agent consumption" --body "$(cat <<'EOF'
## Summary
- New \`TestReport\` library + \`test-report\` CLI consume swift-testing's
  \`--experimental-event-stream-output\` JSONL and emit a stable JSON
  summary (or human-readable text by default).
- New \`make test-json\` target runs the suite and pipes through the reporter.
- Spec: docs/superpowers/specs/2026-05-04-structured-test-output-design.md
- Plan: docs/superpowers/plans/2026-05-04-structured-test-output.md

## Test plan
- [x] \`swift build --build-tests\` clean
- [x] \`swift test\` green (dynamic tests self-skip without runtime)
- [x] \`make test-json | jq .summary\` returns expected fields
- [x] Failure exit code (1) propagates when a test fails
- [x] Missing/empty events file → exit 2 with stderr message
EOF
)"
```

Expected: PR URL printed.

---

## Self-review checklist (run after writing all tasks)

- **Spec coverage**: every section of the spec maps to at least one task above. ✓
- **No placeholders**: no `TBD`/`TODO`/"fill in later" in tasks 1–14. ✓
- **Type consistency**: `EventStream.SourceLocation` (decode) vs `TestRun.SourceLocation` (encode) are intentionally distinct types — the decode shape carries `_filePath`/`filePath`, the encode shape doesn't. Names match across tasks. ✓
- **Forward references**: Task 11 deliberately ships without a golden file. Task 12 adds the golden file (captured via the just-built CLI) and the snapshot test. No backward-pointing TODOs remain in Task 11. ✓

