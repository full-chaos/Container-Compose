# Phase 1 Remainder: Test Gap Audit

**Author:** Team F (Phase 1 Remainder)  
**Date:** 2026-05-03  
**Tasks covered:** 1.3 (Network Runtime CRUD Tests), 1.4 (Security Feature Integration Tests)

---

## Summary

This audit documents gaps discovered while writing the Phase 1 remainder tests.
All gaps are observable facts about the current codebase; none of them represent
new regressions introduced in this PR.

---

## 1. Security Fields: Compose Accepts, Runtime Spec Does Not Carry

`RuntimeCreateConfiguration` is the struct passed to `Runtime.create()` in the
native API path.  It intentionally carries only fields that the native
apple/containerization runtime consumes today.  The following security fields are
**accepted by the compose parser** and **translated to argv by SecurityArgs.build()**,
but they **have no counterpart in `RuntimeCreateConfiguration`**.

| Compose field | Argv emission | RuntimeCreateConfiguration field |
|---|---|---|
| `cap_add` | `--cap-add <CAP>` per entry | MISSING |
| `cap_drop` | `--cap-drop <CAP>` per entry | MISSING |
| `security_opt` | warn-and-skip (apple/container rejects `--security-opt`) | MISSING |
| `read_only` | `--read-only` when true | MISSING |
| `user` | `--user <value>` | MISSING |
| `group_add` | warn-and-skip (apple/container rejects `--group-add`) | MISSING |
| `privileged` | warn-and-skip (apple/container rejects `--privileged`) | MISSING |

### Why this gap exists

Container-Compose uses **two parallel mechanisms** to reach the runtime:

1. **argv pipeline (`RunCommandRunner`)** — the existing path that shells out
   to `container run`.  `SecurityArgs.build()` produces argv for this path.

2. **Native API path (`Runtime.create()`)** — the newer path via
   `RuntimeCreateConfiguration`.  Currently used only by the API server for
   tests; production `compose up` still goes through the argv pipeline.

The gap is expected until the production `compose up` command migrates fully to
the native API path.  At that point, each security field will need to be wired
into `RuntimeCreateConfiguration`.

### Recommended follow-up

- `TODO(CHAOS-1407)`: Add `capabilities: (add: [String], drop: [String])?` to
  `RuntimeCreateConfiguration` and wire from `SecurityArgs` logic.
- `TODO(CHAOS-1407)`: Add `readOnly: Bool?` to `RuntimeCreateConfiguration`.
- `TODO(CHAOS-1407)`: Add `user: String?` to `RuntimeCreateConfiguration`.
- The three warn-and-skip fields (`security_opt`, `group_add`, `privileged`) do
  NOT need a counterpart in `RuntimeCreateConfiguration` today, because
  apple/container has no equivalent flags.  When apple/container gains support,
  add fields and flip warn-and-skip to real emission.

---

## 2. Network CRUD: Call-Site Coverage Gaps

### 2.1 Production `compose up` does not use `Runtime.createNetwork`

`NetworkRoutes.swift` (`POST /networks`, `DELETE /networks/{id}`) correctly
calls `Runtime.createNetwork` and `Runtime.removeNetwork`.  However, the
production `ComposeUp.configService` flow that creates top-level networks at
`compose up` time still goes through `RunCommandRunner` (shells out to
`container network create`).  The `Runtime.createNetwork` seam is only exercised
by the API server routes.

This means the tests in `NetworkRuntimeOperationsTests.swift` test the **HTTP
route contract** but not the **`compose up` integration**.  A future PR should
wire `ComposeUp` through `Runtime.createNetwork` so the seam is exercised
end-to-end.

### 2.2 Both real conformers throw `.notSupported` for network CRUD

`BridgeContainerClientRuntime.createNetwork` and
`AppleContainerizationRuntime.createNetwork` both throw
`RuntimeError.notSupported`.  The tests in `NetworkRuntimeOperationsTests.swift`
document this by asserting the known `.notSupported` error on the conformer
directly, and by verifying that the route handler surfaces HTTP 501 when the
injected runtime throws `.notSupported`.

The tests are intentionally designed to **pass today** while accurately documenting
that these operations are not yet implemented at the conformer level.

### 2.3 `RecordingRuntime` extended minimally for error injection

To test the `.notSupported` degradation path through the `POST /networks` and
`DELETE /networks/{id}` routes, `RecordingRuntime` was extended with two new
constructor parameters:

- `createNetworkError: RuntimeError?` — if set, `createNetwork(spec:)` throws
  this error before recording the call.
- `removeNetworkError: RuntimeError?` — if set, `removeNetwork(id:)` throws
  this error before checking `stubbedNetworks`.

Both parameters default to `nil`, preserving all existing behavior.

---

## 3. Other Observations

### 3.1 No IPAM field in `RuntimeNetwork` or `RuntimeCreateNetworkSpec.subnet/gateway`

`RuntimeCreateNetworkSpec` carries `subnet` and `gateway` fields, but
`RuntimeNetwork` (the returned type) does not carry them.  A post-creation
assertion that the subnet was "stored" is not possible without inspecting
the spec inside the conformer.  The test for IPAM in
`NetworkRuntimeOperationsTests` therefore only verifies that the route returns
201 without error, not that the subnet is preserved.

`TODO(CHAOS-1409)`: Add `subnet` and `gateway` to `RuntimeNetwork` and assert
they are preserved by `MockRuntime.createNetwork`.

### 3.2 `userns_mode` missing from security integration tests

`Service.userns_mode` is decoded and warn-and-skipped by `SecurityArgs`.
It is not covered by `SecurityFeatureIntegrationTests` because the pattern is
identical to `security_opt` and `group_add`.  It IS covered by the existing
unit test `SecurityArgsTests.usernsModeWarnsOnceAndEmitsNoUnsupportedFlags`.
No additional integration test is needed unless the behavior changes.

### 3.3 Warn-once semantics interact with test isolation

`SecurityArgs.build()` uses a `warnUnsupportedRuntimeFieldOnce(_:_:)` helper
that suppresses duplicate warnings across calls in the same process.  Tests that
check for warning output must run with `.serialized` (which
`SecurityFeatureIntegrationTests` does) and should be aware that the first test
to trigger a given warning will consume it.  If a future test expects a warning
for `privileged` after another test already triggered it, the warning will not
appear.  The existing `SecurityArgsTests` is also `.serialized` for this reason.

---

## 4. Files Created / Modified in This PR

| File | Type | Action |
|---|---|---|
| `Tests/Container-Compose-StaticTests/NetworkRuntimeOperationsTests.swift` | Test | Created |
| `Tests/Container-Compose-StaticTests/SecurityFeatureIntegrationTests.swift` | Test | Created |
| `Tests/TestHelpers/RecordingRuntime.swift` | TestHelper | Extended (2 new init params) |
| `docs/reviews/phase1-remainder-test-gaps.md` | Audit doc | Created |
