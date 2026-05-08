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

        let supportsHealthcheckFlags: Bool
        let supportsBlkioFlags: Bool

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
            supportsHealthcheckFlags: Bool = true,
            supportsBlkioFlags: Bool = false
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
            self.supportsHealthcheckFlags = supportsHealthcheckFlags
            self.supportsBlkioFlags = supportsBlkioFlags
        }
    }
}
