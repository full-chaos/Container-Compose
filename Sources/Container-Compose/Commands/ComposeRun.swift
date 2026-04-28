//===----------------------------------------------------------------------===//
// Copyright © 2025 Morris Richman and the Container-Compose project authors. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

//
//  ComposeRun.swift
//  Container-Compose
//

import ArgumentParser
import ContainerAPIClient
import ContainerCommands
import ContainerizationExtras
import Foundation
import Yams

public struct ComposeRun: AsyncParsableCommand, @unchecked Sendable {
    public init() {}

    public static let configuration: CommandConfiguration = .init(
        commandName: "run",
        abstract: "Run a one-off command on a service"
    )

    @Argument(help: "The service to run a command on")
    var serviceName: String

    @Argument(parsing: .captureForPassthrough, help: "Command to run (overrides service command)")
    var command: [String] = []

    @Flag(name: [.customLong("detach")], help: "Run container in the background")
    var detach: Bool = false

    @Flag(name: [.long], help: "Remove container after exit")
    var rm: Bool = false

    @Flag(name: [.customLong("service-ports")], help: "Publish the service's ports to the host")
    var servicePorts: Bool = false

    @Option(name: [.customLong("run-env")], help: "Set an environment variable KEY=VALUE (can be repeated)")
    var environment: [String] = []

    @Option(name: [.customLong("run-volume")], help: "Bind-mount a volume (can be repeated)")
    var volumes: [String] = []

    @Option(name: [.customLong("run-user")], help: "Run as specified username or uid")
    var user: String?

    @Option(name: [.long], help: "Override the container name")
    var name: String?

    @Option(name: [.customShort("f"), .customLong("file")], help: "The path to your Docker Compose file")
    var composeFilename: String?

    @Option(name: [.long], help: "Specify a profile to enable. Can be specified multiple times.")
    var profile: [String] = []

    @OptionGroup
    var process: Flags.Process

    @OptionGroup
    var projectFlags: ProjectFlags

    @OptionGroup
    var logging: Flags.Logging

    // MARK: - Computed helpers

    private var cwd: String { process.cwd ?? FileManager.default.currentDirectoryPath }

    /// Project root for outside-container relative-path resolution. Honors
    /// `--project-directory`, falls back to the compose file's directory.
    private var effectiveProjectDirectory: String {
        resolveProjectDirectory(
            cliOverride: projectFlags.projectDirectory,
            composeFilePath: composePath,
            cwd: cwd
        )
    }

    private var cwdURL: URL { URL(fileURLWithPath: cwd) }

    private static let supportedComposeFilenames = [
        "compose.yml",
        "compose.yaml",
        "docker-compose.yml",
        "docker-compose.yaml",
    ]

    private var composePath: String {
        if let composeFilename {
            return resolvedPath(for: composeFilename, relativeTo: cwdURL)
        }
        for filename in Self.supportedComposeFilenames {
            let candidate = cwdURL.appending(path: filename).path
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }
        return cwdURL.appending(path: Self.supportedComposeFilenames[0]).path
    }

    private var envFilePath: String {
        let envFile = process.envFile.first ?? ".env"
        return resolvedPath(for: envFile, relativeTo: cwdURL)
    }

    // MARK: - run()

