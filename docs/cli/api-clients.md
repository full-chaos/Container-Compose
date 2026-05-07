---
title: container-compose API clients
description: SDKs and client packages generated from Resources/openapi.yaml.
---

# container-compose API clients

The daemon exposes a hand-written OpenAPI 3.1 contract at `GET /openapi.yaml`.
This page tracks the language-specific SDKs generated from that contract.

## Package targets

| Language | Package target | Notes |
| :--- | :--- | :--- |
| Swift | `container-compose-client-swift` | SwiftPM package tarball attached to tagged GitHub releases. |
| TypeScript | `@full-chaos/container-compose-client` | Published to npm with `latest` tags for releases and `snapshot` tags for main. |
| Python | `container-compose-client` | Published to PyPI with release versions and unique `.dev` snapshot versions. |
| Go | `github.com/full-chaos/container-compose-client` | Go module source tarball attached to tagged GitHub releases. |

## Consumer snippets

### TypeScript

```bash
npm install @full-chaos/container-compose-client
```

```ts
import { createClient } from "@full-chaos/container-compose-client";

const client = createClient({
  baseUrl: "https://localhost:8443",
  token: process.env.CONTAINER_COMPOSE_TOKEN,
});

const { data, error } = await client.GET("/version");
if (error) throw error;
console.log(data.version);
```

### Python

```bash
pip install container-compose-client
```

```python
from container_compose_client import Client

client = Client(base_url="https://localhost:8443", token="...")
```

### Swift

The generated Swift target is a SwiftPM package named
`ContainerComposeClient`. Tagged builds attach a `container-compose-client-swift`
source package tarball to the GitHub release.

```swift
import ContainerComposeClient
import OpenAPIURLSession

let client = Client(
    serverURL: URL(string: "https://localhost:8443")!,
    transport: URLSessionTransport()
)
```

### Go

Tagged builds attach a Go module source tarball using module path
`github.com/full-chaos/container-compose-client`.

```go
client, err := containercomposeclient.NewClient("https://localhost:8443")
if err != nil {
    panic(err)
}
_ = client
```

## Local generation

If you need to regenerate a client locally, start from `Resources/openapi.yaml` and use the language toolchain that matches the target package.

```bash title="terminal"
swift test --filter OpenAPIRouteTests

# TypeScript
npx --yes openapi-typescript Resources/openapi.yaml -o /tmp/container-compose-client/index.d.ts

# Python
python3 -m pip install --upgrade openapi-python-client
openapi-python-client generate --path Resources/openapi.yaml --output-path /tmp/container-compose-client-python --overwrite

# Go
go install github.com/oapi-codegen/oapi-codegen/v2/cmd/oapi-codegen@latest
"$(go env GOPATH)/bin/oapi-codegen" --package containercomposeclient --generate types,client -o /tmp/container-compose-client-go/client.gen.go Resources/openapi.yaml
```

The Swift client is emitted as a SwiftPM package rooted at `dist/swift` in CI.
It contains `Sources/ContainerComposeClient/openapi.yaml`,
`openapi-generator-config.yaml`, and a `Package.swift` that runs
`apple/swift-openapi-generator` during `swift build`.

## Release model

- Pull request and main-branch builds upload snapshot SDK tarballs as workflow artifacts.
- Main-branch builds publish npm snapshots with the `snapshot` dist-tag and PyPI snapshots with unique `0.0.0.dev<run>` versions.
- Tagged releases attach the same versioned SDK tarballs to the GitHub release and publish npm/PyPI packages with the tag's version.
- Pull-request SDK generation is path-filtered to `Resources/openapi.yaml` and the SDK workflow itself, while pushes to `main` and `v*` tags always run the publishing workflow.
- `Resources/openapi.yaml` remains the source of truth; the SDK workflow should fail if the bundled spec stops matching the served route.

## See also

- [`container-compose serve`](./serve.md)
- [`container-compose system`](./system.md)
- [`CLI reference`](../cli-reference.md)
