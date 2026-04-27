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
//  Service.swift
//  container-compose-app
//
//  Created by Morris Richman on 6/17/25.
//

import Foundation


/// Represents a single service definition within the `services` section.
public struct Service: Codable, Hashable {
    /// Docker image name
    public let image: String?

    /// Build configuration if the service is built from a Dockerfile
    public let build: Build?

    /// Deployment configuration (primarily for Swarm)
    public let deploy: Deploy?

    /// Restart policy (e.g., 'unless-stopped', 'always')
    public let restart: String?

    /// Healthcheck configuration
    public let healthcheck: Healthcheck?

    /// List of volume mounts (e.g., "hostPath:containerPath", "namedVolume:/path")
    public let volumes: [String]?

    /// Environment variables to set in the container
    public let environment: [String: String]?

    /// List of .env files to load environment variables from
    public let env_file: [String]?

    /// Port mappings (e.g., "hostPort:containerPort")
    public let ports: [String]?

    /// Command to execute in the container, overriding the image's default
    public let command: [String]?

    /// Services this service depends on (for startup order)
    public let dependsOn: DependsOn?

    /// User or UID to run the container as
    public let user: String?

    /// Explicit name for the container instance
    public let container_name: String?

    /// Networks the service will connect to (list or map form)
    public let networks: ServiceNetworks?

    /// Container hostname
    public let hostname: String?

    /// Entrypoint to execute in the container, overriding the image's default
    public let entrypoint: [String]?

    /// Run container in privileged mode
    public let privileged: Bool?

    /// Mount container's root filesystem as read-only
    public let read_only: Bool?

    /// Working directory inside the container
    public let working_dir: String?

    /// Platform architecture for the service
    public let platform: String?

    /// Service-specific config usage (primarily for Swarm)
    public let configs: [ServiceConfig]?

    /// Service-specific secret usage (primarily for Swarm)
    public let secrets: [ServiceSecret]?

    /// Keep STDIN open (-i flag for `container run`)
    public let stdin_open: Bool?

    /// Allocate a pseudo-TTY (-t flag for `container run`)
    public let tty: Bool?

    // MARK: - Security & Capabilities

    /// Linux capabilities to add
    public let cap_add: [String]?

    /// Linux capabilities to drop
    public let cap_drop: [String]?

    /// Security options (e.g., "seccomp:unconfined")
    public let security_opt: [String]?

    // MARK: - DNS

    /// Custom DNS servers (accepts single string or list)
    public let dns: [String]?

    /// DNS options
    public let dns_opt: [String]?

    /// DNS search domains (accepts single string or list)
    public let dns_search: [String]?

    // MARK: - Network Settings

    /// Extra /etc/hosts entries as "HOST:IP" strings (accepts list or map)
    public let extra_hosts: [String]?

    /// Container domain name
    public let domainname: String?

    /// Ports to expose without publishing to the host
    public let expose: [String]?

    /// Container MAC address
    public let mac_address: String?

    /// Network mode (e.g., "host", "bridge", "none", "service:<name>")
    public let network_mode: String?

    // MARK: - IPC / PID / UTS / User Namespaces

    /// IPC namespace sharing mode
    public let ipc: String?

    /// PID namespace sharing mode
    public let pid: String?

    /// UTS namespace sharing mode
    public let uts: String?

    /// User namespace mode
    public let userns_mode: String?

    // MARK: - User & Groups

    /// Additional groups to add the container user to
    public let group_add: [String]?

    // MARK: - Runtime Behaviour

    /// Run an init process inside the container (CodingKey: "init")
    public let init_: Bool?

    /// Container runtime (e.g., "nvidia")
    public let runtime: String?

    /// Number of containers to run for this service
    public let scale: Int?

    /// Image pull policy (e.g., "always", "missing", "never", "build")
    public let pull_policy: String?

    /// Profiles this service belongs to
    public let profiles: [String]?

    // MARK: - Labels

    /// Metadata labels
    public let labels: [String: String]?

    // MARK: - Stop Behaviour

    /// Signal to stop the container (default SIGTERM)
    public let stop_signal: String?

