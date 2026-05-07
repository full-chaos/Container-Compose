---
title: Compose-spec Coverage
description: Live matrix of compose-spec fields implemented in Container-Compose.
---

# Compose-spec Coverage

The matrix below shows which `compose-spec` fields Container-Compose implements,
which are partially supported, and which are warn-skipped.

> **Canonical source of truth.** This page is the authoritative coverage view.
> For tier-by-tier analysis (silent failure, wireable now, upstream FR, won't do)
> see [Feature Parity](./feature-parity.md). For the dependency story, see
> [Upstream / Fork Status](./upstream-fork-status.md).

[Open the coverage report in a standalone tab](../coverage.html){target="_blank" rel="noopener"}

<iframe
  src="../coverage.html"
  title="Compose-spec coverage matrix"
  loading="lazy"
  style="width: 100%; height: 1100px; border: 1px solid var(--md-default-fg-color--lightest); border-radius: 4px;">
</iframe>

## Summary

| Status | Count | % |
| :--- | ---: | ---: |
| Implemented | 122 | 61.3% |
| Partial | 61 | 30.7% |
| Missing | 16 | 8.0% |
| **Total** | **199** | **100%** |

The summary refreshes whenever `coverage.html` is regenerated; see
[`scripts/regen-coverage.sh`](https://github.com/full-chaos/container-compose/blob/main/scripts/regen-coverage.sh)
for the extraction script.

## See also

- [Feature Parity](./feature-parity.md) — tiered split of remaining gaps
- [Limitations and Gotchas](./guides/limitations-and-gotchas.md) — practical impact organized by user pain
- [Upstream / Fork Status](./upstream-fork-status.md) — fork dependencies and the `full-chaos/container` `dev` branch for additional features
