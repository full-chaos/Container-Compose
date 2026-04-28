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
@testable import ContainerComposeCore

@Suite("Image Reference Qualification Tests")
struct ImageReferenceQualifyTests {

    @Test("single-component image gets Docker Hub library namespace and latest tag")
    func singleComponentImageGetsDockerHubLibraryLatest() {
        #expect(ComposeUp.qualifyImageReference("alpine") == "docker.io/library/alpine:latest")
    }

    @Test("single-component tagged image gets Docker Hub library namespace")
    func singleComponentTaggedImageGetsDockerHubLibrary() {
        #expect(ComposeUp.qualifyImageReference("alpine:3.20") == "docker.io/library/alpine:3.20")
    }

    @Test("namespace image gets Docker Hub host and latest tag")
    func namespaceImageGetsDockerHubLatest() {
        #expect(ComposeUp.qualifyImageReference("mycompany/web") == "docker.io/mycompany/web:latest")
    }

    @Test("namespace tagged image gets Docker Hub host")
    func namespaceTaggedImageGetsDockerHub() {
        #expect(ComposeUp.qualifyImageReference("mycompany/web:v1") == "docker.io/mycompany/web:v1")
    }

    @Test("registry host image gets latest tag")
    func registryHostImageGetsLatest() {
        #expect(ComposeUp.qualifyImageReference("ghcr.io/foo/bar") == "ghcr.io/foo/bar:latest")
    }

    @Test("registry host tagged image stays unchanged")
    func registryHostTaggedImageIsUnchanged() {
        #expect(ComposeUp.qualifyImageReference("ghcr.io/foo/bar:v1") == "ghcr.io/foo/bar:v1")
    }

    @Test("localhost registry image gets latest tag")
    func localhostRegistryImageGetsLatest() {
        #expect(ComposeUp.qualifyImageReference("localhost:5000/foo") == "localhost:5000/foo:latest")
    }

    @Test("localhost registry tagged image stays unchanged")
    func localhostRegistryTaggedImageIsUnchanged() {
        #expect(ComposeUp.qualifyImageReference("localhost:5000/foo:dev") == "localhost:5000/foo:dev")
    }

    @Test("digest-only library image does not get latest tag")
    func digestOnlyLibraryImageDoesNotGetLatest() {
        #expect(ComposeUp.qualifyImageReference("alpine@sha256:abc") == "docker.io/library/alpine@sha256:abc")
    }

    @Test("digest-only namespace image does not get latest tag")
    func digestOnlyNamespaceImageDoesNotGetLatest() {
        #expect(ComposeUp.qualifyImageReference("mycompany/web@sha256:abc") == "docker.io/mycompany/web@sha256:abc")
    }

    @Test("IP registry with port is treated as host")
    func ipRegistryWithPortIsTreatedAsHost() {
        #expect(ComposeUp.qualifyImageReference("192.168.1.5:5000/foo") == "192.168.1.5:5000/foo:latest")
    }
}