    /// Time to wait after stop_signal before SIGKILL (e.g., "10s")
    public let stop_grace_period: String?

    // MARK: - Filesystem

    /// Tmpfs mounts inside the container
    public let tmpfs: [String]?

    /// Kernel parameters to set (sysctl key:value pairs)
    public let sysctls: [String: String]?

    /// Mount volumes from another container or service
    public let volumes_from: [String]?

    // MARK: - CPU & Memory Limits (top-level, non-deploy)

    /// CPU quota as a decimal (e.g., 1.5 = 1.5 CPUs); CodingKey: "cpus"
    public let cpus_top: Double?

    /// Number of CPUs to allocate
    public let cpu_count: Int?

    /// Percentage of CPU to use
    public let cpu_percent: Int?

    /// CPU shares (relative weight)
    public let cpu_shares: Int?

    /// CPUs to use (e.g., "0-3", "0,1")
    public let cpuset: String?

    /// Specifies the CPU CFS scheduler period (µs)
    public let cpu_period: Int?

    /// CPU CFS scheduler quota (µs)
    public let cpu_quota: Int?

    /// CPU real-time scheduler period (µs)
    public let cpu_rt_period: Int?

    /// CPU real-time scheduler runtime (µs)
    public let cpu_rt_runtime: Int?

    /// Memory limit (e.g., "512m", "1g")
    public let mem_limit: String?

    /// Memory reservation (soft limit)
    public let mem_reservation: String?

    /// Memory swappiness (0-100)
    public let mem_swappiness: Int?

    /// Total memory + swap limit (-1 for unlimited)
    public let memswap_limit: String?

    /// Disable OOM killer for the container
    public let oom_kill_disable: Bool?

    /// OOM score adjustment (-1000 to 1000)
    public let oom_score_adj: Int?

    /// Limit on number of PIDs
    public let pids_limit: Int?

    /// Size of /dev/shm (e.g., "64m")
    public let shm_size: String?

    // MARK: - Ulimits & Logging

    /// Resource limits (ulimits) for the container
    public let ulimits: [String: Ulimit]?

    /// Logging driver configuration
    public let logging: Logging?

    // MARK: - Devices

    /// Device mappings (e.g., "/dev/ttyUSB0:/dev/ttyUSB0")
    public let devices: [String]?

    /// cgroup device rules
    public let device_cgroup_rules: [String]?

    /// Storage driver options
    public let storage_opt: [String: String]?

    /// Extends configuration — allows this service to inherit from another service
    public let extends: ExtendsConfig?

    // MARK: - GPUs & Block I/O

    /// GPU reservations ("all" shorthand or an array of GpuRequest)
    public let gpus: Gpus?

    /// Block I/O configuration (weight, per-device rates and IOPS)
    public let blkio_config: BlkioConfig?

    /// Develop configuration for filesystem watching (Phase 5C)
    public let develop: Develop?

    /// Other services that depend on this service
    public var dependedBy: [String] = []

    // Defines custom coding keys to map YAML keys to Swift properties
    enum CodingKeys: String, CodingKey {
        case image, build, deploy, restart, healthcheck, volumes, environment, env_file, ports, command, user,
             container_name, networks, hostname, entrypoint, privileged, read_only, working_dir, configs, secrets, stdin_open, tty, platform
        // Security & Capabilities
        case cap_add, cap_drop, security_opt
        // DNS
        case dns, dns_opt, dns_search
        // Network Settings
        case extra_hosts, domainname, expose, mac_address, network_mode
        // IPC / PID / UTS / User Namespaces
        case ipc, pid, uts, userns_mode
        // User & Groups
        case group_add
        // Runtime Behaviour
        case init_ = "init"
        case runtime, scale, pull_policy, profiles
        // Labels
        case labels
        // Stop Behaviour
        case stop_signal, stop_grace_period
        // Filesystem
        case tmpfs, sysctls, volumes_from
        // CPU & Memory Limits
        case cpus_top = "cpus"
        case cpu_count, cpu_percent, cpu_shares, cpuset, cpu_period, cpu_quota, cpu_rt_period, cpu_rt_runtime
        case mem_limit, mem_reservation, mem_swappiness, memswap_limit
        case oom_kill_disable, oom_score_adj, pids_limit, shm_size
        // Ulimits & Logging
        case ulimits, logging
        // Devices
        case devices, device_cgroup_rules, storage_opt
        // Service Dependencies (Phase 1.3)
        case dependsOn = "depends_on"
        // Service Inheritance (Phase 3F)
        case extends
        // GPUs & Block I/O (Phase 5D)
        case gpus
        case blkio_config
        // Develop / Watch (Phase 5C)
        case develop
    }
    
