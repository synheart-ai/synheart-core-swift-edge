// SPDX-License-Identifier: Apache-2.0
// Copyright (c) Synheart authors

import Foundation
import Combine
import SynheartSession

/// Compute mode for an edge session.
public enum EngineMode {
    /// Watch is a dumb sensor: raw samples are surfaced via callbacks for the
    /// host app to relay to the paired phone. The on-device runtime is not used.
    case stream
    /// `synheart-core-runtime` runs locally; raw samples are pushed to FFI and
    /// HSI artifacts emitted by the runtime are persisted + relayed.
    case computeLocal
}

/// On-watch session engine with a formal state machine.
///
/// Motion (accel) is captured locally since HealthKit doesn't stream raw IMU.
/// The runtime owns signal math when `mode == .computeLocal`.
public final class WatchSessionEngine: ObservableObject {

    /// HSI payload versions this SDK understands. When the runtime emits a tick
    /// whose `hsi_version` is outside this set we log it so an engine bump is
    /// observable. NO wire change — the artifact envelope `schema_version`
    /// is untouched; this is purely a diagnostic on the parsed tick payload.
    public static let SUPPORTED_HSI_VERSIONS: [String] = ["1.1", "1.2", "1.3"]

    // MARK: - Published state

    @Published public private(set) var state: WatchSessionState = .idle
    @Published public private(set) var currentHr: Double = 0
    @Published public private(set) var elapsedSec: Int = 0
    @Published public private(set) var lastMetrics: [String: Any]?
    @Published public private(set) var sessionKind: SessionKind = .focus
    @Published public private(set) var mode: EngineMode = .stream
    /// Number of pending (un-ACKed) artifacts in the outbox. Published so a
    /// SwiftUI badge (e.g. HomeView) updates when artifacts are enqueued or
    /// acknowledged. Mirrors Kotlin's `UiState.pendingArtifacts`. Refreshed via
    /// `refreshPendingCount()` after every enqueue (emitFrame/finishSession) and
    /// every ACK (`acknowledgeArtifacts`).
    @Published public private(set) var pendingArtifactCount: Int = 0

    /// Whether raw `BiosignalSample`s are surfaced on `onBiosignalSample` for the
    /// host to relay to the phone for this session (`edge_mode` provenance; see
    /// docs/EDGE-WIRE-CONTRACT.md).
    ///
    /// Decoupled from `mode` so SHADOW can BOTH compute locally (`.computeLocal`)
    /// and stream raw samples. Resolved from `config.profile.edgeMode`:
    ///  - `.off`       → true  (pure stream; runtime never started)
    ///  - `.shadow`    → true  (compute-local AND stream raw)
    ///  - `.canonical` → false (edge HSI is product-of-record; raw not streamed)
    /// When a runtime is unavailable, both SHADOW and CANONICAL degrade to
    /// `.stream` and this is forced true so the phone still receives samples.
    public private(set) var streamRawSamples: Bool = true

    // MARK: - Event stream

    public var onEvent: ((SessionEvent) -> Void)?
    public var onHrSample: ((Double, Int64) -> Void)?
    /// Stream mode only: fires for every biosignal sample so the host app can
    /// relay raw data to the paired phone.
    public var onBiosignalSample: ((BiosignalSample) -> Void)?

    // MARK: - Dependencies (internal access for app wiring)

    public let outbox: EdgeOutbox
    /// Always present: when the caller passes `nil` the engine default-constructs
    /// one so a real per-device `subjectId` is always available (the runtime
    /// `subject_id` is never seeded from a shared placeholder).
    public private(set) var sessionManager: EdgeSessionManager

    // MARK: - Internal

    /// Factory that resolves the per-session edge runtime for a given config.
    /// Production uses the native `RuntimeBridge` loader (the default); tests
    /// swap in a fake so the per-`edge_mode` resolution + frame/summary metric
    /// contract is exercised without the native library. Returns nil when no
    /// runtime is available → `.stream`. `internal` so it never widens the
    /// public API.
    var runtimeFactory: (RuntimeBridge.Config) -> RuntimeHandle? = { cfg in
        RuntimeBridge.createIfAvailable(config: cfg)
    }

    private var config: SessionConfig?
    private var edgeManifest: EdgeSessionManager.SessionManifest?
    private var runtimeBridge: RuntimeHandle?
    private var startedAtMs: Int64 = 0
    private var seq = 0
    private var frameTimer: Timer?
    private var durationTimer: Timer?
    private var elapsedTimer: Timer?
    private var bioProvider: BiosignalProvider?
    private let provider: BiosignalProvider
    private let motionSensor: MotionSensor
    private var motionTask: Task<Void, Never>?
    /// Timestamp when the session entered `.paused`. Used by `resumeSession`
    /// to advance `startedAtMs` so the paused interval doesn't count
    /// against elapsed/remaining.
    private var pausedAtMs: Int64 = 0

