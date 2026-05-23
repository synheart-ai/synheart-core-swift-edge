// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SynheartCoreEdge",
    platforms: [
        .watchOS(.v9),
        .iOS(.v15),
        .macOS(.v13),
    ],
    products: [
        .library(name: "SynheartCoreEdge", targets: ["SynheartCoreEdge"]),
    ],
    dependencies: [
        // Session lifecycle + biosignal provider abstraction. Pulls
        // SynheartSession (core) + SynheartSessionHealthKit (Apple Watch /
        // iPhone HealthKit-backed BiosignalProvider).
        // Transitively pulls synheart-wear-swift.
        //
        // Resolves over the public GitHub registry so OSS CI (which has no
        // sibling monorepo checkout) can build the package. Matches the
        // pattern used by synheart-session-swift itself for its own
        // dependencies.
        .package(url: "https://github.com/synheart-ai/synheart-session-swift.git", from: "0.2.0"),
        // synheart-core-runtime itself is loaded via dlsym in RuntimeBridge.swift;
        // no SwiftPM dependency declared.
    ],
    targets: [
        .target(
            name: "SynheartCoreEdge",
            dependencies: [
                .product(name: "SynheartSession", package: "synheart-session-swift"),
                .product(name: "SynheartSessionHealthKit", package: "synheart-session-swift"),
            ],
            path: "Sources/SynheartCoreEdge"
        ),
        .testTarget(
            name: "SynheartCoreEdgeTests",
            dependencies: ["SynheartCoreEdge"],
            path: "Tests/SynheartCoreEdgeTests"
        ),
    ]
)
