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

/// On-watch session engine with formal state machine (RFC §8.1).
///
/// Motion (accel) is captured locally since HealthKit doesn't stream raw IMU.
/// The runtime owns signal math when `mode == .computeLocal`.
public final class WatchSessionEngine: ObservableObject {

    // MARK: - Published state

    @Published public private(set) var state: WatchSessionState = .idle
    @Published public private(set) var currentHr: Double = 0
    @Published public private(set) var elapsedSec: Int = 0
    @Published public private(set) var lastMetrics: [String: Any]?
    @Published public private(set) var sessionKind: SessionKind = .focus
    @Published public private(set) var mode: EngineMode = .stream

    // MARK: - Event stream

    public var onEvent: ((SessionEvent) -> Void)?
    public var onHrSample: ((Double, Int64) -> Void)?
    /// Stream mode only: fires for every biosignal sample so the host app can
    /// relay raw data to the paired phone.
    public var onBiosignalSample: ((BiosignalSample) -> Void)?

    // MARK: - Dependencies (internal access for app wiring)

    public let outbox: EdgeOutbox
    public private(set) var sessionManager: EdgeSessionManager?

    // MARK: - Internal

    private var config: SessionConfig?
    private var edgeManifest: EdgeSessionManager.SessionManifest?
    private var runtimeBridge: RuntimeBridge?
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

    /// - Parameter provider: source of HR / RR samples (BLE HRM, HealthKit,
    ///   mock, etc.) conforming to `BiosignalProvider`.
    public init(provider: BiosignalProvider,
                motionSensor: MotionSensor = MotionSensor(),
                outbox: EdgeOutbox = EdgeOutbox(),
                sessionManager: EdgeSessionManager? = nil) {
        self.provider = provider
        self.motionSensor = motionSensor
        self.outbox = outbox
        self.sessionManager = sessionManager
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
        self.sessionKind = config.kind

        // Resolve mode: try runtime first.
        let runtime = RuntimeBridge.createIfAvailable(config: .init(
            windowMs: Int64(config.profile.windowSec * 1000),
            stepMs: Int64(config.profile.emitIntervalSec * 1000),
            subjectId: "sub_watch",
            sessionId: config.sessionId,
            behaviorEnabled: false
        ))
        let resolved = requestedMode ?? (runtime != nil ? .computeLocal : .stream)
        self.mode = resolved
        self.runtimeBridge = (resolved == .computeLocal) ? runtime : nil

        // For standalone edge sessions, create a manifest
        if config.origin == .edge, let mgr = sessionManager {
            self.edgeManifest = mgr.createSession(sessionId: config.sessionId, kind: config.kind)
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
            self.elapsedSec = Int((Int64(Date().timeIntervalSince1970 * 1000) - self.startedAtMs) / 1000)
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
            self.elapsedSec = Int((Int64(Date().timeIntervalSince1970 * 1000) - self.startedAtMs) / 1000)
        }
    }

    /// Start a standalone edge session from a preset (RFC §4.2).
    public func startEdgeSession(preset: SessionPreset, mode requestedMode: EngineMode? = nil) {
        guard let mgr = sessionManager else {
            startSession(config: preset.toSessionConfig(), mode: requestedMode)
            return
        }
        let config = preset.toEdgeSessionConfig(sessionManager: mgr)
        startSession(config: config, mode: requestedMode)
    }

    // MARK: - Outbox access

    public var pendingArtifactCount: Int { outbox.pendingCount }

    public func getPendingArtifacts() -> [HsiArtifactEnvelope] { outbox.pending() }

    public func acknowledgeArtifacts(ids: [String]) {
        outbox.ackBatch(artifactIds: ids)
    }

    // MARK: - Private

    private func transition(to next: WatchSessionState) {
        guard state.canTransition(to: next) else {
            NSLog("[Engine] Invalid transition \(state.rawValue) -> \(next.rawValue)")
            return
        }
        state = next
    }

    private func startBiosignalProvider() {
        bioProvider = provider
        do {
            try provider.startStreaming { [weak self] sample in
                guard let self = self else { return }

                if self.mode == .computeLocal, let bridge = self.runtimeBridge {
                    bridge.pushHr(tsMs: sample.timestampMs, bpm: sample.bpm)
                    if let rrs = sample.rrIntervalsMs {
                        for rr in rrs {
                            bridge.pushRr(tsMs: sample.timestampMs, rrMs: rr)
                        }
                    }
                }

                if self.mode == .stream {
                    self.onBiosignalSample?(sample)
                }

                self.onHrSample?(sample.bpm, sample.timestampMs)
                DispatchQueue.main.async {
                    self.currentHr = sample.bpm
                }
            }
        } catch {
            handleError(code: "sensor_unavailable", message: "\(error)")
        }
    }

    private func startMotion() {
        // Motion is only piped to runtime in computeLocal mode. In stream mode,
        // the host app can capture motion separately if it needs it; we don't
        // emit accel samples through the BiosignalProvider channel.
        guard mode == .computeLocal, motionSensor.isAvailable else { return }
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

        // Tick the runtime pipeline — returns HSI JSON when a window completes
        // (only meaningful in computeLocal mode).
        let hsiJson = runtimeBridge?.tick(nowMs: nowMs)

        var metrics: [String: Any] = [
            "session_id": config.sessionId,
            "mode": config.mode,
            "seq": seq,
        ]
        if let hsiJson = hsiJson,
           let data = hsiJson.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            metrics["hsi"] = parsed
        }

        lastMetrics = metrics

        // Wrap as HSI artifact envelope only when runtime produced output (RFC §6)
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

            if config.origin == .edge, var manifest = edgeManifest {
                manifest.artifactCount += 1
                edgeManifest = manifest
                sessionManager?.updateManifest(manifest)
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
        if let hsiJson = runtimeBridge?.tick(nowMs: nowMs),
           let data = hsiJson.data(using: .utf8),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            metrics["hsi"] = parsed
        }

        lastMetrics = metrics

        if config.origin == .edge, var manifest = edgeManifest {
            manifest.endMs = nowMs
            edgeManifest = manifest
            sessionManager?.updateManifest(manifest)
        }

        let event = SessionEvent.summary(
            sessionId: config.sessionId,
            durationActualSec: durationActual,
            metrics: metrics
        )
        onEvent?(event)

        self.config = nil
        self.runtimeBridge = nil
        self.edgeManifest = nil

        transition(to: .idle)
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
