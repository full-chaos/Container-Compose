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
//  DockerCompose.swift
//  container-compose-app
//
//  Created by Morris Richman on 6/17/25.
//

import Foundation
import Yams

/// Represents the top-level structure of a docker-compose.yml file.
public struct DockerCompose: Codable {
    /// The Compose file format version (e.g., '3.8')
    public let version: String?
    /// Optional project name
    public let name: String?
    /// Dictionary of service definitions, keyed by service name
    public let services: [String: Service?]
    /// Optional top-level model definitions
    public let models: [String: Model]?
    /// Optional top-level volume definitions
    public let volumes: [String: Volume?]?
    /// Optional top-level network definitions
    public let networks: [String: Network?]?
    /// Optional top-level config definitions (primarily for Swarm)
    public let configs: [String: Config?]?
    /// Optional top-level secret definitions (primarily for Swarm)
    public let secrets: [String: Secret?]?
    /// Optional list of other compose files to include and merge.
    public let include: [IncludeEntry]?
    /// Canonical path this document was loaded from, when loaded from disk.
    internal let sourcePath: String?

    /// Memberwise initializer used when creating a resolved copy
    /// (e.g. after `resolvingExtends()` or `loadAndMerge(...)`).
    public init(
        version: String?,
        name: String?,
        services: [String: Service?],
        models: [String: Model]? = nil,
        volumes: [String: Volume?]?,
        networks: [String: Network?]?,
        configs: [String: Config?]?,
        secrets: [String: Secret?]?,
        include: [IncludeEntry]? = nil
    ) {
        self.version = version
        self.name = name
        self.services = services
        self.models = models
        self.volumes = volumes
        self.networks = networks
        self.configs = configs
        self.secrets = secrets
        self.include = include
        self.sourcePath = nil
    }

    internal init(
        version: String?,
        name: String?,
        services: [String: Service?],
        models: [String: Model]? = nil,
        volumes: [String: Volume?]?,
        networks: [String: Network?]?,
        configs: [String: Config?]?,
        secrets: [String: Secret?]?,
        include: [IncludeEntry]? = nil,
        sourcePath: String?
    ) {
        self.version = version
        self.name = name
        self.services = services
        self.models = models
        self.volumes = volumes
        self.networks = networks
        self.configs = configs
        self.secrets = secrets
        self.include = include
        self.sourcePath = sourcePath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        services = try container.decode([String: Service?].self, forKey: .services)
        models = try container.decodeIfPresent([String: Model].self, forKey: .models)

        if let volumes = try container.decodeIfPresent([String: Optional<Volume>].self, forKey: .volumes) {
            let safeVolumes: [String: Volume] = volumes.mapValues { value in
                value ?? Volume()
            }
            self.volumes = safeVolumes
        } else {
            self.volumes = nil
        }
        networks = try container.decodeIfPresent([String: Network?].self, forKey: .networks)
        configs = try container.decodeIfPresent([String: Config?].self, forKey: .configs)
        secrets = try container.decodeIfPresent([String: Secret?].self, forKey: .secrets)
        include = try container.decodeIfPresent([IncludeEntry].self, forKey: .include)
        sourcePath = nil
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(version, forKey: .version)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encode(services, forKey: .services)
        try container.encodeIfPresent(volumes, forKey: .volumes)
        try container.encodeIfPresent(networks, forKey: .networks)
        try container.encodeIfPresent(configs, forKey: .configs)
        try container.encodeIfPresent(secrets, forKey: .secrets)
        try container.encodeIfPresent(include, forKey: .include)
    }

    enum CodingKeys: String, CodingKey {
        case version
        case name
        case services
        case models
        case volumes
        case networks
        case configs
        case secrets
        case include
    }
}

