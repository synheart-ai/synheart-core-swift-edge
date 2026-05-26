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
        // Only SynheartSession's BiosignalProvider protocol. Since 0.0.4 the
        // engine requires the consumer to inject a provider, so we no longer
        // pull SynheartSessionHealthKit + SynheartWear (and their grpc /
        // protobuf transitive payload) for a watchOS SDK that runs neither.
        //
        // Consumers wiring HealthKit on Apple platforms build the previous
        // default themselves:
        //   HealthKitBiosignalProvider(wear: SynheartWear())
        // pulled from synheart-session-swift / synheart-wear-swift in the
        // consumer's Package.swift.
        .package(url: "https://github.com/synheart-ai/synheart-session-swift.git", from: "0.2.1"),
        // synheart-core-runtime itself is loaded via dlsym in RuntimeBridge.swift;
        // no SwiftPM dependency declared.
    ],
    targets: [
        .target(
            name: "SynheartCoreEdge",
            dependencies: [
                .product(name: "SynheartSession", package: "synheart-session-swift"),
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
