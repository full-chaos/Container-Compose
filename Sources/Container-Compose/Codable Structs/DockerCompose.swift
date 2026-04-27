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


import Foundation

/// Represents the top-level structure of a docker-compose.yml file.
public struct DockerCompose: Codable {
    /// The Compose file format version (e.g., '3.8')
    public let version: String?
    /// Optional project name
    public let name: String?
    /// Dictionary of service definitions, keyed by service name
    public let services: [String: Service?]
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

    /// Memberwise initializer used when creating a resolved copy
    /// (e.g. after `resolvingExtends()` or `loadAndMerge(...)`).
    public init(
        version: String?,
        name: String?,
        services: [String: Service?],
        volumes: [String: Volume?]?,
        networks: [String: Network?]?,
        configs: [String: Config?]?,
        secrets: [String: Secret?]?,
        include: [IncludeEntry]? = nil
    ) {
        self.version = version
        self.name = name
        self.services = services
        self.volumes = volumes
        self.networks = networks
        self.configs = configs
        self.secrets = secrets
        self.include = include
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(String.self, forKey: .version)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        services = try container.decode([String: Service?].self, forKey: .services)

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
    }

    enum CodingKeys: String, CodingKey {
        case version
        case name
        case services
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
        let fileManager = FileManager.default

        // Resolve to a canonical path to reliably detect cycles across relative
        // symlinks and ".." segments.
        let canonicalPath: String = (mainPath as NSString).standardizingPath

        // Cycle detection
        guard !visited.contains(canonicalPath) else {
            throw IncludeError.cyclicInclude(canonicalPath)
        }

        // Read the file
        guard let yamlData = fileManager.contents(atPath: canonicalPath),
              let yamlString = String(data: yamlData, encoding: .utf8) else {
            throw IncludeError.fileNotFound(mainPath)
        }

        // Decode the main file (without recursing into includes yet)
        let main = try YAMLDecoder().decode(DockerCompose.self, from: yamlString)

        guard let includeEntries = main.include, !includeEntries.isEmpty else {
            // Nothing to merge
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
            volumes: nil,
            networks: nil,
            configs: nil,
            secrets: nil,
            include: nil
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
        return mergeTwo(base: merged, override: main)
    }

    /// Merges `override` on top of `base`.  For every key that exists in both,
    /// `override` wins and a warning is printed.  The `include` list is NOT
    /// propagated to the result (it has already been resolved).
    private static func mergeTwo(base: DockerCompose, override: DockerCompose) -> DockerCompose {
        // Services
        var mergedServices = base.services
        for (key, value) in override.services {
            if mergedServices[key] != nil {
                print("Warning: Service '\(key)' defined in multiple compose files; the later definition wins.")
            }
            mergedServices[key] = value
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
            volumes: mergedVolumes,
            networks: mergedNetworks,
            configs: mergedConfigs,
            secrets: mergedSecrets,
            include: nil  // resolved; not propagated
        )
    }

    // MARK: - Phase 3F: extends resolution