    public mutating func run() async throws {
        // 1. Load and merge compose file
        let dockerCompose = try DockerCompose
            .loadAndMerge(mainPath: composePath)
            .resolvingExtends()

        // 2. Load environment variables from .env file
        let environmentVariables = loadEnvFile(path: envFilePath)

        // 3. Determine project name (CLI flag > compose `name:` > directory basename).
        let projectName = resolveProjectName(
            cliOverride: projectFlags.projectName,
            composeName: dockerCompose.name,
            projectDirectory: effectiveProjectDirectory
        )

        // 4. Filter by active profiles
        var allServices: [(serviceName: String, service: Service)] = dockerCompose.services.compactMap { name, service in
            guard let service else { return nil }
            return (name, service)
        }
        let activeProfiles = Service.resolveActiveProfiles(cliProfiles: profile)
        allServices = Service.filterByProfiles(allServices, activeProfiles: activeProfiles)

        // 5. Find the named service
        guard let (_, service) = allServices.first(where: { $0.serviceName == serviceName }) else {
            throw ValidationError("Service '\(serviceName)' not found in compose file.")
        }

        // 6. Generate a unique one-off container name
        let containerName: String
        if let nameOverride = name {
            containerName = nameOverride
        } else {
            let uuidPrefix = String(UUID().uuidString.prefix(8).lowercased())
            containerName = "\(projectName)-\(serviceName)-run-\(uuidPrefix)"
        }

        // 7. Resolve the image to run
        let imageToRun: String
        if let img = service.image {
            let qualifiedImage = ComposeUp.qualifyImageReference(img)
            try await pullImage(qualifiedImage, platform: service.platform, policy: service.pull_policy, logging: logging)
            imageToRun = qualifiedImage
        } else if service.build != nil {
            // Build-only service — use the derived image tag
            imageToRun = ComposeUp.qualifyImageReference(service.image ?? "\(serviceName):latest")
        } else {
            throw ComposeError.imageNotFound(serviceName)
        }

        // 8. Build the argv for `container run`
        var runArgs: [String] = []

        // Detach flag
        if detach {
            runArgs.append("-d")
        }

        // Remove after exit
        if rm {
            runArgs.append("--rm")
        }

        // Container name
        runArgs.append(contentsOf: ["--name", containerName])

        // Build ArgsContext for the per-concern builders
        let ctx = ComposeUp.ArgsContext(
            service: service,
            serviceName: serviceName,
            projectName: projectName,
            containerName: containerName,
            detach: detach,
            environmentVariables: environmentVariables,
            dockerCompose: dockerCompose,
            composeFilename: composeFilename
        )

        // LifecycleArgs — but we already emitted -d and --name above, so we
        // use the raw builder and skip the duplicate platform / detach / name
        // flags by calling builders individually at the concern level.
        // Instead, call the sub-concerns that LifecycleArgs embeds:
        if let platform = service.platform {
            runArgs.append(contentsOf: ["--platform", platform])
        }
        if service.stdin_open == true { runArgs.append("-i") }
        if service.tty == true { runArgs.append("-t") }
        if service.init_ == true { runArgs.append("--init") }
        if let stopSignal = service.stop_signal {
            runArgs.append(contentsOf: ["--stop-signal", stopSignal])
        }
        if let gracePeriod = service.stop_grace_period,
           let seconds = ComposeUp.LifecycleArgs.parseGoDuration(gracePeriod) {
            runArgs.append(contentsOf: ["--stop-timeout", "\(seconds)"])
        }
        if let runtime = service.runtime {
            runArgs.append(contentsOf: ["--runtime", runtime])
        }
        if let loggingConfig = service.logging {
            if loggingConfig.driver != nil {
                warnUnsupportedRuntimeFieldOnce(
                    "service.logging.driver",
                    "Note: 'logging.driver' is parsed but not supported by Apple container; ignored."
                )
            }
            if let options = loggingConfig.options, !options.isEmpty {
                warnUnsupportedRuntimeFieldOnce(
                    "service.logging.options",
                    "Note: 'logging.options' is parsed but not supported by Apple container; ignored."
                )
            }
        }

        runArgs.append(contentsOf: ComposeUp.SecurityArgs.build(ctx))
        runArgs.append(contentsOf: ComposeUp.ResourceArgs.build(ctx))

        // Networking: only emit ports if --service-ports is set
        if servicePorts {
            runArgs.append(contentsOf: ComposeUp.NetworkingArgs.build(ctx))
        } else {
            // Emit everything from NetworkingArgs except the -p port bindings
            let networkArgs = ComposeUp.NetworkingArgs.build(ctx)
            // Filter out pairs of ["-p", "<value>"] from the args
            var filteredNetworkArgs: [String] = []
            var skipNext = false
            for arg in networkArgs {
                if skipNext {
                    skipNext = false
                    continue
                }
                if arg == "-p" {
                    skipNext = true
                    continue
                }
                filteredNetworkArgs.append(arg)
            }
            runArgs.append(contentsOf: filteredNetworkArgs)
        }

        runArgs.append(contentsOf: ComposeUp.StorageArgs.build(ctx))
        runArgs.append(contentsOf: ComposeUp.LabelsArgs.build(ctx))

        // Combined env: .env file + service env
        var combinedEnv = environmentVariables
        if let envFiles = service.env_file {
            for entry in envFiles {
                let resolved = URL(fileURLWithPath: entry.path, relativeTo: URL(fileURLWithPath: effectiveProjectDirectory)).path
                if !entry.required && !FileManager.default.fileExists(atPath: resolved) {
                    continue
                }
                let additionalEnvVars = loadEnvFile(path: resolved)
                combinedEnv.merge(additionalEnvVars) { current, _ in current }
            }
        }
        if let serviceEnv = service.environment {
            combinedEnv.merge(serviceEnv) { old, new in
                guard !new.contains("${") else { return old }
                return new
            }
        }
        combinedEnv = combinedEnv.mapValues { value in
            guard value.contains("${") else { return value }
            let varName = String(value.replacingOccurrences(of: "${", with: "").dropLast())
            return combinedEnv[varName] ?? value
        }
        for (key, value) in combinedEnv {
            runArgs.append(contentsOf: ["-e", "\(key)=\(value)"])
        }

        // Extra -e / --env flags from CLI
        for envVar in environment {
            runArgs.append(contentsOf: ["-e", envVar])
        }

        // Extra -v / --volume flags from CLI
        for vol in volumes {
            runArgs.append(contentsOf: ["-v", vol])
        }

        // User override from CLI
        if let userOverride = user {
            runArgs.append(contentsOf: ["--user", userOverride])
        } else if let serviceUser = service.user {
            runArgs.append(contentsOf: ["--user", serviceUser])
        }

        // 9. Image + entrypoint/command tail.
        //
        // The CLI `command` override (`!command.isEmpty`) wins outright per
        // `docker compose run [--] CMD…` semantics: the supplied tokens are
        // positional command args appended after the image, and any
        // service-level `entrypoint` / `command` is suppressed.
        //
        // Otherwise we mirror `compose up` and emit
        // `--entrypoint <first>` *before* the image with remaining entrypoint
        // tokens (and `command`) trailing as positional args. See
        // `Self.imageAndEntrypointTail(image:cliCommand:entrypoint:command:)`
        // and `docs/plans/PLAN.md` §1 / `docs/plans/PLAN-recorder-seam.md` §7.
        runArgs.append(contentsOf: Self.imageAndEntrypointTail(
            image: imageToRun,
            cliCommand: command,
            entrypoint: service.entrypoint,
            command: service.command
        ))

        // 10. Hand off to the runner.
        print("Running one-off container '\(containerName)' from service '\(serviceName)'")
        print("Executing: container run \(runArgs.joined(separator: " "))")

        // Route through the RunCommandRunner seam (PR-3 of the recorder
        // migration; see docs/plans/PLAN-recorder-seam.md §7 / §9 PR-3).
        // Production behaviour is byte-for-byte unchanged: the default
        // `ProductionRunner` falls back to `print` / `fputs(_:stderr)` when
        // the stdout/stderr closures are nil (see plan §10 Q5), preserving
        // the deleted `streamCommand`'s direct-stdio semantics.
        let request = RunRequest(
            kind: .streaming,
            argv: ["container", "run"] + runArgs,
            cwd: cwd
        )
        let _ = try await RunnerEnvironment.current.run(
            request,
            onStdout: nil,
            onStderr: nil
        )
    }