    /// Public memberwise initializer for testing
    public init(
        image: String? = nil,
        build: Build? = nil,
        deploy: Deploy? = nil,
        restart: String? = nil,
        healthcheck: Healthcheck? = nil,
        volumes: [String]? = nil,
        environment: [String: String]? = nil,
        env_file: [String]? = nil,
        ports: [String]? = nil,
        command: [String]? = nil,
        dependsOn: DependsOn? = nil,
        user: String? = nil,
        container_name: String? = nil,
        networks: ServiceNetworks? = nil,
        hostname: String? = nil,
        entrypoint: [String]? = nil,
        privileged: Bool? = nil,
        read_only: Bool? = nil,
        working_dir: String? = nil,
        platform: String? = nil,
        configs: [ServiceConfig]? = nil,
        secrets: [ServiceSecret]? = nil,
        stdin_open: Bool? = nil,
        tty: Bool? = nil,
        // Security & Capabilities
        cap_add: [String]? = nil,
        cap_drop: [String]? = nil,
        security_opt: [String]? = nil,
        // DNS
        dns: [String]? = nil,
        dns_opt: [String]? = nil,
        dns_search: [String]? = nil,
        // Network Settings
        extra_hosts: [String]? = nil,
        domainname: String? = nil,
        expose: [String]? = nil,
        mac_address: String? = nil,
        network_mode: String? = nil,
        // IPC / PID / UTS / User Namespaces
        ipc: String? = nil,
        pid: String? = nil,
        uts: String? = nil,
        userns_mode: String? = nil,
        // User & Groups
        group_add: [String]? = nil,
        // Runtime Behaviour
        init_: Bool? = nil,
        runtime: String? = nil,
        scale: Int? = nil,
        pull_policy: String? = nil,
        profiles: [String]? = nil,
        // Labels
        labels: [String: String]? = nil,
        // Stop Behaviour
        stop_signal: String? = nil,
        stop_grace_period: String? = nil,
        // Filesystem
        tmpfs: [String]? = nil,
        sysctls: [String: String]? = nil,
        volumes_from: [String]? = nil,
        // CPU & Memory Limits
        cpus_top: Double? = nil,
        cpu_count: Int? = nil,
        cpu_percent: Int? = nil,
        cpu_shares: Int? = nil,
        cpuset: String? = nil,
        cpu_period: Int? = nil,
        cpu_quota: Int? = nil,
        cpu_rt_period: Int? = nil,
        cpu_rt_runtime: Int? = nil,
        mem_limit: String? = nil,
        mem_reservation: String? = nil,
        mem_swappiness: Int? = nil,
        memswap_limit: String? = nil,
        oom_kill_disable: Bool? = nil,
        oom_score_adj: Int? = nil,
        pids_limit: Int? = nil,
        shm_size: String? = nil,
        // Ulimits & Logging
        ulimits: [String: Ulimit]? = nil,
        logging: Logging? = nil,
        // Devices
        devices: [String]? = nil,
        device_cgroup_rules: [String]? = nil,
        storage_opt: [String: String]? = nil,
        extends: ExtendsConfig? = nil,
        // GPUs & Block I/O
        gpus: Gpus? = nil,
        blkio_config: BlkioConfig? = nil,
        develop: Develop? = nil,
        dependedBy: [String] = []
    ) {
        self.image = image
        self.build = build
        self.deploy = deploy
        self.restart = restart
        self.healthcheck = healthcheck
        self.volumes = volumes
        self.environment = environment
        self.env_file = env_file
        self.ports = ports
        self.command = command
        self.dependsOn = dependsOn
        self.user = user
        self.container_name = container_name
        self.networks = networks
        self.hostname = hostname
        self.entrypoint = entrypoint
        self.privileged = privileged
        self.read_only = read_only
        self.working_dir = working_dir
        self.platform = platform
        self.configs = configs
        self.secrets = secrets
        self.stdin_open = stdin_open
        self.tty = tty
        self.cap_add = cap_add
        self.cap_drop = cap_drop
        self.security_opt = security_opt
        self.dns = dns
        self.dns_opt = dns_opt
        self.dns_search = dns_search
        self.extra_hosts = extra_hosts
        self.domainname = domainname
        self.expose = expose
        self.mac_address = mac_address
        self.network_mode = network_mode
        self.ipc = ipc
        self.pid = pid
        self.uts = uts
        self.userns_mode = userns_mode
        self.group_add = group_add
        self.init_ = init_
        self.runtime = runtime
        self.scale = scale
        self.pull_policy = pull_policy
        self.profiles = profiles
        self.labels = labels
        self.stop_signal = stop_signal
        self.stop_grace_period = stop_grace_period
        self.tmpfs = tmpfs
        self.sysctls = sysctls
        self.volumes_from = volumes_from
        self.cpus_top = cpus_top
        self.cpu_count = cpu_count
        self.cpu_percent = cpu_percent
        self.cpu_shares = cpu_shares
        self.cpuset = cpuset
        self.cpu_period = cpu_period
        self.cpu_quota = cpu_quota
        self.cpu_rt_period = cpu_rt_period
        self.cpu_rt_runtime = cpu_rt_runtime
        self.mem_limit = mem_limit
        self.mem_reservation = mem_reservation
        self.mem_swappiness = mem_swappiness
        self.memswap_limit = memswap_limit
        self.oom_kill_disable = oom_kill_disable
        self.oom_score_adj = oom_score_adj
        self.pids_limit = pids_limit
        self.shm_size = shm_size
        self.ulimits = ulimits
        self.logging = logging
        self.devices = devices
        self.device_cgroup_rules = device_cgroup_rules
        self.storage_opt = storage_opt
        self.extends = extends
        self.gpus = gpus
        self.blkio_config = blkio_config
        self.develop = develop
        self.dependedBy = dependedBy
    }

