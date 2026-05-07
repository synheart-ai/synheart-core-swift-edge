# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.0.1] - 2026-05-07

Initial release. Watch-side SDK for Apple Watch / watchOS, extracted from
[`synheart-edge-watch-ios`](https://github.com/synheart-ai/synheart-edge-watch-ios)
and recomposed against the same sibling SDKs the phone SDK depends on.

### Architecture

This SDK is a **thin FFI wrapper** around `synheart-core-runtime`. All math
and signal derivation runs in the native runtime, not in Swift. The watch
SDK is just: sensor capture → push raw samples (`pushHr` / `pushRr` /
`pushAccel`) to runtime → outbox runtime-emitted artifacts → relay to phone.

### Composition

- **Biosignals** flow through `HealthKitBiosignalProvider` from
  `SynheartSessionHealthKit` (which wraps `SynheartWear`). This is the same
  multi-device biosignal abstraction the phone SDK uses — Apple Watch +
  BLE HRMs / Whoop / Garmin all share one path.
- **Motion** (accelerometer) is captured locally via CoreMotion since
  HealthKit doesn't stream raw IMU. Raw `(t, x, y, z)` samples are pushed
  straight to the runtime; no client-side aggregation.
- **Session lifecycle** is owned by `WatchSessionEngine` (state machine,
  timers, outbox). A future release will move lifecycle ownership into
  `SynheartSession.SessionEngine` directly.
- **Native runtime** (`synheart-core-runtime`) is dlopen'd at runtime via
  `RuntimeBridge`; no SwiftPM dependency declared. Apps must bundle the
  static library.

### Engine modes

`EngineMode` selects how the watch participates in a session:

- `.stream` — raw `BiosignalSample`s are surfaced via `onBiosignalSample`
  for the host app to relay to the paired phone. Runtime not loaded.
- `.computeLocal` — raw samples piped to `synheart-core-runtime` via FFI;
  HSI artifacts emitted by the runtime are persisted into `EdgeOutbox` and
  relayed to phone.

Default resolution at `startSession`: try to load the runtime; if available
use `.computeLocal`, otherwise fall back to `.stream`. Caller can override
via `startSession(config:mode:)`.

### Code hygiene at extraction

Pulled out of the reference watch app and **not carried forward** into this
SDK:

- `MotionAccumulator` (local RMS-g aggregation) — runtime owns it.
- In-process HR / RR sample buffers (`hrBpmSamples`, `rrIntervals`) and the
  local computation of `hr_mean_bpm`, `hr_sdnn_ms`, `rmssd_ms` — runtime
  emits authoritative values in HSI JSON.
- Bespoke `HeartRateSensor` (HKWorkoutSession-only) — replaced by
  `HealthKitBiosignalProvider` for multi-device support.
- `Sensor/HrSample.swift` — replaced by `BiosignalSample` from
  `SynheartSession`.
- Per-frame metric synthesis from accumulated buffers — replaced by passing
  the runtime's HSI dict through unchanged.

### Notes

- Source types are mostly `internal` (Swift default) and not yet visible
  to SwiftPM consumers. Scope refinement (promoting the v0 public surface)
  lands in `0.0.2`.
- `Package.swift` depends on `synheart-session-swift` via path for
  monorepo dev. Will switch to a `.package(url: ...)` GitHub dep once
  `synheart-session-swift` tags a satisfying version.
- `PhoneRelay` and `MotionSensor` are guarded with `#if canImport`
  (`WatchConnectivity`, `CoreMotion`) so the package builds and tests on
  macOS hosts.

### Planned (0.0.2)

- Drive session lifecycle through `SynheartSession.SessionEngine` directly
  rather than maintaining a parallel timer-driven loop. Connect runtime
  HSI output to `engine.ingestHsiMetrics(...)` so frames carry authoritative
  metrics from native code.
- Promote core types to `public` — define the v0 public API surface
  (`EdgeSession`, `SessionConfig`, `SessionPreset`, `ComputeProfile`,
  `SessionEvent`, `MotionSample`, `HsiArtifactEnvelope`, `PhoneRelay`,
  `RuntimeBridge`, `EdgeOutbox`).
- Add CI binary-size assertion to enforce the 500 KB budget.
