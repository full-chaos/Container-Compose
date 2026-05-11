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

import Testing
import Foundation
import Yams
@testable import ContainerComposeCore

@Suite("ComposeValidationError Tests")
struct ComposeValidationTests {

    // MARK: - Happy path

    @Test("Valid compose with image passes validation")
    func validComposeWithImagePassesValidation() throws {
        let yaml = """
        services:
          web:
            image: nginx:latest
        """
        let compose = try decode(yaml)
        #expect(throws: Never.self) { try compose.validate() }
    }

    @Test("Valid compose with build passes validation")
    func validComposeWithBuildPassesValidation() throws {
        let yaml = """
        services:
          app:
            build: .
        """
        let compose = try decode(yaml)
        #expect(throws: Never.self) { try compose.validate() }
    }

    @Test("Valid compose with multiple services passes validation")
    func validComposeWithMultipleServicesPassesValidation() throws {
        let yaml = """
        services:
          web:
            image: nginx:latest
            ports:
              - "80:80"
          db:
            image: postgres:14
          redis:
            image: redis:alpine
        """
        let compose = try decode(yaml)
        #expect(throws: Never.self) { try compose.validate() }
    }

    @Test("Valid compose with depends_on (no cycle) passes validation")
    func validComposeWithDependsOnPassesValidation() throws {
        let yaml = """
        services:
          web:
            image: nginx:latest
            depends_on:
              - db
          db:
            image: postgres:14
        """
        let compose = try decode(yaml)
        #expect(throws: Never.self) { try compose.validate() }
    }

    // MARK: - noServicesDefined

