# Container-Compose

Container-Compose brings (limited) Docker Compose support to [Apple Container](https://github.com/apple/container), allowing you to define and orchestrate multi-container applications on Apple platforms using familiar Compose files. This project is not a Docker or Docker Compose wrapper but a tool to bridge Compose workflows with Apple's container management ecosystem.

> **Note:** Container-Compose does not automatically configure DNS for macOS 15 (Sequoia). Use macOS 26 (Tahoe) for an optimal experience.

### Coverage Report

<img width="1807" height="458" alt="image" src="https://github.com/user-attachments/assets/2b02b64c-18a5-4851-9d6a-e5fd886f92af" />

[Compose feature coverage report](https://full-chaos.github.io/container-compose/)

## Documentation

Full documentation lives in [`docs/`](./docs/):

- [**Quickstart**](./docs/quickstart.md) — up and running in 2 minutes
- [**CLI Reference**](./docs/cli-reference.md) — every subcommand and flag
- [**Tutorials**](./docs/tutorials/) — paired walkthroughs for the working samples in [`Sample Compose Files/`](./Sample%20Compose%20Files/)
- [**Feature Parity**](./docs/feature-parity.md) — tiered split of compose-spec coverage gaps
- [**Upstream / Fork Status**](./docs/upstream-fork-status.md) — what we depend on from `full-chaos/container` and what's pending in `apple/container`

## Features

- **Compose file support:** Parse and interpret `docker-compose.yml` files to configure Apple Containers.
- **Apple Container orchestration:** Launch and manage multiple containerized services using Apple’s native container runtime.
- **Environment configuration:** Support for environment variable files (`.env`) to customize deployments.
- **Service dependencies:** Specify service dependencies and startup order.
- **Volume and network mapping:** Map data and networking as specified in Compose files to Apple Container equivalents.
- **Extensible:** Designed for future extension and customization.

## Getting Started

### Prerequisites

- A Mac running macOS with Apple Container support (macOS Sonoma or later recommended)
- Git
- [Xcode command line tools](https://developer.apple.com/xcode/resources/) (for building, if building from source)

### Installation

You can install Container-Compose via **Homebrew** (recommended):

```sh
brew update
brew install container-compose
````

Or, build it from source:

1. **Clone the repository:**

   ```sh
   git clone https://github.com/Mcrich23/Container-Compose.git
   cd Container-Compose
   ```

2. **Build the executable:**

   > *Note: Ensure you have Swift installed (or the required toolchain).*

   ```sh
   make build
   ```

3. **(Optional)**: Install globally

   ```sh
   make install
   ```

### Usage

After installation, simply run:

```sh
container-compose up
```

You may need to provide a path to your `docker-compose.yml` and `.env` file as arguments.

## Native API server (optional)

The HTTP daemon exposes a Container REST API over a Unix domain socket at `~/.container-compose/api.sock`. It is optional — Container-Compose's CLI commands (`up`, `down`, `ps`, etc.) work without the daemon. The daemon is only needed for ecosystem tooling that wants to talk to Container-Compose over HTTP (e.g., reverse proxies, observability collectors, dashboards). The daemon runs in the foreground by default; users wanting background can use `brew services` (recommended for Homebrew installs) or `&`, `nohup`, or `tmux`.

### Auto-start with brew services (recommended)

Homebrew installs include a `LaunchAgent` plist so macOS can manage the daemon automatically:

```sh
brew services start container-compose   # start daemon + enable at login
brew services stop container-compose    # stop daemon + disable auto-start
brew services restart container-compose # restart (e.g., after config change)
```

Logs are written to `~/Library/Logs/container-compose/serve.log` and `serve.err`.

### Starting the daemon

```sh
container-compose serve
```

Press Ctrl-C or send SIGTERM (`kill -TERM <pid>`) to gracefully shut down.

To bind to a non-default socket path:

```sh
container-compose serve --socket /tmp/container-compose.sock
```

### Checking daemon status

Use `system status` to verify the daemon is reachable:

```sh
container-compose system status
```

Exit code 0 means the daemon is running and responsive; exit code 1 means it is not. This makes status suitable for shell scripts:

```sh
if container-compose system status >/dev/null; then
    echo "daemon is up"
fi
```

### Verifying the API

The daemon's `/_ping` endpoint confirms the HTTP layer is responsive:

```sh
curl --unix-socket "$HOME/.container-compose/api.sock" http://localhost/_ping
```

```
{"ok":true,"server":"container-compose","version":"0.11.0"}
```

### Idempotence

Running `container-compose serve` a second time while the daemon is already up detects the existing socket, prints a friendly message, and exits cleanly with status 0 — safe to invoke from setup scripts.

For architectural rationale, see [`docs/plans/native-api-server.md`](docs/plans/native-api-server.md).

## Contributing

Contributions are welcome! Please open issues or submit pull requests to help improve this project.

1. Fork the repository.
2. Create your feature branch (`git checkout -b feat/YourFeature`).
3. Commit your changes (`git commit -am 'Add new feature'`).
4. Add tests to you changes.
5. Push to the branch (`git push origin feature/YourFeature`).
6. Open a pull request.

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.

## Support

If you encounter issues or have questions, please open an [Issue](https://github.com/full-chaos/container-compose/issues).

---

Happy Coding! 🚀


<img width="1026" height="1005" alt="image" src="https://github.com/user-attachments/assets/d39c2dd6-6fa4-494e-9fbb-b825e3f61e47" />
