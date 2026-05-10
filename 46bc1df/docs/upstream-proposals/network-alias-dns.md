# [Request]: Per-network DNS aliases for `container run` (`--network <net>,alias=<name>`)

## Summary

`container run` currently registers exactly one DNS name per container: the value
passed to `--name`. There is no way to attach additional DNS aliases to a container
on a specific network at launch time. This makes it impossible for orchestration
tools that follow the [Compose spec](https://github.com/compose-spec/compose-spec/blob/master/spec.md#networking)
to provide correct peer-name DNS resolution without colliding on the globally-unique
`--name` namespace.

This request proposes extending the existing `--network` comma-suboption grammar
(which already accepts `mac=` and `mtu=`) with a repeatable `alias=<name>` suboption.
The change is additive: no existing flag changes meaning, no new top-level flag is
introduced, and the DNS resolution path in `ContainerDNSHandler` requires no
modification because it already resolves by queried name string.

---

## Motivation

The [Compose spec](https://github.com/compose-spec/compose-spec/blob/master/spec.md#networking)
defines `services.<svc>.networks.<net>.aliases[]` as an array of additional DNS names
a container answers to on a specific network attachment. This is a core primitive for
service discovery: a `postgres` container should be reachable as `postgres` from any
peer on the same project network, regardless of what the runtime calls the container
internally.

Today, `apple/container` has no mechanism to register a second DNS name for a
container. The only registered name is the runtime `--name`. Orchestrators that
need to expose a service under a logical name (e.g. `postgres`, `redis`, `api`)
while keeping the runtime name unique across all projects (e.g.
`myproject-postgres-1`) are stuck: they cannot satisfy both constraints
simultaneously.

This gap blocks full Compose interoperability on macOS. Docker Compose treats
per-network aliases as a first-class networking primitive, and the Compose
spec requires them. Implementing alias support in `apple/container` would
unblock this for any Compose-compatible tool targeting
the runtime.

---

## Current Behavior

Verified against `container CLI 0.12.3-38-g58d5d32`.

The recent peer-name DNS fix in this build correctly resolves a container's
`--name` as `<name>.<dns-domain>` (default domain: `test`). That fix is the
foundation this request extends.

### Probe transcript

```bash
# Create a shared network
container network create --subnet 10.99.99.0/24 cc-net

# Start a container named "alpha" — no alias registered for "postgres"
container run --rm -d --name alpha --network cc-net \
  docker.io/library/alpine:latest sleep 100

# Query from a peer on the same network
container run --rm --name probe --network cc-net \
  docker.io/library/alpine:latest getent hosts postgres
# Result: NXDOMAIN — "postgres" is not registered
#         "alpha.test" resolves correctly (PROBE 1 ✅)
#         "postgres" does not (PROBE 2 ❌)
```

**Additional probes (all against `0.12.3-38-g58d5d32`):**

| Probe | Approach | Result |
| :--- | :--- | :--- |
| 1 | Peer lookup by `--name` (`alpha.test`) | ✅ A + AAAA answered |
| 2 | Bare service name (`postgres`) from peer | ❌ NXDOMAIN |
| 3 | `--dns-domain compose.local` on querying container | ❌ Even `alpha.test` fails — observed behavior is consistent with the resolver appending the client's search domain and not retrying the bare label (see [Trailing-dot / FQDN handling](#trailing-dot--fqdn-handling)) |
| 4 | `--aux-address HOSTNAME=IPV4` on `network create` | ❌ IP reservation only; does NOT register DNS |
| 5 | `--name postgres` (rename to bare service name) | ✅ DNS works, but `--name` is globally unique → second project collides: `Error: container with id postgres already exists` |

---

## Proposed Surface

### CLI grammar

Extend the existing `--network` comma-suboption grammar with a repeatable
`alias=<name>` key. The grammar already accepts `mac=` and `mtu=`; this adds
one more optional key.

```
--network <name>[,mac=<addr>][,mtu=<bytes>][,alias=<name>]...
```

`alias=` is repeatable. A container attached to two networks can carry different
aliases on each:

```bash
container run --rm -d \
  --name myproject-postgres-1 \
  --network frontend,alias=postgres \
  --network backend,alias=postgres,alias=db \
  docker.io/library/postgres:16
```

This registers:
- `postgres` on `frontend` (resolves to the container's IP on that network)
- `postgres` and `db` on `backend` (resolves to the container's IP on that network)
- `myproject-postgres-1.test` globally (existing behavior, unchanged)

### Validation rules

Alias values are validated at CLI parse time:

- **Non-empty**: `--network cc-net,alias=` is rejected with `alias value must not be empty`.
- **DNS-label format**: 1-63 octets per label, total ≤ 253 octets, RFC 1035 character set (letters, digits, hyphens; dots only between labels for internal qualification).
- **Reserved characters**: alias values must not contain `,` or `=` (these would conflict with the comma-suboption grammar).

Duplication semantics:

- **Same alias twice on one attachment** (`alias=foo,alias=foo`) is silently de-duplicated to one registration.
- **Same alias from two attachments on the same network** is intentional — this is how Compose models scaled services; both attachments register and DNS returns multi-A.
- **Duplicate primary `--name`** collisions remain rejected exactly as today; the runtime's existing global `--name` invariant is unchanged.

### API / runtime change

The change touches three layers, with the bulk of the complexity in the
name-registration data model.

#### Allocator: many-to-many name ↔ IP

[`AttachmentAllocator`](https://github.com/apple/container/blob/main/Sources/Services/ContainerNetworkService/Server/AttachmentAllocator.swift#L20-L42)
today stores a single `private var hostnames: [String: UInt32]` map (one IP
index per registered name; the same name on a duplicate `allocate(hostname:)`
call returns the existing index). The Compose alias contract requires a
strictly more expressive shape: **many-to-many DNS registration** — each IP
index can have multiple registered names (one container with
`--network mynet,alias=postgres,alias=db`), **and** each name can resolve to
multiple IP indices (three replicas all registering `alias=worker`). The
latter direction is what produces multi-A answers for scaled Compose
deployments.

Concretely, the registration table (or whatever per-network structure
replaces the current allocator state) needs to support:

1. Accepting an `aliases: [String]` parameter alongside `hostname: String` at
   allocation time, scoped to a specific network attachment.
2. Storing both directions: `name -> set<index>` and `index -> set<name>`.
3. On deallocation, removing only the exiting attachment's `(name, index)`
   memberships and leaving any name registered while at least one other index
   still references it. **Critical for the scaled-service case:** when one
   `worker` replica exits, peers must keep resolving `worker` to the surviving
   replicas.
4. Per-network scoping: `alias=postgres` on `frontend` and `alias=postgres`
   on `backend` are distinct registrations stored in distinct per-network
   tables; they never cross-leak.

#### DNS resolver: conditional change

[`ContainerDNSHandler.answerHost`](https://github.com/apple/container/blob/main/Sources/APIServer/ContainerDNSHandler.swift#L78-L81)
calls `networkService.lookup(hostname: question.name)` and returns a single
`ResourceRecord`. For **single-target aliases** (one `alias=<name>` mapped to
exactly one IP), this path needs no change — the existing string-keyed lookup
finds the registration and answers exactly as for a primary `--name`. For
**shared aliases** (the scaled-service case), the resolver is extended to
return one A record per registered IP: `lookup(hostname:)` returns a
collection of indices and `answerHost` (plus `answerHost6` for AAAA) emits one
resource record per address. No record-rotation policy is needed — standard
glibc/musl resolvers already round-robin multi-A answers. Alias TTLs follow
the same default the existing handler uses for `--name` answers.

#### IPv6 / NODATA preservation

A and AAAA registrations share the same name table; the `hostnameExists`
check used by [`answerHost6`](https://github.com/apple/container/blob/main/Sources/APIServer/ContainerDNSHandler.swift#L41-L52)
consults the same table the alias path writes to. The existing musl-libc
NODATA-on-AAAA contract is therefore preserved without alias-specific logic.

#### CLI flag parser

The `--network` value parser (the code that already accepts `mac=…,mtu=…`)
gains a repeatable `alias=<name>` key. The proposal specifies the wire
grammar; concrete placement of the parser is up to maintainers and lives
somewhere under
[`Sources/Services/ContainerAPIService/Client/`](https://github.com/apple/container/tree/main/Sources/Services/ContainerAPIService/Client).

#### Observability

A passing implementation extends the per-network-attachment view in
`container inspect` to list registered aliases alongside the existing
`hostname` field. This makes alias state debuggable without reading internal
runtime data.

---

## Reproduction Steps

Paste these commands on any macOS host with `container CLI 0.12.3-38-g58d5d32`
(or later) to confirm the current gap:

```bash
# Setup
# (idempotent cleanup of any prior probe artifacts; safe to ignore errors)
container stop alpha 2>/dev/null || true
container delete alpha 2>/dev/null || true
container network delete cc-net 2>/dev/null || true

container network create --subnet 10.99.99.0/24 cc-net

# Start a container — no alias for "postgres" exists
container run --rm -d \
  --name alpha \
  --network cc-net \
  docker.io/library/alpine:latest sleep 100

# Confirm gap: "postgres" is NXDOMAIN
container run --rm \
  --name probe \
  --network cc-net \
  docker.io/library/alpine:latest \
  getent hosts postgres
# Expected today: exit 2, no output (NXDOMAIN)

# Cleanup
container stop alpha
container network delete cc-net
```

After this FR lands, the same workflow with the proposed flag:

```bash
container network create --subnet 10.99.99.0/24 cc-net

container run --rm -d \
  --name alpha \
  --network cc-net,alias=postgres \
  docker.io/library/alpine:latest sleep 100

container run --rm \
  --name probe \
  --network cc-net \
  docker.io/library/alpine:latest \
  getent hosts postgres
# Expected after FR: exit 0, an address in 10.99.99.0/24 returned for `postgres`

container stop alpha
container network delete cc-net
```

---

## Test Plan

A passing implementation would be covered by tests like the following (suite layout and conventions are left to maintainers):

1. **Unit — `AttachmentAllocator` multi-alias registration**
   `allocate(hostname: "alpha", aliases: ["postgres", "db"])` registers all three
   names against this attachment's index. At the allocator/registration level,
   `AttachmentAllocator.lookup(hostname:)` (or whatever public surface the
   allocator exposes) returns the same index for `"alpha"`, `"postgres"`, and `"db"`.

2. **Unit — CLI flag parsing**
   `--network cc-net,alias=foo,alias=bar` parses into a network attachment with
   `name = "cc-net"` and `aliases = ["foo", "bar"]`. Single `alias=` and absent
   `alias=` are also covered.

3. **Integration — peer resolution via alias**
   Two containers on a shared network. Container A launched with
   `--network cc-net,alias=postgres`. Container B's `getent hosts postgres`
   resolves to container A's IP on `cc-net`.

4. **Integration — per-network alias scoping**
   Container A attached to `net1` with `alias=svc` and to `net2` with
   `alias=backend`. A peer on `net1` resolves `svc` to A's `net1` IP. A peer
   on `net2` resolves `backend` to A's `net2` IP. Neither alias leaks across
   networks.

5. **Integration — multi-container same alias (scale case)**
   Three containers each launched with `--network cc-net,alias=worker`. A DNS
   query for `worker` from a peer returns multiple A records, one per container.
   This validates the 1:N IP-per-alias direction (multiple containers sharing
   one alias name).

6. **Integration — musl libc NODATA preservation for aliases**
   Container A launched with `--network cc-net,alias=postgres`. From an Alpine
   (musl libc) peer, query `postgres` for AAAA: if the alias has no IPv6
   address, the response must be NODATA (return code `noError`, empty answers),
   NOT NXDOMAIN. This preserves the existing behavior at
   [`ContainerDNSHandler.swift` L41-L52](https://github.com/apple/container/blob/main/Sources/APIServer/ContainerDNSHandler.swift#L41-L52),
   which the file's own comment notes is required because "musl treats NXDOMAIN
   on AAAA as 'domain doesn't exist' and fails DNS resolution entirely." Compose
   stacks heavily use Alpine-based images (`postgres:alpine`, `valkey/valkey:9-alpine`,
   etc.), so a regression here would be very visible.

---

## Backward Compatibility

This change is strictly additive:

- All existing `--network <name>` invocations continue to behave exactly as today.
  No alias is registered unless `alias=` is explicitly provided.
- The default `--dns-domain test` behavior is unchanged.
- Containers launched without `alias=` register exactly one hostname (the `--name`
  value), preserving today's behavior in full.
- No new dependencies on libnetwork, vmnet plugin variants, or any external resolver are introduced.
- The change is localized to the per-network registration table, the CLI flag
  parser, and — only when shared aliases are supported — the multi-A response
  shape in `lookup`/`answerHost`. No other subsystems are touched.
- The `mac=` and `mtu=` suboptions are unaffected.
- The existing musl libc NODATA-on-AAAA contract at
  [`ContainerDNSHandler.swift` L41-L52](https://github.com/apple/container/blob/main/Sources/APIServer/ContainerDNSHandler.swift#L41-L52)
  is preserved by routing alias presence checks through the same name table
  used by `answerHost` and `answerHost6`. If shared-alias support changes the
  multi-record return shape of `lookup`, the AAAA `hostnameExists` check must
  consult the same shared table to keep returning NODATA (not NXDOMAIN) when an
  alias has an A record but no AAAA.

---

## Trailing-dot / FQDN Handling

**Open design question — input from the apple/container team is needed here.**

Probe 3 (above) revealed a subtle interaction: when the querying container is
launched with `--dns-domain compose.local` (a domain other than the registration
domain `test`), even the registered `--name` fails to resolve. The resolver
appends the client's search domain and never tries the bare label without a
suffix. Only `<name>.test` (the canonical FQDN) resolves from a client whose
`--dns-domain` matches the registration domain.

This means aliases registered under the short form (e.g. `postgres`) may silently
fail to resolve from containers whose `--dns-domain` differs from the server's
registration domain. Three approaches exist; the right answer depends on
apple/container's DNS architecture:

**Option A — Register both short and FQDN forms.**
When `alias=postgres` is requested on a network whose registration domain is
`test`, register both `postgres` and `postgres.test`. Clients querying either
form get an answer. Downside: doubles the registration entries; may interact
unexpectedly with search-domain appending.

**Option B — Server-side query canonicalization.**
The DNS handler normalizes incoming queries before lookup: strip a single
trailing dot, and when the query's suffix matches the network DNS domain
(default `.test`), also try the bare label. A client whose resolver expands
`postgres` to `postgres.test` (default search domain on the same network) gets
a hit because the bare label resolves through canonicalization. A client whose
resolver expands `postgres` to a different suffix (`postgres.compose.local`)
still misses unless the runtime canonicalizes against alternate suffixes,
which it cannot do without knowing the client's domain. Downside: server-side
complexity; the canonicalization rules need clear documentation.

**Option C — Document the constraint.**
Aliases are registered under the short form only. The runtime documents that
alias resolution assumes the querying container's `--dns-domain` matches the
registration domain. Orchestrators that need cross-domain resolution must
configure `--dns-search` explicitly. Downside: silent failure for users who
mix `--dns-domain` values.

This FR does not prescribe which option to adopt. The apple/container team is
better positioned to evaluate the DNS architecture implications. Whichever
option is chosen, the behavior should be documented in the flag's help text.
The Test Plan above assumes short-form-only resolution (Option C); if Apple
chooses A or B, parallel tests for the FQDN/canonicalized form should accompany
the change.

---

## Compose-Field Mapping

How this FR maps to Compose spec fields, and what changes in container-compose
once the flag lands:

| Compose field | Today (warn-skipped) | After this FR |
| :--- | :--- | :--- |
| Service name (implicit) | Not registered as DNS alias | `--network <net>,alias=<service>` per attachment |
| `networks.<net>.aliases[]` | Parsed in `ServiceNetworkConfig.aliases`; warn-skipped | `--network <net>,alias=<a1>,alias=<a2>` per attachment |
| `hostname` | Warn-skipped | Unchanged — out of scope; local-only per Compose spec |
| `extra_hosts` | Warn-skipped | Unchanged — separate FR (`--add-host`) |
| `container_name` | Honored as `--name` | Unchanged |
| `scale: N` (multiple replicas) | Each replica gets a unique `--name` | Each replica also gets `--network <net>,alias=<service>` → multiple A records |

---

## Out of Scope for v1

The following are related but intentionally excluded from this request:

- **`--add-host` / `extra_hosts`** — injects static host entries into
  `/etc/hosts`. Different mechanism, different use case. File separately.
- **`--hostname`** — sets the container's own hostname (visible inside the
  container). Per the Compose spec, `hostname` "does not affect how other
  containers see this container." No peer-DNS implication; separate concern.
- **`--ip` / `--ip6` (static addresses)** — static IP assignment per network
  attachment. Related to IPAM, not DNS alias registration. File separately.
- **`--mac-address`** — MAC address assignment. Already tracked separately.
- **Reverse DNS (PTR records)** — interesting extension, not required for
  Compose interop. Can be added later without breaking this proposal.
- **Service object semantics, load balancing, health-check-aware DNS** —
  apple/container is a single-host runtime. Swarm-style VIP/DNSRR modes are
  out of scope.

---

## Alternatives Considered

**Separate `--network-alias <name>` flag (Docker classic style)**

Docker's `docker run --network-alias <name>` attaches an alias to the network
specified by the first `--network` flag. This was rejected because it doesn't
compose well with multiple network attachments: there's no way to express
"alias `foo` on `net1` but alias `bar` on `net2`" without per-network
scoping. The comma-suboption form (`--network net1,alias=foo`) is more
expressive and consistent with apple/container's existing `mac=`/`mtu=`
grammar.

**`--add-host` / `/etc/hosts` injection**

Static host entries in `/etc/hosts` are per-container, not per-attachment.
They don't survive container scale (each replica would need its own entry
in every peer's hostfile), and they're not scoped to a network. This
approach doesn't satisfy the Compose alias contract.

**`--aux-address HOSTNAME=IPV4` on `network create`**

Probe 4 verified this does not register DNS. It reserves an IP address
within the network's IPAM pool but does not inject any name into the DNS
server. The CLI help text could be read as DNS-related, but the observed behavior is IP reservation only. Not a viable
workaround.

**Renaming containers to bare service names (`--name postgres`)**

Probe 5 confirmed this works for DNS but breaks multi-project isolation.
`--name` is globally unique to the runtime: a second project with a
`postgres` service fails with `Error: container with id postgres already
exists`. Orchestrators that manage multiple independent projects cannot
use this approach.

**Configuring `--dns-domain` / `--dns-search` per service**

Probe 3 confirmed the resolver does not synthesize aliases from search
domains. Even if every container in a project shared the same `--dns-domain`,
that would only affect how the querying container appends suffixes — it
would not cause the runtime to register additional names for the target
container. This approach does not work.

---

## Downstream Consumer

[container-compose](https://github.com/full-chaos/container-compose) is a
Swift CLI that brings Compose spec support to apple/container on macOS. It
already parses `ServiceNetworkConfig.aliases` from the Compose YAML and
warn-skips the field today (see
[`Compose+ArgsNetworking.swift` L45-50](https://github.com/full-chaos/container-compose/blob/main/Sources/Container-Compose/Commands/Compose%2BArgsNetworking.swift#L45-L50)).
When the `alias=` suboption lands in apple/container, container-compose can
wire it through with a one-file change in the argv builder: replace the
`warnUnsupportedRuntimeFieldOnce` call with a loop that appends
`,alias=<name>` to the `--network` argument for each alias in the array.
This work is tracked at CHAOS-1473 (Phase 11.2: Wire container-compose DNS
aliases when runtime support exists). Runtime alias support is the remaining
prerequisite.

---

## References

- container-compose Phase 11.0 rebaseline (downstream tracking;
  full probe transcripts are inlined above in this proposal)
- [container-compose `docs/feature-parity.md` — Tier 3 section](https://github.com/full-chaos/container-compose/blob/main/docs/feature-parity.md)
  (classifies network aliases as Tier 3: needs upstream apple/container engineering)
- [Compose spec — Networking](https://github.com/compose-spec/compose-spec/blob/master/spec.md#networking)
- [Compose spec — `networks.<name>.aliases`](https://github.com/compose-spec/compose-spec/blob/master/spec.md#aliases)
- [Docker `container run --network-alias`](https://docs.docker.com/reference/cli/docker/container/run/)
  (prior art for per-network alias at run time)
- [libnetwork `endpoint.myAliases`](https://github.com/moby/libnetwork/blob/v0.5.6/endpoint.go#L61)
  (canonical precedent: aliases stored at the endpoint level, scoped to the network attachment)
- [apple/container feature request template `02-feature.yml`](https://github.com/apple/container/blob/main/.github/ISSUE_TEMPLATE/02-feature.yml)
- [`AttachmentAllocator.swift` — DNS name registration](https://github.com/apple/container/blob/main/Sources/Services/ContainerNetworkService/Server/AttachmentAllocator.swift#L20-L42)
  (the actor where alias registration would land)
- [`ContainerDNSHandler.swift` — DNS query resolution](https://github.com/apple/container/blob/main/Sources/APIServer/ContainerDNSHandler.swift#L78-L81)
  (resolves by queried name string; no change required)
- [`Flags.swift` — CLI flag surface](https://github.com/apple/container/blob/main/Sources/Services/ContainerAPIService/Client/Flags.swift)
  (where `--network` comma-suboption parsing lives; `alias=` would be added here)

> **Note on fork dependency:** container-compose currently builds against
> `full-chaos/container`, a transitional fork that is now frozen. Per
> [`docs/upstream-fork-status.md`](https://github.com/full-chaos/container-compose/blob/main/docs/upstream-fork-status.md):
> "apple/container is the only canonical remote." This FR is filed against
> the upstream directly; the fork is not involved.
