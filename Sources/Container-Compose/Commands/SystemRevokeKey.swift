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

import ArgumentParser
import Foundation

// MARK: - SystemRevokeKey

public struct SystemRevokeKey: AsyncParsableCommand {
    public static let configuration: CommandConfiguration = .init(
        commandName: "revoke-key",
        abstract: "Revoke an API key by name. Existing tokens with that name stop working immediately."
    )

    @Argument(help: "The key name to revoke.")
    public var name: String

    @Option(
        name: .customLong("auth-file"),
        help: "Path to auth keys file. Defaults to ~/.container-compose/auth.json.",
        completion: .file()
    )
    public var authFile: String?

    public init() {}

    public func run() async throws {
        let url = SystemKeyCommands.resolveAuthFile(authFile)
        let store = try await FileAuthStore(path: url)
        let removed = try await store.remove(name: name)

        if removed {
            print("Revoked key: \(name)")
        } else {
            FileHandle.standardError.write(Data("no key named '\(name)'\n".utf8))
            throw ExitCode(1)
        }
    }
}