    // MARK: - Pull image helper

    private func pullImage(_ imageName: String, platform: String?, policy: String? = nil, logging: Flags.Logging) async throws {
        let qualifiedImageName = ComposeUp.qualifyImageReference(imageName)
        let effectivePolicy: String
        switch policy?.lowercased() {
        case nil, "missing", "if_not_present":
            effectivePolicy = "missing"
        case "always":
            effectivePolicy = "always"
        case "never":
            effectivePolicy = "never"
        case "build":
            effectivePolicy = "build"
        default:
            effectivePolicy = "missing"
        }

        let imageList = try await ContainerClientEnvironment.current.imageList()
        let imageExists = imageList.contains(where: {
            $0.description.reference == qualifiedImageName || $0.description.reference.components(separatedBy: "/").last == imageName
        })

        switch effectivePolicy {
        case "never", "build":
            guard imageExists else {
                throw ComposeError.imageNotFound(qualifiedImageName)
            }
            return
        case "always":
            break
        default:
            guard !imageExists else { return }
        }

        print("Pulling Image \(qualifiedImageName)...")

        var commands = [qualifiedImageName]
        if let platform {
            commands.append(contentsOf: ["--platform", platform])
        }

        let imagePullArgv = commands + logging.passThroughCommands()
        _ = try await RunnerEnvironment.current.run(
            RunRequest(kind: .swiftAPI(name: "ImagePull"), argv: imagePullArgv, cwd: nil),
            onStdout: nil,
            onStderr: nil
        )
    }
}

