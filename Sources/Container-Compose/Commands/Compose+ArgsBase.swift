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

import Foundation

extension ComposeUp {
    /// Read-only context handed to every argv builder. Carrying it as a struct
    /// keeps builder signatures uniform and lets Phase 2 streams add new
    /// fields without re-plumbing call sites.
    ///
    /// Builders are intentionally side-effect-free: they read the service /
    /// project state and return the `[String]` they contribute to the
    /// `container run` argv. Anything that requires `await` or filesystem
    /// mutation (volume hard-links, network creation) stays in `configService`.
    struct ArgsContext {
        let service: Service
        let serviceName: String
        let projectName: String
        let containerName: String
        let detach: Bool
        /// `.env` files + process env, before service-level overlay. Used for
        /// `${VAR}` substitution in hostname/ports/networks/working_dir.
        let environmentVariables: [String: String]
        let dockerCompose: DockerCompose
        let composeFilename: String?
        let dnsSidecar: SidecarHandle?

        /// CHAOS-1494: implicit project default network synthesized when the
        /// compose file declares no top-level `networks:` block. Builders use
        /// this fallback for services that omit `service.networks` so they can
        /// still attach to the project network where the embedded DNS sidecar
        /// lives. `nil` when no implicit network was synthesized (either the
        /// compose file declares its own networks, or no service needs the
        /// fallback).
        let implicitDefaultNetwork: String?

        /// CHAOS-1496: pre-computed merged environment for the service —
        /// specifically the (a)-layer output of
        /// `ComposeUp.mergeServiceEnvForFingerprint(_:)`: post `${VAR}`
        /// substitution but BEFORE peer-service-name → IP rewriting via
        /// `containerIps`. Threaded through so `LabelsArgs.fingerprintLabels`
        /// can emit a deterministic `compose.spec.env.hash` label without
        /// re-doing the merge (and without duplicating the merge logic
        /// statically).
        ///
        /// MUST NOT include peer-IP-resolved values: `resolveAdoption`'s
        /// `envHashDivergence` re-computes the same (a)-only form at adoption
        /// time, when `containerIps` is empty (per CHAOS-1493 ordering).
        /// Hashing the (b)-layer (full) form here would spuriously diverge
        /// every service whose env references a peer service by name.
        ///
        /// Defaults to an empty dictionary so existing test fixtures that
        /// build `ArgsContext` directly are unaffected — they simply skip
        /// the env-fingerprint emission, matching the "absent when not
        /// applicable" rule used elsewhere in `LabelsArgs.build`.
        let fingerprintEnv: [String: String]

        let supportsHealthcheckFlags: Bool
        let supportsBlkioFlags: Bool

        let supportsRestartFlag: Bool

        init(
            service: Service,
            serviceName: String,
            projectName: String,
            containerName: String,
            detach: Bool,
            environmentVariables: [String: String],
            dockerCompose: DockerCompose,
            composeFilename: String?,
            dnsSidecar: SidecarHandle? = nil,
            fingerprintEnv: [String: String] = [:],
            supportsHealthcheckFlags: Bool = true,
            supportsBlkioFlags: Bool = false,
            supportsRestartFlag: Bool = false,
            implicitDefaultNetwork: String? = nil
        ) {
            self.service = service
            self.serviceName = serviceName
            self.projectName = projectName
            self.containerName = containerName
            self.detach = detach
            self.environmentVariables = environmentVariables
            self.dockerCompose = dockerCompose
            self.composeFilename = composeFilename
            self.dnsSidecar = dnsSidecar
            self.fingerprintEnv = fingerprintEnv
            self.supportsHealthcheckFlags = supportsHealthcheckFlags
            self.supportsBlkioFlags = supportsBlkioFlags
            self.supportsRestartFlag = supportsRestartFlag
            self.implicitDefaultNetwork = implicitDefaultNetwork
        }
    }
}
