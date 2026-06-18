# Synheart Core Edge SDK — Swift

[![Version](https://img.shields.io/badge/version-0.0.5-blue.svg)](https://github.com/synheart-ai/synheart-core-swift-edge)
[![Swift](https://img.shields.io/badge/Swift-5.9%2B-FA7343.svg)](https://swift.org)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)

> **Source-available.** This repository is open for reading, auditing, and
> filing issues. We do **not** accept pull requests — see
> [CONTRIBUTING.md](CONTRIBUTING.md) for the rationale and how to contribute
> via issues. Security reports go through [SECURITY.md](SECURITY.md).

Light Synheart Core SDK for **watchOS / Apple Watch** — the minimum needed to run an on-device session and relay results to a paired iPhone. The full [`synheart-core-swift`](https://github.com/synheart-ai/synheart-core-swift) SDK is too heavy for a watch. See [docs.synheart.ai/synheart-core/edge](https://docs.synheart.ai/synheart-core/edge) for the cross-platform guide.

## Scope

What's in:

- **Engine** — `WatchSessionEngine`, `EdgeSessionManager`, `EdgeOutbox`, `WatchSessionState`
- **Sensors** — `MotionSensor` (CoreMotion). HR comes from a `BiosignalProvider` you inject (e.g. `HealthKitBiosignalProvider` from [synheart-session-swift](https://github.com/synheart-ai/synheart-session-swift), a BLE HRM, or a mock)
- **Relay** — `PhoneRelay` (WCSession to paired iPhone)
- **Models** — `SessionConfig`, `SessionPreset`, `ComputeProfile`, `SessionEvent`, `EdgeTypes`

What's out (ships in `synheart-core-swift`, not here):

- Cloud sync / direct HTTPS upload
- Authentication (phone owns identity)
- Lab ingest, longitudinal SRM, baselines
- Behavior / consent UI

## Install

### Swift Package Manager (recommended)

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/synheart-ai/synheart-core-swift-edge.git", from: "0.0.5"),
],
targets: [
    .target(name: "MyWatchApp", dependencies: [
        .product(name: "SynheartCoreEdge", package: "synheart-core-swift-edge"),
    ]),
]
```

### CocoaPods

```ruby
# Podfile
pod 'SynheartCoreEdge', :git => 'https://github.com/synheart-ai/synheart-core-swift-edge.git', :tag => 'v0.0.5'
pod 'SynheartSession',  :git => 'https://github.com/synheart-ai/synheart-session-swift.git',  :tag => 'v0.2.1'
```

Pod consumers must also declare `SynheartSession` (the `BiosignalProvider`
protocol). The two pods carry their own podspecs in their repos; we don't
publish to CocoaPods Trunk — git refs only.

Platforms: watchOS 9.0+, iOS 15.0+, macOS 13.0+.

## Quickstart

```swift
import SwiftUI
import SynheartCoreEdge

@main
struct MyWatchApp: App {
    @StateObject private var engine = WatchSessionEngine(
        provider: HealthKitBiosignalProvider(wear: SynheartWear()),
        outbox: EdgeOutbox(),
        sessionManager: EdgeSessionManager()
    )

    var body: some Scene {
        WindowGroup {
            Button("Start") {
                engine.startEdgeSession(preset: SessionPreset.defaults[0])
            }
        }
    }
}
```

Swap the provider for a custom HR source (BLE chest-strap, mock, etc.):

```swift
let engine = WatchSessionEngine(
    provider: MyBLEHrmProvider(),
    outbox: EdgeOutbox(),
    sessionManager: EdgeSessionManager()
)
```

## Architecture

```
sensors  →  WatchSessionEngine  →  native FFI bridge (dlsym) → synheart-core-runtime
                  │
                  ├──→  EdgeOutbox    (local artifact persistence)
                  └──→  PhoneRelay    (relay to iPhone via WCSession)
```

The native runtime binary (`libsynheart_core_runtime` / `SynheartCoreRuntime.xcframework`) is `dlsym`'d at startup. When absent, the engine falls back to `.stream` mode and surfaces raw samples via `onBiosignalSample` for the host to relay. When present, the engine runs the edge HSI pipeline locally in `.computeLocal` mode.

**watchOS runtime binary:** building the runtime for `aarch64-apple-watchos` requires nightly Rust with `-Z build-std` (tier-3 target). Until vendored, watchOS apps run `.stream`-only. iPhone apps using this SDK get `.computeLocal` immediately.

## Session API

```swift
engine.startSession(config: ..., mode: .computeLocal? | .stream? | nil)
engine.pauseSession()
engine.resumeSession()
engine.stopSession()
engine.startEdgeSession(preset: ...)         // standalone watch session
engine.acknowledgeArtifacts(ids: [...])      // after phone confirms relay receipt
```

State: `.idle | .starting | .running | .paused | .stopping | .syncing | .error`

Observable: `currentHr`, `state`, `elapsedSec`, `remainingSec`, `pendingArtifactCount`, `droppedFrames`, `lastMetrics`.
Callbacks: `onHrSample`, `onBiosignalSample`, `onEvent`.

## See also

- **Reference watch app:** [synheart-edge-watch-ios](https://github.com/synheart-ai/synheart-edge-watch-ios)

## License

[Apache-2.0](LICENSE)