// MARK: - Multi-file merge
extension DockerCompose {
    /// Loads a compose file at `mainPath`, resolves its `include:` entries
    /// recursively, and returns a single merged `DockerCompose`.
    ///
    /// Merge order (compose-spec §include): included files are processed first
    /// (depth-first); the **main** file wins on any key collision, and a
    /// `Warning:` is printed for every overridden service/network/volume key.
    ///
    /// - Parameters:
    ///   - mainPath: Absolute or working-directory-relative path to the compose file.
    ///   - visited: Canonical paths already on the current call stack — used for
    ///     cycle detection. Pass the default empty set when calling from outside.
    /// - Throws: `IncludeError.cyclicInclude` if a cycle is detected,
    ///           `IncludeError.fileNotFound` if an included file is missing,
    ///           any `DecodingError` from the YAML decoder.
    public static func loadAndMerge(
        mainPath: String,
        visited: Set<String> = []
    ) throws -> DockerCompose {
        let loaded = try loadComposeDocument(mainPath: mainPath, visited: visited)
        let canonicalPath = loaded.canonicalPath
        let main = loaded.compose

        guard let includeEntries = main.include, !includeEntries.isEmpty else {
            return main
        }

        // Directory of the current file — used to resolve relative include paths.
        let baseDir = (canonicalPath as NSString).deletingLastPathComponent

        var newVisited = visited
        newVisited.insert(canonicalPath)

        // Start with an empty accumulator and fold in each included file.
        var merged = DockerCompose(
            version: nil,
            name: nil,
            services: [:],
            models: nil,
            volumes: nil,
            networks: nil,
            configs: nil,
            secrets: nil,
            include: nil,
            sourcePath: canonicalPath
        )

        for entry in includeEntries {
            for relativePath in entry.path {
                let includedPath: String
                if (relativePath as NSString).isAbsolutePath {
                    includedPath = relativePath
                } else {
                    includedPath = (baseDir as NSString).appendingPathComponent(relativePath)
                }
                let resolvedIncluded = (includedPath as NSString).standardizingPath

                let included = try loadAndMerge(mainPath: resolvedIncluded, visited: newVisited)
                merged = mergeTwo(base: merged, override: included)
            }
        }

        // Finally, the main file itself wins over everything included.
        return mergeTwo(base: merged, override: main, sourcePath: canonicalPath)
    }

    /// Shared compose-file loading primitive used by both `include:` and
    /// cross-file `extends:` resolution. It canonicalizes paths, applies the
    /// existing include cycle detection, loads the compose file's sibling `.env`,
    /// substitutes variables in the document, and decodes YAML.
    private static func loadComposeDocument(
        mainPath: String,
        visited: Set<String>
    ) throws -> (canonicalPath: String, compose: DockerCompose) {
        let fileManager = FileManager.default
        let canonicalPath = (mainPath as NSString).standardizingPath

        guard !visited.contains(canonicalPath) else {
            throw IncludeError.cyclicInclude(canonicalPath)
        }

        guard let yamlData = fileManager.contents(atPath: canonicalPath),
              var yamlString = String(data: yamlData, encoding: .utf8) else {
            throw IncludeError.fileNotFound(mainPath)
        }

        let baseDir = (canonicalPath as NSString).deletingLastPathComponent
        let envPath = (baseDir as NSString).appendingPathComponent(".env")
        yamlString = resolveVariable(yamlString, with: loadEnvFile(path: envPath))

        let decoded = try YAMLDecoder().decode(DockerCompose.self, from: yamlString)
        let compose = DockerCompose(
            version: decoded.version,
            name: decoded.name,
            services: decoded.services,
            volumes: decoded.volumes,
            networks: decoded.networks,
            configs: decoded.configs,
            secrets: decoded.secrets,
            include: decoded.include,
            sourcePath: canonicalPath
        )
        return (canonicalPath, compose)
    }

