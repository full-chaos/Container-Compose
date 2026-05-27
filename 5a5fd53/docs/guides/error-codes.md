# Error Codes Reference

> **Scope:** All error types a user or integrator can encounter when running
> Container-Compose commands or calling the Container REST API.
> **Source of truth:** `Sources/Container-Compose/` — every entry below was
> verified against the Swift source before being included.

---

## Quick lookup table

| Error type | Cases | Surface |
| :--- | :--- | :--- |
| [`RuntimeError`](#runtimeerror) | `notFound`, `alreadyExists`, `invalidState`, `timeout`, `imageNotFound`, `notSupported`, `backendFailure`, `persistenceFailure` | REST API, `compose ps`, runtime layer |
| [`ComposeError`](#composeerror) | `imageNotFound`, `invalidProjectName`, `externalVolumeNotFound`, `invalidShellTokenization` | Compose YAML parsing / startup |
| [`YamlError`](#yamlerror) | `composeFileNotFound` | File loading |
| [`IncludeError`](#includeerror) | `cyclicInclude`, `fileNotFound` | `include:` processing |
| [`ComposeMemoryParseError`](#composememoryarseerror) | `empty`, `invalid`, `negative`, `overflow` | Memory quantity validation |
| [`ComposeWaitError`](#composedependswait-composewaiterror) | `timeout`, `nonZeroExitCode` | `depends_on` condition waiting |
| [`ListenAddressError`](#listenaddresserror) | `malformed`, `missingHostOrPort`, `unsupportedScheme` | `--listen` flag on `compose serve` |
| [`TerminalError`](#terminalerror) | `commandFailed` | Subprocess execution |
| [`OrchestratorError`](#orchestratorerror) | `projectNotFound`, `serviceNotFound`, `invalidReplicaCount` | REST API project routes |
| [`AuthStoreError`](#authstoreerror) | `duplicateName`, `malformedFile` | TLS client auth store |

---

## RuntimeError

**Source:** `Sources/Container-Compose/Runtime/Runtime.swift` lines 169–178

The errors a `Runtime` conformer can throw. These types are kept independent
of any specific backend (`apple/container` XPC or `apple/containerization`
native) so call sites stay portable across runtime backends. `RuntimeError`
conforms to both `Error` and `Sendable`, and is `Equatable`.

### `notFound(id: String)`

**Meaning:** No container, network, volume, or secret exists with the given
identifier.

**Common causes:**
- The container was stopped and removed before this call ran.
- A typo in the service or container name.
- The compose project was torn down with `compose down` before the query reached
  the runtime.
- Calling `get(id:)` against a container id that was never created.

**Resolution:**
1. Run `container-compose ps` (or `GET /containers`) to list currently
   registered containers.
2. If the container should exist, check whether it was removed by a concurrent
   `compose down`. Re-run `compose up` to recreate it.
3. Verify the container id matches the compose project/service naming
   convention: `<project>-<service>`.

---

### `alreadyExists(id: String)`

**Meaning:** A resource with the given identifier already exists and the
operation does not allow replacing it.

**Common causes:**
- Running `compose up` twice without `compose down` in between.
- Creating a volume or network whose name is already in use.
- A previous failed teardown left orphan containers in the registry.

**Resolution:**
1. Run `compose down` to remove existing resources, then retry `compose up`.
2. For volumes: if you want to preserve data, inspect the volume first
   (`container volume inspect <name>`) before removing it.
3. For orphan containers: `container rm <id>` removes an individual container.

---

### `invalidState(id: String, expected: RuntimeContainerStatus, actual: RuntimeContainerStatus)`

**Meaning:** A lifecycle operation was attempted on a container that is not in
the required state. For example, `start` requires the container to be in
`.created`, `.stopped`, or `.exited`; `remove` without `force: true` requires
`.stopped` or `.exited`.

**Common causes:**
- Calling `start` on an already-running container.
- Calling `remove` on a running container without `--force`.
- A race condition between two concurrent operations (e.g., auto-restart and
  manual stop).

**Resolution:**
1. Check current state: `container-compose ps`.
2. Stop the container first if it is running: `compose stop <service>`.
3. If using the REST API, check the `actual` field in the error response for
   the real current state before retrying.

---

### `timeout(id: String, seconds: Int)`

**Meaning:** A blocking `wait` operation did not complete within the allotted
time. The `wait` method polls for an exit status; if the container has not
exited after `seconds` seconds, this error is thrown.

**Common causes:**
- The container process is hung and not responding to SIGTERM.
- The container is a long-running service that was never intended to exit.
- The timeout value is too short for a slow-starting or slow-stopping
  container.

**Resolution:**
1. Send a stronger signal: `compose kill <service>` (SIGKILL).
2. Increase the stop timeout via `stop_grace_period` in your compose file
   (note: this field is currently warn-skipped — see
   [`docs/feature-parity.md` Tier 0](../feature-parity.md)).
3. For the REST API's `DELETE /containers/{id}` path, use `force=true` to
   skip graceful shutdown.

---

### `imageNotFound(reference: String)`

**Meaning:** The container image specified in the compose service definition
was not found locally or could not be pulled.

**Common causes:**
- The image tag does not exist in the registry.
- Network access to the registry is unavailable.
- A typo in the `image:` field or the `build.dockerfile` path.
- The image name uses a short form (e.g. `nginx`) that requires auto-qualifying
  to the full registry path; Container-Compose auto-qualifies to
  `docker.io/library/<name>` in most cases.

**Resolution:**
1. Pull the image manually: `container pull <reference>`.
2. If using a private registry, check that credentials are configured.
3. For `build:`-backed services, run `compose build <service>` explicitly and
   verify the Dockerfile path is correct.

Note: this `RuntimeError.imageNotFound` is distinct from
`ComposeError.imageNotFound`, which fires during YAML parsing when a service
declares neither `image:` nor `build:`.

---

### `notSupported(operation: String, conformer: String)`

**Meaning:** The requested operation is not implemented by the active runtime
backend. The `operation` field names the protocol method (e.g. `"create"`,
`"listNetworks"`) and `conformer` names which backend rejected it (e.g.
`"BridgeContainerClientRuntime"`).

**Common causes:**
- Calling a REST API route that requires an unsupported lifecycle write (wait) while
  the Bridge backend is active — `BridgeContainerClientRuntime` throws
  `.notSupported` for `wait`, `listNetworks`, and all secret CRUD
  operations.
- Calling network CRUD routes (`POST /networks`, `DELETE /networks/{id}`)
  against either backend: neither `apple/container` XPC nor
  `apple/containerization` exposes a public network management API yet
  (tracked as Leak #9 in
  [`docs/plans/runtime-abstraction-leaks.md`](../plans/runtime-abstraction-leaks.md)).
- Calling secret CRUD routes (`POST /secrets`, etc.) against either production
  backend: secret storage requires a durable backend not yet implemented
  (Leak #11).

**Resolution:**
1. For container create/start via the REST API: use `compose up` (CLI path)
   instead, which goes through `RunCommandRunner` rather than the `Runtime`
   protocol.
2. For network CRUD: use the `container network create/remove` CLI directly;
   compose-side network creation goes through that path already.
3. For secrets: use compose file `secrets:` with a `file:` source; runtime
   secret APIs are in-memory only via `MockRuntime` and are not supported in
   production backends yet.
4. HTTP callers receive **501 Not Implemented** for these routes; treat a 501
   as "use the CLI instead."

---

### `backendFailure(message: String)`

**Meaning:** The underlying runtime backend (XPC daemon, containerization
library) returned an error that does not map to a more specific `RuntimeError`
case. The `message` field carries the backend's original error description.

**Common causes:**
- The `apple/container` XPC service is not running or has crashed.
- The container process exited with an unexpected error.
- Stats collection failed (vsock error, container not running).
- An XPC timeout in the bridge backend during `start` or `kill`.

**Resolution:**
1. Check whether the container runtime service is running:
   `container system info`.
2. Inspect recent logs: `compose logs <service>`.
3. Restart the container runtime service if it is unresponsive.
4. HTTP callers receive **502 Bad Gateway** for backend failures; a 502
   indicates a problem with the underlying container runtime, not with your
   compose file.

---

### `persistenceFailure(message: String)`

**Meaning:** A durable state write failed. In the current implementation, this
covers failures in `ContainerRegistry` (the in-process registry backing
`AppleContainerizationRuntime`) and in `RuntimeVolumeClient` (the XPC-backed
volume client used by both production conformers).

**Common causes:**
- The container registry actor threw during a state transition (concurrent
  mutation rejected, disk write failure).
- Volume creation failed in the XPC volume client.
- State file corruption.

**Resolution:**
1. Retry the operation once; transient XPC errors may resolve automatically.
2. If the error persists, stop all containers (`compose down`) and restart the
   container runtime service.
3. Report the `message` field content in a bug report — it carries the
   upstream error from the registry or volume client.

---

## ComposeError

**Source:** `Sources/Container-Compose/Errors.swift` lines 39–57

Errors thrown during compose YAML parsing and startup. These fire before any
container is started.

### `imageNotFound(String)`

**Meaning:** A service in the compose file defines neither an `image:` field
nor a `build:` section. The associated string is the service name.

**Message format:** `Service <name> must define either 'image' or 'build'.`

**Resolution:** Add either `image: <reference>` or `build: <context>` to the
service definition.

---

### `invalidProjectName`

**Meaning:** Container-Compose could not determine a project name. The project
name is derived from (in order): the `--project-name` flag, the
`COMPOSE_PROJECT_NAME` environment variable, or the directory name of the
compose file.

**Common causes:**
- The compose file is in a root directory whose name is empty or invalid.
- All project-name sources return an empty string.

**Resolution:** Pass `--project-name <name>` explicitly on the command line or
set `COMPOSE_PROJECT_NAME` in your shell environment.

---

### `externalVolumeNotFound(String)`

**Meaning:** A volume declared with `external: true` was not found in the
container runtime's volume list. The associated string is the volume name.

**Message format:** `External volume '<name>' was not found. Create it with 'container volume create <name>' before running compose.`

**Resolution:** Create the volume before running `compose up`:

```sh
container volume create <name>
```

If the volume name is wrong, correct the `name:` field under `volumes:` in
your compose file.

---

### `invalidShellTokenization(input: String, reason: String)`

**Meaning:** A `command:` or `entrypoint:` field was supplied as a string
(rather than a YAML list) and Container-Compose could not split it into tokens
using POSIX shell rules.

**Common causes:**
- Unmatched quotes: `command: "start --name 'my app"` (missing closing `'`).
- Invalid escape sequences in the string value.

**Resolution:** Either fix the quoting in the string form, or rewrite the
value as a YAML list:

```yaml
# Before (string form, may fail)
command: "myapp --flag 'value with space'"

# After (list form, always safe)
command: ["myapp", "--flag", "value with space"]
```

---

## YamlError

**Source:** `Sources/Container-Compose/Errors.swift` lines 28–37

### `composeFileNotFound(String)`

**Meaning:** No compose file was found at the expected path. The associated
string is the path that was searched.

**Common causes:**
- Running `container-compose` from a directory that has no `compose.yml`,
  `compose.yaml`, `docker-compose.yml`, or `docker-compose.yaml`.
- Specifying a `--file` path that does not exist.

**Resolution:**
1. Verify the current directory: `ls compose.yml`.
2. Pass the path explicitly: `container-compose -f /path/to/compose.yml up`.

---

## IncludeError

**Source:** `Sources/Container-Compose/Codable Structs/Include.swift` lines 75–87

Errors thrown when processing `include:` directives in a compose file.

### `cyclicInclude(String)`

**Meaning:** An `include:` directive creates a cycle — the file being included
is already in the current include stack.

**Message format:** `Cyclic include detected: '<path>' is already being loaded.`

**Resolution:** Remove the cycle. Compose `include:` is a DAG, not a loop;
no file may include itself, directly or transitively.

---

### `fileNotFound(String)`

**Meaning:** A path listed under `include:` could not be opened.

**Message format:** `Included compose file not found: '<path>'`

**Resolution:** Verify the path relative to the primary compose file's
directory, or use an absolute path.

---

## ComposeMemoryParseError

**Source:** `Sources/Container-Compose/Helper Functions.swift` lines 29–34

Internal validation errors for memory quantity strings. These surface when
Container-Compose validates `mem_limit`, `mem_reservation`, or
`deploy.resources.*` memory fields for logical consistency (e.g. reservation
vs. limit comparison). The raw string value is still passed through to the
runtime, so only edge-case strings trigger these.

### `empty`

**Meaning:** The memory quantity string is empty or whitespace-only.

**Resolution:** Provide a valid quantity: `256m`, `1g`, `536870912`.

---

### `invalid(String)`

**Meaning:** The memory quantity string has an unrecognized suffix or format.
The associated string is the unparseable input.

**Common causes:**
- Using a Docker Compose shorthand that Container-Compose does not recognize.
- A stray character after the number.

**Resolution:** Use standard Docker Compose memory suffixes: `b`, `k`, `m`,
`g`, `t` (or uppercase variants, or IEC `Ki`/`Mi`/`Gi`/`Ti`).

---

### `negative(String)`

**Meaning:** The numeric portion of the memory quantity is negative.

**Resolution:** Use a positive integer.

---

### `overflow(String)`

**Meaning:** The computed byte value overflows a `UInt64`.

**Resolution:** Use a realistic memory limit. Values above 16 exabytes are
unlikely to be intentional.

---

## Depends-on wait: ComposeWaitError

**Source:** `Sources/Container-Compose/Commands/Compose+Wait.swift` lines 82–102

Errors thrown when waiting for a `depends_on` condition to be satisfied.

### `timeout(containerName: String, condition: DependsOnCondition, seconds: TimeInterval)`

**Meaning:** The dependency container did not reach the required condition
within the configured timeout period.

**Message format:** `Timed out after <N>s waiting for container '<name>' to satisfy condition '<condition>'.`

**Common causes:**
- The upstream service is slow to start and the default timeout is too short.
- The upstream service is crashing on startup in a restart loop.
- `condition: service_healthy` is specified but the upstream service has no
  healthcheck defined.

**Resolution:**
1. Check upstream service logs: `compose logs <upstream-service>`.
2. Increase the default timeout (Container-Compose uses a fixed internal
   timeout; this is currently not user-configurable via compose YAML because
   `stop_grace_period` is warn-skipped — see
   [`docs/feature-parity.md` Tier 0](../feature-parity.md)).
3. For `service_healthy`: ensure the upstream service actually defines a
   `healthcheck:` in the compose file.

---

### `nonZeroExitCode(containerName: String, exitCode: Int32)`

**Meaning:** A container that was being waited on with
`condition: service_completed_successfully` exited with a non-zero exit code.
The `exitCode` field carries the actual exit status.

**Message format:** `Container '<name>' exited with non-zero status <code>; service_completed_successfully condition not satisfied.`

**Resolution:**
1. Run the failed service standalone to see its error output:
   `compose run --no-deps <service>`.
2. Check its exit code and logs: `compose logs <service>`.
3. Fix the service's startup logic or initialization script.

---

## ListenAddressError

**Source:** `Sources/Container-Compose/Commands/ListenAddress.swift` lines 115–130

Errors thrown when parsing the `--listen` address for `compose serve`.

### `malformed(String)`

**Meaning:** The address string does not match any supported format.

**Expected formats:** `unix:///path/to/socket`, `tcp://host:port`,
`tls://host:port`

**Resolution:** Correct the `--listen` flag value. Example:
`--listen unix:///var/run/container-compose.sock`

---

### `missingHostOrPort(String)`

**Meaning:** A `tcp://` or `tls://` address was provided but is missing the
host or port component.

**Resolution:** Supply both: `tcp://127.0.0.1:2376`

---

### `unsupportedScheme(String)`

**Meaning:** The URL scheme in the listen address is not one of `unix`, `tcp`,
or `tls`.

**Resolution:** Use one of the supported schemes. `http://` and `https://` are
not accepted directly — use `tcp://` or `tls://` instead.

---

## TerminalError

**Source:** `Sources/Container-Compose/Errors.swift` lines 59–65

### `commandFailed(String)`

**Meaning:** A subprocess invoked via the internal `RunCommandRunner` returned
a non-zero exit code.

**Common causes:**
- `container run` or `container build` failed.
- The `apple/container` CLI is not installed or not on `PATH`.
- The container image failed to build or start.

**Resolution:**
1. Run the failing command manually with the same arguments to see its output.
2. Verify that `container` is installed and accessible: `which container`.
3. Check the container's logs for startup errors.

---

## OrchestratorError

**Source:** `Sources/Container-Compose/Server/ProjectOrchestrator.swift` lines 55–62

Errors surfaced by `ProjectOrchestrator` to REST API route handlers. HTTP
route handlers map these to appropriate status codes.

### `projectNotFound(name: String)`

**Meaning:** No containers with the given project prefix exist in the runtime.

**HTTP mapping:** 404 Not Found

**Resolution:** Verify the project name. The REST API uses the naming
convention `<project>-<service>` to group containers. If the project was never
started, run `compose up` first.

---

### `serviceNotFound(project: String, service: String)`

**Meaning:** The named service was not found within the specified project.

**HTTP mapping:** 404 Not Found

**Resolution:** Check that the service name matches the `services:` key in
the compose file exactly. Service names are case-sensitive.

---

### `invalidReplicaCount(Int)`

**Meaning:** A `replicas` field was set to a negative integer.

**HTTP mapping:** 400 Bad Request

**Resolution:** Set `replicas` to a non-negative integer in the REST request
body.

---

## AuthStoreError

**Source:** `Sources/Container-Compose/Server/AuthStore.swift` lines 152–163

Errors thrown when loading or updating the TLS client authentication store.
These appear during `compose serve` startup when mutual TLS is configured.

### `duplicateName(String)`

**Meaning:** Two client certificates with the same name were found in the auth
store configuration.

**Resolution:** Ensure each client entry in the TLS configuration has a
unique name.

---

### `malformedFile(String)`

**Meaning:** The auth store file at the given path could not be decoded. The
associated string is the file path.

**Resolution:** Verify the auth store file is valid JSON matching the expected
schema. Re-generate it from the certificate if needed.

---

## See also

- [Runtime Protocol Contract](./runtime-protocol.md) — how `RuntimeError` cases map to `Runtime` method throws
- [Migration from Docker Compose](./migration-from-docker-compose.md) — troubleshooting section for common migration errors
- [Feature Parity Inventory](../feature-parity.md) — which compose fields may silently fail (Tier 0)
- [Runtime Abstraction Leaks](../plans/runtime-abstraction-leaks.md) — known gaps that affect `notSupported` and `backendFailure` cases
- [Reviews](../reviews/) — code review notes and context
