# Phase 2 Remainder — Findings (Team G)

**Date:** 2026-05-03
**Branch:** `review-phase2-remainder`
**Tasks covered:** 2.4 (Compose parsing edge case tests), 2.5 (Volume mount validation tests), 2.6 (Volume mount integration tests)

---

## Summary

Three test files totalling 66 `@Test` functions were added to `Tests/Container-Compose-StaticTests/`.
No production code was changed.

---

## Findings

### F1: `$$` literal dollar escape is not implemented in `resolveVariable`

**Severity:** Low  
**File:** `Sources/Container-Compose/Helper Functions.swift`, `resolveVariable(_:with:)`

The compose-spec (§12) states that `$$` in a compose value should produce a literal `$` character.
The current `resolveVariable` regex pattern is `\$\{([A-Za-z0-9_]+)...\}`, which only matches
`${VAR}`-style tokens.  A bare `$$SUFFIX` or `$${VAR}` expression is never matched and passes
through unchanged.

In practice this means that a compose file value like `$$PORT` will NOT be converted to `$PORT`
by Container-Compose; the literal `$$PORT` string will be passed into the container's environment
instead.  For most users this is invisible because they do not use `$$` escapes, but it is a
spec-compliance gap.

**Tracking:** A disabled test (`@Test(.disabled("CHAOS-1411: ..."))`) in `ComposeParsingEdgeCaseTests.swift`
documents the expected behavior.  A Linear issue should be filed under CHAOS if this is a priority.

---

### F2: Nested variable references `${OUTER_${INNER}}` silently fail

**Severity:** Low (spec does not define nested expansion; this is current behavior documentation)  
**File:** `Sources/Container-Compose/Helper Functions.swift`, `resolveVariable(_:with:)`

A value like `${OUTER_${INNER}}` is left unchanged by `resolveVariable` because the outer
`${...}` token contains a `$` character, which is not matched by the inner `[A-Za-z0-9_]+`
character class.  The compose-spec does not define nested variable expansion, so this is
expected — but the behavior is now explicitly documented and tested.

---

### F3: `configVolume` is untestable in isolation due to private access

**Severity:** Medium (testability gap)  
**File:** `Sources/Container-Compose/Commands/ComposeUp.swift`

`ComposeUp.configVolume` is declared `private mutating func`.  This is correct encapsulation
for production code, but it means that unit tests for filesystem side-effects (source-path
existence check, auto-creation, file-vs-directory detection) cannot be written without either:

1. Making the function `internal` (and using `@testable import`), or
2. Testing entirely through the `compose up` command path (i.e. integration tests that write
   a temp compose project + a temp directory, then run the command end-to-end).

The current approach (option 2) was used for Task 2.6.  The limitation means edge cases like
"bind mount source is a regular file not a directory" are not covered at the unit level.

**Recommendation:** Consider extracting the filesystem-checking logic into a `configVolume`
helper function marked `internal`, analogous to how `ensureNamedVolumeRegistered` was extracted
and made `internal` for the CHAOS-1398 idempotency tests.

---

### F4: `resolvingExtends` in an included file is resolved against the merged document

**Severity:** Informational (behavior documented by tests)  
**File:** `Sources/Container-Compose/Codable Structs/DockerCompose.swift`

When a compose file is loaded via `loadAndMerge` (which processes `include:`), all included
services are merged into a single `DockerCompose` document before `resolvingExtends()` is called.
This means that a service in an included file that uses `extends: service: <name>` can resolve
against a service in the main file after merging.  This is the correct behavior per compose-spec,
and tests in `ComposeParsingEdgeCaseTests.swift` pin this contract.

The tested scenario: main file declares `worker_prod` that extends `worker_base`; `worker_base`
is defined only in an included `workers.yml`.  After merge + resolve, `worker_prod` correctly
inherits `worker_base`'s fields.

---

### F5: `compose down -v` tolerates `notFound` for removed volumes

**Severity:** Informational (existing behavior, confirmed by test)  
**File:** `Sources/Container-Compose/Commands/ComposeDown.swift`

`compose down -v` will attempt `removeVolume` for every declared named volume and gracefully
tolerate `RuntimeError.notFound` (i.e. the volume was already removed or never created).
This matches Docker Compose behavior and is already covered by `ComposeDownVolumeRemovalTests.swift`.
The new integration tests in `VolumeMountIntegrationTests.swift` build on this confirmed behavior.

---

## Tests with `.disabled` annotation

| Test | File | Reason |
|------|------|--------|
| `doubleDollarShouldProduceLiteralDollar` | `ComposeParsingEdgeCaseTests.swift` | `$$` literal escape not yet implemented in `resolveVariable`; documents expected future behavior |
| `bindMountNonExistentSourceWarnSkip` | `VolumeMountValidationTests.swift` | `configVolume` is private; filesystem side-effects tested via integration only |
| `bindMountSourceIsFileNotDirectory` | `VolumeMountValidationTests.swift` | Same as above |

---

## Coverage not included (with rationale)

| Scenario | Rationale |
|----------|-----------|
| `configVolume` auto-creates missing bind-mount source directory | Private API; cannot test directly without refactoring production code |
| Bind-mount source is a file not a directory → warn+skip | Private API; behavior is documented in a disabled test |
| `${VAR:?error}` missing-variable error path | Calls `Application.exit(withError:)` which is not easily interceptable in static tests; covered by `EnvironmentVariableTests.swift` description comments |
| Malformed YAML with unclosed quotes | Yams surfaces a `DecodingError` before our code is reached; behavior is already documented in `DockerComposeParsingTests.swift` |
