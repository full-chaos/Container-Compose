//
//  main.swift
//  Container-Compose
//
//  Created by Morris Richman on 6/18/25.
//

import ContainerComposeCore
import ArgumentParser

@main
struct Application: AsyncParsableCommand {
    @Argument(parsing: .captureForPassthrough) var args: [String]

    func run() async throws {
        let remote = try RemoteRuntimeFlagParser.extract(from: args)

        // Reorder args so global flags placed BEFORE the subcommand
        // (e.g. `container-compose -f compose.yml build`) are moved
        // to immediately AFTER the subcommand, matching `docker compose` UX.
        let normalized = ArgvNormalizer.promoteGlobalFlags(remote.remainder)

        if let configuration = remote.configuration {
            await RuntimeExecutionMode.$isRemote.withValue(true) {
                await RuntimeEnvironment.$current.withValue(RemoteRuntime(configuration: configuration)) {
                    await Main.main(normalized)
                }
            }
        } else {
            await Main.main(normalized)
        }
    }
}