// MARK: Argv tail (image + entrypoint/command, with `compose run`'s CLI override)

extension ComposeRun {

    /// Builds the trailing portion of a `container run` argv for `compose run`.
    ///
    /// `compose run` adds one wrinkle on top of `compose up`'s
    /// `imageAndEntrypointTail`: a non-empty CLI command (`compose run [--]
    /// SVC CMD…`) is treated by Docker / Apple `container` as the in-container
    /// command and *suppresses* both the service-level `entrypoint` and
    /// `command` (the runtime keeps its image-default ENTRYPOINT). The CLI
    /// command tokens are appended after the image as positional args; no
    /// `--entrypoint` flag is emitted.
    ///
    /// Otherwise we mirror `ComposeUp.imageAndEntrypointTail` exactly: first
    /// element of `entrypoint` becomes the value of the pre-image
    /// `--entrypoint` flag, remaining tokens become positional args after the
    /// image, and `command` is appended last. This is the fix for
    /// `docs/plans/PLAN.md` §1 at the `compose run` site (the buggy code
    /// previously placed `--entrypoint` *after* the image, which the runtime
    /// then misparsed as a command).
    ///
    /// We deliberately keep this helper local to `ComposeRun` rather than
    /// extending `ComposeUp.imageAndEntrypointTail` to take a `cliCommand`:
    /// `compose up` has no per-call CLI override and adding a fourth
    /// parameter would force every up call site to pass `cliCommand: []`.
    /// Local helper keeps each command's argv logic readable in isolation.
    ///
    /// Resulting shapes:
    /// - `cliCommand: ["x", "y"]`, any `entrypoint` / `command` → `[<image>, "x", "y"]`
    ///   (CLI command suppresses service entrypoint AND service command)
    /// - `cliCommand: []`, `entrypoint: ["a"]`, no `command`         → `[--entrypoint, a, <image>]`
    /// - `cliCommand: []`, `entrypoint: ["a", "b"]`, `command: ["c"]` → `[--entrypoint, a, <image>, b, c]`
    /// - `cliCommand: []`, no `entrypoint`, `command: ["c"]`         → `[<image>, c]`
    /// - `cliCommand: []`, neither                                    → `[<image>]`
    static func imageAndEntrypointTail(
        image: String,
        cliCommand: [String],
        entrypoint: [String]?,
        command: [String]?
    ) -> [String] {
        // CLI command override wins outright: `docker compose run svc CMD…`
        // suppresses the service's entrypoint and command, and the supplied
        // tokens become positional args after the image.
        if !cliCommand.isEmpty {
            return [image] + cliCommand
        }

        var tail: [String] = []
        var positional: [String] = []

        if let entrypoint, let first = entrypoint.first {
            tail.append("--entrypoint")
            tail.append(first)
            positional.append(contentsOf: entrypoint.dropFirst())
        }

        tail.append(image)
        tail.append(contentsOf: positional)

        if let command {
            tail.append(contentsOf: command)
        }

        return tail
    }
}

// PR-3 of the recorder migration removed the
// `private func streamCommand(...)` helper that previously lived here. The
// `compose run` shell-out now flows through
// `RunnerEnvironment.current.run(_:onStdout:onStderr:)` (see the call site
// in `run()` above). `ProductionRunner` in
// `Sources/Container-Compose/Runtime/RunCommandRunner.swift` preserves the
// previous `Process()` semantics — including the parent-stdio fall-through
// when the closures are nil — byte-for-byte. See
// `docs/plans/PLAN-recorder-seam.md` §7 / §10 Q5 / §11.
