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
        // Path-based for now (matches synheart-core-swift's pattern). Switch
        // to a `.package(url: ...)` GitHub dep once synheart-session-swift
        // tags a version that satisfies the SemVer constraint we want.
        .package(path: "../synheart-session-swift"),
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