    /// Merges `override` on top of `base`.  For every key that exists in both,
    /// `override` wins and a warning is printed.  The `include` list is NOT
    /// propagated to the result (it has already been resolved).
    private static func mergeTwo(
        base: DockerCompose,
        override: DockerCompose,
        sourcePath: String? = nil
    ) -> DockerCompose {
        // Services
        var mergedServices = base.services
        for (key, value) in override.services {
            if mergedServices[key] != nil {
                print("Warning: Service '\(key)' defined in multiple compose files; the later definition wins.")
            }
            mergedServices[key] = value
        }

        // Models
        var mergedModels: [String: Model]? = base.models
        if let overrideModels = override.models {
            var models = mergedModels ?? [:]
            for (key, value) in overrideModels {
                if models[key] != nil {
                    print("Warning: Model '\(key)' defined in multiple compose files; the later definition wins.")
                }
                models[key] = value
            }
            mergedModels = models
        }

        // Volumes
        var mergedVolumes: [String: Volume?]? = base.volumes
        if let overrideVolumes = override.volumes {
            var vols = mergedVolumes ?? [:]
            for (key, value) in overrideVolumes {
                if vols[key] != nil {
                    print("Warning: Volume '\(key)' defined in multiple compose files; the later definition wins.")
                }
                vols[key] = value
            }
            mergedVolumes = vols
        }

        // Networks
        var mergedNetworks: [String: Network?]? = base.networks
        if let overrideNetworks = override.networks {
            var nets = mergedNetworks ?? [:]
            for (key, value) in overrideNetworks {
                if nets[key] != nil {
                    print("Warning: Network '\(key)' defined in multiple compose files; the later definition wins.")
                }
                nets[key] = value
            }
            mergedNetworks = nets
        }

        // Configs — simple last-wins merge
        var mergedConfigs: [String: Config?]? = base.configs
        if let overrideConfigs = override.configs {
            var cfgs = mergedConfigs ?? [:]
            cfgs.merge(overrideConfigs) { _, new in new }
            mergedConfigs = cfgs
        }

        // Secrets — simple last-wins merge
        var mergedSecrets: [String: Secret?]? = base.secrets
        if let overrideSecrets = override.secrets {
            var secs = mergedSecrets ?? [:]
            secs.merge(overrideSecrets) { _, new in new }
            mergedSecrets = secs
        }

        return DockerCompose(
            version: override.version ?? base.version,
            name: override.name ?? base.name,
            services: mergedServices,
            models: mergedModels,
            volumes: mergedVolumes,
            networks: mergedNetworks,
            configs: mergedConfigs,
            secrets: mergedSecrets,
            include: nil,  // resolved; not propagated
            sourcePath: sourcePath ?? override.sourcePath ?? base.sourcePath
        )
    }

    // MARK: - Phase 3F: extends resolution

    /// Returns a new `DockerCompose` with every service's `extends:` field resolved.
    ///
    /// - Throws: `ComposeError.extendsNotFound` if a referenced service doesn't exist,
    ///           `ComposeError.extendsCycle` if a cycle is detected.
    public func resolvingExtends(composeFilePath: String? = nil) throws -> DockerCompose {
        struct ServiceKey: Hashable {
            let file: String
            let service: String
        }

        let rootPath = (composeFilePath ?? sourcePath).map { ($0 as NSString).standardizingPath }
        let memoryPath = "<in-memory-compose>"
        let rootResolvedMap = concreteServices(from: self)
        var cache: [ServiceKey: Service] = [:]
        var visiting: Set<ServiceKey> = []

        func serviceKey(filePath: String?, name: String) -> ServiceKey {
            ServiceKey(file: filePath ?? memoryPath, service: name)
        }

        func resolveExtendsPath(_ extendsPath: String, relativeTo filePath: String?) -> String {
            let expanded = NSString(string: extendsPath).expandingTildeInPath
            if (expanded as NSString).isAbsolutePath { return (expanded as NSString).standardizingPath }
            let baseDir = filePath.map { ($0 as NSString).deletingLastPathComponent }
                ?? FileManager.default.currentDirectoryPath
            return ((baseDir as NSString).appendingPathComponent(expanded) as NSString).standardizingPath
        }

        func resolve(_ name: String, in compose: DockerCompose, filePath: String?) throws -> Service {
            let key = serviceKey(filePath: filePath, name: name)
            if let cached = cache[key] { return cached }

            let resolvedMap = filePath == rootPath ? rootResolvedMap : concreteServices(from: compose)
            guard let svc = resolvedMap[name] else {
                let location = filePath ?? "this Compose file"
                throw NSError(
                    domain: "ComposeError", code: 10,
                    userInfo: [NSLocalizedDescriptionKey: "extends: service '\(name)' not found in \(location)."]
                )
            }

            guard let extendsConfig = svc.extends else {
                cache[key] = svc
                return svc
            }

            guard !visiting.contains(key) else {
                throw NSError(
                    domain: "ComposeError", code: 11,
                    userInfo: [NSLocalizedDescriptionKey: "extends: cycle detected involving service '\(name)' in \(key.file)."]
                )
            }
            visiting.insert(key)

            let base: Service
            if let extendsFile = extendsConfig.file {
                let externalPath = resolveExtendsPath(extendsFile, relativeTo: filePath)
                let externalCompose = try DockerCompose.loadAndMerge(mainPath: externalPath)
                base = try resolve(
                    extendsConfig.service,
                    in: externalCompose,
                    filePath: externalCompose.sourcePath ?? externalPath
                )
            } else {
                base = try resolve(extendsConfig.service, in: compose, filePath: filePath)
            }

            visiting.remove(key)

            let merged = mergeService(base: base, override: svc)
            cache[key] = merged
            return merged
        }

        // Resolve every service.
        var newServices: [String: Service?] = [:]
        for name in rootResolvedMap.keys {
            newServices[name] = try resolve(name, in: self, filePath: rootPath)
        }
        // Preserve nil entries from the original map (though these are unusual).
        for (name, svc) in services where svc == nil {
            newServices[name] = nil
        }

        return DockerCompose(
            version: version,
            name: name,
            services: newServices,
            models: models,
            volumes: volumes,
            networks: networks,
            configs: configs,
            secrets: secrets,
            sourcePath: rootPath
        )
    }

