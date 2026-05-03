# Container-Compose

Container-Compose is a Swift CLI that brings Docker Compose support to [Apple Container](https://github.com/apple/container). It parses standard `compose.yaml` files and orchestrates services using Apple's native container runtime on macOS — no Docker daemon required.

## Get started

- [**Quickstart**](./quickstart.md) — Up and running in 2 minutes.
- [**CLI Reference**](./cli-reference.md) — Every subcommand, every flag.
- [**Tutorials**](./tutorials/) — End-to-end walkthroughs paired with working sample compose files.

## Reference & status

- [**Compose-Spec Coverage**](../coverage.html) — Live matrix of which compose-spec fields are implemented (canonical source of truth).
- [**Feature Parity Inventory**](./feature-parity.md) — Tiered split of gaps: silent-failure bugs, wireable now, fork-patch path, upstream FR, won't-do.
- [**Upstream / Fork Status**](./upstream-fork-status.md) — What we depend on from `full-chaos/container` and what's blocked on `apple/container`.

## For contributors

- [**Documentation Standards**](./standards.md) — Templates and style rules for adding new docs.
- [**Plans**](./plans/) — Active and historical engineering plans.

## Compatibility

| Requirement | Status | Notes |
| :--- | :--- | :--- |
| **Apple Silicon Mac** | Required | Apple Container only runs on Apple Silicon. |
| **macOS 15 (Sequoia)** | Supported | DNS resolution requires manual configuration. |
| **macOS 26 (Tahoe)** | Recommended | Native DNS support and full feature parity. |
| **Apple Container** | Required | Install from [github.com/apple/container/releases](https://github.com/apple/container/releases) and start with `container system start`. |

## What it isn't

Container-Compose is a translator: it converts compose-spec YAML into invocations of the `container` CLI. It is **not** a Docker daemon, **not** a standalone container runtime, and **not** a Compose-spec implementation by Docker. Compose-spec features that don't have an apple/container equivalent are decoded with a runtime warning rather than silently broken — see [Feature Parity](./feature-parity.md) for the current gap landscape.