    /// Returns a new `DockerCompose` with every service's `extends:` field resolved.
    ///
    /// Only same-file extends is fully supported. Cross-file extends (`file:` parameter)
    /// emits a warning and is skipped — the extending service keeps its own fields.
    ///
    /// - Throws: `ComposeError.extendsNotFound` if a referenced service doesn't exist,
    ///           `ComposeError.extendsCycle` if a cycle is detected.
    public func resolvingExtends() throws -> DockerCompose {
        // Collect the concrete (non-nil) services.
        var resolvedMap: [String: Service] = [:]
        for (name, svc) in services {
            guard let svc else { continue }
            resolvedMap[name] = svc
        }

        // Topological resolve: iterate until stable or cycle detected.
        // We do a simple DFS with a "visiting" set for cycle detection.
        var cache: [String: Service] = [:]
        var visiting: Set<String> = []

        func resolve(_ name: String) throws -> Service {
            if let cached = cache[name] { return cached }

            guard let svc = resolvedMap[name] else {
                throw NSError(
                    domain: "ComposeError", code: 10,
                    userInfo: [NSLocalizedDescriptionKey: "extends: service '\(name)' not found in this Compose file."]
                )
            }

            guard let extendsConfig = svc.extends else {
                cache[name] = svc
                return svc
            }

            // Cross-file extends: warn and skip — use the service as-is.
            if extendsConfig.file != nil {
                print("Warning: Cross-file extends (file: \(extendsConfig.file!)) for service '\(name)' is not supported in this version. The extends will be skipped.")
                let stripped = Service(
                    image: svc.image, build: svc.build, deploy: svc.deploy, restart: svc.restart,
                    healthcheck: svc.healthcheck, volumes: svc.volumes, environment: svc.environment,
                    env_file: svc.env_file, ports: svc.ports, command: svc.command,
                    dependsOn: svc.dependsOn, user: svc.user, container_name: svc.container_name,
                    networks: svc.networks, hostname: svc.hostname, entrypoint: svc.entrypoint,
                    privileged: svc.privileged, read_only: svc.read_only, working_dir: svc.working_dir,
                    platform: svc.platform, configs: svc.configs, secrets: svc.secrets,
                    stdin_open: svc.stdin_open, tty: svc.tty,
                    cap_add: svc.cap_add, cap_drop: svc.cap_drop, security_opt: svc.security_opt,
                    dns: svc.dns, dns_opt: svc.dns_opt, dns_search: svc.dns_search,
                    extra_hosts: svc.extra_hosts, domainname: svc.domainname, expose: svc.expose,
                    mac_address: svc.mac_address, network_mode: svc.network_mode,
                    ipc: svc.ipc, pid: svc.pid, uts: svc.uts, userns_mode: svc.userns_mode,
                    group_add: svc.group_add, init_: svc.init_, runtime: svc.runtime,
                    scale: svc.scale, pull_policy: svc.pull_policy, profiles: svc.profiles,
                    labels: svc.labels, stop_signal: svc.stop_signal, stop_grace_period: svc.stop_grace_period,
                    tmpfs: svc.tmpfs, sysctls: svc.sysctls, volumes_from: svc.volumes_from,
                    cpus_top: svc.cpus_top, cpu_count: svc.cpu_count, cpu_percent: svc.cpu_percent,
                    cpu_shares: svc.cpu_shares, cpuset: svc.cpuset, cpu_period: svc.cpu_period,
                    cpu_quota: svc.cpu_quota, cpu_rt_period: svc.cpu_rt_period, cpu_rt_runtime: svc.cpu_rt_runtime,
                    mem_limit: svc.mem_limit, mem_reservation: svc.mem_reservation,
                    mem_swappiness: svc.mem_swappiness, memswap_limit: svc.memswap_limit,
                    oom_kill_disable: svc.oom_kill_disable, oom_score_adj: svc.oom_score_adj,
                    pids_limit: svc.pids_limit, shm_size: svc.shm_size,
                    ulimits: svc.ulimits, logging: svc.logging,
                    devices: svc.devices, device_cgroup_rules: svc.device_cgroup_rules, storage_opt: svc.storage_opt,
                    extends: nil
                )
                cache[name] = stripped
                return stripped
            }

            // Cycle detection.
            if visiting.contains(name) {
                throw NSError(
                    domain: "ComposeError", code: 11,
                    userInfo: [NSLocalizedDescriptionKey: "extends: cycle detected involving service '\(name)'."]
                )
            }
            visiting.insert(name)

            // Recursively resolve the base service.
            let base = try resolve(extendsConfig.service)

            visiting.remove(name)

            // Merge: child fields override base fields (child wins when non-nil).
            let merged = Service(
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
                extends: nil  // clear extends after resolution
            )

            cache[name] = merged
            return merged
        }

        // Resolve every service.
        var newServices: [String: Service?] = [:]
        for name in resolvedMap.keys {
            newServices[name] = try resolve(name)
        }
        // Preserve nil entries from the original map (though these are unusual).
        for (name, svc) in services where svc == nil {
            newServices[name] = nil
        }

        return DockerCompose(
            version: version,
            name: name,
            services: newServices,
            volumes: volumes,
            networks: networks,
            configs: configs,
            secrets: secrets
        )
    }
}