    private func concreteServices(from compose: DockerCompose) -> [String: Service] {
        var resolvedMap: [String: Service] = [:]
        for (name, svc) in compose.services {
            guard let svc else { continue }
            resolvedMap[name] = svc
        }
        return resolvedMap
    }

    private func mergeService(base: Service, override svc: Service) -> Service {
        Service(
            image: svc.image ?? base.image,
            build: svc.build ?? base.build,
            deploy: svc.deploy ?? base.deploy,
            restart: svc.restart ?? base.restart,
            healthcheck: svc.healthcheck ?? base.healthcheck,
            volumes: svc.volumes ?? base.volumes,
            environment: svc.environment ?? base.environment,
            env_file: svc.env_file ?? base.env_file,
            ports: svc.ports ?? base.ports,
            command: svc.command ?? base.command,
            dependsOn: svc.dependsOn ?? base.dependsOn,
            user: svc.user ?? base.user,
            container_name: svc.container_name ?? base.container_name,
            networks: svc.networks ?? base.networks,
            hostname: svc.hostname ?? base.hostname,
            entrypoint: svc.entrypoint ?? base.entrypoint,
            privileged: svc.privileged ?? base.privileged,
            read_only: svc.read_only ?? base.read_only,
            working_dir: svc.working_dir ?? base.working_dir,
            platform: svc.platform ?? base.platform,
            configs: svc.configs ?? base.configs,
            secrets: svc.secrets ?? base.secrets,
            stdin_open: svc.stdin_open ?? base.stdin_open,
            tty: svc.tty ?? base.tty,
            cap_add: svc.cap_add ?? base.cap_add,
            cap_drop: svc.cap_drop ?? base.cap_drop,
            security_opt: svc.security_opt ?? base.security_opt,
            dns: svc.dns ?? base.dns,
            dns_opt: svc.dns_opt ?? base.dns_opt,
            dns_search: svc.dns_search ?? base.dns_search,
            extra_hosts: svc.extra_hosts ?? base.extra_hosts,
            domainname: svc.domainname ?? base.domainname,
            expose: svc.expose ?? base.expose,
            mac_address: svc.mac_address ?? base.mac_address,
            network_mode: svc.network_mode ?? base.network_mode,
            ipc: svc.ipc ?? base.ipc,
            pid: svc.pid ?? base.pid,
            uts: svc.uts ?? base.uts,
            userns_mode: svc.userns_mode ?? base.userns_mode,
            group_add: svc.group_add ?? base.group_add,
            init_: svc.init_ ?? base.init_,
            runtime: svc.runtime ?? base.runtime,
            scale: svc.scale ?? base.scale,
            pull_policy: svc.pull_policy ?? base.pull_policy,
            profiles: svc.profiles ?? base.profiles,
            models: svc.models ?? base.models,
            provider: svc.provider ?? base.provider,
            labels: svc.labels ?? base.labels,
            stop_signal: svc.stop_signal ?? base.stop_signal,
            stop_grace_period: svc.stop_grace_period ?? base.stop_grace_period,
            tmpfs: svc.tmpfs ?? base.tmpfs,
            sysctls: svc.sysctls ?? base.sysctls,
            volumes_from: svc.volumes_from ?? base.volumes_from,
            cpus_top: svc.cpus_top ?? base.cpus_top,
            cpu_count: svc.cpu_count ?? base.cpu_count,
            cpu_percent: svc.cpu_percent ?? base.cpu_percent,
            cpu_shares: svc.cpu_shares ?? base.cpu_shares,
            cpuset: svc.cpuset ?? base.cpuset,
            cpu_period: svc.cpu_period ?? base.cpu_period,
            cpu_quota: svc.cpu_quota ?? base.cpu_quota,
            cpu_rt_period: svc.cpu_rt_period ?? base.cpu_rt_period,
            cpu_rt_runtime: svc.cpu_rt_runtime ?? base.cpu_rt_runtime,
            mem_limit: svc.mem_limit ?? base.mem_limit,
            mem_reservation: svc.mem_reservation ?? base.mem_reservation,
            mem_swappiness: svc.mem_swappiness ?? base.mem_swappiness,
            memswap_limit: svc.memswap_limit ?? base.memswap_limit,
            oom_kill_disable: svc.oom_kill_disable ?? base.oom_kill_disable,
            oom_score_adj: svc.oom_score_adj ?? base.oom_score_adj,
            pids_limit: svc.pids_limit ?? base.pids_limit,
            shm_size: svc.shm_size ?? base.shm_size,
            ulimits: svc.ulimits ?? base.ulimits,
            logging: svc.logging ?? base.logging,
            devices: svc.devices ?? base.devices,
            device_cgroup_rules: svc.device_cgroup_rules ?? base.device_cgroup_rules,
            storage_opt: svc.storage_opt ?? base.storage_opt,
            extends: nil,  // clear extends after resolution
            gpus: svc.gpus ?? base.gpus,
            blkio_config: svc.blkio_config ?? base.blkio_config,
            develop: svc.develop ?? base.develop,
            cgroup_parent: svc.cgroup_parent ?? base.cgroup_parent,
            credential_spec: svc.credential_spec ?? base.credential_spec,
            isolation: svc.isolation ?? base.isolation,
            label_file: svc.label_file ?? base.label_file,
            post_start: svc.post_start ?? base.post_start,
            pre_stop: svc.pre_stop ?? base.pre_stop,
            pull_refresh_after: svc.pull_refresh_after ?? base.pull_refresh_after,
            use_api_socket: svc.use_api_socket ?? base.use_api_socket,
            annotations: svc.annotations ?? base.annotations,
            attach: svc.attach ?? base.attach,
            cgroup: svc.cgroup ?? base.cgroup
        )
    }
}

