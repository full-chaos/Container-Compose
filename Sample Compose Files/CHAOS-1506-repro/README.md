# CHAOS-1506 reproduction sample

Two services build the same multi-stage Dockerfile in parallel. This
fixture demonstrates a confirmed apple/container upstream signal — inconsistent
platform-string normalization across stages of one build — and serves as a
starting point for the eventual repro of the `COPY --from=builder` race
that motivated CHAOS-1506.

## What this fixture proves today

Running `container-compose up` against this directory consistently shows
**platform-string drift** in the trace:

```
#8 [linux/arm64/v8 builder 2/4] COPY . .
#9 [linux/arm64 builder 3/4] RUN ...
```

Container-Compose passes `--os linux --arch arm64` to apple/container's
`BuildCommand` (Compose+BuildService.swift:128-141). It never passes `v8`.
Yet apple/container's buildkit-shim emits both `linux/arm64` and
`linux/arm64/v8` in the same build's trace — normalization is inconsistent
across stages. This is the upstream signal that motivates the apple/container
issue filed for CHAOS-1506.

## What this fixture does NOT prove

The actual `ERROR [runtime] COPY --from=builder /install /usr/local`
failure that the original Linear issue captured did **not** reproduce
across multiple attempts here. The race is timing- and load-dependent:
- The original failure used a heavier Python pip-install workload that
  produced large content-hash collisions and saturated the builder VM.
- The lightweight fixture (mkdir + 1 MB random payload) completes the
  builder stage too quickly to widen the race window.

The race condition the platform drift implies remains plausible but is
not deterministically reproducible at this fixture's scale.

## Existing workaround

Until upstream apple/container fixes the buildkit-shim, the documented
workaround is to serialize image-prep at the compose fan-out layer:

```sh
container-compose up --parallel 1
# or
COMPOSE_PARALLEL_LIMIT=1 container-compose up
```

This makes `compose up`'s Phase A (image preparation — pulls and builds)
single-flight, which avoids two concurrent `BuildCommand` clients dialing
the same buildkit container. Trade-off: pulls also serialize, so users
with mostly-pull compose files pay an unnecessary cost. If that proves
problematic in practice, CHAOS-1506 may grow a finer-granularity
`--serial-builds` flag — but the discipline is to ship that only after
verifying the inner serialization actually adds value beyond `--parallel 1`.

## Compose-spec coverage

This fixture also exercises two feature-parity fixes that landed alongside:

- **CHAOS-1510** — `image:` alongside `build:` is now accepted (per
  compose-spec, `image:` becomes the build tag).
- **CHAOS-1511** — auto-derived project names are lowercased (the
  parent directory `CHAOS-1506-repro/` produces project name
  `chaos-1506-repro` instead of failing apple/container's lowercase
  network-ID validator).

## Run

```sh
cd "Sample Compose Files/CHAOS-1506-repro"
container-compose up
# Expect: builds complete with arm64/v8 platform drift visible.
# The original COPY --from=builder failure may not appear without
# additional load. See "What this fixture does NOT prove" above.
```

## Upstream

apple/container issue (link pending — file with platform-drift evidence
from this repro + the original Linear trace).
