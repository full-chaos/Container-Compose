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

import Testing
import Foundation
@testable import Yams
@testable import ContainerComposeCore

/// Tests for Swarm-only deploy stub fields (CHAOS-1305).
/// These fields are decoded but not enforced at runtime.
@Suite("Deploy Stubs Parsing Tests")
struct DeployStubsParsingTests {

    // MARK: - deploy.endpoint_mode

    @Test("Parse deploy.endpoint_mode 'vip'")
    func parseDeployEndpointModeVip() throws {
        let yaml = """
        services:
          app:
            image: alpine:latest
            deploy:
              endpoint_mode: vip
        """
        let compose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        #expect(compose.services["app"]??.deploy?.endpoint_mode == "vip")
    }

    @Test("Parse deploy.endpoint_mode 'dnsrr'")
    func parseDeployEndpointModeDnsrr() throws {
        let yaml = """
        services:
          app:
            image: alpine:latest
            deploy:
              endpoint_mode: dnsrr
        """
        let compose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        #expect(compose.services["app"]??.deploy?.endpoint_mode == "dnsrr")
    }

    // MARK: - deploy.placement

    @Test("Parse deploy.placement with constraints")
    func parseDeployPlacementConstraints() throws {
        let yaml = """
        services:
          app:
            image: alpine:latest
            deploy:
              placement:
                constraints:
                  - "node.role == manager"
                  - "node.labels.region == us-east"
        """
        let compose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        let placement = compose.services["app"]??.deploy?.placement
        #expect(placement?.constraints?.count == 2)
        #expect(placement?.constraints?.contains("node.role == manager") == true)
        #expect(placement?.constraints?.contains("node.labels.region == us-east") == true)
    }

    @Test("Parse deploy.placement with max_replicas_per_node")
    func parseDeployPlacementMaxReplicas() throws {
        let yaml = """
        services:
          app:
            image: alpine:latest
            deploy:
              placement:
                max_replicas_per_node: 3
        """
        let compose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        #expect(compose.services["app"]??.deploy?.placement?.max_replicas_per_node == 3)
    }

    @Test("Parse deploy.placement with preferences (spread)")
    func parseDeployPlacementPreferences() throws {
        let yaml = """
        services:
          app:
            image: alpine:latest
            deploy:
              placement:
                preferences:
                  - spread: node.labels.zone
                  - spread: node.labels.region
        """
        let compose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        let prefs = compose.services["app"]??.deploy?.placement?.preferences
        #expect(prefs?.count == 2)
        #expect(prefs?[0].spread == "node.labels.zone")
        #expect(prefs?[1].spread == "node.labels.region")
    }

    @Test("Parse deploy.placement with all fields")
    func parseDeployPlacementAllFields() throws {
        let yaml = """
        services:
          app:
            image: alpine:latest
            deploy:
              placement:
                constraints:
                  - "node.role == worker"
                preferences:
                  - spread: node.labels.zone
                max_replicas_per_node: 2
        """
        let compose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        let placement = compose.services["app"]??.deploy?.placement
        #expect(placement?.constraints?.count == 1)
        #expect(placement?.preferences?.count == 1)
        #expect(placement?.max_replicas_per_node == 2)
    }

    // MARK: - deploy.update_config

    @Test("Parse deploy.update_config")
    func parseDeployUpdateConfig() throws {
        let yaml = """
        services:
          app:
            image: alpine:latest
            deploy:
              update_config:
                parallelism: 2
                delay: 10s
                failure_action: pause
                monitor: 60s
                max_failure_ratio: 0.3
                order: start-first
        """
        let compose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        let uc = compose.services["app"]??.deploy?.update_config
        #expect(uc?.parallelism == 2)
        #expect(uc?.delay == "10s")
        #expect(uc?.failure_action == "pause")
        #expect(uc?.monitor == "60s")
        #expect(uc?.max_failure_ratio == 0.3)
        #expect(uc?.order == "start-first")
    }

    @Test("Parse deploy.update_config partial fields")
    func parseDeployUpdateConfigPartial() throws {
        let yaml = """
        services:
          app:
            image: alpine:latest
            deploy:
              update_config:
                parallelism: 1
                failure_action: rollback
        """
        let compose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        let uc = compose.services["app"]??.deploy?.update_config
        #expect(uc?.parallelism == 1)
        #expect(uc?.failure_action == "rollback")
        #expect(uc?.delay == nil)
        #expect(uc?.order == nil)
    }

    // MARK: - deploy.rollback_config

    @Test("Parse deploy.rollback_config")
    func parseDeployRollbackConfig() throws {
        let yaml = """
        services:
          app:
            image: alpine:latest
            deploy:
              rollback_config:
                parallelism: 1
                delay: 5s
                failure_action: pause
                monitor: 30s
                max_failure_ratio: 0.1
                order: stop-first
        """
        let compose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        let rc = compose.services["app"]??.deploy?.rollback_config
        #expect(rc?.parallelism == 1)
        #expect(rc?.delay == "5s")
        #expect(rc?.failure_action == "pause")
        #expect(rc?.monitor == "30s")
        #expect(rc?.max_failure_ratio == 0.1)
        #expect(rc?.order == "stop-first")
    }

    @Test("Parse deploy.rollback_config partial fields")
    func parseDeployRollbackConfigPartial() throws {
        let yaml = """
        services:
          app:
            image: alpine:latest
            deploy:
              rollback_config:
                parallelism: 2
                order: start-first
        """
        let compose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        let rc = compose.services["app"]??.deploy?.rollback_config
        #expect(rc?.parallelism == 2)
        #expect(rc?.order == "start-first")
        #expect(rc?.delay == nil)
        #expect(rc?.failure_action == nil)
    }

    // MARK: - Combined

    @Test("Parse deploy with all swarm-only stubs together")
    func parseDeployAllStubs() throws {
        let yaml = """
        services:
          app:
            image: alpine:latest
            deploy:
              endpoint_mode: vip
              placement:
                constraints:
                  - "node.role == manager"
                max_replicas_per_node: 1
              update_config:
                parallelism: 1
                delay: 10s
              rollback_config:
                parallelism: 1
                failure_action: pause
        """
        let compose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        let deploy = compose.services["app"]??.deploy
        #expect(deploy?.endpoint_mode == "vip")
        #expect(deploy?.placement?.constraints?.first == "node.role == manager")
        #expect(deploy?.placement?.max_replicas_per_node == 1)
        #expect(deploy?.update_config?.parallelism == 1)
        #expect(deploy?.update_config?.delay == "10s")
        #expect(deploy?.rollback_config?.parallelism == 1)
        #expect(deploy?.rollback_config?.failure_action == "pause")
    }

    @Test("Existing deploy fields unaffected by new stubs")
    func parseDeployExistingFieldsUnaffected() throws {
        let yaml = """
        services:
          app:
            image: alpine:latest
            deploy:
              mode: replicated
              replicas: 3
              endpoint_mode: dnsrr
              resources:
                limits:
                  cpus: "0.5"
                  memory: 512M
              restart_policy:
                condition: on-failure
                max_attempts: 3
        """
        let compose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        let deploy = compose.services["app"]??.deploy
        #expect(deploy?.mode == "replicated")
        #expect(deploy?.replicas == 3)
        #expect(deploy?.endpoint_mode == "dnsrr")
        #expect(deploy?.resources?.limits?.cpus == "0.5")
        #expect(deploy?.resources?.limits?.memory == "512M")
        #expect(deploy?.restart_policy?.condition == "on-failure")
        #expect(deploy?.restart_policy?.max_attempts == 3)
    }
}
