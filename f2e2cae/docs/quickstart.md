# Quickstart

Get a multi-container application running on Apple Container in 2 minutes.

## Prerequisites

- **Apple Silicon Mac**: Required for the native container runtime.
- **macOS 26 (Tahoe)**: Recommended for the best experience.
- **Apple Container**: Installed and running.
  ```bash filename="terminal"
  container system start
  ```
- **Container-Compose**: Installed via Homebrew.
  ```bash filename="terminal"
  brew install container-compose
  ```

## Step 1: Create your project

Create a new directory and a minimal `compose.yaml` file.

```bash filename="terminal"
mkdir my-app && cd my-app
touch compose.yaml
```

Add the following content to `compose.yaml`:

```yaml filename="compose.yaml"
services:
  web:
    image: nginx:alpine
    ports:
      - "8080:80"
```

## Step 2: Start the application

Launch your services in detached mode.

```bash filename="terminal"
container-compose up -d
```

## Step 3: Verify status

Check that your container is running.

```bash filename="terminal"
container-compose ps
```

## Step 4: Test the service

Verify the Nginx server is responding on the mapped port.

```bash filename="terminal"
curl localhost:8080
```

## Step 5: Clean up

Stop and remove the containers when you are finished.

```bash filename="terminal"
container-compose down
```

## Using a `.env` file

Create a `.env` file in the same directory as your compose file:

```bash filename=".env"
IMAGE_TAG=alpine
HOST_PORT=8080
```

Reference the variables in `compose.yaml`:

```yaml filename="compose.yaml"
services:
  web:
    image: nginx:${IMAGE_TAG}
    ports:
      - "${HOST_PORT}:80"
```

Container-Compose loads `./.env` by default. Pass a different file with `--env-file`:

```bash filename="terminal"
container-compose --env-file ./config/prod.env up -d
```

Verify substitution before starting:

```bash filename="terminal"
container-compose config
```

## Multi-service with `depends_on`

This example starts a web service only after Redis passes its healthcheck.

```yaml filename="compose.yaml"
services:
  web:
    image: nginx:alpine
    ports:
      - "8080:80"
    depends_on:
      redis:
        condition: service_healthy

  redis:
    image: redis:7-alpine
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 5
```

Container-Compose enforces the ordering: `redis` must reach a healthy state before `web` starts. If `redis` has no `healthcheck` block, the condition falls back to `service_started` (running state). See [Troubleshooting — depends_on with service_healthy](./guides/troubleshooting.md#depends_on-with-condition-service_healthy-doesnt-wait) if the wait does not behave as expected.

## What's Next

- Explore the [CLI Reference](./cli-reference.md) for advanced flags.
- Check out [Tutorials](./tutorials/) for complex architecture examples.
- Read [Limitations and Gotchas](./guides/limitations-and-gotchas.md) before dropping in an existing stack.
- See [Troubleshooting](./guides/troubleshooting.md) if something is not working.
## Essential Commands

| Command | Description |
| :--- | :--- |
| `up` | Create and start containers. |
| `down` | Stop and remove containers, networks, and images. |
| `ps` | List containers. |
| `logs` | View output from containers. |
| `build` | Build or rebuild services. |
| `exec` | Execute a command in a running container. |
| `run` | Run a one-off command on a service. |
| `watch` | Watch for file changes and update containers. |
