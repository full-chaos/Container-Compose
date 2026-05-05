# Structured Swift Testing Output for Agent Consumption

**Date:** 2026-05-04
**Status:** Design (approved, awaiting implementation plan)
**Linear:** TBD — create CHAOS issue before merge
**Branch:** `feat/structured-test-output`

## Problem

Agents (and humans, occasionally) drive `swift test` to validate changes in this
repo. Today the only signal available is line-grepped console output:

```
swift test 2>&1 | grep -E '(Test Suite|Test Case|passed|failed)'
```

This is brittle. Swift Testing's console emits Unicode glyphs, multi-line issue
diagnostics, source locations split across continuation lines, and intermixes
issue text with progress events. Regex parsers miss failures, miscount totals,
and lose source locations. The result is wasted agent time and occasional
silently-missed failures.

The user's stated goal: **stop parsing lines with grep; consume structured JSON.**

## Why not Testify

`BinaryBirds/Testify` was the obvious off-the-shelf candidate. It is a parser
that converts `swift test` output into JSON / JUnit XML / Markdown / GFM. The
parser, however, targets **XCTest's** textual output. This codebase uses Swift
Testing exclusively (118 test files, 0 XCTest). Testify's parser would produce
empty or malformed results against our test output.

We could fork Testify and write a Swift Testing adapter, but that duplicates
work the Swift toolchain already does natively (see next section), and we would
own the adapter forever as the schema evolves.

## Why native event stream

Swift Testing (bundled with the Swift toolchain) ships a structured event stream:

```
swift test --experimental-event-stream-output <path>
```

This writes one JSON object per line (JSONL) covering test discovery, run
boundaries, individual test start/end, recorded issues with source locations,
skips, and a final run summary. The flag is currently named with an
`--experimental-` prefix; the schema itself carries a `version` field (a
swift-testing release string such as `"6.3.0"`) that we surface in errors and
warnings if it changes shape.

This is exactly the structured data the user asked for, sourced from the
testing framework itself rather than recovered from console output.

## Architecture

One small library target plus a thin executable wrapper, one Makefile addition.
No runtime impact on `container-compose` itself.

```
swift test --experimental-event-stream-output .build/test-events.jsonl
                          │
                          ▼
            test-report (new executable target)
                          │
                          ▼
   Claude-friendly JSON  │  human summary  │  exit code
```

Why a typed reporter rather than a 30-line `jq` script: the event schema
includes nested test IDs, source locations with file IDs, and tagged unions for
issue kinds. A typed `Codable` model gives compile-time discovery when the
schema gains a field. `jq` would silently miss new fields or misroute on
union-tag changes.

## Components

| Component | Location | Responsibility |
|---|---|---|
| `TestReport` library | `Sources/TestReport/` | Event `Codable` types, aggregator, formatters. Pure — no I/O. |
| `test-report` executable | `Sources/TestReportCLI/` | ArgumentParser CLI: read JSONL, call library, print. |
| `TestReportTests` | `Tests/TestReportTests/` | swift-testing tests — decode fixtures, aggregator, formatter snapshots. |
| `make test-json` | `Makefile` | One-shot: run tests with event stream, then run report, propagate exit code. |

The library/CLI split exists so the aggregator and formatters are unit-testable
without touching the filesystem.

## Data flow

1. `make test-json` runs:
   ```
   swift test --experimental-event-stream-output .build/test-events.jsonl
   ```
2. After the test run finishes (success or failure), it runs:
   ```
   swift run test-report .build/test-events.jsonl --format json
   ```
3. `test-report` opens the file, decodes one event per line, folds events into
   an in-memory `TestRun` summary.
4. Emits to stdout — JSON when `--format json`, human-readable otherwise.
5. Exit code (this is also what `make test-json` propagates):
   - `0` — all tests passed (or all failures were expected, e.g. `.knownIssue`)
   - `1` — one or more tests failed
   - `2` — events file missing/unreadable, schema-version mismatch, or `swift test`
     never produced events (compile error, test runner crash before first event)

## CLI surface

```
test-report <events.jsonl> [--format json|human] [--include-passed]
```

| Flag | Default | Purpose |
|---|---|---|
| `<events.jsonl>` | (required) | Positional path to a JSONL produced by `swift test --experimental-event-stream-output`. |
| `--format` | `human` | `json` for agent consumption; `human` for terminal. |
| `--include-passed` | off | List every test, not just failures. Useful for diffing. |

The schema's `version` field is read off the first record and surfaced in
errors when it doesn't match what the decoder was built against.

`--format human` is default because `make test-json` is also run interactively;
defaulting to JSON would print machine output to a TTY. Agents pass
`--format json` explicitly — the contract is opt-in.

## JSON output shape

