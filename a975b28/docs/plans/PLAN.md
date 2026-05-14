# Container-Compose — Open Work

_Captured 2026-04-27. Living document; update or prune freely as items resolve._

## Status snapshot

**Closed**
- Three Swift 6 compiler warnings fixed → PR [#2](https://github.com/full-chaos/Container-Compose/pull/2), commit `5cbcc2a` on `fix/compiler-warnings`.
  - `DependsOnCondition` made `Sendable`
  - Dead `?? false` removed from `DependsOnEntry.init(from:)`
  - `var networkArgs` → `let` in `ComposeRun`

**Open** — everything below.

---

## 1. Bug: `--entrypoint` placed after the image name

### Symptom
Running `container-compose up` with `entrypoint: [/app/entrypoint.sh]` fails with
```
failed to find target executable --entrypoint
```
The runtime is treating `--entrypoint` as the in-container executable name, not as a flag.

### Root cause
The `container run` CLI (and Docker) interpret everything after the image as the in-container command. Our code appends the image first, then `--entrypoint <value>` after it — so the flag is parsed as a command.

### Affected sites
| File | Lines | Note |
|---|---|---|
| `Sources/Container-Compose/Commands/ComposeUp.swift` | 558–566 | Comment says "final argument before command/entrypoint" — intent is right, ordering is wrong |
| `Sources/Container-Compose/Commands/ComposeRun.swift` | 297–299 | Same inverted pattern |
| `Sources/Container-Compose/Commands/ComposeCreate.swift` | 420–422 | Same inverted pattern |

### Correct argv shape
For `entrypoint: [a, b, c]`:
```
container run [flags] --entrypoint a [more flags] <image> b c
```
- First element of `entrypoint` → value of `--entrypoint` (BEFORE image)
- Remaining elements → positional command args (AFTER image)
- If `command:` is also set, it's appended to the positional args

For the current user fixture (`entrypoint: [/app/entrypoint.sh]`, no `command`), the resulting argv is simply `--entrypoint /app/entrypoint.sh <image>`.

---

## 2. Test infrastructure gap

### What exists
- `Tests/Container-Compose-StaticTests/` — 20+ files asserting **YAML → struct** parsing. Strong coverage of the parser layer.
- `Tests/Container-Compose-DynamicTests/` — runtime tests gated on `RuntimeAvailability.isAvailable()`. **Skipped on CI** because Apple `container` isn't installed on the GitHub macOS runner.

### What's missing
No test asserts **struct → argv** — the command-builder layer where the entrypoint bug lives. Static tests stop at parsing; dynamic tests don't run on CI. The argv-construction code in `ComposeUp.swift` / `ComposeRun.swift` / `ComposeCreate.swift` has zero automated coverage.

### Three fidelity layers
| Layer | Asserts | CI cost | Catches the entrypoint-class bug? |
|---|---|---|---|
| A. Argv-shape tests (static) | Exact `[String]` passed to `container run` | Cheap — runs on current CI | ✅ |
| B. Recorder / fake runtime | End-to-end through a fake `RunCommand` that records its inputs | Medium — needs a protocol seam | ✅, broader; catches lifecycle bugs too |
| C. Self-hosted macOS runner with Apple container | Real container starts and exits 0 | Expensive — provisioning, runtime drift, flakes | ✅, highest fidelity |

---

## 3. Open decisions (need user input)

### 3.1 Bug-fix + test scope
1. Fix the entrypoint bug, add argv-shape test for that one site.
2. Audit all three call sites for the same inverted-ordering class, add `Tests/Container-Compose-StaticTests/CommandBuildArgvTests.swift` covering each.
3. Introduce a `RunCommandRecorder` seam so dynamic-style tests can run on CI without Apple `container`.

_Recommendation: 2 first (highest bug-finding ROI per hour); revisit 3 if siblings keep surfacing._

### 3.2 Compose fixture matrix
Current `Sample Compose Files/` examples are documentation-shaped (one feature each). Real bugs come from awkward combinations. Candidate adversarial fixtures:
- `entrypoint`: string / single-list / multi-list / null override
- `entrypoint` + `command` together (canonical "override entrypoint, keep args" pattern)
- `image` + `build` together (image gets used as the build tag)
- `volumes`: bind + named + anonymous + read-only in one service
- `depends_on`: list form and object form in the same file
- `env_file`: multiple files + `environment` overrides on top
- `ports`: `"80"`, `"8080:80"`, `"127.0.0.1:8080:80"`, `"8080:80/udp"` mixed

_User to identify which patterns matter most based on real-world usage. Even redacted real-world compose files would be high signal._

### 3.3 Pre-subcommand global flags
Today: `container-compose -f compose.yml build` fails (or silently uses the wrong file); `-f` only parses after the subcommand. Should match `docker compose` UX: globals before the subcommand.

The passthrough at `Sources/ContainerComposeApp/application.swift:13` (`@Argument(parsing: .captureForPassthrough) var args`) is a clean preprocessing seam — we can reorder before swift-argument-parser sees the args, no subcommand changes needed.

Open question: which flags get promoted?
1. Just `-f` / `--file`. Minimal change.
2. Match Docker Compose's full pre-subcommand set: `-f`/`--file`, `-p`/`--project-name`, `--profile`, `--env-file`, possibly `--project-directory`.

_Recommendation: 2 — muscle-memory parity wins; doing one and then the rest later is the same work twice._

### 3.4 Build command empty-output wording
Current message:
```
No services with a 'build' configuration found.
```
Reads as ambiguous between "all good, nothing to do" and "warning, did you forget something?".

Options:
1. Keep terse (matches `docker compose build`'s style).
2. Expand to something like:
   ```
   No services with a 'build' configuration found.
   All N service(s) use pre-built images. Nothing to build.
   ```
   Possibly gated on `--verbose`.

---

## 4. Parking lot (noted, not scoped)

### Log column-wrap issue
Container log lines stream wrapped at very narrow widths (~14–35 columns each), each with the `domains:` service prefix repeated:
```
domains: Error: failed to start process cloudfla
domains: re-domains in container cloudflare-domains (cause: "internalError: "faile
domains: d to start process (cause: "int
…
```
Suggests the streaming relay is splitting on transport-chunk boundaries rather than newlines. Investigate once the entrypoint bug is fixed and a real container can start.

---

## Suggested resumption path
1. Pick scope from §3.1.
2. Red-green: write argv-shape tests first (against current buggy behavior they should fail), then fix the call sites — each test should flip red → green as the corresponding fix lands.
3. Verify end-to-end against `~/projects/cloudflare/compose.yml`.
4. Revisit §3.3 / §3.4 in whichever order matches the next user pain point.
