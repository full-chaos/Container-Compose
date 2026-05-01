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

@Suite("Gpus and BlkioConfig Tests", .serialized)
struct GpusBlkioTests {

    // MARK: - Helpers

    private func minimalDockerCompose() throws -> DockerCompose {
        let yaml = """
        services:
          svc:
            image: alpine:latest
        """
        return try YAMLDecoder().decode(DockerCompose.self, from: yaml)
    }

    private func ctx(_ service: Service) throws -> ComposeUp.ArgsContext {
        ComposeUp.ArgsContext(
            service: service,
            serviceName: "svc",
            projectName: "test",
            containerName: "test-svc",
            detach: true,
            environmentVariables: [:],
            dockerCompose: try minimalDockerCompose(),
            composeFilename: nil
        )
    }

    private func args(_ service: Service) throws -> [String] {
        ComposeUp.ResourceArgs.build(try ctx(service))
    }

    private func capturedArgs(_ service: Service) throws -> (output: String, args: [String]) {
        fflush(stdout)
        let original = dup(STDOUT_FILENO)
        let pipe = Pipe()
        guard original >= 0, dup2(pipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO) >= 0 else {
            if original >= 0 { close(original) }
            throw CaptureError.dupFailed
        }

        do {
            let result = try args(service)
            fflush(stdout)
            restoreStandardOutput(original: original, pipe: pipe)
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return (String(data: data, encoding: .utf8) ?? "", result)
        } catch {
            fflush(stdout)
            restoreStandardOutput(original: original, pipe: pipe)
            _ = pipe.fileHandleForReading.readDataToEndOfFile()
            throw error
        }
    }

    private func restoreStandardOutput(original: Int32, pipe: Pipe) {
        _ = dup2(original, STDOUT_FILENO)
        close(original)
        pipe.fileHandleForWriting.closeFile()
    }

    private enum CaptureError: Error {
        case dupFailed
    }

    private func expectWarnSkipped(_ service: Service, flags: [String], field: String) throws {
        let captured = try capturedArgs(service)
        for flag in flags {
            #expect(!captured.args.contains(flag))
        }
        #expect(captured.output.contains("Note: '\(field)' is parsed but not supported by Apple container; ignored."))
    }

