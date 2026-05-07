# container-compose restart prompt

> Paste this at the start of a fresh Claude Code session on container-compose work to restore strategic context without conversation history.
>
> Last refreshed: 2026-05-06 (after CHAOS-1345 strategic update + Phase 0 cleanup).

---

I'm working on `container-compose` (repo: `/Users/chris/projects/full-chaos/container/container-compose`, currently on `main`).

**Strategic posture (recently established):** apple/container is treated as a frozen dependency; the `full-chaos/container` fork is the canonical runtime. The full strategic doc + active phase plan lives in **CHAOS-1345** — read its description first to orient.

**Quick orient (run these to bring yourself up to speed):**

```bash
# 1. Strategic doc — entry point, has phase plan + bucket categorization
linear i get CHAOS-1345 --output json | jq -r .description

# 2. Active fork-patch backlog (Phase 1, in priority order)
linear search --label fork-bound --team CHAOS --output json --format compact \
  | jq '[.[] | {id, priority, title, state}]'

# 3. Spike-actionable backlog (Phase 2)
linear i list --project "Container Compose" --output json --format full --limit 100 \
  | jq '[.[] | select(.state.name == "Backlog" and (.labels | map(.name) | contains(["fork-bound"]) | not)) | {id: .identifier, priority, title}]'
```

**Phase 1 starting target if nothing else comes up: CHAOS-1381** (`--health-cmd / --health-*` CLI flags). Pairs with already-shipped `ContainerSnapshot.health` field. CHAOS-1365 (programmatic `ContainerClientProvider.create()`) is also Phase-1 P3 if you'd rather close the route layer's HTTP 501 first. CHAOS-1379 (`--gpus`) is deferred unless there is an explicit user need; the 2026-05-06 spike found Virtualization display-device APIs, not Docker-style GPU compute passthrough.

**Project conventions:**

- **Linear**: default team `CHAOS`, default project `Container Compose`. Always use `linear i get/list/search --output json` over text. `linear i update` does NOT accept `--output` — verified empirically. Pipe through `jq` for filtering.
- **Git/PR**: `gh pct "<title>" -b "<body>"` is the alias for `gh pr create -t` (push + create in one call); `gh checks <num>` for CI status. Always push explicitly to `origin HEAD:refs/heads/<branch>` before creating a PR — past 504s have eaten one-shot pushes.
- **Swift testing**: prefer `swift test --parallel --filter "<SuiteName>"` over broad `--skip Container-Compose-DynamicTests` — the broad pattern can wedge concurrent test invocations on the shared `.build/`. Long-running tests should run as background tasks (`run_in_background: true`).
- **Fork patches**: each `fork-bound` ticket lands as a named patch series (e.g., `feature/health-cli-flags`) in the `full-chaos/container` repo. PR #6 (merge commit `c63ed9a3`, "feat: add Tier 2 fork APIs") sets the precedent for "Tier 2 fork APIs" squash-merged feature commits.
- **Worktree-friendly parallel work**: prefer `Agent({isolation: "worktree", ...})` for parallel feature work; `git worktree list` to inspect; `git worktree remove -f -f <path>` to clean locked agent worktrees.

**Linear automation gotcha (one-time, but worth knowing):** removing the legacy `upstream-blocked` label from an `In Progress` ticket auto-flipped state to `Canceled` in this team's workflow. The `fork-bound` label is the active replacement; the legacy labels remain on already-closed tickets for historical context.

What should we tackle first?
