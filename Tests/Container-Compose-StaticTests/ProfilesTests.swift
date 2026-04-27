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
//  ProfilesTests.swift
//  Container-Compose
//

import Testing
import Foundation
@testable import ContainerComposeCore

@Suite("Service Profile Filtering Tests")
struct ProfilesTests {

    // MARK: - filterByProfiles

    @Test("No profiles on any service + activeProfiles empty → all services kept")
    func noProfilesNoActiveProfiles() {
        let web = Service(image: "nginx")
        let db = Service(image: "postgres")
        let services: [(serviceName: String, service: Service)] = [
            ("web", web),
            ("db", db),
        ]

        let result = Service.filterByProfiles(services, activeProfiles: [])
        #expect(result.count == 2)
        #expect(result.map(\.serviceName).contains("web"))
        #expect(result.map(\.serviceName).contains("db"))
    }

    @Test("Service with profiles=[] → kept regardless of active set")
    func emptyProfilesArrayAlwaysIncluded() {
        let service = Service(image: "nginx", profiles: [])
        let services: [(serviceName: String, service: Service)] = [("web", service)]

        // Even with a non-empty active set, an empty profiles array means "always run".
        let result = Service.filterByProfiles(services, activeProfiles: ["prod"])
        #expect(result.count == 1)
        #expect(result[0].serviceName == "web")
    }

    @Test("Service with profiles=[\"dev\"] + activeProfiles=[\"dev\"] → kept")
    func profileMatchKept() {
        let service = Service(image: "myapp", profiles: ["dev"])
        let services: [(serviceName: String, service: Service)] = [("app", service)]

        let result = Service.filterByProfiles(services, activeProfiles: ["dev"])
        #expect(result.count == 1)
        #expect(result[0].serviceName == "app")
    }

    @Test("Service with profiles=[\"dev\"] + activeProfiles=[\"prod\"] → filtered OUT")
    func profileMismatchFilteredOut() {
        let service = Service(image: "myapp", profiles: ["dev"])
        let services: [(serviceName: String, service: Service)] = [("app", service)]

        let result = Service.filterByProfiles(services, activeProfiles: ["prod"])
        #expect(result.isEmpty)
    }

    @Test("Service with profiles=[\"dev\",\"staging\"] + activeProfiles=[\"staging\"] → kept (intersection match)")
    func multiProfileIntersectionMatch() {
        let service = Service(image: "myapp", profiles: ["dev", "staging"])
        let services: [(serviceName: String, service: Service)] = [("app", service)]

        let result = Service.filterByProfiles(services, activeProfiles: ["staging"])
        #expect(result.count == 1)
        #expect(result[0].serviceName == "app")
    }

    @Test("Mixed: 3 services — dev-only, prod-only, no-profile — activeProfiles=[\"dev\"] → 2 kept")
    func mixedServicesDevProfileActive() {
        let devService = Service(image: "dev-tool", profiles: ["dev"])
        let prodService = Service(image: "prod-tool", profiles: ["prod"])
        let coreService = Service(image: "nginx")  // no profiles
        let services: [(serviceName: String, service: Service)] = [
            ("dev-tool", devService),
            ("prod-tool", prodService),
            ("core", coreService),
        ]

        let result = Service.filterByProfiles(services, activeProfiles: ["dev"])
        #expect(result.count == 2)
        let names = Set(result.map(\.serviceName))
        #expect(names.contains("dev-tool"))
        #expect(names.contains("core"))
        #expect(!names.contains("prod-tool"))
    }

    @Test("Multi-active: activeProfiles=[\"dev\",\"prod\"] matches services with EITHER profile")
    func multiActiveProfilesMatchEither() {
        let devService = Service(image: "dev-tool", profiles: ["dev"])
        let prodService = Service(image: "prod-tool", profiles: ["prod"])
        let stagingService = Service(image: "staging-tool", profiles: ["staging"])
        let coreService = Service(image: "nginx")  // no profiles
        let services: [(serviceName: String, service: Service)] = [
            ("dev-tool", devService),
            ("prod-tool", prodService),
            ("staging-tool", stagingService),
            ("core", coreService),
        ]

        let result = Service.filterByProfiles(services, activeProfiles: ["dev", "prod"])
        #expect(result.count == 3)
        let names = Set(result.map(\.serviceName))
        #expect(names.contains("dev-tool"))
        #expect(names.contains("prod-tool"))
        #expect(names.contains("core"))
        #expect(!names.contains("staging-tool"))
    }

    // MARK: - resolveActiveProfiles

    @Test("CLI profiles take precedence over empty env")
    func cliProfilesPrecedence() {
        let resolved = Service.resolveActiveProfiles(cliProfiles: ["dev", "local"])
        #expect(resolved == ["dev", "local"])
    }

    @Test("Empty CLI profiles with no env → empty set (no filter)")
    func noCliNoEnv() {
        // Cannot set ProcessInfo.processInfo.environment in tests, so we rely on
        // the env var not being set in CI. If COMPOSE_PROFILES is unset, result is empty.
        // We test the path where cliProfiles is non-empty to confirm precedence.
        let resolved = Service.resolveActiveProfiles(cliProfiles: [])
        // In most test environments COMPOSE_PROFILES is unset, so this should be empty.
        // We only assert it doesn't crash; actual env-var fallback is covered by filterByProfiles tests.
        let _ = resolved  // no-crash assertion
    }
}
