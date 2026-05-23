# SynheartCoreEdge (Swift)

Light Synheart Core SDK for **watchOS / Apple Watch**. The full [`synheart-core-swift`](https://github.com/synheart-ai/synheart-core-swift) SDK is too heavy for a watch — this package ships the minimum needed to run an on-device session and relay results to a paired iPhone.

**Status:** `0.0.3` — public API. Mirrors [`synheart-core-kotlin-edge`](https://github.com/synheart-ai/synheart-core-kotlin-edge) one-for-one (same engine surface, same state machine, same model types). See [docs.synheart.ai/synheart-core/edge](https://docs.synheart.ai/synheart-core/edge) for the cross-platform guide.

## Scope

What's in:

- **Engine** — `WatchSessionEngine`, `EdgeSessionManager`, `EdgeOutbox`, `RuntimeBridge`, `WatchSessionState`
- **Sensors** — `MotionSensor` (CoreMotion). HR comes from a `BiosignalProvider` (defaults to `HealthKitBiosignalProvider` from [synheart-session-swift](https://github.com/synheart-ai/synheart-session-swift); injectable)
- **Relay** — `PhoneRelay` (WCSession to paired iPhone)
- **Models** — `SessionConfig`, `SessionPreset`, `ComputeProfile`, `SessionEvent`, `EdgeTypes`

What's out (ships in `synheart-core-swift`, not here):

- Cloud sync / direct HTTPS upload
- Authentication (phone owns identity)
- Lab ingest, longitudinal SRM, baselines
- Behavior / consent UI

## Install

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/synheart-ai/synheart-core-swift-edge.git", from: "0.0.3"),
],
targets: [
    .target(name: "MyWatchApp", dependencies: [
        .product(name: "SynheartCoreEdge", package: "synheart-core-swift-edge"),
    ]),
]
```

Platforms: watchOS 9.0+, iOS 15.0+, macOS 13.0+.

## Quickstart

```swift
import SwiftUI
import SynheartCoreEdge

@main
struct MyWatchApp: App {
    @StateObject private var engine = WatchSessionEngine(
        outbox: EdgeOutbox(),
        sessionManager: EdgeSessionManager()
    )

    var body: some Scene {
        WindowGroup {
            Button("Start") {
                engine.startSession(config: .focusDefault())
            }
        }
    }
}
```

Swap the default `HealthKitBiosignalProvider` for a custom HR source (BLE chest-strap, mock, etc.):

```swift
let engine = WatchSessionEngine(
    provider: MyBLEHrmProvider(),
    outbox: EdgeOutbox(),
    sessionManager: EdgeSessionManager()
)
```

## Architecture

```
sensors  →  WatchSessionEngine  →  RuntimeBridge (dlsym) → synheart-core-runtime
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

Observable: `currentHr`, `state`, `elapsedSec`, `remainingSec`, `pendingArtifacts`, `lastMetrics`.
Callbacks: `onHrSample`, `onBiosignalSample`, `onEvent`.

## See also

- **Cross-platform guide:** [docs.synheart.ai/synheart-core/edge](https://docs.synheart.ai/synheart-core/edge)
- **Kotlin parallel:** [synheart-core-kotlin-edge](https://github.com/synheart-ai/synheart-core-kotlin-edge)
- **Reference watch app:** [synheart-edge-watch-ios](https://github.com/synheart-ai/synheart-edge-watch-ios)

## License

[Apache-2.0](LICENSE)