    /// Custom initializer to handle decoding and basic validation.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        image = try container.decodeIfPresent(String.self, forKey: .image)
        build = try container.decodeIfPresent(Build.self, forKey: .build)
        deploy = try container.decodeIfPresent(Deploy.self, forKey: .deploy)
        let extendsDecoded = try container.decodeIfPresent(ExtendsConfig.self, forKey: .extends)

        // Ensure that a service has either an image, a build context, or extends another service.
        guard image != nil || build != nil || extendsDecoded != nil else {
            throw DecodingError.dataCorruptedError(forKey: .image, in: container, debugDescription: "Service must have either 'image', 'build', or 'extends' specified.")
        }

        restart = try container.decodeIfPresent(String.self, forKey: .restart)
        healthcheck = try container.decodeIfPresent(Healthcheck.self, forKey: .healthcheck)
        volumes = try container.decodeIfPresent([String].self, forKey: .volumes)
        environment = try container.decodeIfPresent([String: String].self, forKey: .environment)
        env_file = try container.decodeIfPresent([String].self, forKey: .env_file)
        ports = try container.decodeIfPresent([String].self, forKey: .ports)

        // Decode 'command' which can be either a single string or an array of strings.
        if let cmdArray = try? container.decodeIfPresent([String].self, forKey: .command) {
            command = cmdArray
        } else if let cmdString = try? container.decodeIfPresent(String.self, forKey: .command) {
            command = [cmdString]
        } else {
            command = nil
        }
        
        self.dependsOn = try container.decodeIfPresent(DependsOn.self, forKey: .dependsOn)
        user = try container.decodeIfPresent(String.self, forKey: .user)