// MARK: - Validation

extension DockerCompose {
    /// Validates the compose document for semantic correctness.
    ///
    /// Checks performed:
    /// 1. At least one service is defined.
    /// 2. Each service has either `image` or `build` (not both).
    /// 3. Every port specification is parseable and port numbers are in 0–65535.
    /// 4. The `depends_on` graph is acyclic.
    /// 5. Resource constraints (`deploy.resources.limits.cpus`, `mem_limit`, etc.)
    ///    are within the allowed ranges.
    ///
    /// All violations are accumulated before throwing so the user sees every
    /// problem in one pass.
    ///
    /// - Throws: The first `ComposeValidationError` encountered (fail-fast within
    ///   each rule; all rules are checked in order).
    public func validate() throws {
        // 1. Non-empty services
        let concrete = services.compactMapValues { $0 }
        guard !concrete.isEmpty else {
            throw ComposeValidationError.noServicesDefined
        }

        // 2. Per-service checks: image/build conflict, image-or-build presence, ports, resources.
        for (name, service) in concrete {
            // image + build conflict: both present is ambiguous
            if service.image != nil && service.build != nil {
                throw ComposeValidationError.imageBuildConflict(serviceName: name)
            }

            // Must have at least one of image or build
            if service.image == nil && service.build == nil {
                throw ComposeValidationError.serviceNeedsImageOrBuild(serviceName: name)
            }

            if let ports = service.ports {
                try validatePorts(ports, forService: name)
            }

            try validateResourceConstraints(for: service, serviceName: name)
        }

        // 3. Circular dependency detection via DFS
        try detectCircularDependencies(in: concrete)
    }