    /// - Parameters:
    ///   - provider: source of HR / RR samples (BLE HRM, HealthKit, mock, etc.)
    ///     conforming to `BiosignalProvider`.
    ///   - sessionManager: optional; when `nil` the engine default-constructs an
    ///     `EdgeSessionManager` so a real per-device `subjectId` always exists.
    public init(provider: BiosignalProvider,
                motionSensor: MotionSensor = MotionSensor(),
                outbox: EdgeOutbox = EdgeOutbox(),
                sessionManager: EdgeSessionManager? = nil) {
        self.provider = provider
        self.motionSensor = motionSensor
        self.outbox = outbox
        self.sessionManager = sessionManager ?? EdgeSessionManager()
    }

    // MARK: - Lifecycle

    /// Start a session. If `mode` is nil the engine resolves it: try to load
    /// `synheart-core-runtime` — if available, run `.computeLocal`; otherwise
    /// fall back to `.stream` (raw samples surfaced via `onBiosignalSample`).
    public func startSession(config: SessionConfig, mode requestedMode: EngineMode? = nil) {
        guard state.canTransition(to: .starting) else { return }
        transition(to: .starting)

        self.config = config
        self.seq = 0
        self.startedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        onMain { self.sessionKind = config.kind }

        // ── Mode resolution (edge_mode provenance; see EDGE-WIRE-CONTRACT.md) ──
        // An explicit requestedMode still wins (host override / tests). Absent
        // that, derive behaviour from config.profile.edgeMode:
        //   .off       → .stream, runtime is NOT started at all (skip the native
        //                factory); watch streams raw samples only.
        //   .canonical → .computeLocal if a runtime is available, else .stream;
        //                raw samples are NOT emitted (edge HSI is product-of-
        //                record).
        //   .shadow    → .computeLocal if available AND raw samples ALSO emitted
        //                (compute locally and stream raw). If no runtime is
        //                available it degrades to .stream.
        // subject_id is the EdgeSessionManager per-device opaque id, so runtime
        // personalization is always keyed to this physical device.
        let edgeMode = config.profile.edgeMode
        let subjectId = sessionManager.subjectId

        let runtime: RuntimeHandle?
        if requestedMode == .stream || edgeMode == .off {
            runtime = nil  // never start the native runtime
        } else {
            runtime = runtimeFactory(.init(
                windowMs: Int64(config.profile.windowSec * 1000),
                stepMs: Int64(config.profile.emitIntervalSec * 1000),
                subjectId: subjectId,
                sessionId: config.sessionId,
                behaviorEnabled: false,
                edgeMode: edgeMode
            ))
        }

        let resolved: EngineMode = requestedMode ?? (runtime != nil ? .computeLocal : .stream)
        onMain { self.mode = resolved }
        self.runtimeBridge = (resolved == .computeLocal) ? runtime : nil
        // Drop any runtime we resolved but won't use (requestedMode == .stream).
        if self.runtimeBridge == nil, let unused = runtime {
            unused.destroy()
        }

        // Raw-sample streaming is independent of compute mode: .canonical
        // suppresses it, .off/.shadow/.stream keep it. When .computeLocal didn't
        // resolve (no runtime), SHADOW/CANONICAL degrade to .stream, so raw must
        // flow regardless to keep the phone fed.
        if resolved == .stream {
            self.streamRawSamples = true
        } else if edgeMode == .canonical {
            self.streamRawSamples = false
        } else {
            self.streamRawSamples = true  // SHADOW (+ OFF, though OFF never reaches .computeLocal)
        }

        // For standalone edge sessions, create a manifest
        if config.origin == .edge {
            self.edgeManifest = sessionManager.createSession(sessionId: config.sessionId, kind: config.kind)
        }

        // Emit started
        let event = SessionEvent.started(sessionId: config.sessionId, startedAtMs: startedAtMs)
        onEvent?(event)

        transition(to: .running)

        // Start sensors
        startBiosignalProvider()
        startMotion()

        // Periodic frame emission
        let interval = TimeInterval(config.profile.emitIntervalSec)
        frameTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.emitFrame()
        }

