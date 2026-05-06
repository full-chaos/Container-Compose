//===----------------------------------------------------------------------===//
// Copyright © 2026 Morris Richman and the Container-Compose project authors. All rights reserved.
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

import Foundation

// MARK: - RuntimeCapabilities (CHAOS-1407)

/// Linux capability adjustments declared by a Compose service's `cap_add` /
/// `cap_drop` fields. Combined into a single optional value on
/// `RuntimeCreateConfiguration` so a nil means "no capability adjustment"
/// (the runtime uses its default set).
///
/// Conformers that cannot apply capabilities (e.g. the bridge backend in Phase
/// 1) ignore this field; a Phase 2 ticket wires it through the native API.
public struct RuntimeCapabilities: Sendable, Equatable {
    /// Capabilities to add beyond the runtime default set (e.g. `NET_ADMIN`).
    public let add: [String]
    /// Capabilities to drop from the runtime default set (e.g. `ALL`).
    public let drop: [String]

    public init(add: [String] = [], drop: [String] = []) {
        self.add = add
        self.drop = drop
    }
}

// MARK: - RuntimeCreateConfiguration

/// Minimum container creation surface needed to round-trip a Compose service
/// definition through the `Runtime` protocol. Phase 1 defines the shape so
/// `AppleContainerizationRuntime.create(...)` can be exercised by tests; Phase
/// 2 wires `compose up` through it.
///
/// Security fields added in CHAOS-1407 (`capabilities`, `securityOpt`,
/// `readOnly`, `user`, `groupAdd`, `privileged`) are spec-only for now —
/// conformers that cannot apply them ignore them gracefully. A follow-up
/// ticket wires them through the native-API and bridge runtime paths.
public struct RuntimeCreateConfiguration: Sendable, Equatable {
    public let imageReference: String
    public let cpus: Int
    public let memoryInBytes: UInt64
    public let hostname: String?
    public let environment: [String]
    public let command: [String]
    public let workingDirectory: String?
    public let publishedPorts: [RuntimePublishedPort]

    // MARK: Security fields (CHAOS-1407)

    /// Linux capability adjustments (`cap_add` / `cap_drop`). `nil` means no
    /// adjustment — use the runtime's default capability set.
    public let capabilities: RuntimeCapabilities?

    /// Security options passed via Compose `security_opt` (e.g.
    /// `"no-new-privileges:true"`). `nil` or empty means no overrides.
    ///
    /// Note: apple/container does not expose a `--security-opt` flag; the
    /// field is carried here so future backends can apply it.
    public let securityOpt: [String]?

    /// Mount the container's root filesystem read-only (`read_only: true`).
    /// `nil` and `false` both mean writable (current behaviour unchanged).
    public let readOnly: Bool?

    /// UID (or `user:group`) to run the container process as (`user:` field).
    /// `nil` means use the image default.
    public let user: String?

    /// Additional supplementary groups for the container user (`group_add`).
    /// `nil` or empty means no additions.
    ///
    /// Note: apple/container does not expose a `--group-add` flag; carried
    /// here for future backends.
    public let groupAdd: [String]?

    /// Run the container in privileged mode (`privileged: true`). `nil` and
    /// `false` both mean non-privileged.
    ///
    /// Note: apple/container does not expose a `--privileged` flag; carried
    /// here for future backends.
    public let privileged: Bool?

    public init(
        imageReference: String,
        cpus: Int = 1,
        memoryInBytes: UInt64 = 256 * 1024 * 1024,
        hostname: String? = nil,
        environment: [String] = [],
        command: [String] = [],
        workingDirectory: String? = nil,
        publishedPorts: [RuntimePublishedPort] = [],
        capabilities: RuntimeCapabilities? = nil,
        securityOpt: [String]? = nil,
        readOnly: Bool? = nil,
        user: String? = nil,
        groupAdd: [String]? = nil,
        privileged: Bool? = nil
    ) {
        self.imageReference = imageReference
        self.cpus = cpus
        self.memoryInBytes = memoryInBytes
        self.hostname = hostname
        self.environment = environment
        self.command = command
        self.workingDirectory = workingDirectory
        self.publishedPorts = publishedPorts
        self.capabilities = capabilities
        self.securityOpt = securityOpt
        self.readOnly = readOnly
        self.user = user
        self.groupAdd = groupAdd
        self.privileged = privileged
    }
}