    /// Validates a list of Compose port specifications for a given service.
    ///
    /// Accepted forms (with optional `/tcp` or `/udp` suffix):
    /// - `"80"` — bare container port
    /// - `"8080:80"` — host:container
    /// - `"127.0.0.1:8080:80"` — ip:host:container
    ///
    /// Port numbers must be in the range 0–65535.
    ///
    /// - Parameters:
    ///   - ports: The port strings from `service.ports`.
    ///   - serviceName: The service name, used in error messages.
    /// - Throws: `ComposeValidationError.invalidPortFormat` for any malformed
    ///   or out-of-range entry.
    public func validatePorts(_ ports: [String], forService serviceName: String) throws {
        for portSpec in ports {
            try Self.validatePortSpec(portSpec, serviceName: serviceName)
        }
    }

    // MARK: Private helpers

    /// Validates a single port specification string.
    private static func validatePortSpec(_ portSpec: String, serviceName: String) throws {
        // Strip optional /tcp or /udp protocol suffix
        var portBody = portSpec
        if let slashRange = portSpec.range(of: "/", options: [.backwards]) {
            let protocolPart = String(portSpec[slashRange.lowerBound...])
            if protocolPart == "/tcp" || protocolPart == "/udp" {
                portBody = String(portSpec[..<slashRange.lowerBound])
            }
            // Any other slash-prefixed suffix is invalid
            else {
                throw ComposeValidationError.invalidPortFormat(portSpec: portSpec, serviceName: serviceName)
            }
        }

        let components = portBody.split(separator: ":", maxSplits: 3).map(String.init)
        switch components.count {
        case 1:
            // "PORT"
            let containerPort = components[0]
            try validatePort(containerPort, portSpec: portSpec, serviceName: serviceName)
        case 2:
            // "HOST:CONTAINER" or "IP:CONTAINER" (IP contains dots)
            let hostPart = components[0]
            let containerPart = components[1]
            let hasIPv4 = hostPart.contains(".")
            let hasIPv6 = hostPart.contains(":") && hostPart.hasPrefix("[") && hostPart.hasSuffix("]")
            if hasIPv4 || hasIPv6 {
                // IP:CONTAINER — only containerPart is a port number
                try validatePort(containerPart, portSpec: portSpec, serviceName: serviceName)
            } else {
                // HOST:CONTAINER — both are port numbers
                try validatePort(hostPart, portSpec: portSpec, serviceName: serviceName)
                try validatePort(containerPart, portSpec: portSpec, serviceName: serviceName)
            }
        case 3:
            // "IP:HOST:CONTAINER"
            let hostPart = components[1]
            let containerPart = components[2]
            try validatePort(hostPart, portSpec: portSpec, serviceName: serviceName)
            try validatePort(containerPart, portSpec: portSpec, serviceName: serviceName)
        default:
            throw ComposeValidationError.invalidPortFormat(portSpec: portSpec, serviceName: serviceName)
        }
    }

    /// Validates that `portString` is a valid port number (0–65535).
    /// Port ranges like "8080-8090" are also accepted as valid Compose syntax.
    private static func validatePort(_ portString: String, portSpec: String, serviceName: String) throws {
        // Support port ranges (e.g. "8080-8090")
        if portString.contains("-") {
            let rangeParts = portString.split(separator: "-", maxSplits: 1).map(String.init)
            guard rangeParts.count == 2,
                  let low = Int(rangeParts[0]),
                  let high = Int(rangeParts[1]),
                  low >= 0, low <= 65535,
                  high >= 0, high <= 65535,
                  low <= high
            else {
                throw ComposeValidationError.invalidPortFormat(portSpec: portSpec, serviceName: serviceName)
            }
            return
        }
        guard let portNum = Int(portString), portNum >= 0, portNum <= 65535 else {
            throw ComposeValidationError.invalidPortFormat(portSpec: portSpec, serviceName: serviceName)
        }
    }