        container_name = try container.decodeIfPresent(String.self, forKey: .container_name)
        networks = try container.decodeIfPresent(ServiceNetworks.self, forKey: .networks)
        hostname = try container.decodeIfPresent(String.self, forKey: .hostname)
        
        // Decode 'entrypoint' which can be either a single string or an array of strings.
        if let entrypointArray = try? container.decodeIfPresent([String].self, forKey: .entrypoint) {
            entrypoint = entrypointArray
        } else if let entrypointString = try? container.decodeIfPresent(String.self, forKey: .entrypoint) {
            entrypoint = [entrypointString]
        } else {
            entrypoint = nil
        }

        privileged = try container.decodeIfPresent(Bool.self, forKey: .privileged)
        read_only = try container.decodeIfPresent(Bool.self, forKey: .read_only)
        working_dir = try container.decodeIfPresent(String.self, forKey: .working_dir)
        configs = try container.decodeIfPresent([ServiceConfig].self, forKey: .configs)
        secrets = try container.decodeIfPresent([ServiceSecret].self, forKey: .secrets)
        stdin_open = try container.decodeIfPresent(Bool.self, forKey: .stdin_open)
        tty = try container.decodeIfPresent(Bool.self, forKey: .tty)
        platform = try container.decodeIfPresent(String.self, forKey: .platform)

        // Security & Capabilities
        cap_add = try container.decodeIfPresent([String].self, forKey: .cap_add)
        cap_drop = try container.decodeIfPresent([String].self, forKey: .cap_drop)
        security_opt = try container.decodeIfPresent([String].self, forKey: .security_opt)

        // DNS — each field accepts single string OR array of strings
        if let dnsString = try? container.decodeIfPresent(String.self, forKey: .dns) {
            dns = [dnsString]
        } else {
            dns = try container.decodeIfPresent([String].self, forKey: .dns)
        }
        dns_opt = try container.decodeIfPresent([String].self, forKey: .dns_opt)
        if let dnsSearchString = try? container.decodeIfPresent(String.self, forKey: .dns_search) {
            dns_search = [dnsSearchString]
        } else {
            dns_search = try container.decodeIfPresent([String].self, forKey: .dns_search)
        }

        // extra_hosts — accepts [String] of "HOST:IP" OR [String: String] map
        if let hostsArray = try? container.decodeIfPresent([String].self, forKey: .extra_hosts) {
            extra_hosts = hostsArray
        } else if let hostsMap = try? container.decodeIfPresent([String: String].self, forKey: .extra_hosts) {
            extra_hosts = hostsMap.map { "\($0.key):\($0.value)" }
        } else {
            extra_hosts = nil
        }

        // Network Settings
        domainname = try container.decodeIfPresent(String.self, forKey: .domainname)
        expose = try container.decodeIfPresent([String].self, forKey: .expose)
        mac_address = try container.decodeIfPresent(String.self, forKey: .mac_address)
        network_mode = try container.decodeIfPresent(String.self, forKey: .network_mode)

        // IPC / PID / UTS / User Namespaces
        ipc = try container.decodeIfPresent(String.self, forKey: .ipc)
        pid = try container.decodeIfPresent(String.self, forKey: .pid)
        uts = try container.decodeIfPresent(String.self, forKey: .uts)
        userns_mode = try container.decodeIfPresent(String.self, forKey: .userns_mode)

        // User & Groups
        group_add = try container.decodeIfPresent([String].self, forKey: .group_add)

        // Runtime Behaviour
        init_ = try container.decodeIfPresent(Bool.self, forKey: .init_)
        runtime = try container.decodeIfPresent(String.self, forKey: .runtime)
        scale = try container.decodeIfPresent(Int.self, forKey: .scale)
        pull_policy = try container.decodeIfPresent(String.self, forKey: .pull_policy)
        profiles = try container.decodeIfPresent([String].self, forKey: .profiles)

        // Labels
        labels = try container.decodeIfPresent([String: String].self, forKey: .labels)

        // Stop Behaviour
        stop_signal = try container.decodeIfPresent(String.self, forKey: .stop_signal)
        stop_grace_period = try container.decodeIfPresent(String.self, forKey: .stop_grace_period)

