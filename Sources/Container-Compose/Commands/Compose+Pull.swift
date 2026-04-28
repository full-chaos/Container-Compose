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

func pullImage(
    image imageName: String,
    policy: String? = nil,
    client: any ContainerClientProvider = ContainerClientEnvironment.current,
    runner: any RunCommandRunner = RunnerEnvironment.current,
    platform: String? = nil,
    loggingArguments: [String] = []
) async throws {
    let effectivePolicy = normalizedPullPolicy(policy)

    let imageList = try await client.imageList()
    let imageExists = imageList.contains(where: {
        $0.description.reference.components(separatedBy: "/").last == imageName
    })

    switch effectivePolicy {
    case "never", "build":
        // Image must already be present; pull is forbidden.
        guard imageExists else {
            throw ComposeError.imageNotFound(imageName)
        }
        return

    case "always":
        // Always pull, regardless of whether the image is cached locally.
        break

    default:
        // "missing": short-circuit if image already exists.
        guard !imageExists else { return }
    }

    print("Pulling Image \(imageName)...")

    var commands = [imageName]

    if let platform {
        commands.append(contentsOf: ["--platform", platform])
    }

    let imagePullArgv = commands + loggingArguments
    _ = try await runner.run(
        RunRequest(kind: .swiftAPI(name: "ImagePull"), argv: imagePullArgv, cwd: nil),
        onStdout: nil,
        onStderr: nil
    )
}

private func normalizedPullPolicy(_ policy: String?) -> String {
    // Normalise policy: nil and "if_not_present" are aliases for "missing".
    switch policy?.lowercased() {
    case nil, "missing", "if_not_present":
        return "missing"
    case "always":
        return "always"
    case "never":
        return "never"
    case "build":
        return "build"
    default:
        return "missing"
    }
}