The agent-facing contract. Stable across patch releases of `test-report`. Field
values below are illustrative; test IDs and source locations come straight from
swift-testing's emitted events (we don't synthesize them).

```json
{
  "schemaVersion": 0,
  "summary": {
    "totalTests": 247,
    "passed": 246,
    "failed": 1,
    "skipped": 0,
    "knownIssues": 0,
    "durationSeconds": 12.847,
    "runCompleted": true
  },
  "failures": [
    {
      "testID": "Container_Compose_StaticTests.VolumeMountParserTests/parsesAnonymousVolumeWithDriver()",
      "displayName": "parses anonymous volume with driver",
      "sourceLocation": {
        "fileID": "Container-Compose-StaticTests/VolumeMountParserTests.swift",
        "line": 142,
        "column": 13
      },
      "issues": [
        {
          "kind": "expectationFailed",
          "message": "Expectation failed: result.driver == \"local\"",
          "comments": []
        }
      ],
      "durationSeconds": 0.018
    }
  ],
  "skipped": [],
  "unknownEventKinds": []
}
```

Rationale for shape:
- **`summary` is flat scalars** — agents can answer "did everything pass?"
  without parsing arrays.
- **`failures` carries everything needed to act**: test ID for re-running, source
  location for opening the file, issue messages for reasoning about the cause.
- **`unknownEventKinds`** counts events the decoder didn't recognize. Forward
  compatibility surfaced explicitly rather than hidden.

## Error handling

- **Missing events file** → exit 2, message: `events file not found at <path> — did 'swift test' fail to start? compile error?`
- **Empty events file** → exit 2, distinct message: `events file is empty — 'swift test' may have crashed before emitting any events`
- **Malformed JSON line** → log to stderr, skip the line, continue. Don't abort the entire report on one bad line. Track count, surface in summary.
- **Unknown event kind** → counted under `unknownEventKinds`, surfaced in summary. Forward-compatible.
- **Schema version mismatch** → the observed `version` is surfaced as `toolchainVersion` in the JSON output and as a header line in the human output. Per-event decode failures hit the malformed-line path. We don't gate on version explicitly — the schema has been stable across recent toolchain versions, and the visible `toolchainVersion` is enough to diagnose drift.
- **Run did not finish (no `runEnded` event)** → set `summary.runCompleted = false` and report what we have. Useful when `swift test` itself crashed mid-run.

## Testing

- **Capture a real fixture once**: run `swift test --filter ScaleTests --experimental-event-stream-output
  Tests/TestReportTests/Fixtures/sample-events-pass.jsonl` (or another small
  static-test class) against the existing tests, scrub host-specific paths,
  check the file in. A second fixture covers failure events (captured by adding
  a temporary failing test, running the event stream, then removing the test).
- **Decode tests**: every event kind appearing in the fixture decodes cleanly.
  This catches schema drift when toolchain updates.
- **Aggregator tests**: synthetic event sequences (constructed in code, not from
  fixtures) → expected `TestRun`. Cover happy path, all-skip, all-fail, missing
  `runEnded`, malformed line interleaved with valid lines.
- **Formatter tests**: golden-file style — `--format json` output for a known
  event sequence is checked against a stored expected JSON. Detects accidental
  shape changes.
- All tests use `import Testing` to match the rest of the codebase.

## Out of scope (deliberately YAGNI)

- JUnit XML output — no consumer in this repo today.
- Markdown / GFM PR-comment output — defer until someone asks.
- Wiring `.github/workflows/tests.yml` to use `make test-json` — separate change, separate PR.
- Installing `test-report` as a system binary — it's a dev tool; `swift run` and `make` are the entry points.
- Streaming/incremental output — the JSONL is small enough to read end-to-end (KB, not MB, even for the full suite).

## Risks

- **Schema instability**: the flag is `--experimental-event-stream-output`,
  signaling Apple may evolve it. The `version` field on every record is
  surfaced in the report's `toolchainVersion`, so drift is diagnosable. Per-event
  decode failures still surface as malformed lines.
- **Fixture drift**: the captured JSONL fixture will need refresh after each
  Swift toolchain bump. This is the same risk any consumer of the schema has;
  the decode tests will fail loudly if we miss a bump.
- **Behavioral coupling to the Swift toolchain**: if a future toolchain
  renames `--experimental-event-stream-output` (drops the prefix when
  promoted to stable), the Makefile target breaks. Mitigation: surface the
  observed toolchain `version` in the report header so the failure is
  diagnosable, and update the Makefile target alongside the toolchain bump.

## Open questions

None — design is sized for a single PR.

## Implementation plan

To be written next, in `docs/superpowers/plans/2026-05-04-structured-test-output-plan.md`,
following the writing-plans skill.
