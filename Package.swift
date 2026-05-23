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
        // URL-based so this SDK is consumable by external apps via SwiftPM
        // (a path dep here would error with "package … depends on local
        // package … which is not supported" the moment a remote consumer
        // tries to resolve us). synheart-session-swift is pre-1.0; we pin
        // via `from: "0.2.1"` and rely on its 0.2.x line staying compatible
        // until we both tag stable.
        .package(url: "https://github.com/synheart-ai/synheart-session-swift.git", from: "0.2.1"),
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