    /// Validates resource constraint fields on a service.
    ///
    /// Rules:
    /// - `deploy.resources.limits.cpus`: must be parseable as a positive number (> 0)
    /// - `cpus_top` (top-level `cpus:`): must be > 0
    /// - `mem_limit` / `deploy.resources.limits.memory`: must not be "0" (zero is rejected
    ///   by the compose-spec and apple/container alike)
    /// - `memswap_limit`: -1 is allowed (unlimited), otherwise must be parseable
    /// - `mem_swappiness`: 0–100
    /// - `oom_score_adj`: -1000–1000
    private func validateResourceConstraints(for service: Service, serviceName: String) throws {
        // deploy.resources.limits.cpus
        if let cpusStr = service.deploy?.resources?.limits?.cpus {
            guard let cpusVal = Double(cpusStr), cpusVal >= 0 else {
                throw ComposeValidationError.resourceConstraintOutOfRange(
                    field: "deploy.resources.limits.cpus",
                    value: cpusStr,
                    min: 0,
                    max: nil
                )
            }
        }

        // cpus (top-level service.cpus_top)
        if let cpusTop = service.cpus_top {
            guard cpusTop >= 0 else {
                throw ComposeValidationError.resourceConstraintOutOfRange(
                    field: "cpus",
                    value: String(cpusTop),
                    min: 0,
                    max: nil
                )
            }
        }

        // mem_limit: reject "0" — zero memory is always invalid
        if let memLimit = service.mem_limit {
            let trimmed = memLimit.trimmingCharacters(in: .whitespaces)
            if trimmed == "0" {
                throw ComposeValidationError.resourceConstraintOutOfRange(
                    field: "mem_limit",
                    value: memLimit,
                    min: 1,
                    max: nil
                )
            }
        }

        // deploy.resources.limits.memory: reject "0"
        if let deployMem = service.deploy?.resources?.limits?.memory {
            let trimmed = deployMem.trimmingCharacters(in: .whitespaces)
            if trimmed == "0" {
                throw ComposeValidationError.resourceConstraintOutOfRange(
                    field: "deploy.resources.limits.memory",
                    value: deployMem,
                    min: 1,
                    max: nil
                )
            }
        }

        // mem_swappiness: 0–100
        if let swappiness = service.mem_swappiness {
            guard swappiness >= 0, swappiness <= 100 else {
                throw ComposeValidationError.resourceConstraintOutOfRange(
                    field: "mem_swappiness",
                    value: String(swappiness),
                    min: 0,
                    max: 100
                )
            }
        }

        // oom_score_adj: -1000–1000
        if let oomAdj = service.oom_score_adj {
            guard oomAdj >= -1000, oomAdj <= 1000 else {
                throw ComposeValidationError.resourceConstraintOutOfRange(
                    field: "oom_score_adj",
                    value: String(oomAdj),
                    min: -1000,
                    max: 1000
                )
            }
        }
    }

    /// Performs a DFS cycle detection over the `depends_on` graph.
    private func detectCircularDependencies(in services: [String: Service]) throws {
        var visited: Set<String> = []
        var currentPath: [String] = []

        func dfs(service: String) throws {
            if let idx = currentPath.firstIndex(of: service) {
                // Cycle detected — build the chain from the cycle entry point to current
                let cycle = Array(currentPath[idx...]) + [service]
                throw ComposeValidationError.circularDependency(serviceChain: cycle)
            }

            guard !visited.contains(service) else { return }

            currentPath.append(service)
            if let deps = services[service]?.dependsOn {
                for depName in deps.serviceNames {
                    // Only recurse into services defined in this compose file
                    if services[depName] != nil {
                        try dfs(service: depName)
                    }
                }
            }
            currentPath.removeLast()
            visited.insert(service)
        }

        for serviceName in services.keys {
            try dfs(service: serviceName)
        }
    }
}