        // Filesystem
        tmpfs = try container.decodeIfPresent([String].self, forKey: .tmpfs)
        sysctls = try container.decodeIfPresent([String: String].self, forKey: .sysctls)
        volumes_from = try container.decodeIfPresent([String].self, forKey: .volumes_from)

        // CPU Limits
        cpus_top = try container.decodeIfPresent(Double.self, forKey: .cpus_top)
        cpu_count = try container.decodeIfPresent(Int.self, forKey: .cpu_count)
        cpu_percent = try container.decodeIfPresent(Int.self, forKey: .cpu_percent)
        cpu_shares = try container.decodeIfPresent(Int.self, forKey: .cpu_shares)
        cpuset = try container.decodeIfPresent(String.self, forKey: .cpuset)
        cpu_period = try container.decodeIfPresent(Int.self, forKey: .cpu_period)
        cpu_quota = try container.decodeIfPresent(Int.self, forKey: .cpu_quota)
        cpu_rt_period = try container.decodeIfPresent(Int.self, forKey: .cpu_rt_period)
        cpu_rt_runtime = try container.decodeIfPresent(Int.self, forKey: .cpu_rt_runtime)

        // Memory Limits
        mem_limit = try container.decodeIfPresent(String.self, forKey: .mem_limit)
        mem_reservation = try container.decodeIfPresent(String.self, forKey: .mem_reservation)
        mem_swappiness = try container.decodeIfPresent(Int.self, forKey: .mem_swappiness)
        memswap_limit = try container.decodeIfPresent(String.self, forKey: .memswap_limit)
        oom_kill_disable = try container.decodeIfPresent(Bool.self, forKey: .oom_kill_disable)
        oom_score_adj = try container.decodeIfPresent(Int.self, forKey: .oom_score_adj)
        pids_limit = try container.decodeIfPresent(Int.self, forKey: .pids_limit)
        shm_size = try container.decodeIfPresent(String.self, forKey: .shm_size)

        // Ulimits & Logging
        ulimits = try container.decodeIfPresent([String: Ulimit].self, forKey: .ulimits)
        logging = try container.decodeIfPresent(Logging.self, forKey: .logging)

        // Devices
        devices = try container.decodeIfPresent([String].self, forKey: .devices)
        device_cgroup_rules = try container.decodeIfPresent([String].self, forKey: .device_cgroup_rules)
        storage_opt = try container.decodeIfPresent([String: String].self, forKey: .storage_opt)

        // Service Inheritance (Phase 3F)
        extends = extendsDecoded

        // GPUs & Block I/O (Phase 5D)
        gpus = try container.decodeIfPresent(Gpus.self, forKey: .gpus)
        blkio_config = try container.decodeIfPresent(BlkioConfig.self, forKey: .blkio_config)

        // Develop / Watch (Phase 5C)
        develop = try container.decodeIfPresent(Develop.self, forKey: .develop)
    }

    /// Returns the services in topological order based on `dependsOn` relationships.
    public static func topoSortConfiguredServices(
        _ services: [(serviceName: String, service: Service)]
    ) throws -> [(serviceName: String, service: Service)] {
        
        var visited = Set<String>()
        var visiting = Set<String>()
        var sorted: [(String, Service)] = []

        func visit(_ name: String, from service: String? = nil) throws {
            guard var serviceTuple = services.first(where: { $0.serviceName == name }) else { return }
            if let service {
                serviceTuple.service.dependedBy.append(service)
            }
            
            if visiting.contains(name) {
                throw NSError(domain: "ComposeError", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Cyclic dependency detected involving '\(name)'"
                ])
            }
            guard !visited.contains(name) else { return }

            visiting.insert(name)
            for depName in serviceTuple.service.dependsOn?.serviceNames ?? [] {
                try visit(depName, from: name)
            }
            visiting.remove(name)
            visited.insert(name)
            sorted.append(serviceTuple)
        }

        for (serviceName, _) in services {
            if !visited.contains(serviceName) {
                try visit(serviceName)
            }
        }

        return sorted
    }
}
