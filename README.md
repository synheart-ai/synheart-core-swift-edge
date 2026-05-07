# SynheartCoreEdge (Swift)

Light Synheart Core SDK for **watchOS / Apple Watch**. The full
[`synheart-core-swift`](https://github.com/synheart-ai/synheart-core-swift) SDK
is too heavy for a watch — this package ships the minimum needed to run an
on-device session and relay results to a paired iPhone.

> **Status:** `0.0.1` — initial extraction from the
> [`synheart-edge-watch-ios`](https://github.com/synheart-ai/synheart-edge-watch-ios)
> reference app. **Public API surface is being scoped — types are currently
> `internal` (Swift default) and will be promoted to `public` in `0.0.2`.**
> Use as a structure preview; not yet importable as a third-party SwiftPM dep.

## Scope

What's in:

- **Engine** — `WatchSessionEngine`, `EdgeSessionManager`, `EdgeOutbox`,
  `MotionAccumulator`, `RuntimeBridge`
- **Sensors** — `HeartRateSensor` (HKWorkoutSession), `MotionSensor` (CoreMotion)
- **Relay** — `PhoneRelay` (WCSession to paired iPhone)
- **Models** — `SessionConfig`, `SessionPreset`, `ComputeProfile`, `SessionEvent`

What's out (ships in `synheart-core-swift`, not here):

- Cloud sync / direct HTTPS upload
- Authentication (phone owns identity)
- Lab ingest, longitudinal SRM, baselines
- Behavior / consent UI

## Architecture

```
sensors  →  WatchSessionEngine  →  RuntimeBridge (FFI) → synheart-core-runtime
                  │
                  ├──→  EdgeOutbox    (local artifact persistence)
                  └──→  PhoneRelay    (relay to iPhone)
```

Native runtime (`synheart-core-runtime`) is loaded at runtime via `dlsym` —
no SwiftPM dependency declared. Consumers must bundle the appropriate static
library at app build time.

## Install

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/synheart-ai/synheart-core-swift-edge", from: "0.0.1"),
],
targets: [
    .target(name: "MyWatchApp", dependencies: ["SynheartCoreEdge"]),
]
```

## Size budget

| Metric | Target | Status |
|---|---|---|
| Compiled library (excl. native runtime) | < 500 KB | not yet measured |
| Public top-level types | ≤ 12 | TBD in 0.0.2 |
| Transitive Synheart SDK deps | 0 | ✓ 0 |

## Reference app

[`synheart-edge-watch-ios`](https://github.com/synheart-ai/synheart-edge-watch-ios)
is the canonical consumer. It will migrate to this SDK once `0.1.0` is tagged.

## License

[Apache-2.0](LICENSE)
