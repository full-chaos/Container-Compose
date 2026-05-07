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

public struct ComposeRun: AsyncParsableCommand, ComposeCommand, @unchecked Sendable {
    public init() {}

    public static let configuration: CommandConfiguration = .init(
        commandName: "run",
        abstract: "Run a one-off command on a service"
    )

    @Argument(help: "The service to run a command on")
    var serviceName: String

    @Argument(parsing: .captureForPassthrough, help: "Command to run (overrides service command)")
    var command: [String] = []

    @Flag(name: [.customShort("d"), .customLong("detach")], help: "Run container in the background")
    var detach: Bool = false

    @Flag(name: [.long], help: "Remove container after exit")
    var rm: Bool = false

    @Flag(name: [.customLong("service-ports")], help: "Publish the service's ports to the host")
    var servicePorts: Bool = false

    @Option(name: [.short, .long], help: "Set an environment variable KEY=VALUE (can be repeated)")
    var environment: [String] = []

    @Option(name: [.customShort("v"), .customLong("volume")], help: "Bind-mount a volume (can be repeated)")
    var volumes: [String] = []

    @Option(name: [.short, .long], help: "Run as specified username or uid")
    var user: String?

    @Option(name: [.long], help: "Override the container name")
    var name: String?

    @Option(name: [.customShort("f"), .customLong("file")], help: "The path to your Docker Compose file")
    var composeFilename: String?

    @Option(name: [.long], help: "Specify a profile to enable. Can be specified multiple times.")
    var profile: [String] = []

    @OptionGroup
    var process: Flags.ProcessBase

    @OptionGroup
    var projectFlags: ProjectFlags

    @OptionGroup
    var logging: Flags.Logging

    // MARK: - Computed helpers

    var cwd: String { process.cwd ?? FileManager.default.currentDirectoryPath }

    private var envFilePath: String {
        let envFile = process.envFile.first ?? ".env"
        return resolvedPath(for: envFile, relativeTo: cwdURL)
    }

    // MARK: - run()

    public mutating func run() async throws {
        // 1. Load and merge compose file
        let dockerCompose = try loadAndResolve()

        // 2. Load environment variables from .env file
        let environmentVariables = loadEnvFile(path: envFilePath)

        // 3. Determine project name (CLI flag > compose `name:` > directory basename).
        let projectName = resolveProjectName(for: dockerCompose)

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

        if RuntimeExecutionMode.isRemote {
            try await remoteRun(service, projectName: projectName)
            return
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
            try await pullImage(
                image: qualifiedImage,
                policy: service.pull_policy,
                platform: service.platform,
                loggingArguments: logging.passThroughCommands()
            )
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
        let supportsHealthcheckFlags = service.healthcheck == nil
            ? false
            : await ComposeUp.LifecycleArgs.supportsHealthcheckFlags(for: "run")
        let supportsBlkioFlags = service.blkio_config == nil
            ? false
            : await ComposeUp.ResourceArgs.supportsBlkioFlags(for: "run")

        let ctx = ComposeUp.ArgsContext(
            service: service,
            serviceName: serviceName,
            projectName: projectName,
            containerName: containerName,
            detach: detach,
            environmentVariables: environmentVariables,
            dockerCompose: dockerCompose,
            composeFilename: composeFilename,
            supportsHealthcheckFlags: supportsHealthcheckFlags,
            supportsBlkioFlags: supportsBlkioFlags
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
        // stop_signal + stop_grace_period — Apple container's `container run`
        // accepts neither flag, so both warn-and-skip. Centralized helper keeps
        // the message strings in sync with `LifecycleArgs` (warn-once dedup
        // makes calling from both sites safe).
        warnUnsupportedContainerLifecycleStopFields(service)
        if let runtime = service.runtime {
            runArgs.append(contentsOf: ["--runtime", runtime])
        }
        runArgs.append(contentsOf: ComposeUp.LifecycleArgs.healthcheckArgs(
            for: service.healthcheck,
            supportsHealthcheckFlags: supportsHealthcheckFlags
        ))
        warnUnsupportedContainerLoggingFields(service)

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
        var combinedEnv = mergeServiceEnvironment(
            baseline: environmentVariables,
            serviceEnvFile: service.env_file,
            serviceEnvironment: service.environment,
            projectDirectory: effectiveProjectDirectory
        )
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

    private func remoteRun(_ service: Service, projectName: String) async throws {
        let runtime = RuntimeEnvironment.current

        guard volumes.isEmpty else {
            throw RuntimeError.notSupported(operation: "compose run --volume", conformer: "RemoteRuntime")
        }
        guard service.entrypoint == nil || !command.isEmpty else {
            throw RuntimeError.notSupported(operation: "remote compose run with service entrypoint", conformer: "RemoteRuntime")
        }
        guard !(detach && rm) else {
            throw RuntimeError.notSupported(operation: "compose run --detach --rm", conformer: "RemoteRuntime")
        }

        let containerName: String
        if let nameOverride = name {
            containerName = nameOverride
        } else {
            let uuidPrefix = String(UUID().uuidString.prefix(8).lowercased())
            containerName = "\(projectName)-\(serviceName)-run-\(uuidPrefix)"
        }

        guard let image = service.image else {
            if service.build != nil {
                throw RuntimeError.notSupported(operation: "remote compose run for build-only service '\(serviceName)'", conformer: "RemoteRuntime")
            }
            throw ComposeError.imageNotFound(serviceName)
        }

        var combinedEnv = mergeServiceEnvironment(
            baseline: loadEnvFile(path: envFilePath),
            serviceEnvFile: service.env_file,
            serviceEnvironment: service.environment,
            projectDirectory: effectiveProjectDirectory
        )
        for envVar in environment {
            let parts = envVar.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 {
                combinedEnv[String(parts[0])] = String(parts[1])
            }
        }

        let runtimeCommand = command.isEmpty ? (service.command ?? []) : command
        let ports = servicePorts ? remotePublishedPorts(for: service) : []
        let config = RuntimeCreateConfiguration(
            imageReference: ComposeUp.qualifyImageReference(image),
            cpus: Int(service.cpus_top ?? 1),
            hostname: service.hostname,
            environment: combinedEnv.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" },
            command: runtimeCommand,
            workingDirectory: service.working_dir,
            publishedPorts: ports,
            capabilities: RuntimeCapabilities(add: service.cap_add ?? [], drop: service.cap_drop ?? []),
            securityOpt: service.security_opt,
            readOnly: service.read_only,
            user: user ?? service.user,
            groupAdd: service.group_add,
            privileged: service.privileged
        )

        if (try? await runtime.get(id: containerName)) != nil {
            try await runtime.remove(id: containerName, force: true)
        }

        _ = try await runtime.create(id: containerName, configuration: config)
        try await runtime.start(id: containerName)
        print("Started remote one-off container: \(containerName)")

        if !detach {
            _ = try await runtime.wait(id: containerName, timeoutSeconds: 30)
            if rm {
                try await runtime.remove(id: containerName, force: true)
            }
        }
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
