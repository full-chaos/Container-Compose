# Naming Consistency Audit — CHAOS-1396 follow-up
Date: 2026-05-03

## Summary
Audited 14 command files (all `Compose*.swift` except `ComposeUp.swift` and `ComposeDown.swift`).
Found 9 instances of the bug pattern across 8 files; fixed all of them.
5 files were already clean (no container-name construction at all, or correct use of `effectiveContainerName`).

## Files audited
| File | Status | Notes |
|---|---|---|
| `ComposeCreate.swift` | fixed | replaced ad-hoc `if/else` at line ~352 |
| `ComposeExec.swift` | fixed | replaced ad-hoc `if/else` at line ~139 |
| `ComposeKill.swift` | fixed | replaced ad-hoc `if/else` in `killServices` at line ~134 |
| `ComposePs.swift` | fixed | replaced `??` inline at line ~122 |
| `ComposeRm.swift` | fixed | replaced ad-hoc `if/else` in `removeServices` at line ~153 |
| `ComposeStart.swift` | fixed | replaced ad-hoc `if/else` in `startServices` at line ~133 |
| `ComposeStop.swift` | fixed | replaced ad-hoc `if/else` in `stopServices` at line ~130 |
| `ComposeLogs.swift` | fixed | replaced `??` inline in `targets` map at line ~150 |
| `ComposeEvents.swift` | fixed | replaced `??` inline in `targetNames` set at line ~135 |
| `ComposeRestart.swift` | clean | delegates entirely to `ComposeStop.stopServices` + `ComposeStart.startServices`; no direct name construction |
| `ComposeBuild.swift` | clean | no container name construction (build does not run containers) |
| `ComposeRun.swift` | clean | one-off container uses intentional `<project>-<service>-run-<uuid>` pattern; `container_name` is deliberately not honored for throw-away containers |
| `ComposeTop.swift` | clean | builds `baseName`+`explicitName` tuple for pattern-matching against runtime container IDs; both fields needed for `hasPrefix` range-match (replica suffix detection) — not a name-construction bug |
| `ComposePull.swift` | clean | no container name construction (pull operates on images) |
| `ComposePort.swift` | clean | no container name construction |
| `ComposePush.swift` | clean | no container name construction |
| `ComposeConfig.swift` | clean | no container name construction |
| `ComposeLs.swift` | clean | no container name construction (list operates on running projects) |
| `ComposeWatch.swift` | clean | no container name construction |
| `ComposeServe.swift` | clean | no container name construction |
| `ComposeSystem.swift` | clean | no container name construction |

## Bug patterns found

### Pattern A — ad-hoc `if/else` (7 occurrences)
```swift
let containerName: String
if let explicitName = service.container_name {
    containerName = explicitName
} else {
    containerName = "\(projectName)-\(serviceName)"
}
```
Found in: `ComposeCreate`, `ComposeExec`, `ComposeKill`, `ComposeRm`, `ComposeStart`, `ComposeStop`.
`ComposeCreate` additionally printed `"Info: Using explicit container_name: \(containerName)"` inside the branch — this info log was removed by the replacement since `effectiveContainerName` does not emit any output, and the log was not tested or load-bearing.

### Pattern B — inline `??` (2 occurrences)
```swift
service.container_name ?? "\(projectName)-\(serviceName)"
```
Found in: `ComposePs` (in `targetNames` set), `ComposeLogs` (in `targets` map), `ComposeEvents` (in `targetNames` set).

Both patterns have the same defect: an empty `container_name: ""` in the compose file would result in using `""` as the container name instead of falling back to `<project>-<service>`. `effectiveContainerName` treats empty strings as absent, matching `resolveProjectName`'s semantics.

## Lessons
1. **The helper existed but was not used.** `effectiveContainerName` was introduced for CHAOS-1396 but only wired into `ComposeUp` and `ComposeDown`. All sibling commands had copy-pasted the two-line inline pattern without adopting the helper.
2. **Two surface forms of the same bug.** The `if/else` block and the `??` shorthand are semantically equivalent for non-empty `container_name`, but both fail on `container_name: ""`. A single helper call eliminates both forms.
3. **`ComposeTop`'s matching pattern is intentionally different.** It maintains `baseName` and `explicitName` as separate tuple fields to support prefix-based replica matching (`project-service-1`, `project-service-2`, …). This is a legitimate pattern for matching containers that already exist in the runtime, not for constructing new names.
4. **`ComposeRun` is intentionally exempt.** One-off `run` containers use a UUID suffix by design; `container_name` from the service definition is not intended to apply.
5. **`ComposeRestart` needed no changes** because it fully delegates to `ComposeStop.stopServices` and `ComposeStart.startServices` — fixing those two was sufficient.