    private func decodeService(_ serviceYaml: String) throws -> Service {
        let indented = serviceYaml.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "    \($0)" }.joined(separator: "\n")
        let yaml = """
        services:
          svc:
        \(indented)
        """
        let compose = try YAMLDecoder().decode(DockerCompose.self, from: yaml)
        return try #require(compose.services["svc"] as? Service)
    }

    // MARK: - Gpus: Decode

    @Test("Service decodes gpus: all as Gpus.all")
    func gpusDecodesAll() throws {
        let svc = try decodeService("""
          image: alpine
          gpus: all
        """)
        #expect(svc.gpus == .all)
    }

    @Test("Service decodes gpus array form with multiple requests")
    func gpusDecodesArrayForm() throws {
        let svc = try decodeService("""
          image: alpine
          gpus:
            - driver: nvidia
              count: 2
              device_ids: ["0", "1"]
              capabilities: [compute, utility]
              options:
                memory: 8G
        """)
        guard case .requests(let reqs) = svc.gpus else {
            #expect(Bool(false), "Expected .requests case")
            return
        }
        #expect(reqs.count == 1)
        let req = reqs[0]
        #expect(req.driver == "nvidia")
        #expect(req.count == 2)
        #expect(req.device_ids == ["0", "1"])
        #expect(req.capabilities == ["compute", "utility"])
        #expect(req.options?["memory"] == "8G")
    }

    @Test("Service decodes gpus array form with multiple entries")
    func gpusDecodesMultipleRequests() throws {
        let svc = try decodeService("""
          image: alpine
          gpus:
            - count: 1
              capabilities: [compute]
            - count: 1
              capabilities: [utility]
        """)
        guard case .requests(let reqs) = svc.gpus else {
            #expect(Bool(false), "Expected .requests case")
            return
        }
        #expect(reqs.count == 2)
    }

    // MARK: - BlkioConfig: Decode

    @Test("Service decodes blkio_config with weight and weight_device")
    func blkioDecodesWeightAndDevice() throws {
        let svc = try decodeService("""
          image: alpine
          blkio_config:
            weight: 300
            weight_device:
              - path: /dev/sda
                weight: 400
        """)
        let blkio = try #require(svc.blkio_config)
        #expect(blkio.weight == 300)
        #expect(blkio.weight_device?.count == 1)
        #expect(blkio.weight_device?[0].path == "/dev/sda")
        #expect(blkio.weight_device?[0].weight == 400)
    }

    @Test("Service decodes blkio_config with rate devices")
    func blkioDecodesRateDevices() throws {
        let svc = try decodeService("""
          image: alpine
          blkio_config:
            device_read_bps:
              - path: /dev/sda
                rate: 12mb
            device_write_bps:
              - path: /dev/sdb
                rate: 8mb
            device_read_iops:
              - path: /dev/sda
                rate: 120
            device_write_iops:
              - path: /dev/sda
                rate: 100
        """)
        let blkio = try #require(svc.blkio_config)
        #expect(blkio.device_read_bps?[0].path == "/dev/sda")
        #expect(blkio.device_read_bps?[0].rate == "12mb")
        #expect(blkio.device_write_bps?[0].path == "/dev/sdb")
        #expect(blkio.device_write_bps?[0].rate == "8mb")
        #expect(blkio.device_read_iops?[0].rate == 120)
        #expect(blkio.device_write_iops?[0].rate == 100)
    }

    // MARK: - ResourceArgs: Gpus warn-skip

    @Test("gpus: .all warn-skips --gpus all")
    func gpusAllEmitsFlag() throws {
        let svc = Service(image: "alpine", gpus: .all)
        try expectWarnSkipped(svc, flags: ["--gpus"], field: "gpus")
    }

    @Test("gpus: requests with count, device_ids, capabilities emits no --gpus spec")
    func gpusRequestsEmitsSpec() throws {
        let req = GpuRequest(
            count: 2,
            device_ids: ["0", "1"],
            capabilities: ["compute", "utility"]
        )
        let svc = Service(image: "alpine", gpus: .requests([req]))
        let result = try args(svc)
        #expect(!result.contains("--gpus"))
    }

    @Test("gpus: multiple requests emit no --gpus flags")
    func gpusMultipleRequestsEmitsMultipleFlags() throws {
        let reqs = [
            GpuRequest(count: 1, capabilities: ["compute"]),
            GpuRequest(count: 1, capabilities: ["utility"])
        ]
        let svc = Service(image: "alpine", gpus: .requests(reqs))
        let result = try args(svc)
        let gpusCount = result.filter { $0 == "--gpus" }.count
        #expect(gpusCount == 0)
    }

    @Test("nil gpus emits no --gpus flag")
    func nilGpusNoFlag() throws {
        let svc = Service(image: "alpine")
        let result = try args(svc)
        #expect(!result.contains("--gpus"))
    }

    // MARK: - ResourceArgs: BlkioConfig warn-skip

    @Test("blkio_config weight warn-skips --blkio-weight")
    func blkioWeightFlag() throws {
        let blkio = BlkioConfig(weight: 300)
        let svc = Service(image: "alpine", blkio_config: blkio)
        try expectWarnSkipped(svc, flags: ["--blkio-weight"], field: "blkio_config")
    }

    @Test("blkio_config weight_device emits no --blkio-weight-device")
    func blkioWeightDeviceFlag() throws {
        let blkio = BlkioConfig(weight_device: [BlkioWeightDevice(path: "/dev/sda", weight: 400)])
        let svc = Service(image: "alpine", blkio_config: blkio)
        let result = try args(svc)
        #expect(!result.contains("--blkio-weight-device"))
    }

    @Test("blkio_config device_read_bps emits no --device-read-bps")
    func blkioReadBpsFlag() throws {
        let blkio = BlkioConfig(device_read_bps: [BlkioRateDevice(path: "/dev/sda", rate: "12mb")])
        let svc = Service(image: "alpine", blkio_config: blkio)
        let result = try args(svc)
        #expect(!result.contains("--device-read-bps"))
    }

    @Test("blkio_config device_write_bps emits no --device-write-bps")
    func blkioWriteBpsFlag() throws {
        let blkio = BlkioConfig(device_write_bps: [BlkioRateDevice(path: "/dev/sdb", rate: "8mb")])
        let svc = Service(image: "alpine", blkio_config: blkio)
        let result = try args(svc)
        #expect(!result.contains("--device-write-bps"))
    }

    @Test("blkio_config device_read_iops emits no --device-read-iops")
    func blkioReadIopsFlag() throws {
        let blkio = BlkioConfig(device_read_iops: [BlkioIopsDevice(path: "/dev/sda", rate: 120)])
        let svc = Service(image: "alpine", blkio_config: blkio)
        let result = try args(svc)
        #expect(!result.contains("--device-read-iops"))
    }

    @Test("blkio_config device_write_iops emits no --device-write-iops")
    func blkioWriteIopsFlag() throws {
        let blkio = BlkioConfig(device_write_iops: [BlkioIopsDevice(path: "/dev/sda", rate: 100)])
        let svc = Service(image: "alpine", blkio_config: blkio)
        let result = try args(svc)
        #expect(!result.contains("--device-write-iops"))
    }

    @Test("nil blkio_config emits no blkio flags")
    func nilBlkioNoFlags() throws {
        let svc = Service(image: "alpine")
        let result = try args(svc)
        #expect(!result.contains("--blkio-weight"))
        #expect(!result.contains("--blkio-weight-device"))
        #expect(!result.contains("--device-read-bps"))
        #expect(!result.contains("--device-write-bps"))
        #expect(!result.contains("--device-read-iops"))
        #expect(!result.contains("--device-write-iops"))
    }

    // MARK: - Combined nil check

    @Test("service with neither gpus nor blkio_config emits no related flags")
    func noGpusNoBlkioNoFlags() throws {
        let svc = Service(image: "alpine")
        let result = try args(svc)
        #expect(!result.contains("--gpus"))
        #expect(!result.contains("--blkio-weight"))
    }
}
