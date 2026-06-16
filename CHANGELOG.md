# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.0.5] - 2026-06-15

### Added
- `RuntimeBridge.tickAndReadout()` — fetches the tick HSI plus the raw
  `preprocessed` + `quality` JSON in ONE serial-queue critical section
  (`RuntimeReadout`), so a concurrent motion push can no longer tear
  preprocessed/quality away from the HSI of that frame. Used by
  `emitFrame`/`finishSession`.
- `WatchSessionEngine.droppedFrames` (public `Int`) — surfaces the native
  contention counter (previously only on the bridge).
- `EdgeOutbox` retention sweep: un-ACKed artifacts older than the retention
  window (default 14 days) are reaped on init and on `sweepExpired()`, so the
  outbox can't grow without bound.
- `EdgeMode` enum (`off` / `shadow` / `canonical`, rawValue = wire string) and
  `ComputeProfile.edgeMode` (default `.canonical`), emitted to the native
  runtime as nested `compute_profile.edge_mode` in the create-config JSON.
- `WatchSessionEngine.SUPPORTED_HSI_VERSIONS = ["1.1","1.2","1.3"]`; the parsed
  tick HSI payload's `hsi_version` is logged when outside the set (no wire
  change — envelope `schema_version` untouched).
- Internal native-bridge diagnostic counter for frames the native runtime
  reported as dropped under contention.
- `EdgeSessionManager.subjectId` (`"sub_<deviceOpaque>"`) — stable per-device
  opaque id used as the runtime `subject_id`. No shared placeholder is ever
  used. `EdgeSessionManager` and `PhoneRelay` now accept an optional
  `UserDefaults`/key so two SDK-based apps on one device don't collide
  (defaults unchanged).
- `WatchSessionEngine.streamRawSamples` — whether raw `BiosignalSample`s are
  surfaced for phone relay this session, resolved from `edge_mode`.

### Fixed
- **Final-window artifact durability:** when the final tick in
  `finishSession` produces HSI, the last window is now wrapped, enqueued to the
  durable outbox, and relayed as an `.artifact` event (computeLocal: CANONICAL
  + SHADOW) — previously it only landed in the Summary metrics and was never
  persisted or ACK-tracked.
- **Outbox reader/writer consistency:** `EdgeOutbox.pending()` /
  `pendingCount` now read through the serial queue (`queue.sync`) instead of
  scanning the directory on the caller thread while writes go through
  `queue.async`, so counts/lists never observe a half-applied mutation.
- **Path-traversal hardening:** a wire-supplied `artifact_id` that isn't
  `^[A-Za-z0-9_-]+$` is rejected before any path op on enqueue and ack/remove,
  so a crafted id can't escape the outbox directory.
- **Encryption at rest + relocation:** the outbox and session manifests
  move to Application Support (out of user-visible Documents) and are written
  `[.atomic, .completeFileProtectionUnlessOpen]`, encrypted at rest while the
  device is locked. On-the-wire / on-disk JSON shape unchanged.
- **Bridge handle free:** `RuntimeBridge.deinit` now frees the FFI
  handle through the serial `queue` (it freed off-queue before, risking a UAF
  against the non-idempotent Rust destroy if a handle call was still draining).
- **Frame-readout tearing:** `emitFrame`/`finishSession` read the HSI,
  preprocessed, and quality via the single-critical-section `tickAndReadout()`
  rather than three separate reads that a push could interleave.
- **Decode `hsi_version` re-extraction:** a pre-`hsi_version` outbox file now
  re-extracts its real version from `payload_json` on decode instead of
  defaulting to `"unknown"`.
- **Numeric phone duration:** `SessionConfig(fromPhoneCommand:)` accepts a
  Double-or-Int `duration_sec` (a `300.0` from the phone is no longer silently
  dropped by `as? Int`).

### Changed
- `WatchSessionEngine` now HONORS `config.profile.edgeMode`:
  `.off` → `.stream`, native runtime never started, raw samples stream;
  `.canonical` → `.computeLocal` (if runtime available), raw samples suppressed;
  `.shadow` → `.computeLocal` AND raw samples streamed. Previously OFF/SHADOW
  behaved as CANONICAL.
- `WatchSessionEngine` marshals all `@Published` mutations (`state`, `currentHr`,
  `elapsedSec`, `lastMetrics`, `sessionKind`, `mode`) to the main thread; timer
  and provider/motion callback writes no longer publish off-main (SwiftUI
  hazard). FFI stays confined to the native bridge's serial queue.
- `MotionSensor` timestamps samples from `CMAccelerometerData.timestamp`
  (device-uptime → epoch-ms) instead of `Date()` at delivery, aligning the accel
  timeline with HR/RR.
- All native-bridge handle calls (push/tick/last_*/frameCount/reset/destroy)
  are now confined to one dedicated serial `DispatchQueue` per session so calls
  never race the native handle (the runtime `try_lock`-drops on contention).
- Native-bridge frame-count query returns `Int64` to match the C ABI
  `c_longlong`.
- Native-bridge handle teardown is idempotent — the stored handle is niled
  after the first free, preventing a double-free.
- `PhoneCommandRouter` is now `internal` (it is an implementation detail / test
  seam; host apps route phone commands through `PhoneRelay`).
- Renamed `PhoneRelay.isPhoneReachable` → `phoneReachable` (WCSession mechanism
  unchanged).

## [0.0.4] - 2026-05-26

### Changed (breaking)
- `WatchSessionEngine.init(provider:…)` — the `provider` parameter is now
  **required** (previously defaulted to `HealthKitBiosignalProvider(wear:
  SynheartWear())`). Removing the default lets us drop
  `SynheartSessionHealthKit` + the transitive `SynheartWear` SwiftPM
  dependency, which pulled grpc-swift + swift-protobuf + the full
  vendor-provider stack into every consumer binary — bloat that a
  lightweight watchOS SDK has no business carrying.

  **Migration:** consumers that were relying on the HealthKit default
  now construct it themselves and inject it:

  ```swift
  import SynheartSessionHealthKit
  import SynheartWear

  let engine = WatchSessionEngine(
      provider: HealthKitBiosignalProvider(wear: SynheartWear()),
      // … (other args unchanged)
  )
  ```

  BLE / mock / custom providers are unaffected — they were already
  passed explicitly.

### Removed
- SwiftPM dep on `SynheartSessionHealthKit` (and transitively on
  `synheart-wear-swift`). Edge now depends only on `SynheartSession`
  (the BiosignalProvider protocol).

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
  (`WatchSessionEngine`, `SessionConfig`, `SessionPreset`, `ComputeProfile`,
  `SessionEvent`, `MotionSample`, `HsiArtifactEnvelope`, `PhoneRelay`,
  `EdgeSessionManager`, `EdgeOutbox`). The native FFI bridge and command
  router stay `internal` (implementation detail / test seam).
- Add CI binary-size assertion to enforce the 500 KB budget.
