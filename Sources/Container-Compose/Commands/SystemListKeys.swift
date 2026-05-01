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

// MARK: - SystemListKeys

public struct SystemListKeys: AsyncParsableCommand {
    public static let configuration: CommandConfiguration = .init(
        commandName: "list-keys",
        abstract: "List API keys (NAME, HASH-PREFIX, CREATED). Never prints raw tokens or full hashes."
    )

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
        let keys = await store.list()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        print("NAME\tHASH-PREFIX\tCREATED")
        for key in keys.sorted(by: { $0.createdAt < $1.createdAt }) {
            let prefix = String(key.hash.prefix(8))
            let when = formatter.string(from: key.createdAt)
            print("\(key.name)\t\(prefix)\t\(when)")
        }
    }
}
