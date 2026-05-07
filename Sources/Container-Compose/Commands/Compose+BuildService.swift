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

import ContainerAPIClient
import ContainerCommands
import Foundation
import SystemPackage

// Canonical implementation of `compose build`'s per-service image build, shared
// across `ComposeUp`, `ComposeCreate`, and `ComposeBuild`. Lifts the logic onto
// `ComposeCommand` so any conforming subcommand can drive it via the same
// argv-construction pipeline.
extension ComposeCommand {
    /// Builds the image for a single service and returns the qualified image tag.
    ///
    /// When `rebuild` is `false`, the runtime image list is consulted first and
    /// the build is skipped if the target tag is already present. When `rebuild`
    /// is `true`, the build always runs (this is the `compose build` behavior).
    ///
    /// `passThroughCommands` is appended to the final argv unmodified; callers
    /// that have a `Flags.Logging` group typically pass
    /// `logging.passThroughCommands()`.
    func buildService(
        _ buildConfig: Build,
        for service: Service,
        serviceName: String,
        environmentVariables: [String: String],
        rebuild: Bool,
        noCache: Bool,
        passThroughCommands: [String] = []
    ) async throws -> String {
        var inlineTempURL: URL? = nil
        defer { inlineTempURL.flatMap { try? FileManager.default.removeItem(at: $0) } }

        let imageToRun = ComposeUp.qualifyImageReference(service.image ?? "\(serviceName):latest")

        if !rebuild {
            let imageList = try await ContainerClientEnvironment.current.imageList()
            if imageList.contains(where: { $0.description.reference == imageToRun || $0.description.reference.components(separatedBy: "/").last == imageToRun }) {
                return imageToRun
            }
        }

        let buildContextPath = FilePath(effectiveProjectDirectory)
            .pushing(FilePath(buildConfig.context))
            .lexicallyNormalized()
            .string
        var commands = [buildContextPath]

        for (key, value) in buildConfig.args ?? [:] {
            commands.append(contentsOf: ["--build-arg", "\(key)=\(resolveVariable(value, with: environmentVariables))"])
        }

        if let inlineContent = buildConfig.dockerfile_inline {
            if buildConfig.dockerfile != nil {
                print("Warning: Both 'dockerfile' and 'dockerfile_inline' are set for service '\(serviceName)'. 'dockerfile_inline' takes priority.")
            }
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".Dockerfile")
            try inlineContent.write(to: tempURL, atomically: true, encoding: .utf8)
            inlineTempURL = tempURL
            commands.append(contentsOf: ["--file", tempURL.path])
        } else {
            let dockerfilePath = FilePath(effectiveProjectDirectory)
                .pushing(FilePath(buildConfig.dockerfile ?? "Dockerfile"))
                .lexicallyNormalized()
                .string
            commands.append(contentsOf: ["--file", dockerfilePath])
        }

        if noCache {
            commands.append("--no-cache")
        }

        if let target = buildConfig.target {
            commands.append(contentsOf: ["--target", target])
        }

        warnUnsupportedContainerBuildFields(buildConfig, serviceName: serviceName)

        for (key, value) in buildConfig.labels ?? [:] {
            commands.append(contentsOf: ["--label", "\(key)=\(value)"])
        }

        for secretId in buildConfig.secrets ?? [] {
            commands.append(contentsOf: ["--secret", "id=\(secretId)"])
        }

        if let buildPlatforms = buildConfig.platforms, !buildPlatforms.isEmpty {
            if buildPlatforms.count > 1 {
                print("Warning: Service '\(serviceName)' declares \(buildPlatforms.count) build platforms. Only the first ('\(buildPlatforms[0])') will be used.")
            }
            let firstPlatform = buildPlatforms[0]
            let split = firstPlatform.split(separator: "/")
            let os = String(split.first ?? "linux")
            let arch = String(split.count >= 2 ? split.last! : "arm64")
            commands.append(contentsOf: ["--os", os, "--arch", arch])
        } else {
            let split = service.platform?.split(separator: "/")
            let os = String(split?.first ?? "linux")
            let arch = String(((split ?? []).count >= 1 ? split?.last : nil) ?? "arm64")
            commands.append(contentsOf: ["--os", os, "--arch", arch])
        }

        commands.append(contentsOf: ["--tag", imageToRun])

        let cpuCount = Int64(service.deploy?.resources?.limits?.cpus ?? "2") ?? 2
        let memoryLimit = service.deploy?.resources?.limits?.memory ?? "2048MB"
        commands.append(contentsOf: ["--cpus", "\(cpuCount)", "--memory", memoryLimit])

        let buildArgv = commands + passThroughCommands

        print("\n----------------------------------------")
        print("Building image for service: \(serviceName) (Tag: \(imageToRun))")
        _ = try await RunnerEnvironment.current.run(
            RunRequest(kind: .swiftAPI(name: "BuildCommand"), argv: buildArgv, cwd: nil),
            onStdout: nil,
            onStderr: nil
        )
        print("Image build for \(serviceName) completed.")
        print("----------------------------------------")

        return imageToRun
    }
}
