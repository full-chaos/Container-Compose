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
        // Reorder args so global flags placed BEFORE the subcommand
        // (e.g. `container-compose -f compose.yml build`) are moved
        // to immediately AFTER the subcommand, matching `docker compose` UX.
        await Main.main(ArgvNormalizer.promoteGlobalFlags(args))
    }
}
