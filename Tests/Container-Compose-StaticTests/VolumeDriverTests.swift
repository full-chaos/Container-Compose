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

@Suite("Volume Driver Tests")
struct VolumeDriverTests {

    @Test("Volume with driver 'local' decodes correctly")
    func volumeWithLocalDriver() throws {
        let yaml = """
        driver: local
        """
        let decoder = YAMLDecoder()
        let volume = try decoder.decode(Volume.self, from: yaml)

        #expect(volume.driver == "local")
        #expect(volume.driver_opts == nil)
    }

    @Test("Volume with driver 'nfs' and driver_opts decodes correctly")
    func volumeWithNfsDriver() throws {
        let yaml = """
        driver: nfs
        driver_opts:
          type: nfs
          o: addr=192.168.1.1,rw
          device: ":/path/to/dir"
        """
        let decoder = YAMLDecoder()
        let volume = try decoder.decode(Volume.self, from: yaml)

        #expect(volume.driver == "nfs")
        #expect(volume.driver_opts != nil)
        #expect(volume.driver_opts?["type"] == "nfs")
        #expect(volume.driver_opts?["o"] == "addr=192.168.1.1,rw")
        #expect(volume.driver_opts?["device"] == ":/path/to/dir")
    }

    @Test("Volume without driver has nil driver")
    func volumeWithoutDriver() throws {
        let yaml = """
        name: my-volume
        """
        let decoder = YAMLDecoder()
        let volume = try decoder.decode(Volume.self, from: yaml)

        #expect(volume.driver == nil)
        #expect(volume.name == "my-volume")
    }

    @Test("Volume memberwise init sets driver field")
    func volumeMemberwiseInitDriver() {
        let volume = Volume(driver: "nfs", driver_opts: ["type": "nfs"], name: "nfs-vol")
        #expect(volume.driver == "nfs")
        #expect(volume.driver_opts?["type"] == "nfs")
        #expect(volume.name == "nfs-vol")
    }

    @Test("Volume memberwise init with nil driver")
    func volumeMemberwiseInitNilDriver() {
        let volume = Volume(driver: nil, name: "plain-vol")
        #expect(volume.driver == nil)
        #expect(volume.name == "plain-vol")
    }

    @Test("Volume with external flag and driver decodes")
    func volumeWithExternalAndDriver() throws {
        let yaml = """
        driver: local
        external: true
        """
        let decoder = YAMLDecoder()
        let volume = try decoder.decode(Volume.self, from: yaml)

        #expect(volume.driver == "local")
        #expect(volume.external?.isExternal == true)
    }

    @Test("Volume with labels decodes correctly")
    func volumeWithLabels() throws {
        let yaml = """
        driver: local
        labels:
          com.example.env: production
          com.example.tier: storage
        """
        let decoder = YAMLDecoder()
        let volume = try decoder.decode(Volume.self, from: yaml)

        #expect(volume.driver == "local")
        #expect(volume.labels?["com.example.env"] == "production")
        #expect(volume.labels?["com.example.tier"] == "storage")
    }

    @Test("Volume driver preserved through DockerCompose decode")
    func volumeDriverThroughDockerCompose() throws {
        let yaml = """
        version: '3.8'
        services:
          app:
            image: myapp:latest
        volumes:
          data:
            driver: local
          nfs-data:
            driver: nfs
            driver_opts:
              type: nfs
              o: addr=10.0.0.1
              device: ":/exports/data"
        """
        let decoder = YAMLDecoder()
        let compose = try decoder.decode(DockerCompose.self, from: yaml)

        #expect(compose.volumes?["data"]??.driver == "local")
        #expect(compose.volumes?["nfs-data"]??.driver == "nfs")
        #expect(compose.volumes?["nfs-data"]??.driver_opts?["type"] == "nfs")
    }
}
