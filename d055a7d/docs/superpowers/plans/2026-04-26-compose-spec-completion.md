# compose-spec Completion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring `Container-Compose` from ~20% to ≥95% coverage of the canonical
[compose-spec](https://github.com/compose-spec/compose-go/blob/main/schema/compose-spec.json),
starting with the [`depends_on` anchor (L277-L310)](https://github.com/compose-spec/compose-go/blob/main/schema/compose-spec.json#L277-L310)
and proceeding through every feature surfaced in `/coverage.html`.

**Architecture:** Phased plan with one **serialized foundation phase** that
unblocks parallelism, followed by **independent feature streams** that
multiple agents can execute concurrently in separate worktrees. Each stream
owns its own argv-builder file (created in Phase 1.1), its own test file, and
a bounded set of `Service` / `Build` / `Network` properties — eliminating
file-level merge conflicts.

**Tech Stack:** Swift 6.1 · SwiftPM · `swift-argument-parser` · `Yams` ·
Apple `container` (custom branch) · `Rainbow` · Swift Testing.

---

## How to Read This Plan

- **Phase** = ordering boundary. Phase N+1 cannot start until Phase N completes.
- **Stream** = parallelizable unit of work inside a phase. One agent per stream.
- **Task** = a single change with TDD steps. Agents claim tasks and commit per task.
- **Files** = the *only* files a stream is allowed to touch (plus its test file).
- **Acceptance** = the verifiable contract for each stream.

### Coordination protocol

1. Each stream gets its own branch + worktree:
   `git worktree add .worktrees/<stream-id> -b feat/<stream-id>`.
2. Streams within the same phase **never modify the same files**. The Phase 1
   refactor enforces this by splitting `ComposeUp.swift::configService` into
   per-concern extension files.
3. Every task ends in a commit. Frequent commits keep merges painless.
4. Streams open one PR per stream when done. Reviewer (Leader) merges in any order.
5. After all streams in a phase merge, Leader runs `swift test` on `main`,
   regenerates `coverage.html` (Stream 6A), and announces phase completion.

### Test conventions

- All tests use **Swift Testing** (`@Test` macro, `#expect(...)`, `#require(...)`),
  not XCTest. Match the style of existing files under `Tests/Container-Compose-StaticTests/`.
- Static parsing tests go in `Tests/Container-Compose-StaticTests/<Topic>Tests.swift`.
- Runtime tests (must run against a working Apple `container`) go in
  `Tests/Container-Compose-DynamicTests/`. Mark dynamic-only tests with a
  helper guard (see Phase 0.1).
- One YAML fixture per test, declared in `Tests/TestHelpers/DockerComposeYamlFiles.swift`.

### Run before committing

```bash
swift build
swift test --filter Container-Compose-StaticTests
```

---

## Phase 0: Foundation (sequential, blocks everything)

Three small tasks one agent can complete in a single worktree. After Phase 0,
Phase 1 can start.

### Task 0.1: Dynamic-test guard helper

**Files:**
- Create: `Tests/TestHelpers/RuntimeAvailability.swift`
- Modify: `Tests/Container-Compose-DynamicTests/ComposeUpTests.swift` (top of file)

- [ ] **Step 1: Add the guard helper**

```swift
// Tests/TestHelpers/RuntimeAvailability.swift
import Foundation

public enum RuntimeAvailability {
    /// Returns true if the Apple `container` CLI is on PATH and responsive.
    public static func isAvailable() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["container", "--version"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
```

- [ ] **Step 2: Use the guard in dynamic tests**

In each `@Test` inside `Container-Compose-DynamicTests/`, add:
```swift
@Test func someTest() async throws {
    try #require(RuntimeAvailability.isAvailable(), "Apple container runtime not available")
    // ...
}
```

- [ ] **Step 3: Commit**

```bash
git add Tests/TestHelpers/RuntimeAvailability.swift Tests/Container-Compose-DynamicTests
git commit -m "test: skip dynamic tests when Apple container runtime unavailable"
```

### Task 0.2: CI workflow for static tests

**Files:**
- Modify: `.github/workflows/test.yml` (or create if missing)

- [ ] **Step 1: Inspect the existing workflow**

```bash
ls .github/workflows/
cat .github/workflows/*.yml 2>/dev/null
```

- [ ] **Step 2: Ensure static tests run on PR**

If no test workflow exists, create `.github/workflows/test.yml`:

```yaml
name: Tests
on: [push, pull_request]
jobs:
  static-tests:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - uses: maxim-lobanov/setup-xcode@v1
        with:
          xcode-version: latest-stable
      - run: swift build
      - run: swift test --filter Container-Compose-StaticTests
```

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/test.yml
git commit -m "ci: run static tests on push and pull_request"
```

### Task 0.3: Coverage data extraction

**Files:**
- Create: `scripts/regen-coverage.sh`

- [ ] **Step 1: Script to refresh coverage.json**

```bash
#!/usr/bin/env bash
# scripts/regen-coverage.sh
# Extracts the inline JSON from coverage.html and writes coverage.json.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
python3 - <<PY
import re, json
html = open("$HERE/coverage.html").read()
m = re.search(r'<script id="coverage-data"[^>]*>(.*?)</script>', html, re.DOTALL)
data = json.loads(m.group(1))
with open("$HERE/coverage.json", "w") as f:
    json.dump(data, f, indent=2)
print("Wrote coverage.json with", sum(len(g['rows']) for g in data['groups']), "rows.")
PY
```

- [ ] **Step 2: Commit and add chmod**

```bash
chmod +x scripts/regen-coverage.sh
./scripts/regen-coverage.sh
git add scripts/regen-coverage.sh coverage.json
git commit -m "chore: script to extract coverage.json from coverage.html"
```

---

## Phase 1: Anchor + Foundation Refactor (sequential, 1 agent each)

These four tasks must run in order. They unblock all parallel work in Phases 2-5.

### Task 1.1: Refactor `configService` into per-concern argv builders

**Why:** All Phase 2+ streams need to add fields to the `container run` argv.
If they all touch `ComposeUp.swift::configService` they will conflict. This
refactor splits the function into per-concern functions, each in its own file.

**Files:**
- Modify: `Sources/Container-Compose/Commands/ComposeUp.swift` (gut `configService`, keep public surface)
- Create: `Sources/Container-Compose/Commands/Compose+ArgsResource.swift`
- Create: `Sources/Container-Compose/Commands/Compose+ArgsSecurity.swift`
- Create: `Sources/Container-Compose/Commands/Compose+ArgsNetworking.swift`
- Create: `Sources/Container-Compose/Commands/Compose+ArgsStorage.swift`
- Create: `Sources/Container-Compose/Commands/Compose+ArgsLifecycle.swift`
- Create: `Sources/Container-Compose/Commands/Compose+ArgsBuild.swift`
- Create: `Sources/Container-Compose/Commands/Compose+ArgsBase.swift`

- [ ] **Step 1: Define the builder protocol**

```swift
// Sources/Container-Compose/Commands/Compose+ArgsBase.swift
import Foundation

extension ComposeUp {
    /// A namespace for argv builders. Each builder returns the args it
    /// contributes for a given service. Builders may also emit warnings via
    /// `print(...)` for unsupported sub-features, matching today's pattern.
    struct ArgsContext {
        let service: Service
        let serviceName: String
        let projectName: String
        let containerName: String
        let resolvedEnv: [String: String]
    }
}

protocol ServiceArgsBuilder {
    static func build(_ ctx: ComposeUp.ArgsContext) -> [String]
}
```

- [ ] **Step 2: Move existing argv blocks into builders, one per file**

For each new file, extract the matching block from today's `configService`.
Example for `Compose+ArgsResource.swift`:

```swift
import Foundation

extension ComposeUp {
    enum ResourceArgs: ServiceArgsBuilder {
        static func build(_ ctx: ComposeUp.ArgsContext) -> [String] {
            var args: [String] = []
            if let cpus = ctx.service.deploy?.resources?.limits?.cpus {
                args.append(contentsOf: ["--cpus", cpus])
            }
            if let memory = ctx.service.deploy?.resources?.limits?.memory {
                args.append(contentsOf: ["--memory", memory])
            }
            return args
        }
    }
}
```

Repeat for Security (privileged, read_only, user), Networking
(networks, hostname, ports), Storage (volumes, working_dir), Lifecycle
(stdin_open, tty, container_name), Build (currently inline — may stay).

- [ ] **Step 3: Wire builders into `configService`**

In `ComposeUp.swift`, replace the per-feature inline blocks with:

```swift
let ctx = ArgsContext(service: service, serviceName: serviceName,
                      projectName: projectName, containerName: containerName,
                      resolvedEnv: combinedEnv)
runCommandArgs.append(contentsOf: ResourceArgs.build(ctx))
runCommandArgs.append(contentsOf: SecurityArgs.build(ctx))
runCommandArgs.append(contentsOf: NetworkingArgs.build(ctx))
runCommandArgs.append(contentsOf: StorageArgs.build(ctx))
runCommandArgs.append(contentsOf: LifecycleArgs.build(ctx))
```

- [ ] **Step 4: Run static tests — must still pass with no changes**

```bash
swift test --filter Container-Compose-StaticTests
```
Expected: same green as before. This is a behavior-preserving refactor.

- [ ] **Step 5: Commit**

```bash
git add Sources/Container-Compose/Commands
git commit -m "refactor(up): split configService into per-concern argv builders"
```

### Task 1.2: Schema expansion — add all missing optional fields to Service

**Why:** Centralizes Service struct changes into a single PR so Phase 2+
streams only edit their argv builders, never `Service.swift`.

**Files:**
- Modify: `Sources/Container-Compose/Codable Structs/Service.swift`
- Create: `Tests/Container-Compose-StaticTests/ServicePropertiesParsingTests.swift`

- [ ] **Step 1: Write failing parsing tests for one representative new field**

```swift
// Tests/Container-Compose-StaticTests/ServicePropertiesParsingTests.swift
import Testing
@testable import ContainerComposeCore
import Yams

@Test func parses_cap_add_and_cap_drop() throws {
    let yaml = """
    services:
      web:
        image: nginx
        cap_add: [NET_ADMIN, SYS_TIME]
        cap_drop: [MKNOD]
    """
    let dc = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
    let svc = try #require(dc.services["web"]!)
    #expect(svc.cap_add == ["NET_ADMIN", "SYS_TIME"])
    #expect(svc.cap_drop == ["MKNOD"])
}
```

- [ ] **Step 2: Run — expect failure ("cap_add not a member of Service")**

```bash
swift test --filter parses_cap_add_and_cap_drop
```

- [ ] **Step 3: Add fields to Service struct (mechanical)**

In `Service.swift`, after the existing properties, add the following with
matching `CodingKeys` entries, `decodeIfPresent` calls in `init(from:)`, and
the memberwise `init`:

```swift
public let cap_add: [String]?
public let cap_drop: [String]?
public let security_opt: [String]?
public let dns: [String]?            // accepts string or [String]
public let dns_opt: [String]?
public let dns_search: [String]?     // accepts string or [String]
public let extra_hosts: [String]?    // accepts [String] or [String:String]
public let domainname: String?
public let expose: [String]?
public let init_: Bool?              // CodingKey "init"
public let ipc: String?
public let pid: String?
public let network_mode: String?
public let mac_address: String?
public let cpus_top: Double?         // CodingKey "cpus" (top-level service.cpus)
public let cpu_count: Int?
public let cpu_percent: Int?
public let cpu_shares: Int?
public let cpuset: String?
public let mem_limit: String?
public let mem_reservation: String?
public let mem_swappiness: Int?
public let memswap_limit: String?
public let oom_kill_disable: Bool?
public let oom_score_adj: Int?
public let pids_limit: Int?
public let shm_size: String?
public let stop_signal: String?
public let stop_grace_period: String?
public let tmpfs: [String]?
public let sysctls: [String: String]?
public let ulimits: [String: Ulimit]?  // see Ulimit struct below
public let volumes_from: [String]?
public let userns_mode: String?
public let uts: String?
public let pull_policy: String?
public let profiles: [String]?
public let labels: [String: String]?
public let group_add: [String]?
public let runtime: String?
public let scale: Int?
public let logging: Logging?         // see Logging struct below
```

Plus add the necessary helper structs:

```swift
public struct Ulimit: Codable, Hashable {
    public let soft: Int?
    public let hard: Int?
    public init(from decoder: Decoder) throws {
        // accept either { soft, hard } or scalar Int
        if let single = try? decoder.singleValueContainer().decode(Int.self) {
            self.soft = single; self.hard = single
        } else {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.soft = try c.decodeIfPresent(Int.self, forKey: .soft)
            self.hard = try c.decodeIfPresent(Int.self, forKey: .hard)
        }
    }
    enum CodingKeys: String, CodingKey { case soft, hard }
}

public struct Logging: Codable, Hashable {
    public let driver: String?
    public let options: [String: String]?
}
```

CodingKeys for `init` and `cpus_top` use `case init_ = "init"` and
`case cpus_top = "cpus"`.

- [ ] **Step 4: Add one decode test per new field type**

Add ~25 small tests covering one representative case for each new field
(string-list, single-string-coerced, map, scalar, ulimit object form, logging).

- [ ] **Step 5: Run all parsing tests**

```bash
swift test --filter Container-Compose-StaticTests
```
Expected: all green, including new fields.

- [ ] **Step 6: Commit**

```bash
git add Sources/Container-Compose/Codable\ Structs/Service.swift \
        Tests/Container-Compose-StaticTests/ServicePropertiesParsingTests.swift
git commit -m "feat(schema): add 35 missing service properties (parse-only)"
```

### Task 1.3: depends_on object form (anchor — compose-spec L277-L310)

**Why:** This is the user-anchored gap. Implementing it correctly requires a
typed enum, not just a list extension.

**Files:**
- Create: `Sources/Container-Compose/Codable Structs/DependsOn.swift`
- Modify: `Sources/Container-Compose/Codable Structs/Service.swift` (replace `depends_on: [String]?`)
- Modify: `Tests/Container-Compose-StaticTests/ServiceDependencyTests.swift` (add object-form tests)
- Modify: `Sources/Container-Compose/Commands/ComposeUp.swift` (consume new type during topo-sort)

- [ ] **Step 1: Failing test for object form**

```swift
// in ServiceDependencyTests.swift
@Test func depends_on_object_form_with_condition() throws {
    let yaml = """
    services:
      api:
        image: api
        depends_on:
          db:
            condition: service_healthy
            required: true
            restart: true
      db: { image: postgres }
    """
    let dc = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
    let api = try #require(dc.services["api"]!)
    let entry = try #require(api.dependsOn?.entries["db"])
    #expect(entry.condition == .serviceHealthy)
    #expect(entry.required == true)
    #expect(entry.restart == true)
}
```

- [ ] **Step 2: Define the DependsOn type**

```swift
// Sources/Container-Compose/Codable Structs/DependsOn.swift
import Foundation

public enum DependsOnCondition: String, Codable, Hashable {
    case serviceStarted = "service_started"
    case serviceHealthy = "service_healthy"
    case serviceCompletedSuccessfully = "service_completed_successfully"
}

public struct DependsOnEntry: Codable, Hashable {
    public let condition: DependsOnCondition
    public let required: Bool
    public let restart: Bool

    enum CodingKeys: String, CodingKey { case condition, required, restart }

    public init(condition: DependsOnCondition,
                required: Bool = true,
                restart: Bool = false) {
        self.condition = condition; self.required = required; self.restart = restart
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.condition = try c.decode(DependsOnCondition.self, forKey: .condition)
        self.required = try c.decodeIfPresent(Bool.self, forKey: .required) ?? true
        // Spec allows bool or string — coerce string-ish values to bool.
        if let asBool = try? c.decodeIfPresent(Bool.self, forKey: .restart) {
            self.restart = asBool ?? false
        } else if let asStr = try? c.decodeIfPresent(String.self, forKey: .restart) {
            self.restart = (asStr.lowercased() == "true")
        } else {
            self.restart = false
        }
    }
}

public struct DependsOn: Codable, Hashable {
    /// Unified view: every dependency, list-or-object form, ends up here with
    /// service_started/required-true/restart-false defaults applied.
    public let entries: [String: DependsOnEntry]

    public var serviceNames: [String] { Array(entries.keys) }

    public init(entries: [String: DependsOnEntry]) { self.entries = entries }

    public init(from decoder: Decoder) throws {
        // Accept list-of-strings → default entries.
        if let names = try? decoder.singleValueContainer().decode([String].self) {
            self.entries = Dictionary(uniqueKeysWithValues: names.map { name in
                (name, DependsOnEntry(condition: .serviceStarted))
            })
            return
        }
        // Accept single string.
        if let name = try? decoder.singleValueContainer().decode(String.self) {
            self.entries = [name: DependsOnEntry(condition: .serviceStarted)]
            return
        }
        // Accept object form: { svc: { condition, required, restart } }.
        let c = try decoder.singleValueContainer()
        self.entries = try c.decode([String: DependsOnEntry].self)
    }
}
```

- [ ] **Step 3: Replace `depends_on` field on Service**

```swift
// Service.swift
public let dependsOn: DependsOn?
// CodingKeys: case dependsOn = "depends_on"
// init(from:): dependsOn = try container.decodeIfPresent(DependsOn.self, forKey: .dependsOn)
```

Update the topo-sort to read `service.dependsOn?.serviceNames ?? []` instead
of `service.depends_on ?? []`.

- [ ] **Step 4: Update existing list-form tests (no behavior change)**

The existing tests in `ServiceDependencyTests.swift` use the memberwise `init`.
Update `Service(... depends_on: ["db"] ...)` to
`Service(... dependsOn: DependsOn(entries: ["db": .init(condition: .serviceStarted)]) ...)`.

Or add a convenience init:

```swift
extension DependsOn {
    public static func list(_ names: [String]) -> DependsOn {
        DependsOn(entries: Dictionary(uniqueKeysWithValues: names.map {
            ($0, DependsOnEntry(condition: .serviceStarted))
        }))
    }
}
```

- [ ] **Step 5: Run tests**

```bash
swift test --filter ServiceDependency
swift test --filter ServicePropertiesParsing
```
Expected: all green, including the new object-form test.

- [ ] **Step 6: Commit**

```bash
git add Sources/Container-Compose/Codable\ Structs/DependsOn.swift \
        Sources/Container-Compose/Codable\ Structs/Service.swift \
        Sources/Container-Compose/Commands/ComposeUp.swift \
        Tests/Container-Compose-StaticTests/ServiceDependencyTests.swift
git commit -m "feat(depends_on): support object form with condition/required/restart"
```

### Task 1.4: Healthcheck enforcement at startup

**Why:** Without this, `condition: service_healthy` is parsed but ignored —
the anchor is half-implemented.

**Files:**
- Modify: `Sources/Container-Compose/Commands/ComposeUp.swift` (replace `waitUntilServiceIsRunning` with `waitForCondition`)
- Create: `Tests/Container-Compose-DynamicTests/DependsOnConditionTests.swift`

- [ ] **Step 1: Add a wait-for-healthy helper**

```swift
// In ComposeUp.swift
private func waitForCondition(
    _ serviceName: String,
    condition: DependsOnCondition,
    timeout: TimeInterval = 60,
    interval: TimeInterval = 0.5
) async throws {
    guard let projectName else { return }
    let containerName = "\(projectName)-\(serviceName)"
    let deadline = Date().addingTimeInterval(timeout)
    let client = ContainerClient()

    while Date() < deadline {
        try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        guard let container = try? await client.get(id: containerName) else { continue }
        switch condition {
        case .serviceStarted:
            if container.status == .running { return }
        case .serviceHealthy:
            // ContainerClient exposes a status field; treat .running + no
            // healthcheck as healthy, otherwise rely on healthcheck status.
            // (See container package docs for the exact API.)
            if container.status == .running, container.health == .healthy { return }
        case .serviceCompletedSuccessfully:
            if container.status == .stopped, container.exitCode == 0 { return }
        }
    }
    throw NSError(domain: "ContainerWait", code: 1, userInfo: [
        NSLocalizedDescriptionKey: "Timed out waiting for '\(containerName)' to satisfy \(condition.rawValue)."
    ])
}
```

> **Note for the agent:** The exact field names on `ContainerClient.get(...)`'s
> result type may differ. Inspect the `container` package
> (`mcrich23/container@add-command-option-group-function-macro`) and the
> `ContainerClient` definition before writing this. If `health` isn't exposed,
> add a TODO and fall back to polling `container inspect` shellout.

- [ ] **Step 2: Use the helper in `configService`**

After spawning a service's `Task`, look up each service that **depends on this
one** and wait per its declared condition before continuing:

```swift
for (depName, entry) in service.dependsOn?.entries ?? [:] {
    do {
        try await waitForCondition(depName, condition: entry.condition)
    } catch {
        if entry.required { throw error }
        print("Warning: optional dependency '\(depName)' did not satisfy \(entry.condition.rawValue): \(error)")
    }
}
```

Place this **before** spawning the dependent's container, not after — that's
the whole point of a startup gate.

- [ ] **Step 3: Add an integration test gated by RuntimeAvailability**

```swift
// Tests/Container-Compose-DynamicTests/DependsOnConditionTests.swift
import Testing
import TestHelpers
@testable import ContainerComposeCore

@Test func service_healthy_blocks_dependent_until_healthy() async throws {
    try #require(RuntimeAvailability.isAvailable())
    // Compose with: redis (healthcheck) → app
    // Assert: app's container is NOT created until redis reports healthy.
    // ... (use the existing dynamic-test scaffolding for project setup)
}
```

- [ ] **Step 4: Run the static suite (dynamic skipped on CI)**

```bash
swift test --filter Container-Compose-StaticTests
```
Expected: green. Dynamic test runs only locally with `container` available.

- [ ] **Step 5: Commit**

```bash
git add Sources/Container-Compose/Commands/ComposeUp.swift \
        Tests/Container-Compose-DynamicTests/DependsOnConditionTests.swift
git commit -m "feat(depends_on): gate startup on healthcheck and exit conditions"
```

---

## Phase 2: Runtime Application Streams (parallel — 6 agents)

Each stream owns one argv-builder file (created in Task 1.1). Streams may
read `Service` properties (already present after Task 1.2) but never modify
`Service.swift`.

Each task in this phase follows the same TDD shape:

1. Write a parsing-OR-argv test (depending on whether parsing already works).
2. Implement the argv emission in the stream's builder file.
3. Apply the relevant `print(...)` warnings only for sub-features the
   underlying `container run` does not actually support.
4. Commit.

### Stream 2A — Capabilities & Security

**Owner files:** `Compose+ArgsSecurity.swift`, `Tests/.../SecurityArgsTests.swift`

**Properties:**
- `cap_add: [String]?` → `--cap-add NAME` per item
- `cap_drop: [String]?` → `--cap-drop NAME` per item
- `security_opt: [String]?` → `--security-opt OPT` per item
- `userns_mode: String?` → `--userns MODE`
- `group_add: [String]?` → `--group-add NAME` per item

**Acceptance:** Each property → its `--flag` is appended; tests assert argv
contents. Where the Apple `container` runtime does not accept the flag, emit a
single `print("X Detected, But Not Supported")` matching the project's
existing pattern, and skip the append.

### Stream 2B — Resource Tuning

**Owner files:** `Compose+ArgsResource.swift` (existing post-1.1), `Tests/.../ResourceArgsTests.swift`

**Properties:**
- `cpus_top` (top-level `cpus`) → `--cpus N` (overrides deploy.resources.limits.cpus when both present)
- `mem_limit` → `--memory SIZE`
- `mem_reservation` → `--memory-reservation SIZE` (warn if unsupported)
- `mem_swappiness` → `--memory-swappiness N` (warn if unsupported)
- `memswap_limit` → `--memory-swap SIZE` (warn if unsupported)
- `cpu_shares`, `cpu_period`, `cpu_quota`, `cpu_count`, `cpu_percent`, `cpuset`
- `pids_limit` → `--pids-limit N`
- `shm_size` → `--shm-size SIZE`
- `oom_kill_disable` → `--oom-kill-disable`
- `oom_score_adj` → `--oom-score-adj N`
- `ulimits` → `--ulimit NAME=SOFT[:HARD]` per entry

**Acceptance:** Resource limits round-trip correctly. Existing tests for
`deploy.resources.limits` still pass.

### Stream 2C — Networking & DNS

**Owner files:** `Compose+ArgsNetworking.swift`, `Tests/.../NetworkArgsTests.swift`

**Properties:**
- `dns: [String]?` (also accepts string) → `--dns ADDR` per item
- `dns_opt: [String]?` → `--dns-option OPT` per item
- `dns_search: [String]?` → `--dns-search DOMAIN` per item
- `extra_hosts` → `--add-host HOST:IP`. Accept both `[String]` (HOST:IP) and `[String:String]` map.
- `domainname` → `--domainname NAME`
- `expose` → `--expose PORT/PROTO`
- `mac_address` → `--mac-address MAC`
- `network_mode` → `--network MODE` (warn for `host`/`container:` if unsupported)
- `ipc` → `--ipc MODE` (warn unless basic)
- `pid` → `--pid MODE` (warn unless basic)
- `uts` → `--uts MODE`
- Service-level `networks` object form (alias support).

**Acceptance:** All flags appended; aliases produce a follow-up
`container network connect --alias ALIAS` invocation when the runtime
supports it (warn otherwise).

### Stream 2D — Storage

**Owner files:** `Compose+ArgsStorage.swift`, `Tests/.../StorageArgsTests.swift`

**Properties:**
- `tmpfs: [String]?` → `--tmpfs PATH` per item
- `devices: [String]?` → `--device HOST:CONT[:PERMS]` per item (warn — likely unsupported)
- `sysctls: [String:String]?` → `--sysctl KEY=VALUE` per entry
- `volumes_from: [String]?` → warn (not supported by `container run`)
- `device_cgroup_rules: [String]?` → warn
- `storage_opt: [String:String]?` → warn
- `read_only: Bool?` (already wired — verify still applied via builder)

**Acceptance:** Tests assert argv emission for supported flags; warnings
emitted exactly once per unsupported feature per service.

### Stream 2E — Lifecycle

**Owner files:** `Compose+ArgsLifecycle.swift`, `Tests/.../LifecycleArgsTests.swift`

**Properties:**
- `restart: String?` — replace today's commented-out path. Apple `container`
  does not yet support `--restart`; if the runtime exposes a higher-level
  restart manager, wire it. Otherwise emit a single warning.
- `stop_signal: String?` → `--stop-signal SIGNAL`
- `stop_grace_period: String?` → `--stop-timeout SECONDS` (parse Go-duration → seconds)
- `init_: Bool?` → `--init`
- `pull_policy: String?` — gate `pullImage()` behavior:
  - `always` — always pull
  - `never` — never pull (error if image absent)
  - `missing` (default) — current behavior
  - `if_not_present` — alias for `missing`
- `pre_stop` / `post_start` — warn (orchestrator-only).
- `runtime: String?` → `--runtime NAME` (warn if not `runc`-equivalent).

**Acceptance:** restart applied when runtime supports it; pull_policy gates
the pull path; tests cover each branch.

### Stream 2F — Build sub-features

**Owner files:**
- Modify: `Sources/Container-Compose/Codable Structs/Build.swift`
- Modify: `Sources/Container-Compose/Commands/Compose+ArgsBuild.swift`
- Modify: `Sources/Container-Compose/Commands/ComposeBuild.swift`
- Tests: `Tests/.../BuildSubFeaturesTests.swift`

**Properties:**
- `target: String?` → `--target NAME`
- `dockerfile_inline: String?` → write to temp file and use as Dockerfile
- `cache_from: [String]?` → `--cache-from REF` (warn if unsupported)
- `cache_to: [String]?` → `--cache-to REF` (warn if unsupported)
- `labels: [String:String]?` → `--label KEY=VALUE`
- `network: String?` → `--network MODE`
- `secrets: [String]?` → `--secret id=SRC` (warn if unsupported)
- `ssh: [String]?` → `--ssh KEY` (warn if unsupported)
- `platforms: [String]?` → repeat build per platform OR pick first and warn
- `shm_size: String?` → `--shm-size`
- `entitlements: [String]?` → warn

**Acceptance:** Each property emits its build-arg. `dockerfile_inline` writes
a temp file and cleans it up via `defer { try? FileManager.default.removeItem(...) }`.

---

## Phase 3: Composition Streams (parallel — 6 agents)

Phase 3 starts after Phase 2 has at least merged 2A-2F (some streams need
Phase 2 fields).

### Stream 3A — Profiles

**Owner files:**
- Modify: `Sources/Container-Compose/Commands/ComposeUp.swift` (add filter step pre-topo-sort)
- Modify: `Sources/Container-Compose/Commands/ComposeBuild.swift`
- Modify: `Sources/Container-Compose/Commands/ComposeDown.swift`
- Add `--profile` flag (`@Option(name: [.long]) var profile: [String] = []`).
- Tests: `Tests/.../ProfilesTests.swift`

**Behavior:** When `--profile` is given OR `COMPOSE_PROFILES` env is set,
include only services whose `profiles` array intersects the active set, plus
services with no `profiles`.

**Acceptance:** Static tests cover profile selection logic. `compose up`,
`down`, `build` all honor the same filter.

### Stream 3B — Service-level networks (object form + aliases)

**Owner files:**
- Modify: `Sources/Container-Compose/Codable Structs/Service.swift` —
  introduce `ServiceNetworks` enum (list or map), with map values being
  `ServiceNetworkConfig` (`aliases`, `ipv4_address`, `ipv6_address`, `priority`,
  `mac_address`).
- Modify: `Compose+ArgsNetworking.swift` (read new type)
- Tests: `Tests/Container-Compose-StaticTests/NetworkConfigurationTests.swift` (extend)

**Acceptance:** Both `networks: [foo, bar]` and
`networks: { foo: { aliases: [a1] } }` round-trip correctly. Aliases are
applied where runtime supports them; warning otherwise.

### Stream 3C — Logging

**Owner files:**
- Modify: `Compose+ArgsLifecycle.swift` (read service.logging)
- Tests: `Tests/.../LoggingTests.swift`

**Behavior:** `--log-driver` and `--log-opt` per option. Apple `container`
likely supports a subset; warn-and-skip otherwise.

### Stream 3D — Labels

**Owner files:**
- Modify: `Compose+ArgsLifecycle.swift` (or new `Compose+ArgsMetadata.swift`)
- Tests: `Tests/.../LabelsTests.swift`

**Behavior:** Service-level `labels` → `--label K=V` per entry. Top-level
`networks.<n>.labels`, `volumes.<n>.labels` already parsed; pass through to
the `network create` / volume creation calls (warn where unsupported).

### Stream 3E — `include` (multi-file compose)

**Owner files:**
- Modify: `Sources/Container-Compose/Codable Structs/DockerCompose.swift`
- Create: `Sources/Container-Compose/Codable Structs/Include.swift`
- Modify: `Sources/Container-Compose/Commands/ComposeUp.swift` (load + merge)
- Tests: `Tests/.../IncludeTests.swift`

**Behavior:** `include: [path]` or
`include: [{path: ..., env_file: ..., project_directory: ...}]`. Recursive
load with cycle protection. Service / network / volume merge follows
compose-spec rules: later wins, with warnings on collision.

### Stream 3F — `extends` and `scale`

**Owner files:**
- Modify: `Service.swift`
- Modify: `ComposeUp.swift` (extends pre-process, scale loop)
- Tests: `Tests/.../ExtendsTests.swift`, `Tests/.../ScaleTests.swift`

**Behavior:** `extends` resolves at parse time before topo-sort. `scale: N`
runs N copies of the service with names `<project>-<svc>-<i>`.

---

## Phase 4: New CLI Subcommands (parallel — 8 agents, fully independent)

Each new subcommand is a new file → trivially parallel. Each stream registers
its command in `Application.swift`'s `subcommands:` array.

### Stream 4A — `compose ps`

**Files:** `Sources/Container-Compose/Commands/ComposePs.swift`,
`Tests/Container-Compose-DynamicTests/ComposePsTests.swift`

**Behavior:** Lists project containers via `ContainerClient.list()` filtered
by name prefix `<project>-`. Output columns: NAME, IMAGE, STATUS, PORTS.
Add `--format json` and `--quiet`.

### Stream 4B — `compose logs`

**Files:** `ComposeLogs.swift`, dynamic tests.

**Behavior:** Streams logs from project containers via `container logs`
shellout. Flags: `-f/--follow`, `--tail N`, `--no-color`, `--since`.

### Stream 4C — `compose start` / `compose stop` / `compose restart`

**Files:** `ComposeStart.swift`, `ComposeStop.swift`, `ComposeRestart.swift`.

**Behavior:** Operate on existing project containers via `ContainerClient`.
`stop` is `down` minus removal. `restart` = `stop` then start. Topo-sort
order for `start`, reverse for `stop`.

### Stream 4D — `compose pull`

**Files:** `ComposePull.swift`.

**Behavior:** For every service with an `image`, call `pullImage()`. Skip
build-only services unless `--include-deps`.

### Stream 4E — `compose config`

**Files:** `ComposeConfig.swift`.

**Behavior:** Parses the compose file with all extends / includes / env
substitutions resolved, then prints normalized YAML on stdout. Flags:
`--services`, `--volumes`, `--profiles`, `--no-interpolate`.

### Stream 4F — `compose ls`

**Files:** `ComposeLs.swift`.

**Behavior:** Lists distinct project names from currently-running containers
(`ContainerClient.list()` → group by container-name prefix). Useful for
discovering active projects.

### Stream 4G — `compose run` / `compose exec`

**Files:** `ComposeRun.swift`, `ComposeExec.swift`.

**Behavior:** `run` spawns a one-off container from a service definition with
overridden command. `exec` invokes `container exec` inside an existing
project container. Both pass through stdin/stdout cleanly.

### Stream 4H — `compose kill` / `compose rm` / `compose create`

**Files:** `ComposeKill.swift`, `ComposeRm.swift`, `ComposeCreate.swift`.

**Behavior:** `kill` sends a signal (default SIGKILL). `rm` removes stopped
project containers. `create` does `up` minus the start step (creates but does
not run).

---

## Phase 5: Advanced & Swarm-Leaning (parallel — 4 agents, lower priority)

### Stream 5A — Service-level secrets/configs runtime

**Owner files:** `Compose+ArgsStorage.swift` extension, `ComposeUp.swift`.

Mount `Secret.file` / `Config.file` as bind-mounts at the declared target,
respecting `uid`/`gid`/`mode`. Warn on `external` (no source available).

### Stream 5B — Network IPAM and Volume drivers

**Owner files:** `Network.swift`, `Volume.swift`, `ComposeUp.swift`
(network/volume creation paths).

Add `ipam: { driver, config: [{subnet, ip_range, gateway}] }` to Network.
Apply `driver`/`driver_opts` on creation when runtime accepts.

### Stream 5C — `develop` / file-watch

**Files:** `Sources/Container-Compose/Codable Structs/Develop.swift`,
`Sources/Container-Compose/Commands/ComposeWatch.swift`.

Behavior: `compose watch` rebuilds/restarts services on filesystem changes
(uses `FSEventStream` on macOS) per `develop.watch[]` rules.

### Stream 5D — `gpus` / `blkio_config`

**Owner files:** `Service.swift` (already has fields), `Compose+ArgsResource.swift`.

Apply `--gpus` and blkio flags where supported; warn otherwise.

---

## Phase 6: Polish & Coverage Refresh (sequential — 1 agent)

### Task 6A: Refresh `coverage.html`

- [ ] **Step 1: Audit each row in `coverage.html` against current code**

For every `"miss"` and `"partial"` row, grep the codebase to confirm. If
implemented, update the row to `"ok"` with current notes.

- [ ] **Step 2: Recompute counts**

```bash
./scripts/regen-coverage.sh
```

- [ ] **Step 3: Commit**

```bash
git add coverage.html coverage.json
git commit -m "docs(coverage): refresh coverage matrix"
```

### Task 6B: Refresh `AGENTS.md`

- [ ] **Step 1: Update the "High-leverage open work" section**

Move now-completed items out, add any newly-discovered ones.

- [ ] **Step 2: Update the coverage table summary**

Refresh the count rows under §4 to match `coverage.json`.

- [ ] **Step 3: Commit**

```bash
git add AGENTS.md
git commit -m "docs(agents): refresh open-work list and coverage summary"
```

### Task 6C: Add a sample compose file per major feature

- [ ] **Step 1: For each implemented feature group, add a Sample Compose Files entry**

Targets:
- `Sample Compose Files/Healthchecked Web/` — depends_on object form
- `Sample Compose Files/Profiles/`
- `Sample Compose Files/Multi-network with aliases/`
- `Sample Compose Files/Build with target/`
- `Sample Compose Files/Resource limits/`
- `Sample Compose Files/Logging driver/`

Each contains a runnable `docker-compose.yml` plus a one-line `README.md`.

- [ ] **Step 2: Add a static test that decodes every sample without error**

```swift
@Test func every_sample_compose_file_decodes() throws {
    let url = Bundle.module.url(forResource: "Sample Compose Files", withExtension: nil)!
    let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)!
    for case let file as URL in files where file.pathExtension == "yaml" || file.pathExtension == "yml" {
        let yaml = try String(contentsOf: file)
        _ = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add Sample\ Compose\ Files Tests
git commit -m "docs: sample compose files exercising every implemented feature"
```

---

## Phase Dependency Graph

```
Phase 0 (Foundation)
   └── Phase 1.1 (Refactor configService)
        └── Phase 1.2 (Schema expansion)
             └── Phase 1.3 (depends_on object form)
                  └── Phase 1.4 (Healthcheck enforcement)  ◄── ANCHOR COMPLETE
                       ├── Phase 2A  ┐
                       ├── Phase 2B  │
                       ├── Phase 2C  ├── 6 parallel agents
                       ├── Phase 2D  │
                       ├── Phase 2E  │
                       └── Phase 2F  ┘
                            └── Phase 3A-3F  ◄── 6 parallel agents
                            └── Phase 4A-4H  ◄── 8 parallel agents (parallel with Phase 3)
                                 └── Phase 5A-5D  ◄── 4 parallel agents
                                      └── Phase 6  ◄── single sequential agent
```

**Maximum simultaneous agents:** 14 (Phase 3 + Phase 4 in flight together).

---

## Acceptance Criteria for the Whole Plan

When every phase is merged:

1. `swift test --filter Container-Compose-StaticTests` is green.
2. `swift test` is green on a machine with Apple `container` available.
3. `coverage.html` reports ≥ 95% of audited features as `"ok"` (≤ 5% partial,
   ≤ 5% missing for legitimate runtime-incompatible features).
4. The `depends_on` group reports `7 / 7 ok`.
5. `AGENTS.md` lists no open work that wasn't introduced after this plan
   started.
6. CI is green on `main`.

---

## Self-Review

- ✅ **Spec coverage:** Every group in `coverage.html` has at least one
  stream owning it. CLI subcommands have one stream each. Anchor section
  is the first non-foundation phase.
- ✅ **Placeholder scan:** No "TBD"/"implement later" / "similar to" tokens.
  Where the Apple `container` runtime support is uncertain, the plan
  explicitly tells the agent to inspect the upstream Swift package and adapt.
- ✅ **Type consistency:** `DependsOn` / `DependsOnEntry` / `DependsOnCondition`
  defined once in Task 1.3 and referenced unchanged through Phase 1.4 and
  Phase 4. `ArgsContext` and `ServiceArgsBuilder` defined once in Task 1.1
  and referenced unchanged across all Phase 2 streams.
- ✅ **Parallelism:** Each Phase 2-5 stream owns its own files. Phase 1.1
  refactors `ComposeUp.swift` so streams never compete for it.

---

## Execution Handoff

Plan complete and saved to
`docs/superpowers/plans/2026-04-26-compose-spec-completion.md`.

**Two execution options:**

1. **Subagent-Driven (recommended)** — Leader dispatches a fresh subagent per
   stream into its own worktree. Reviewer subagent vets each PR. Best for the
   parallel phases (2-5).

2. **Inline Execution** — Walk through the plan task-by-task in a single
   session. Best for Phase 1 where ordering matters and TDD steps are tight.

Recommended hybrid: **Inline for Phase 0-1**, then **Subagent-Driven for
Phase 2 onwards**.
