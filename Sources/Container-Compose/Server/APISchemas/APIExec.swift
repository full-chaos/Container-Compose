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

import Foundation

// MARK: - Runtime command schemas (CHAOS-1427)

public struct APIExecRequest: Codable, Sendable, Hashable {
    public let command: [String]
    public let detach: Bool?
    public let interactive: Bool?
    public let tty: Bool?
    public let environment: [String]?
    public let user: String?
    public let workingDirectory: String?

    public init(
        command: [String],
        detach: Bool? = nil,
        interactive: Bool? = nil,
        tty: Bool? = nil,
        environment: [String]? = nil,
        user: String? = nil,
        workingDirectory: String? = nil
    ) {
        self.command = command
        self.detach = detach
        self.interactive = interactive
        self.tty = tty
        self.environment = environment
        self.user = user
        self.workingDirectory = workingDirectory
    }

    public var runtimeOptions: RuntimeExecOptions {
        RuntimeExecOptions(
            detach: detach ?? false,
            interactive: interactive ?? true,
            tty: tty ?? true,
            environment: environment ?? [],
            user: user,
            workingDirectory: workingDirectory
        )
    }
}

public struct APIExecResponse: Codable, Sendable, Hashable {
    public let stdout: [String]
    public let stderr: [String]
    public let exitCode: Int32

    public init(stdout: [String], stderr: [String], exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

public struct APIProcessListResponse: Codable, Sendable, Hashable {
    public let containerId: String
    public let output: [String]

    public init(containerId: String, output: [String]) {
        self.containerId = containerId
        self.output = output
    }
}
