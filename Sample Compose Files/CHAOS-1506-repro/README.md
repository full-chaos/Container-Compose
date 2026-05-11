# CHAOS-1506 reproduction sample

apple/container's buildkit-shim emits inconsistent platform identifiers
(`linux/arm64` ↔ `linux/arm64/v8`) across stages of a **single** build —
even when the client never passes `--arch` or `--platform`. Under load
this drift triggers the `COPY --from=builder /install /usr/local`
failure that originally surfaced in production (Linear CHAOS-1506).

## Primary repro — apple/container only (for upstream filing)

```sh
cd "Sample Compose Files/CHAOS-1506-repro"
./repro.sh 5
```

The script fires two `container build --no-cache` invocations in parallel
per iteration against the same Dockerfile. **No container-compose
involvement** — this is the form to attach to the apple/container issue
since the upstream maintainers can reproduce it in their own tool.

What you'll see (consistently, every iteration):

```
#6 [linux/arm64 builder 1/2] RUN mkdir -p /install ...
#7 [linux/arm64/v8 runtime 1/2] COPY --from=builder /install /usr/local
```

Same build. Two stages. Two different platform strings. Apple/container
is introducing the `v8` variant internally somewhere between argv parsing
(`BuildCommand.swift:305` — `Set<Platform>`) and stage execution.

Script exit codes:
- `0` — all iterations completed (drift observed but no COPY failure)
- `1` — at least one iteration failed (COPY error or non-zero build exit)

## Compose-driven repro (how the bug originally surfaced)

```sh
cd "Sample Compose Files/CHAOS-1506-repro"
container-compose up
```

Same upstream behavior, driven through `container-compose`'s parallel
image-prep fan-out (`runBoundedThrowingFanOut`). Useful as context for
how the bug originally surfaced in user workloads. **Not** the primary
upstream artifact — apple's maintainers prefer reproducing in their own
tooling.

This fixture also exercises two compose-spec parity fixes that landed
alongside CHAOS-1506:

- **CHAOS-1510** — `image:` alongside `build:` is now accepted (per
  compose-spec, `image:` becomes the build tag).
- **CHAOS-1511** — auto-derived project names are lowercased (the
  parent directory `CHAOS-1506-repro/` produces project name
  `chaos-1506-repro` instead of failing apple/container's lowercase
  network-ID validator).

## Why the COPY failure doesn't always fire

The platform-string drift is the **trigger**; the `COPY --from=builder`
race is the **symptom under load**. This lightweight fixture (mkdir + 1
MB random payload + alpine base) completes the builder stage too quickly
to widen the race window. The original Linear failure used a heavier
Python pip-install workload that produced large content-hash collisions
and saturated the builder VM.

To exercise the COPY race specifically, either:
- Use a heavier Dockerfile (pip-install, large `RUN` stages with multi-MB
  output), or
- Bump the builder VM: `container builder stop && container builder start --cpus 4 --memory 8192`

The platform drift alone is sufficient for upstream filing; the race
the drift can trigger is documented in the original Linear trace.

## Existing client workaround

Until upstream apple/container fixes the buildkit-shim, container-compose
users hit by the bug can serialize image preparation at the fan-out
layer:

```sh
container-compose up --parallel 1
# or
COMPOSE_PARALLEL_LIMIT=1 container-compose up
```

This makes `compose up`'s image-prep phase single-flight, which avoids
two concurrent `BuildCommand` clients dialing the same buildkit
container. Pulls also serialize as a side effect — acceptable until
upstream lands.

## Upstream

apple/container issue (link pending; ready-to-paste draft lives at
`.sisyphus/plans/CHAOS-1506-upstream-issue.md` locally — gitignored).