    @Test("Empty services dict throws noServicesDefined")
    func emptyServicesDictThrowsNoServicesDefined() throws {
        let compose = makeCompose(services: [:])
        #expect(throws: ComposeValidationError.noServicesDefined) {
            try compose.validate()
        }
    }

    @Test("All-nil services throws noServicesDefined")
    func allNilServicesThrowsNoServicesDefined() throws {
        let compose = DockerCompose(
            version: nil,
            name: nil,
            services: ["ghost": nil],
            volumes: nil,
            networks: nil,
            configs: nil,
            secrets: nil
        )
        #expect(throws: ComposeValidationError.noServicesDefined) {
            try compose.validate()
        }
    }

    // MARK: - serviceNeedsImageOrBuild

    @Test("Service without image or build throws serviceNeedsImageOrBuild")
    func serviceWithoutImageOrBuildThrows() throws {
        // Service.init has defaults — image and build are both nil by default
        let service = Service(environment: ["FOO": "bar"])
        let compose = makeCompose(services: ["orphan": service])
        #expect(throws: ComposeValidationError.serviceNeedsImageOrBuild(serviceName: "orphan")) {
            try compose.validate()
        }
    }

    @Test("Service with only image passes image-or-build check")
    func serviceWithOnlyImagePassesCheck() throws {
        let service = Service(image: "nginx:latest")
        let compose = makeCompose(services: ["web": service])
        #expect(throws: Never.self) { try compose.validate() }
    }

    @Test("Service with only build passes image-or-build check")
    func serviceWithOnlyBuildPassesCheck() throws {
        let yaml = """
        services:
          app:
            build: .
        """
        let compose = try decode(yaml)
        #expect(throws: Never.self) { try compose.validate() }
    }

    // MARK: - invalidPortFormat (via validate())

    @Test("Out-of-range container port 99999 throws invalidPortFormat")
    func outOfRangeContainerPortThrows() {
        let compose = makeComposeWithPorts(["99999"])
        #expect(throws: ComposeValidationError.self) { try compose.validate() }
    }

    @Test("Negative-looking port -1 throws invalidPortFormat")
    func negativePortThrows() {
        // "-1" as a string — Int("-1") would succeed but value < 0
        let compose = makeComposeWithPorts(["-1"])
        #expect(throws: ComposeValidationError.self) { try compose.validate() }
    }

    @Test("Non-numeric port 'abc' throws invalidPortFormat")
    func nonNumericPortThrows() {
        let compose = makeComposeWithPorts(["abc"])
        #expect(throws: ComposeValidationError.self) { try compose.validate() }
    }

    @Test("Unknown protocol suffix '/sctp' throws invalidPortFormat")
    func unknownProtocolSuffixThrows() {
        let compose = makeComposeWithPorts(["80/sctp"])
        #expect(throws: ComposeValidationError.self) { try compose.validate() }
    }

    // MARK: - circularDependency

    @Test("Direct self-dependency throws circularDependency")
    func selfDependencyThrows() {
        let service = Service(image: "nginx:latest", dependsOn: DependsOn.list(["web"]))
        let compose = makeCompose(services: ["web": service])
        #expect(throws: ComposeValidationError.self) { try compose.validate() }
    }

    @Test("Two-service cycle throws circularDependency")
    func twoServiceCycleThrows() {
        let web = Service(image: "nginx:latest", dependsOn: DependsOn.list(["db"]))
        let db  = Service(image: "postgres:14",  dependsOn: DependsOn.list(["web"]))
        let compose = makeCompose(services: ["web": web, "db": db])
        #expect(throws: ComposeValidationError.self) { try compose.validate() }
    }

    @Test("Three-service linear chain (no cycle) passes validation")
    func threeServiceChainNoCyclePassesValidation() {
        let web = Service(image: "nginx:latest", dependsOn: DependsOn.list(["api"]))
        let api = Service(image: "myapp:latest", dependsOn: DependsOn.list(["db"]))
        let db  = Service(image: "postgres:14")
        let compose = makeCompose(services: ["web": web, "api": api, "db": db])
        #expect(throws: Never.self) { try compose.validate() }
    }

    @Test("Three-service cycle throws circularDependency")
    func threeServiceCycleThrows() {
        let a = Service(image: "img:1", dependsOn: DependsOn.list(["b"]))
        let b = Service(image: "img:2", dependsOn: DependsOn.list(["c"]))
        let c = Service(image: "img:3", dependsOn: DependsOn.list(["a"]))
        let compose = makeCompose(services: ["a": a, "b": b, "c": c])
        #expect(throws: ComposeValidationError.self) { try compose.validate() }
    }

    @Test("Depends on external (undefined) service does not throw")
    func dependsOnExternalServiceDoesNotThrow() {
        // The dependency "external-db" is NOT in the compose services dict.
        let web = Service(image: "nginx:latest", dependsOn: DependsOn.list(["external-db"]))
        let compose = makeCompose(services: ["web": web])
        #expect(throws: Never.self) { try compose.validate() }
    }

    // MARK: - image + build coexistence (CHAOS-1510)
    //
    // Per compose-spec, `image:` alongside `build:` is valid — `image:` is the
    // tag for the built image. The prior CHAOS-1417/1442 contract that rejected
    // this combination was a deliberate over-validation; CHAOS-1510 reverses it
    // to align with `docker compose` semantics.

    @Test("Service with both image and build is accepted (CHAOS-1510)")
    func serviceBothImageAndBuildAccepted() throws {
        let yaml = """
        services:
          app:
            image: myapp:latest
            build: .
        """
        let compose = try decode(yaml)
        #expect(throws: Never.self) { try compose.validate() }
    }

    @Test("Service with only image and no build is accepted")
    func serviceOnlyImageAccepted() throws {
        let service = Service(image: "nginx:latest")
        let compose = makeCompose(services: ["web": service])
        #expect(throws: Never.self) { try compose.validate() }
    }

    @Test("Service with only build and no image is accepted")
    func serviceOnlyBuildAccepted() throws {
        let yaml = """
        services:
          app:
            build:
              context: .
        """
        let compose = try decode(yaml)
        #expect(throws: Never.self) { try compose.validate() }
    }

    // MARK: - resourceConstraintOutOfRange (validate() logic)

    @Test("Negative cpus_top throws resourceConstraintOutOfRange")
    func negativeCpusTopThrows() {
        let service = Service(image: "nginx:latest", cpus_top: -1)
        let compose = makeCompose(services: ["web": service])
        #expect(throws: ComposeValidationError.self) { try compose.validate() }
    }

    @Test("Zero cpus_top (0.0) is valid")
    func zeroCpusTopIsValid() {
        let service = Service(image: "nginx:latest", cpus_top: 0)
        let compose = makeCompose(services: ["web": service])
        #expect(throws: Never.self) { try compose.validate() }
    }

    @Test("Positive cpus_top is valid")
    func positiveCpusTopIsValid() {
        let service = Service(image: "nginx:latest", cpus_top: 2.5)
        let compose = makeCompose(services: ["web": service])
        #expect(throws: Never.self) { try compose.validate() }
    }

    @Test("mem_limit of '0' throws resourceConstraintOutOfRange")
    func memLimitZeroThrows() {
        let service = Service(image: "nginx:latest", mem_limit: "0")
        let compose = makeCompose(services: ["web": service])
        #expect(throws: ComposeValidationError.self) { try compose.validate() }
    }

    @Test("mem_limit of '512m' is valid")
    func memLimitValidStringIsValid() {
        let service = Service(image: "nginx:latest", mem_limit: "512m")
        let compose = makeCompose(services: ["web": service])
        #expect(throws: Never.self) { try compose.validate() }
    }

    @Test("mem_swappiness of 101 throws resourceConstraintOutOfRange")
    func memSwappiness101Throws() {
        let service = Service(image: "nginx:latest", mem_swappiness: 101)
        let compose = makeCompose(services: ["web": service])
        #expect(throws: ComposeValidationError.self) { try compose.validate() }
    }

    @Test("mem_swappiness of -1 throws resourceConstraintOutOfRange")
    func memSwappinessNegativeThrows() {
        let service = Service(image: "nginx:latest", mem_swappiness: -1)
        let compose = makeCompose(services: ["web": service])
        #expect(throws: ComposeValidationError.self) { try compose.validate() }
    }

    @Test("mem_swappiness of 0 is valid")
    func memSwappiness0IsValid() {
        let service = Service(image: "nginx:latest", mem_swappiness: 0)
        let compose = makeCompose(services: ["web": service])
        #expect(throws: Never.self) { try compose.validate() }
    }

    @Test("mem_swappiness of 100 is valid")
    func memSwappiness100IsValid() {
        let service = Service(image: "nginx:latest", mem_swappiness: 100)
        let compose = makeCompose(services: ["web": service])
        #expect(throws: Never.self) { try compose.validate() }
    }

    @Test("oom_score_adj of 1001 throws resourceConstraintOutOfRange")
    func oomScoreAdj1001Throws() {
        let service = Service(image: "nginx:latest", oom_score_adj: 1001)
        let compose = makeCompose(services: ["web": service])
        #expect(throws: ComposeValidationError.self) { try compose.validate() }
    }

    @Test("oom_score_adj of -1001 throws resourceConstraintOutOfRange")
    func oomScoreAdjNeg1001Throws() {
        let service = Service(image: "nginx:latest", oom_score_adj: -1001)
        let compose = makeCompose(services: ["web": service])
        #expect(throws: ComposeValidationError.self) { try compose.validate() }
    }

    @Test("oom_score_adj of 0 is valid")
    func oomScoreAdj0IsValid() {
        let service = Service(image: "nginx:latest", oom_score_adj: 0)
        let compose = makeCompose(services: ["web": service])
        #expect(throws: Never.self) { try compose.validate() }
    }

    @Test("oom_score_adj of 1000 is valid")
    func oomScoreAdj1000IsValid() {
        let service = Service(image: "nginx:latest", oom_score_adj: 1000)
        let compose = makeCompose(services: ["web": service])
        #expect(throws: Never.self) { try compose.validate() }
    }

    @Test("oom_score_adj of -1000 is valid")
    func oomScoreAdjNeg1000IsValid() {
        let service = Service(image: "nginx:latest", oom_score_adj: -1000)
        let compose = makeCompose(services: ["web": service])
        #expect(throws: Never.self) { try compose.validate() }
    }

    // MARK: - resourceConstraintOutOfRange (error type — description)

    @Test("resourceConstraintOutOfRange description with max bound")
    func resourceConstraintOutOfRangeWithMaxDescription() {
        let err = ComposeValidationError.resourceConstraintOutOfRange(
            field: "deploy.resources.limits.cpus",
            value: "999",
            min: 0,
            max: 256
        )
        #expect(err.errorDescription?.contains("999") == true)
        #expect(err.errorDescription?.contains("deploy.resources.limits.cpus") == true)
        #expect(err.errorDescription?.contains("256") == true)
    }

    @Test("resourceConstraintOutOfRange description without max bound")
    func resourceConstraintOutOfRangeWithoutMaxDescription() {
        let err = ComposeValidationError.resourceConstraintOutOfRange(
            field: "deploy.resources.limits.cpus",
            value: "-1",
            min: 0,
            max: nil
        )
        #expect(err.errorDescription?.contains("-1") == true)
        #expect(err.errorDescription?.contains("0") == true)
    }

    // MARK: - Equatable conformance

    @Test("noServicesDefined equals itself")
    func equatableNoServicesDefined() {
        #expect(ComposeValidationError.noServicesDefined == ComposeValidationError.noServicesDefined)
    }

    @Test("serviceNeedsImageOrBuild equality by service name")
    func equatableServiceNeedsImageOrBuild() {
        let a = ComposeValidationError.serviceNeedsImageOrBuild(serviceName: "web")
        let b = ComposeValidationError.serviceNeedsImageOrBuild(serviceName: "web")
        let c = ComposeValidationError.serviceNeedsImageOrBuild(serviceName: "api")
        #expect(a == b)
        #expect(a != c)
    }

    @Test("invalidPortFormat equality by portSpec and serviceName")
    func equatableInvalidPortFormat() {
        let a = ComposeValidationError.invalidPortFormat(portSpec: "bad", serviceName: "web")
        let b = ComposeValidationError.invalidPortFormat(portSpec: "bad", serviceName: "web")
        let c = ComposeValidationError.invalidPortFormat(portSpec: "also-bad", serviceName: "web")
        #expect(a == b)
        #expect(a != c)
    }

    @Test("circularDependency equality by chain")
    func equatableCircularDependency() {
        let a = ComposeValidationError.circularDependency(serviceChain: ["a", "b", "a"])
        let b = ComposeValidationError.circularDependency(serviceChain: ["a", "b", "a"])
        let c = ComposeValidationError.circularDependency(serviceChain: ["x", "y", "x"])
        #expect(a == b)
        #expect(a != c)
    }

    @Test("resourceConstraintOutOfRange equality")
    func equatableResourceConstraintOutOfRange() {
        let a = ComposeValidationError.resourceConstraintOutOfRange(field: "cpus", value: "999", min: 0, max: 256)
        let b = ComposeValidationError.resourceConstraintOutOfRange(field: "cpus", value: "999", min: 0, max: 256)
        let c = ComposeValidationError.resourceConstraintOutOfRange(field: "cpus", value: "1000", min: 0, max: 256)
        #expect(a == b)
        #expect(a != c)
    }

    // MARK: - LocalizedError descriptions

    @Test("noServicesDefined has a non-empty errorDescription")
    func noServicesDefinedHasDescription() {
        let err = ComposeValidationError.noServicesDefined
        #expect(err.errorDescription?.isEmpty == false)
    }

    @Test("serviceNeedsImageOrBuild description mentions service name")
    func serviceNeedsImageOrBuildDescriptionMentionsName() {
        let err = ComposeValidationError.serviceNeedsImageOrBuild(serviceName: "myservice")
        #expect(err.errorDescription?.contains("myservice") == true)
    }

    @Test("invalidPortFormat description mentions port spec and service name")
    func invalidPortFormatDescriptionMentionsPortSpecAndService() {
        let err = ComposeValidationError.invalidPortFormat(portSpec: "99999", serviceName: "web")
        #expect(err.errorDescription?.contains("99999") == true)
        #expect(err.errorDescription?.contains("web") == true)
    }

    @Test("circularDependency description mentions service names in chain")
    func circularDependencyDescriptionMentionsChain() {
        let err = ComposeValidationError.circularDependency(serviceChain: ["a", "b", "a"])
        #expect(err.errorDescription?.contains("a") == true)
        #expect(err.errorDescription?.contains("b") == true)
    }

    // MARK: - Helpers

    private func decode(_ yaml: String) throws -> DockerCompose {
        try YAMLDecoder().decode(DockerCompose.self, from: yaml)
    }

    private func makeCompose(services: [String: Service?]) -> DockerCompose {
        DockerCompose(
            version: nil,
            name: nil,
            services: services,
            volumes: nil,
            networks: nil,
            configs: nil,
            secrets: nil
        )
    }

    private func makeComposeWithPorts(_ ports: [String]) -> DockerCompose {
        makeCompose(services: ["web": Service(image: "nginx:latest", ports: ports)])
    }
}
