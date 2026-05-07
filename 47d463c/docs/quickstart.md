# Quickstart

Get a multi-container application running on Apple Container in 2 minutes.

## Prerequisites

- **Apple Silicon Mac**: Required for the native container runtime.
- **macOS 26 (Tahoe)**: Recommended for the best experience.
- **Apple Container**: Installed and running.
  ```bash title="terminal"
  container system start
  ```
- **Container-Compose**: Installed via Homebrew.
  ```bash title="terminal"
  brew install container-compose
  ```

## Step 1: Create your project

Create a new directory and a minimal `compose.yaml` file.

```bash title="terminal"
mkdir my-app && cd my-app
touch compose.yaml
```

Add the following content to `compose.yaml`:

```yaml title="compose.yaml"
services:
  web:
    image: nginx:alpine
    ports:
      - "8080:80"
```

## Step 2: Start the application

Launch your services in detached mode.

```bash title="terminal"
container-compose up -d
```

## Step 3: Verify status

Check that your container is running.

```bash title="terminal"
container-compose ps
```

## Step 4: Test the service

Verify the Nginx server is responding on the mapped port.

```bash title="terminal"
curl localhost:8080
```

## Step 5: Clean up

Stop and remove the containers when you are finished.

```bash title="terminal"
container-compose down
```

## What's Next

- Explore the [CLI Reference](./cli-reference.md) for advanced flags.
- Check out [Tutorials](./tutorials/) for complex architecture examples.

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
