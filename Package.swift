// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "container-compose",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.1"),
        .package(url: "https://github.com/full-chaos/container", branch: "tier2-fork-patches"),
        // CHAOS-1346 Phase 1: direct dependency on apple/containerization for the
        // new `protocol Runtime` boundary. Pinned to the same minor as the Phase 0
        // spike (0.31.x); the full-chaos/container fork already pulls 0.31.0
        // transitively, so SwiftPM dedupes to a single resolved version.
        .package(url: "https://github.com/apple/containerization.git", .upToNextMinor(from: "0.31.0")),
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.1"),
        .package(url: "https://github.com/onevcat/Rainbow", .upToNextMajor(from: "4.0.0")),
        // CHAOS-1349 Phase 2.0: HTTP server for `container-compose serve`. Decision #2
        // in `docs/plans/native-api-server.md` locks Hummingbird 2.x. Heavy transitive
        // overlap with apple/containerization's swift-nio stack — small marginal dep cost.
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        // CHAOS-1349: signal-safe graceful shutdown. Hummingbird's `Application` natively
        // conforms to `Service`; ServiceGroup wires SIGTERM/SIGINT into a clean drain.
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.0.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a target.
        // Targets can depend on other targets in this package and products from dependencies.
        
        // Library target containing core logic
        .target(
            name: "ContainerComposeCore",
            dependencies: [
                .product(
                    name: "ContainerCommands",
                    package: "container"
                ),
                .product(
                    name: "Containerization",
                    package: "containerization"
                ),
                .product(
                    name: "ArgumentParser",
                    package: "swift-argument-parser"
                ),
                .product(
                    name: "Hummingbird",
                    package: "hummingbird"
                ),
                .product(
                    name: "ServiceLifecycle",
                    package: "swift-service-lifecycle"
                ),
                "Yams",
                "Rainbow",
            ],
            path: "Sources/Container-Compose"
        ),
        
        // Executable target
        .executableTarget(
            name: "container-compose",
            dependencies: [
                "ContainerComposeCore"
            ],
            path: "Sources/ContainerComposeApp"
        ),
        
        // Test Helper
        .target(
            name: "TestHelpers",
            dependencies: ["ContainerComposeCore"],
            path: "Tests/TestHelpers"
        ),
        
        // Tests
        .testTarget(
            name: "Container-Compose-StaticTests",
            dependencies: [
                "ContainerComposeCore",
                "TestHelpers",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdTesting", package: "hummingbird")
            ]
        ),
        
        .testTarget(
            name: "Container-Compose-DynamicTests",
            dependencies: [
                "ContainerComposeCore",
                "TestHelpers"
            ]
        ),
    ]
)
