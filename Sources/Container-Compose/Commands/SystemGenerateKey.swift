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

// MARK: - SystemGenerateKey

public struct SystemGenerateKey: AsyncParsableCommand {
    public static let configuration: CommandConfiguration = .init(
        commandName: "generate-key",
        abstract: "Generate a new API key for daemon Bearer-token auth.",
        discussion: """
        Prints the raw token ONCE. Copy it now — it cannot be recovered.
        Only the SHA-256 hash is persisted to ~/.container-compose/auth.json.
        """
    )

    @Option(
        name: .customLong("name"),
        help: "Unique label for the key (used by revoke-key/list-keys)."
    )
    public var name: String

    @Option(
        name: .customLong("auth-file"),
        help: "Path to auth keys file. Defaults to ~/.container-compose/auth.json.",
        completion: .file()
    )
    public var authFile: String?

    public init() {}

    public func run() async throws {
        try RuntimeModeSupport.requireLocalOnly(operation: "system generate-key")

        let url = SystemKeyCommands.resolveAuthFile(authFile)
        let store = try await FileAuthStore(path: url)

        guard await !store.list().contains(where: { $0.name == name }) else {
            throw ValidationError("a key named '\(name)' already exists; revoke it first or pick a different name")
        }

        let (rawToken, hashHex) = APIKeyGenerator.generate()
        try await store.insert(StoredKey(name: name, hash: hashHex, createdAt: Date()))

        print("API key generated. Copy it now — it will NOT be shown again:")
        print("")
        print("    \(rawToken)")
        print("")
        print("Stored hash prefix: \(String(hashHex.prefix(8)))…  (file: \(url.path))")
    }
}
