# Error Codes Reference

> **Scope:** Every error type a user or integrator can encounter when running
> Container-Compose commands or calling the Container REST API.
> **Source of truth:** `Sources/Container-Compose/` — every entry below was
> verified against Swift source before inclusion.

---

## Quick lookup table

| Error type | Cases | Layer |
| :--- | :--- | :--- |
| [`RuntimeError`](#runtimeerror) | `notFound`, `alreadyExists`, `invalidState`, `timeout`, `imageNotFound`, `notSupported`, `backendFailure`, `persistenceFailure` | Runtime layer, REST API |
| [`ComposeError`](#composeerror) | `imageNotFound`, `invalidProjectName`, `externalVolumeNotFound`, `invalidShellTokenization` | YAML parsing, startup |
| [`YamlError`](#yamlerror) | `composeFileNotFound` | File loading |
| [`ComposeValidationError`](#composevalidationerror) | `noServicesDefined`, `serviceNeedsImageOrBuild`, `invalidPortFormat`, `circularDependency`, `resourceConstraintOutOfRange` | Structural validation |
| [`IncludeError`](#includeerror) | `cyclicInclude`, `fileNotFound` | `include:` processing |
| [`ComposeMemoryParseError`](#composememoryarseerror) | `empty`, `invalid`, `negative`, `overflow` | Memory quantity parsing |
| [`ComposeWaitError`](#composewaiterror) | `timeout`, `nonZeroExitCode` | `depends_on` waiting |
| [`ListenAddressError`](#listenaddresserror) | `malformed`, `missingHostOrPort`, `unsupportedScheme` | `--listen` flag parsing |
| [`TerminalError`](#terminalerror) | `commandFailed` | Subprocess execution |
| [`OrchestratorError`](#orchestratorerror) | `projectNotFound`, `serviceNotFound`, `invalidReplicaCount` | REST API project routes |
| [`AuthStoreError`](#authstoreerror) | `duplicateName`, `malformedFile` | TLS client auth store |

---

## RuntimeError

**Source:** `Sources/Container-Compose/Runtime/Runtime.swift:191-200`

```swift
public enum RuntimeError: Error, Sendable, Equatable {
    case notFound(id: String)
    case alreadyExists(id: String)
    case invalidState(id: String, expected: RuntimeContainerStatus, actual: RuntimeContainerStatus)
    case timeout(id: String, seconds: Int)
    case imageNotFound(reference: String)
    case notSupported(operation: String, conformer: String)
    case backendFailure(message: String)
    case persistenceFailure(message: String)
}
```

`LocalizedError` messages are defined at `Runtime.swift:202-223`. The error type is `Equatable` — test assertions can use `==`.

Conformers map their backend-specific errors into this vocabulary using private `mapUpstreamError` helpers:
- Bridge conformer: `BridgeContainerClientRuntime.swift:317-333`
- Apple conformer: `AppleContainerizationRuntime.swift:322-333`

---

### `notFound(id: String)`

**Message:** `Runtime: container '<id>' not found` (`Runtime.swift:206`)

**Meaning:** No container, volume, network, or secret with the given identifier exists in the runtime's view.

**Actual throw sites:**
- `BridgeContainerClientRuntime.swift:90` — `get(id:)` catches any XPC error from `ContainerClientProvider.get`
- `BridgeContainerClientRuntime.swift:174` — `logs(id:)` catches any error from `ContainerClientProvider.logs`
- `AppleContainerizationRuntime.swift:103` — `get(id:)` when `registry.get(id:)` returns `nil`
- `AppleContainerizationRuntime.swift:134` — `start(id:)` when container absent
- `AppleContainerizationRuntime.swift:150` — `stop(id:)` when container absent
- `AppleContainerizationRuntime.swift:166` — `kill(id:)` when container absent
- `AppleContainerizationRuntime.swift:173` — `wait(id:)` when container absent
- `AppleContainerizationRuntime.swift:183` — `remove(id:)` when container absent
- `AppleContainerizationRuntime.swift:198` — `logs(id:)` when container absent
- `AppleContainerizationRuntime.swift:226` — `statistics(for:)` when container absent
- `RuntimeVolumeClient.swift:64` — `remove(name:)` when `VolumeError.volumeNotFound`
- `RuntimeVolumeClient.swift:70` — `remove(name:)` when `ContainerizationError` message contains `"not found"`
- `RuntimeVolumeClient.swift:84` — `inspect(name:)` when `VolumeError.volumeNotFound`
- `RuntimeVolumeClient.swift:90` — `inspect(name:)` when `ContainerizationError` message contains `"not found"`
- `RecordingRuntime.swift:141` — `get(id:)` when no stub matches
- `RecordingRuntime.swift:252` — `removeNetwork(id:)` when not in stubs
- `RecordingRuntime.swift:274` — `removeVolume(name:)` when not in stubs
- `RecordingRuntime.swift:293` — `removeSecret(name:)` when not in stubs
- `MockRuntime.swift:96` — `get(id:)` when absent
- `MockRuntime.swift:272` — `requireContainer` helper (used by all lifecycle methods)

**Common triggers:**
- Querying a container that was removed between your last `list` and this call
- A `compose down` ran concurrently with a `ps` or `logs` request
- Typo in the service or project name
- Calling `remove` on an already-removed container (non-idempotent)

**What users see in CLI output:**
```
Error: Runtime: container 'myproject-web' not found
```

**Recovery:**
1. Run `container-compose ps` to see currently registered containers.
2. If the container should exist, re-run `compose up` to recreate it.
3. Verify container naming: compose uses `<project>-<service>` convention.
4. For volume operations, check `container volume list`.

**HTTP mapping:** 404 Not Found (via `ErrorMappingMiddleware`)

**Related:** [protocol-contract.md — get](./protocol-contract.md#getid-string-async-throws---runtimecontainer)

---

### `alreadyExists(id: String)`

**Message:** `Runtime: container '<id>' already exists` (`Runtime.swift:208`)

**Meaning:** A resource with the given identifier already exists and the operation does not overwrite.

**Actual throw sites:**
- `AppleContainerizationRuntime.swift:115` — `create(id:)` when `registry.get(id:)` returns non-nil
- `RuntimeVolumeClient.swift:44` — `create(spec:)` when `VolumeError.volumeAlreadyExists`
- `RuntimeVolumeClient.swift:50` — `create(spec:)` when `ContainerizationError` message contains `"already exists"`
- `MockRuntime.swift:105` — `create(id:)` on duplicate id
- `MockRuntime.swift:364` — `createVolume(spec:)` on duplicate name
- `MockRuntime.swift:391` — `createSecret(spec:)` on duplicate name
- `MockRuntime.swift:336` — `createNetwork(spec:)` on duplicate name

**Common triggers:**
- Running `compose up` twice without `compose down` between runs
- Creating a named volume that already exists in the container runtime
- A failed teardown left orphan containers registered in the runtime

**What users see in CLI output:**
```
Error: Runtime: container 'myproject-web' already exists
```

**Recovery:**
1. Run `compose down` to clean up existing resources, then retry.
2. For volumes you want to preserve: inspect first (`container volume inspect <name>`), then decide whether to remove.
3. For orphan containers: `container rm <id>` removes an individual container.

**HTTP mapping:** 409 Conflict

---

### `invalidState(id: String, expected: RuntimeContainerStatus, actual: RuntimeContainerStatus)`

**Message:** `Runtime: container '<id>' has invalid state (expected <expected>, actual <actual>)` (`Runtime.swift:210`)

`RuntimeContainerStatus` cases: `unknown`, `created`, `running`, `stopping`, `stopped`, `exited` (`RuntimeTypes.swift:66-72`).

**Meaning:** A lifecycle operation was attempted on a container that is not in the required state.

**Actual throw sites:**
- `AppleContainerizationRuntime.swift:137-141` — `start(id:)` when state is not `.created`, `.stopped`, or `.exited`
- `AppleContainerizationRuntime.swift:186` — `remove(id:force: false)` when state is `.running`
- `MockRuntime.swift:125-126` — `start(id:)` when state is not `.created`
- `MockRuntime.swift:144-145` — `stop(id:)` when state is not `.running`
- `MockRuntime.swift:163-164` — `kill(id:)` when state is not `.running`
- `MockRuntime.swift:196-197` — `remove(id:force: false)` when state is `.running`

**Common triggers:**
- Calling `start` on an already-running container
- Calling `kill` on a stopped container (Mock only — Apple `kill` does not check state)
- Calling `remove` on a running container without `--force`
- A race condition between two concurrent lifecycle operations

**What users see in CLI output:**
```
Error: Runtime: container 'myproject-web' has invalid state (expected created, actual running)
```

**Recovery:**
1. Check current state: `container-compose ps`.
2. Stop the container before removing: `compose stop <service>`.
3. Use `--force` flag where the CLI exposes it (e.g. `compose rm --force`).
4. For the REST API, read the `actual` field in the error response before retrying.

**HTTP mapping:** 409 Conflict

---

### `timeout(id: String, seconds: Int)`

**Message:** `Runtime: container '<id>' timed out after <seconds>s` (`Runtime.swift:212`)

**Meaning:** A blocking `wait` operation did not complete within the allotted time.

**Actual throw sites:**
- `AppleContainerizationRuntime.swift:178` — `wait(id:)` when no `exitStatus` is recorded in Phase 1 (immediately)
- `MockRuntime.swift:188` — `wait(id:)` when deadline passes while polling

**Common triggers:**
- The container process is hung and not responding to SIGTERM
- The container is a long-running service that was never intended to exit
- In Phase 1 `AppleContainerizationRuntime`: always thrown when `wait` is called on a container that has not been stopped via `stop(id:)` first (the registry never records an exit status from a real process)

**What users see in CLI output:**
```
Error: Runtime: container 'myproject-worker' timed out after 30s
```

**Recovery:**
1. Send a stronger signal: `compose kill <service>` (SIGKILL).
2. For the REST API's `DELETE /containers/{id}` path, use `force=true`.
3. Increase the timeout if the container is genuinely slow to exit.

**HTTP mapping:** 504 Gateway Timeout

---

### `imageNotFound(reference: String)`

**Message:** `Runtime: image '<reference>' not found` (`Runtime.swift:214`)

**Meaning:** The container image was not found locally or could not be pulled at runtime. Distinct from `ComposeError.imageNotFound`, which fires at YAML parse time when a service has neither `image:` nor `build:`.

**Actual throw sites:** Not thrown by any current production conformer in Phase 1 — declared for Phase 2 when `AppleContainerizationRuntime.create()` wires the actual `ContainerManager.create` call and can encounter a missing image. Will be thrown by the Bridge conformer's `mapUpstreamError` helper when `apple/containerization` pull errors are mapped.

**Common triggers (Phase 2 and later):**
- The image tag does not exist in the registry
- Network access to the registry is unavailable
- A typo in the `image:` field

**What users see in CLI output:**
```
Error: Runtime: image 'myorg/myapp:v1.2.3' not found
```

**Recovery:**
1. Pull the image manually: `container pull <reference>`.
2. If using a private registry, check that credentials are configured.
3. For `build:`-backed services, run `compose build <service>` to build locally.

**Note:** `ComposeError.imageNotFound` fires earlier — see [ComposeError — imageNotFound](#imagenotfoundstring) below.

**HTTP mapping:** 404 Not Found

---

### `notSupported(operation: String, conformer: String)`

**Message:** `Runtime: operation '<operation>' is not supported by '<conformer>'` (`Runtime.swift:216`)

**Meaning:** The requested operation is not implemented by the active runtime backend.

**Actual throw sites:**
- `BridgeContainerClientRuntime.swift:78` — `listNetworks()`
- `BridgeContainerClientRuntime.swift:116-118` — `create(id:)`
- `BridgeContainerClientRuntime.swift:152-154` — `wait(id:)`
- `BridgeContainerClientRuntime.swift:442-445` — `createNetwork(spec:)`
- `BridgeContainerClientRuntime.swift:450-453` — `removeNetwork(id:)`
- `BridgeContainerClientRuntime.swift:476-479` — `listSecrets()`
- `BridgeContainerClientRuntime.swift:484-487` — `createSecret(spec:)`
- `BridgeContainerClientRuntime.swift:492-495` — `removeSecret(name:)`
- `AppleContainerizationRuntime.swift:360-364` — `createNetwork(spec:)`
- `AppleContainerizationRuntime.swift:368-372` — `removeNetwork(id:)`
- `AppleContainerizationRuntime.swift:395-398` — `listSecrets()`
- `AppleContainerizationRuntime.swift:403-406` — `createSecret(spec:)`
- `AppleContainerizationRuntime.swift:411-414` — `removeSecret(name:)`
- `RuntimeVolumeClient.swift:30` — `create(spec:)` when `spec.driver != "local"`

**Operation strings by conformer:**

| operation string | conformer | Reason |
| :--- | :--- | :--- |
| `"listNetworks"` | `BridgeContainerClientRuntime` | No network list API in XPC client |
| `"create"` | `BridgeContainerClientRuntime` | XPC create requires kernel path not available in REST path (Leak #13) |
| `"wait"` | `BridgeContainerClientRuntime` | No blocking wait in XPC client |
| `"createNetwork"` | `BridgeContainerClientRuntime` | No network CRUD in XPC client (Leak #9) |
| `"removeNetwork"` | `BridgeContainerClientRuntime` | No network CRUD in XPC client (Leak #9) |
| `"listSecrets"` | `BridgeContainerClientRuntime` | No secret management in XPC client (Leak #11) |
| `"createSecret"` | `BridgeContainerClientRuntime` | No secret management in XPC client (Leak #11) |
| `"removeSecret"` | `BridgeContainerClientRuntime` | No secret management in XPC client (Leak #11) |
| `"createNetwork"` | `AppleContainerizationRuntime` | No network CRUD in apple/containerization (Leak #9) |
| `"removeNetwork"` | `AppleContainerizationRuntime` | No network CRUD in apple/containerization (Leak #9) |
| `"listSecrets"` | `AppleContainerizationRuntime` | No secret management in apple/containerization (Leak #11) |
| `"createSecret"` | `AppleContainerizationRuntime` | No secret management in apple/containerization (Leak #11) |
| `"removeSecret"` | `AppleContainerizationRuntime` | No secret management in apple/containerization (Leak #11) |
| `"createVolume(driver=<driver>)"` | `RuntimeVolumeClient` | Only `"local"` driver is supported |

**What users see in CLI output:**
```
Error: Runtime: operation 'create' is not supported by 'BridgeContainerClientRuntime'
```

**Recovery:**
1. For container create/start via the REST API with Bridge backend: use `compose up` (CLI path) which goes through `RunCommandRunner` rather than the `Runtime` protocol.
2. For network CRUD: use `container network create/remove` CLI directly.
3. For secrets: use compose file `secrets:` with a `file:` source.
4. HTTP callers receive **501 Not Implemented**; treat this as "use the CLI instead."
5. For non-local volume drivers: only `driver: local` is supported; switch to the default or remove the `driver:` key.

**HTTP mapping:** 501 Not Implemented

---

### `backendFailure(message: String)`

**Message:** `Runtime backend failure: <message>` (`Runtime.swift:218`)

**Meaning:** The underlying runtime backend returned an error that does not map to a more specific `RuntimeError` case. The `message` field carries the backend's original error description.

**Actual throw sites:**
- `BridgeContainerClientRuntime.swift:329` — `mapUpstreamError` fallback for any non-`notFound` upstream error
- `RuntimeVolumeClient.swift:46` — `create` when `VolumeError` case is not `volumeAlreadyExists`
- `RuntimeVolumeClient.swift:52` — `create` when `ContainerizationError` doesn't contain `"already exists"`
- `RuntimeVolumeClient.swift:54` — `create` for any other error type
- `RuntimeVolumeClient.swift:66` — `remove` when `VolumeError` case is not `volumeNotFound`
- `RuntimeVolumeClient.swift:72` — `remove` when `ContainerizationError` doesn't contain `"not found"`
- `RuntimeVolumeClient.swift:74` — `remove` for any other error type
- `RuntimeVolumeClient.swift:86` — `inspect` when `VolumeError` case is not `volumeNotFound`
- `RuntimeVolumeClient.swift:92` — `inspect` when `ContainerizationError` doesn't contain `"not found"`
- `RuntimeVolumeClient.swift:94` — `inspect` for any other error type
- `LogRingBuffer.swift:83` — write-after-close: `"LogRingBuffer write after close"`

**Common triggers:**
- The `apple/container` XPC service is not running or has crashed
- An XPC call during `start` or `kill` failed for a reason other than not-found
- A stats (`vsock`) request failed for a running container
- Volume operations hitting an XPC error not covered by the specific error cases

**What users see in CLI output:**
```
Error: Runtime backend failure: start failed for 'myproject-web': The operation couldn't be completed.
```

**Recovery:**
1. Check that the container runtime service is running: `container system info`.
2. Inspect recent logs: `compose logs <service>`.
3. Restart the container runtime service if unresponsive.
4. HTTP callers receive **502 Bad Gateway**; a 502 indicates a problem with the underlying container runtime, not with the compose file.

**HTTP mapping:** 502 Bad Gateway

---

### `persistenceFailure(message: String)`

**Message:** `Runtime persistence failure: <message>` (`Runtime.swift:220`)

**Meaning:** A durable state write failed. Currently covers failures in `ContainerRegistry` (disk persistence) and POSIX file locking.

**Actual throw sites:**
- `ContainerRegistry.swift:183` — `loadFromDisk` when registry JSON cannot be decoded: `"could not decode registry at <path>: <error>"`
- `ContainerRegistry.swift:227` — `withFileLock` when lock file cannot be opened: `"could not open lock file '<path>' (errno=<errno>)"`
- `ContainerRegistry.swift:234` — `withFileLock` when `flock(LOCK_EX)` fails: `"could not acquire flock on '<path>' (errno=<errno>)"`

**Common triggers:**
- The container registry JSON file on disk is corrupt
- The process does not have write access to the registry directory
- A previous crash left an inconsistent lock file state
- Filesystem is full or the filesystem is read-only

**What users see in CLI output:**
```
Error: Runtime persistence failure: could not decode registry at /var/lib/container-compose/registry.json: ...
```

**Recovery:**
1. Retry once — transient lock acquisition failures may resolve automatically.
2. If the error persists, stop all containers (`compose down`) and restart the container runtime service.
3. If the registry file is corrupt, back it up and remove it; the registry will be re-initialized on next startup.
4. Report the `message` field content in a bug report — it contains the raw error from the disk/lock subsystem.

**HTTP mapping:** 500 Internal Server Error

---

## ComposeError

**Source:** `Sources/Container-Compose/Errors.swift:39-57`

```swift
public enum ComposeError: Error, LocalizedError {
    case imageNotFound(String)
    case invalidProjectName
    case externalVolumeNotFound(String)
    case invalidShellTokenization(input: String, reason: String)
}
```

Thrown during compose YAML parsing and startup, before any container is started.

---

### `imageNotFound(String)`

**Message:** `Service <name> must define either 'image' or 'build'.` (`Errors.swift:46`)

**Meaning:** A service in the compose file declares neither an `image:` field nor a `build:` section.

**Actual throw sites:**
- `Sources/Container-Compose/Commands/Compose+Pull.swift:39` — during `compose pull` when a service has no image reference
- `Sources/Container-Compose/Commands/ComposeCreate.swift:349` — during `compose create`
- `Sources/Container-Compose/Commands/ComposeRun.swift:175` — during `compose run`
- `Sources/Container-Compose/Commands/ComposeUp.swift:747` — during `compose up` service processing

**What users see:**
```
Error: Service myservice must define either 'image' or 'build'.
```

**Recovery:** Add either `image: <reference>` or `build: <context>` to the service definition.

**Note:** Distinct from `RuntimeError.imageNotFound`, which fires at container creation time when an image is not available in the registry.

---

### `invalidProjectName`

**Message:** `Could not find project name.` (`Errors.swift:50`)

**Meaning:** Container-Compose could not determine a project name from any available source.

**Actual throw sites:**
- `Sources/Container-Compose/Commands/ComposeCreate.swift:332`
- `Sources/Container-Compose/Commands/ComposeUp.swift:417`
- `Sources/Container-Compose/Commands/ComposeUp.swift:656`

Project name resolution order:
1. `--project-name` CLI flag
2. `COMPOSE_PROJECT_NAME` environment variable
3. Directory name of the compose file

**What users see:**
```
Error: Could not find project name.
```

**Recovery:** Pass `--project-name <name>` explicitly on the command line, or set `COMPOSE_PROJECT_NAME=myproject` in your shell environment.

---

### `externalVolumeNotFound(String)`

**Message:** `External volume '<name>' was not found. Create it with 'container volume create <name>' before running compose.` (`Errors.swift:53`)

**Meaning:** A volume declared with `external: true` under `volumes:` was not found in the container runtime's volume list.

**Actual throw sites:**
- `Sources/Container-Compose/Commands/ComposeUp.swift:441` — during `compose up` volume setup

**What users see:**
```
Error: External volume 'my-data' was not found. Create it with 'container volume create my-data' before running compose.
```

**Recovery:**
```sh
container volume create <name>
```
Then re-run `compose up`. If the volume name is wrong, correct the `name:` field under `volumes:` in the compose file.

---

### `invalidShellTokenization(input: String, reason: String)`

**Message:** `Could not tokenize string-form command/entrypoint '<input>': <reason>` (`Errors.swift:56`)

**Meaning:** A `command:` or `entrypoint:` field was given as a string (rather than a YAML list) and could not be split into tokens using POSIX shell rules.

**Actual throw sites:**
- `Sources/Container-Compose/Helper Functions.swift:177` — unterminated single quote
- `Sources/Container-Compose/Helper Functions.swift:179` — unterminated double quote
- `Sources/Container-Compose/Helper Functions.swift:181` — trailing backslash

**Reason values:**
- `"unterminated single quote"`
- `"unterminated double quote"`
- `"trailing backslash"`

**What users see:**
```
Error: Could not tokenize string-form command/entrypoint 'start --name 'my app': unterminated single quote
```

**Recovery:** Fix the quoting, or rewrite as a YAML list:
```yaml
# Before (string form — may fail)
command: "myapp --flag 'value with space'"

# After (list form — always safe)
command: ["myapp", "--flag", "value with space"]
```

---

## YamlError

**Source:** `Sources/Container-Compose/Errors.swift:28-37`

```swift
public enum YamlError: Error, LocalizedError {
    case composeFileNotFound(String)
}
```

---

### `composeFileNotFound(String)`

**Message:** `compose.yml not found at <path>` (`Errors.swift:33`)

**Meaning:** No compose file was found at the expected path. The associated string is the path that was searched.

**Common triggers:**
- Running `container-compose` from a directory that has no `compose.yml`, `compose.yaml`, `docker-compose.yml`, or `docker-compose.yaml`
- Specifying a `--file` path that does not exist

**What users see:**
```
Error: compose.yml not found at /Users/me/myproject
```

**Recovery:**
1. Verify the current directory: `ls compose.yml`
2. Pass the path explicitly: `container-compose -f /path/to/compose.yml up`

---

## ComposeValidationError

**Source:** `Sources/Container-Compose/Errors.swift:71-88`

```swift
public enum ComposeValidationError: Error, Equatable {
    case noServicesDefined
    case serviceNeedsImageOrBuild(serviceName: String)
    case invalidPortFormat(portSpec: String, serviceName: String)
    case circularDependency(serviceChain: [String])
    case resourceConstraintOutOfRange(field: String, value: String, min: Int, max: Int?)
}
```

Thrown by `DockerCompose.validate()` when a compose file contains invalid or semantically inconsistent configuration. Fired before any containers are started.

---

### `noServicesDefined`

**Message:** `Compose file defines no services.` (`Errors.swift:94`)

**Actual throw site:** `Sources/Container-Compose/Codable Structs/DockerCompose.swift:558`

**What users see:**
```
Error: Compose file defines no services.
```

**Recovery:** Add at least one service under the `services:` key.

---

### `serviceNeedsImageOrBuild(serviceName: String)`

**Message:** `Service '<name>' must define either 'image' or 'build'.` (`Errors.swift:96`)

**Actual throw site:** `Sources/Container-Compose/Codable Structs/DockerCompose.swift:564`

**Recovery:** Add `image:` or `build:` to the named service.

---

### `invalidPortFormat(portSpec: String, serviceName: String)`

**Message:** `Service '<serviceName>': invalid port specification '<portSpec>'.` (`Errors.swift:98`)

**Actual throw sites:** `DockerCompose.swift:609`, `DockerCompose.swift:640`, `DockerCompose.swift:657`, `DockerCompose.swift:662`

**Common triggers:**
- Port number outside the valid range (1–65535)
- Invalid port spec string format (e.g. missing `:`, extra colons)

**What users see:**
```
Error: Service 'web': invalid port specification '99999:80'.
```

**Recovery:** Use valid port format: `HOST_PORT:CONTAINER_PORT`, `HOST_PORT:CONTAINER_PORT/proto`, or `CONTAINER_PORT` alone. All port numbers must be in range 1–65535.

---

### `circularDependency(serviceChain: [String])`

**Message:** `Circular dependency detected: <svc1> → <svc2> → <svc1>` (`Errors.swift:100`)

**Actual throw site:** `Sources/Container-Compose/Codable Structs/DockerCompose.swift:675`

**What users see:**
```
Error: Circular dependency detected: web → db → web
```

**Recovery:** Remove the cycle from `depends_on`. Compose `depends_on` is a DAG — no service may directly or transitively depend on itself.

---

### `resourceConstraintOutOfRange(field: String, value: String, min: Int, max: Int?)`

**Message (with max):** `Resource constraint '<field>' value '<value>' is out of range [<min>, <max>].` (`Errors.swift:103`)
**Message (no max):** `Resource constraint '<field>' value '<value>' must be ≥ <min>.` (`Errors.swift:106`)

**What users see:**
```
Error: Resource constraint 'deploy.resources.limits.cpus' value '-1' must be ≥ 0.
```

**Recovery:** Set the resource constraint to a value within the documented range. For `cpus`, the minimum is `0`; for memory, the minimum is `0`.

---

## IncludeError

**Source:** `Sources/Container-Compose/Codable Structs/Include.swift` (lines around 75–87, verified by throw sites below)

Thrown when processing `include:` directives in a compose file.

---

### `cyclicInclude(String)`

**Message:** `Cyclic include detected: '<path>' is already being loaded.`

**Actual throw site:** `Sources/Container-Compose/Codable Structs/DockerCompose.swift:225`

**What users see:**
```
Error: Cyclic include detected: '/path/to/common.yml' is already being loaded.
```

**Recovery:** Remove the cycle. No compose file may include itself directly or transitively.

---

### `fileNotFound(String)`

**Message:** `Included compose file not found: '<path>'`

**Actual throw site:** `Sources/Container-Compose/Codable Structs/DockerCompose.swift:230`

**What users see:**
```
Error: Included compose file not found: '/path/to/shared.yml'
```

**Recovery:** Verify the path relative to the primary compose file's directory, or use an absolute path.

---

## ComposeMemoryParseError

**Source:** `Sources/Container-Compose/Helper Functions.swift:29-34`

Internal validation errors for memory quantity strings. Surfaces when Container-Compose validates memory fields for logical consistency.

---

### `empty`

**Actual throw site:** `Sources/Container-Compose/Helper Functions.swift:45`

**Meaning:** The memory quantity string is empty or whitespace-only.

**Recovery:** Provide a valid quantity: `256m`, `1g`, `536870912`.

---

### `invalid(String)`

**Actual throw site:** `Sources/Container-Compose/Helper Functions.swift:85`

**Meaning:** The memory quantity string has an unrecognized suffix or format.

**Recovery:** Use standard suffixes: `b`, `k`, `m`, `g`, `t` (case-insensitive), or IEC variants `Ki`, `Mi`, `Gi`, `Ti`.

---

### `negative(String)`

**Actual throw site:** `Sources/Container-Compose/Helper Functions.swift:87`

**Meaning:** The numeric portion is negative.

**Recovery:** Use a positive integer.

---

### `overflow(String)`

**Actual throw site:** `Sources/Container-Compose/Helper Functions.swift:90`

**Meaning:** The computed byte value overflows a `UInt64` (>16 exabytes).

**Recovery:** Use a realistic memory limit.

---

## ComposeWaitError

**Source:** `Sources/Container-Compose/Commands/Compose+Wait.swift:82-102`

Thrown when waiting for a `depends_on` condition to be satisfied.

---

### `timeout(containerName: String, condition: DependsOnCondition, seconds: TimeInterval)`

**Message:** `Timed out after <N>s waiting for container '<name>' to satisfy condition '<condition>'.`

**Actual throw site:** `Sources/Container-Compose/Commands/Compose+Wait.swift:75`

**Common triggers:**
- The upstream service is slow to start
- The upstream service is crash-looping on startup
- `condition: service_healthy` is specified but the service has no healthcheck defined

**What users see:**
```
Error: Timed out after 30s waiting for container 'myproject-db' to satisfy condition 'service_healthy'.
```

**Recovery:**
1. Check upstream service logs: `compose logs <upstream-service>`.
2. For `service_healthy`: ensure the upstream service defines a `healthcheck:` in the compose file.
3. Internal timeout is not currently user-configurable via compose YAML (`stop_grace_period` is warn-skipped — see `docs/feature-parity.md`).

---

### `nonZeroExitCode(containerName: String, exitCode: Int32)`

**Message:** `Container '<name>' exited with non-zero status <code>; service_completed_successfully condition not satisfied.`

**Actual throw site:** `Sources/Container-Compose/Commands/Compose+Wait.swift:65`

**What users see:**
```
Error: Container 'myproject-migrate' exited with non-zero status 1; service_completed_successfully condition not satisfied.
```

**Recovery:**
1. Run the service standalone: `compose run --no-deps <service>`.
2. Check logs: `compose logs <service>`.
3. Fix the service's startup logic or initialization script.

---

## ListenAddressError

**Source:** `Sources/Container-Compose/Commands/ListenAddress.swift:115-130`

Thrown when parsing the `--listen` address for `compose serve`.

---

### `malformed(String)`

**Actual throw site:** `Sources/Container-Compose/Commands/ListenAddress.swift:39`

**Meaning:** The address string does not match any supported format.

**Expected formats:** `unix:///path/to/socket`, `tcp://host:port`, `tls://host:port`

**What users see:**
```
Error: malformed listen address: 'localhost:8080'
```

**Recovery:** Correct the `--listen` flag: `--listen tcp://127.0.0.1:8080`

---

### `missingHostOrPort(String)`

**Actual throw site:** `Sources/Container-Compose/Commands/ListenAddress.swift:63`

**Meaning:** A `tcp://` or `tls://` address was provided but is missing the host or port component.

**Recovery:** Supply both: `tcp://127.0.0.1:2376`

---

### `unsupportedScheme(String)`

**Actual throw site:** `Sources/Container-Compose/Commands/ListenAddress.swift:68`

**Meaning:** The URL scheme is not one of `unix`, `tcp`, or `tls`.

**Recovery:** Use one of the supported schemes. `http://` and `https://` are not accepted — use `tcp://` or `tls://` instead.

---

## TerminalError

**Source:** `Sources/Container-Compose/Errors.swift:59-65`

```swift
public enum TerminalError: Error, LocalizedError {
    case commandFailed(String)
}
```

---

### `commandFailed(String)`

**Message:** `Command failed: <self>` (`Errors.swift:63`)

**Meaning:** A subprocess invoked via `RunCommandRunner` returned a non-zero exit code. The associated string is the command that failed.

**Common triggers:**
- `container run` or `container build` failed
- The `apple/container` CLI is not installed or not on `PATH`
- The container image failed to build or start

**Recovery:**
1. Run the failing command manually with the same arguments to see its output.
2. Verify that `container` is installed: `which container`.
3. Check container logs for startup errors.

---

## OrchestratorError

**Source:** `Sources/Container-Compose/Server/ProjectOrchestrator.swift:55-62` (approximate; verified by throw sites)

Errors surfaced by `ProjectOrchestrator` to REST API route handlers.

---

### `projectNotFound(name: String)`

**Actual throw sites:**
- `ProjectOrchestrator.swift:107` — when container list for project is empty
- `ProjectOrchestrator.swift:109` — when project lookup returns empty
- `ProjectOrchestrator.swift:148` — service operation with unknown project
- `ProjectOrchestrator.swift:175` — service operation with unknown project
- `ProjectOrchestrator.swift:239` — project stop with unknown project

**HTTP mapping:** 404 Not Found

**What users see in REST API:**
```json
{ "error": "project 'myproject' not found" }
```

**Recovery:** Verify the project name. If the project was never started, run `compose up` first. The REST API uses `<project>-<service>` to group containers.

---

### `serviceNotFound(project: String, service: String)`

**HTTP mapping:** 404 Not Found

**Recovery:** Check that the service name matches the `services:` key in the compose file exactly. Service names are case-sensitive.

---

### `invalidReplicaCount(Int)`

**Actual throw site:** `ProjectOrchestrator.swift:306`

**HTTP mapping:** 400 Bad Request

**Recovery:** Set `replicas` to a non-negative integer in the REST request body.

---

## AuthStoreError

**Source:** `Sources/Container-Compose/Server/AuthStore.swift:152-163` (approximate)

Thrown during `compose serve` startup when mutual TLS is configured.

---

### `duplicateName(String)`

**Actual throw site:** `Sources/Container-Compose/Server/AuthStore.swift:89`

**Meaning:** Two client certificates with the same name were found in the auth store configuration.

**Recovery:** Ensure each client entry in the TLS configuration has a unique name.

---

### `malformedFile(String)`

**Actual throw site:** `Sources/Container-Compose/Server/AuthStore.swift:77`

**Meaning:** The auth store file at the given path could not be decoded. The associated string is the file path.

**Recovery:** Verify the auth store file is valid JSON matching the expected schema. Re-generate it from the certificate if needed.

---

## See also

- [Runtime Protocol Contract](./protocol-contract.md) — how `RuntimeError` cases map to `Runtime` method throws, with per-conformer detail
- [Migration from Docker Compose](../guides/migration-from-docker-compose.md) — troubleshooting section for common migration errors
- [Feature Parity Inventory](../feature-parity.md) — which compose fields may silently fail (Tier 0)
- [Runtime Abstraction Leaks](../plans/runtime-abstraction-leaks.md) — known gaps that affect `notSupported` and `backendFailure` cases
- [Reviews](../reviews/) — code review notes and context
