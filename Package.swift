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
        //
        // ⚠ Transitive bloat (v0.2.0): synheart-session-swift currently
        // pulls grpc-swift, swift-nio, swift-nio-extras, swift-nio-http2,
        // swift-nio-ssl, swift-nio-transport-services, swift-certificates,
        // swift-crypto, swift-asn1, swift-async-algorithms, etc. — Apple
        // swift-server ecosystem deps that are wildly disproportionate for
        // a watch-class edge SDK. The fix lives in synheart-session-swift
        // (a slim variant that excludes the server-only modules); tracked
        // as part of the wider edge-size audit and not addressable from
        // this repo alone. Until then, the linker drops unreferenced
        // symbols so device binary size is contained, but cold build
        // times suffer.
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