        // Duration timer
        durationTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(config.durationSec),
                                              repeats: false) { [weak self] _ in
            self?.stopSession()
        }

        // Elapsed counter (1 Hz)
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let elapsed = Int((Int64(Date().timeIntervalSince1970 * 1000) - self.startedAtMs) / 1000)
            self.onMain { self.elapsedSec = elapsed }
        }
    }

    public func stopSession() {
        guard state.canTransition(to: .stopping) else { return }
        transition(to: .stopping)
        finishSession()
    }

    /// Host-driven pause. Snapshots `pausedAtMs` so a subsequent `resumeSession`
    /// can shift `startedAtMs` forward by the paused interval — elapsed and
    /// remaining time accounting skip the pause.
    public func pauseSession() {
        guard state.canTransition(to: .paused) else { return }
        transition(to: .paused)
        pausedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        // Stop periodic timers; they'll be re-armed on resume.
        frameTimer?.invalidate(); frameTimer = nil
        elapsedTimer?.invalidate(); elapsedTimer = nil
        durationTimer?.invalidate(); durationTimer = nil
    }

    /// Resume a paused session. Re-arms the frame / elapsed / duration timers
    /// and advances `startedAtMs` by the paused interval.
    public func resumeSession() {
        guard state.canTransition(to: .running) else { return }
        guard let cfg = config else { return }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let pausedFor = now - pausedAtMs
        startedAtMs += pausedFor
        transition(to: .running)

        let interval = TimeInterval(cfg.profile.emitIntervalSec)
        frameTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.emitFrame()
        }
        let remaining = max(0, cfg.durationSec - Int((now - startedAtMs) / 1000))
        if remaining > 0 {
            durationTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(remaining),
                                                  repeats: false) { [weak self] _ in
                self?.stopSession()
            }
        }
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let elapsed = Int((Int64(Date().timeIntervalSince1970 * 1000) - self.startedAtMs) / 1000)
            self.onMain { self.elapsedSec = elapsed }
        }
    }

    /// Start a standalone edge session from a preset.
    public func startEdgeSession(preset: SessionPreset, mode requestedMode: EngineMode? = nil) {
        let config = preset.toEdgeSessionConfig(sessionManager: sessionManager)
        startSession(config: config, mode: requestedMode)
    }

    // MARK: - Outbox access

    /// Re-read the outbox pending count and publish it on the main thread so
    /// SwiftUI observers update. `outbox.pendingCount` is serial-queue-synced,
    /// so a call right after an `enqueue`/`ack` reflects the completed mutation.
    private func refreshPendingCount() {
        let count = outbox.pendingCount
        onMain { self.pendingArtifactCount = count }
    }

    /// Number of native FFI calls the runtime reported as errored/dropped under
    /// contention this/the-last session (diagnostic only; parity with Kotlin's
    /// `droppedFrames`). Reads the live bridge while a session runs, otherwise
    /// the snapshot captured at the last `finishSession`. Always 0 in stream
    /// mode (no runtime).
    public var droppedFrames: Int {
        if let bridge = runtimeBridge { return Int(bridge.droppedFrames) }
        return _droppedFramesSnapshot
    }
    private var _droppedFramesSnapshot: Int = 0

    public func getPendingArtifacts() -> [HsiArtifactEnvelope] { outbox.pending() }

    public func acknowledgeArtifacts(ids: [String]) {
        outbox.ackBatch(artifactIds: ids)
        refreshPendingCount()
    }

    // MARK: - Private

    /// Run `block` on the main thread synchronously when already on main, else
    /// hop asynchronously. All `@Published` mutations funnel through this so the
    /// frame/duration/elapsed timer run loops and the provider/motion callback
    /// threads never publish off-main (SwiftUI hazard). FFI stays confined to
    /// `RuntimeBridge`'s own serial queue (unaffected by this hop).
    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread {
            block()
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

    private func transition(to next: WatchSessionState) {
        guard state.canTransition(to: next) else {
            NSLog("[Engine] Invalid transition \(state.rawValue) -> \(next.rawValue)")
            return
        }
        onMain { self.state = next }
    }

    private func startBiosignalProvider() {
        bioProvider = provider
        do {
            try provider.startStreaming { [weak self] sample in
                guard let self = self else { return }

                // Feed the local runtime in .computeLocal (CANONICAL + SHADOW).
                // FFI is confined to RuntimeBridge's own serial queue, so calling
                // from this provider thread is safe.
                if let bridge = self.runtimeBridge {
                    bridge.pushHr(tsMs: sample.timestampMs, bpm: sample.bpm)
                    if let rrs = sample.rrIntervalsMs {
                        for rr in rrs {
                            bridge.pushRr(tsMs: sample.timestampMs, rrMs: rr)
                        }
                    }
                }

                // Emit raw samples for relay independently of compute:
                // STREAM + SHADOW + OFF stream raw; CANONICAL suppresses. SHADOW
                // therefore BOTH computes locally above AND streams raw here.
                if self.streamRawSamples {
                    self.onBiosignalSample?(sample)
                }

                self.onHrSample?(sample.bpm, sample.timestampMs)
                self.onMain { self.currentHr = sample.bpm }
            }
        } catch {
            handleError(code: "sensor_unavailable", message: "\(error)")
        }
    }

    private func startMotion() {
        // Motion is only piped to runtime in computeLocal mode (runtimeBridge
        // non-nil). In stream mode, the host app can capture motion separately
        // if it needs it; we don't emit accel samples through the channel.
        guard runtimeBridge != nil, motionSensor.isAvailable else { return }
        motionTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                for try await sample in self.motionSensor.startStreaming() {
                    self.runtimeBridge?.pushAccel(
                        tsMs: sample.timestampMs, x: sample.x, y: sample.y, z: sample.z
                    )
                }
            } catch { }
        }
    }

    private func emitFrame() {
        guard let config = config, state == .running else { return }

        seq += 1
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let elapsed = Int((nowMs - startedAtMs) / 1000)

        if elapsed >= config.durationSec {
            stopSession()
            return
        }

        // Tick the runtime pipeline and read preprocessed + quality in ONE
        // critical section (see RuntimeBridge.tickAndReadout) so a concurrent
        // motion push can't tear preprocessed/quality away from this frame's
        // HSI. Returns HSI JSON when a window completes (computeLocal only).
        let readout = runtimeBridge?.tickAndReadout(nowMs: nowMs)
        let hsiJson = readout?.hsiJson

        var metrics: [String: Any] = [
            "session_id": config.sessionId,
            "mode": config.mode,
            "seq": seq,
        ]
        if let hsiJson = hsiJson,
           let data = hsiJson.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            Self.checkHsiVersion(parsed)
            metrics["hsi"] = parsed
        }

        // Surface the raw preprocessed + quality artifacts alongside the HSI so
        // consumers can read real HR/HRV/motion numbers (HSI 1.3 carries only
        // inferred scores + embeddings, never raw features). Stable contract:
        // keys `preprocessed` / `quality`, raw nested JSON. computeLocal only —
        // stream mode has no runtime so these stay absent. Already fetched in
        // the single critical section above; just parse + attach here.
        Self.merge(preprocessedJson: readout?.preprocessed,
                   qualityJson: readout?.quality,
                   into: &metrics)

        let frameMetrics = metrics
        onMain { self.lastMetrics = frameMetrics }

        // Wrap as HSI artifact envelope only when the runtime produced output.
        var envelope: HsiArtifactEnvelope?
        if let hsiJson = hsiJson {
            envelope = HsiArtifactEnvelope.wrap(
                sessionId: config.sessionId,
                seq: seq,
                hsiJson: hsiJson,
                deliveryMode: config.deliveryMode,
                origin: config.origin,
                kind: config.kind
            )

            outbox.enqueue(envelope!)
            refreshPendingCount()

            if config.origin == .edge, var manifest = edgeManifest {
                manifest.artifactCount += 1
                edgeManifest = manifest
                sessionManager.updateManifest(manifest)
            }
        }

        let frameEvent = SessionEvent.frame(
            sessionId: config.sessionId,
            seq: seq,
            emittedAtMs: nowMs,
            metrics: metrics
        )
        onEvent?(frameEvent)

        if let envelope = envelope {
            onEvent?(SessionEvent.artifact(envelope: envelope))
        }
    }

    private func finishSession() {
        guard let config = config else {
            transition(to: .idle)
            return
        }

        cancelTimers()
        bioProvider?.stopStreaming()
        bioProvider = nil
        motionTask?.cancel()
        motionSensor.stopStreaming()

        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let durationActual = Int((nowMs - startedAtMs) / 1000)

        var metrics: [String: Any] = [
            "session_id": config.sessionId,
            "mode": config.mode,
            "seq": seq,
        ]
        // Final tick + raw-feature read in ONE critical section: the
        // last window must be captured before teardown and read consistently.
        let readout = runtimeBridge?.tickAndReadout(nowMs: nowMs)
        let finalHsiJson = readout?.hsiJson
        if let hsiJson = finalHsiJson,
           let data = hsiJson.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            Self.checkHsiVersion(parsed)
            metrics["hsi"] = parsed
        }

        Self.merge(preprocessedJson: readout?.preprocessed,
                   qualityJson: readout?.quality,
                   into: &metrics)

        let summaryMetrics = metrics
        onMain { self.lastMetrics = summaryMetrics }

        // Final-window artifact durability. When the final tick produced
        // HSI, persist + relay it exactly like emitFrame does (bump seq, wrap,
        // enqueue, emit `.artifact`) so the last window is durable + ACK-tracked
        // rather than living only in the Summary metrics. computeLocal only
        // (CANONICAL + SHADOW) — stream mode has no runtime so finalHsiJson is
        // nil and this is skipped.
        var finalEnvelope: HsiArtifactEnvelope?
        if let hsiJson = finalHsiJson {
            seq += 1
            let envelope = HsiArtifactEnvelope.wrap(
                sessionId: config.sessionId,
                seq: seq,
                hsiJson: hsiJson,
                deliveryMode: config.deliveryMode,
                origin: config.origin,
                kind: config.kind
            )
            outbox.enqueue(envelope)
            refreshPendingCount()
            if config.origin == .edge, var manifest = edgeManifest {
                manifest.artifactCount += 1
                edgeManifest = manifest
                sessionManager.updateManifest(manifest)
            }
            finalEnvelope = envelope
        }

        if config.origin == .edge, var manifest = edgeManifest {
            manifest.endMs = nowMs
            edgeManifest = manifest
            sessionManager.updateManifest(manifest)
        }

        // Relay the final artifact BEFORE the summary so a phone consumer sees
        // the last window's durable envelope alongside the others (parity with
        // emitFrame's frame→artifact ordering).
        if let finalEnvelope = finalEnvelope {
            onEvent?(SessionEvent.artifact(envelope: finalEnvelope))
        }

        let event = SessionEvent.summary(
            sessionId: config.sessionId,
            durationActualSec: durationActual,
            metrics: metrics
        )
        onEvent?(event)

        self.config = nil
        // Snapshot the dropped-frame count before tearing the bridge down so
        // `droppedFrames` still reports it after the session ends.
        if let bridge = self.runtimeBridge {
            self._droppedFramesSnapshot = Int(bridge.droppedFrames)
        }
        // Explicitly destroy the native handle (idempotent) rather than relying
        // on deinit — the bridge nils its own handle so this can't double-free.
        self.runtimeBridge?.destroy()
        self.runtimeBridge = nil
        self.edgeManifest = nil

        transition(to: .idle)
    }

    /// Parse the preprocessed / quality JSON strings and merge the resulting
    /// objects into `metrics`. Factored out (static, pure) so tests can prove
    /// the contract against a known JSON payload without a live runtime.
    static func merge(preprocessedJson: String?,
                      qualityJson: String?,
                      into metrics: inout [String: Any]) {
        if let json = preprocessedJson,
           let data = json.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            metrics["preprocessed"] = parsed
        }
        if let json = qualityJson,
           let data = json.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            metrics["quality"] = parsed
        }
    }

    /// Inspect a parsed tick HSI payload's `hsi_version` and log if it falls
    /// outside `SUPPORTED_HSI_VERSIONS`. Pure + static so it's trivially
    /// testable and side-effect-free beyond logging. No wire shape is changed.
    static func checkHsiVersion(_ parsed: [String: Any]) {
        guard let version = parsed["hsi_version"] as? String else { return }
        if !SUPPORTED_HSI_VERSIONS.contains(version) {
            NSLog("[Engine] Unsupported HSI version \(version) (supported: \(SUPPORTED_HSI_VERSIONS.joined(separator: ", "))) — engine may have been bumped")
        }
    }

    private func handleError(code: String, message: String) {
        guard let config = config else { return }
        let event = SessionEvent.error(sessionId: config.sessionId, code: code, message: message)
        onEvent?(event)
        if state.canTransition(to: .error) {
            transition(to: .error)
        }
        cancelTimers()
        bioProvider?.stopStreaming()
        bioProvider = nil
        motionTask?.cancel()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.transition(to: .idle)
        }
    }

    private func cancelTimers() {
        frameTimer?.invalidate()
        frameTimer = nil
        durationTimer?.invalidate()
        durationTimer = nil
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        motionTask?.cancel()
        motionTask = nil
    }

    /// Remaining seconds in the session.
    public var remainingSec: Int {
        guard let config = config, state == .running else { return 0 }
        return max(0, config.durationSec - elapsedSec)
    }

}
