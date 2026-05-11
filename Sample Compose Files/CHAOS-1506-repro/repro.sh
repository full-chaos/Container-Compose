#!/usr/bin/env bash
# CHAOS-1506: minimal apple/container-only reproduction.
#
# Fires two `container build` invocations in parallel against the SAME
# Dockerfile (same context, same content hash). This is the smallest
# input that surfaces apple/container's buildkit-shim platform-string
# drift (`linux/arm64` ↔ `linux/arm64/v8` across stages of one build)
# and — under heavier load than this fixture creates — the downstream
# `COPY --from=builder` race the Linear issue captured.
#
# No container-compose involvement: the upstream maintainers care about
# reproducing in their own tool, so this is the form to attach to the
# apple/container issue. `Sample Compose Files/CHAOS-1506-repro/docker-compose.yml`
# is preserved for context (how the bug originally surfaced in the wild)
# but is NOT the primary repro.
#
# Usage:
#   ./repro.sh             # one iteration
#   ./repro.sh 5           # five iterations (race is intermittent)
#   COUNT=5 ./repro.sh     # same via env
#
# Exit:
#   0 — all iterations completed without a COPY/build error
#   1 — at least one iteration's build failed (preserve trace for filing)

set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOCKERFILE="${SCRIPT_DIR}/Dockerfile.shared"
CONTEXT="${SCRIPT_DIR}"
TAG_A="chaos-1506-a:latest"
TAG_B="chaos-1506-b:latest"
COUNT="${1:-${COUNT:-1}}"

if [[ ! -f "${DOCKERFILE}" ]]; then
  echo "missing Dockerfile: ${DOCKERFILE}" >&2
  exit 2
fi

if ! command -v container >/dev/null 2>&1; then
  echo "container CLI not on PATH" >&2
  exit 2
fi

overall_status=0

for i in $(seq 1 "${COUNT}"); do
  echo "=== RUN ${i}/${COUNT} ==="

  # Remove prior images so each iteration is a true fresh build (no
  # content-addressed cache short-circuit). Ignore errors — images may
  # not exist on the first iteration.
  container image rm "${TAG_A}" "${TAG_B}" >/dev/null 2>&1 || true

  # Fire two parallel `container build` invocations against the same
  # Dockerfile + context. Capture each build's stdout+stderr separately
  # so the streams don't interleave inside one line.
  container build --no-cache -t "${TAG_A}" -f "${DOCKERFILE}" "${CONTEXT}" \
    > "/tmp/chaos-1506-a-${i}.log" 2>&1 &
  PID_A=$!

  container build --no-cache -t "${TAG_B}" -f "${DOCKERFILE}" "${CONTEXT}" \
    > "/tmp/chaos-1506-b-${i}.log" 2>&1 &
  PID_B=$!

  wait "${PID_A}"; EXIT_A=$?
  wait "${PID_B}"; EXIT_B=$?

  echo "build A exit: ${EXIT_A}  log: /tmp/chaos-1506-a-${i}.log"
  echo "build B exit: ${EXIT_B}  log: /tmp/chaos-1506-b-${i}.log"

  # Merge both logs into a single per-iteration view for the trace
  # archive. Tag each line with which build produced it.
  {
    echo "--- run ${i} build A (exit ${EXIT_A}) ---"
    sed 's/^/[A] /' "/tmp/chaos-1506-a-${i}.log"
    echo "--- run ${i} build B (exit ${EXIT_B}) ---"
    sed 's/^/[B] /' "/tmp/chaos-1506-b-${i}.log"
  } > "/tmp/chaos-1506-run-${i}.log"

  # Grep the two logs for the specific COPY-from-builder error pattern
  # the Linear issue reported, plus the broader platform-string drift
  # signal we've already confirmed.
  if grep -q "ERROR.*COPY --from=builder" "/tmp/chaos-1506-a-${i}.log" \
        "/tmp/chaos-1506-b-${i}.log" 2>/dev/null; then
    echo ">> COPY --from=builder error observed in run ${i}"
    overall_status=1
  fi

  if [[ ${EXIT_A} -ne 0 || ${EXIT_B} -ne 0 ]]; then
    echo ">> build failure in run ${i}"
    overall_status=1
  fi

  if grep -q "linux/arm64/v8" "/tmp/chaos-1506-a-${i}.log" \
        "/tmp/chaos-1506-b-${i}.log" 2>/dev/null; then
    echo ">> platform-string drift (arm64/v8) observed in run ${i}"
  fi
done

# Best-effort cleanup of test images so successive runs don't accumulate.
container image rm "${TAG_A}" "${TAG_B}" >/dev/null 2>&1 || true

exit "${overall_status}"
