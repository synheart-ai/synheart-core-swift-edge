// SPDX-License-Identifier: Apache-2.0
// Copyright (c) Synheart authors

import Foundation
import SynheartSession

#if canImport(WatchConnectivity)
import WatchConnectivity

/// Watch-side WCSession relay with outbox integration and an edge-session sync
/// flow. Wire message shapes follow EDGE-WIRE-CONTRACT.md in the synheart-edge repo.
public final class PhoneRelay: NSObject, WCSessionDelegate, ObservableObject {

    /// Default `UserDefaults` key the cached presets are stored under.
    public static let defaultPresetsKey = "synheart_cached_presets"

    /// Live reachability flag: true when the paired phone's companion app is
    /// reachable RIGHT NOW (WCSession `isReachable`). NOTE: WCSession
    /// `isReachable` means "the counterpart app is reachable now" (foreground +
    /// connected).
    @Published public private(set) var phoneReachable = false
    @Published public private(set) var presets: [SessionPreset] = []

    private var onCommand: (([String: Any]) -> Void)?
    /// Phone-initiated session start. The host binds this to the engine's
    /// `startSession(config:)`.
    private var onStartSession: ((SessionConfig) -> Void)?
    /// Phone-initiated session stop. Host binds to `engine.stopSession()`.
    private var onStopSession: (() -> Void)?
    /// Phone ACK bridge. When bound (by the host wiring `engine
    /// .acknowledgeArtifacts`), `handleAck` routes acknowledged ids through the
    /// engine so the engine's published pending count refreshes (badge update)
    /// — not just the bare outbox. Falls back to a direct outbox ack when unbound.
    private var onArtifactAck: (([String]) -> Void)?
    private var outbox: EdgeOutbox?
    private var sessionManager: EdgeSessionManager?

    private let defaults: UserDefaults
    private let presetsKey: String

    /// - Parameters:
    ///   - defaults: backing store for cached presets. Defaults to `.standard`.
    ///     Pass an app-specific suite (`UserDefaults(suiteName:)`) so two
    ///     SDK-based apps on one device do not collide on the shared key.
    ///   - presetsKey: key the cached presets are stored under. Defaults to
    ///     ``defaultPresetsKey`` (`"synheart_cached_presets"`).
    public init(defaults: UserDefaults = .standard,
                presetsKey: String = PhoneRelay.defaultPresetsKey) {
        self.defaults = defaults
        self.presetsKey = presetsKey
        super.init()
        loadCachedPresets()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    public func configure(outbox: EdgeOutbox, sessionManager: EdgeSessionManager) {
        self.outbox = outbox
        self.sessionManager = sessionManager
    }

    public func onCommandReceived(_ handler: @escaping ([String: Any]) -> Void) {
        self.onCommand = handler
    }

    /// Bind phone→watch session commands to the engine. `start` receives a
    /// `SessionConfig` parsed from the `start_session` command body; `stop`
    /// fires on `stop_session`.
    public func onSessionCommand(start: @escaping (SessionConfig) -> Void,
                                 stop: @escaping () -> Void) {
        self.onStartSession = start
        self.onStopSession = stop
    }

    /// Bind phone artifact ACKs to the engine. The host wires this to
    /// `engine.acknowledgeArtifacts(ids:)` so an ACK both removes the artifacts
    /// from the outbox AND refreshes the engine's published pending count
    /// (HomeView badge). Android does the equivalent; mirror it. When unbound,
    /// `handleAck` falls back to a direct `outbox.ackBatch`.
    public func onArtifactAcknowledged(_ handler: @escaping ([String]) -> Void) {
        self.onArtifactAck = handler
    }

    /// Send a session event to the phone.
    public func sendEvent(_ event: SessionEvent) {
        guard WCSession.default.isReachable else {
            NSLog("[PhoneRelay] Phone not reachable, event queued in outbox")
            return
        }
        WCSession.default.sendMessage(event.toMessage(), replyHandler: nil) { error in
            NSLog("[PhoneRelay] sendMessage failed: \(error.localizedDescription)")
        }
    }

    /// Send a real-time HR sample to the phone. Builds the canonical wire body
    /// `{ "type":"hr_sample", "bpm":<Double>, "timestamp_ms":<Int64>,
    /// "source":<String?> }`. Owning the shape here keeps the call site from
    /// drifting (e.g. bare `timestamp`). See the Synheart Edge wire contract (EDGE-WIRE-CONTRACT.md in the synheart-edge repo).
    public func sendHrSample(bpm: Double, timestampMs: Int64, source: String? = nil) {
        guard WCSession.default.isReachable else { return }
        var message: [String: Any] = [
            "type": "hr_sample",
            "bpm": bpm,
            "timestamp_ms": timestampMs
        ]
        if let source = source {
            message["source"] = source
        }
        WCSession.default.sendMessage(message, replyHandler: nil) { error in
            NSLog("[PhoneRelay] HR sample send failed: \(error.localizedDescription)")
        }
    }

    /// Send a full biosignal sample (HR + RR intervals + source) to the phone.
    ///
    /// Stream mode relies on this: the watch is a dumb sensor and the phone
    /// computes HRV ("no math in client"), so the raw RR timeline must reach
    /// the phone — scalar HR alone (`sendHrSample`) is not enough to derive
    /// SDNN/RMSSD downstream.
    public func sendBiosignalSample(_ sample: BiosignalSample) {
        guard WCSession.default.isReachable else { return }
        // Wire body: type "bio_sample", epoch-ms key `timestamp_ms`.
        var message: [String: Any] = [
            "type": "bio_sample",
            "bpm": sample.bpm,
            "timestamp_ms": sample.timestampMs,
            "source": sample.source
        ]
        // Omitted/empty when unavailable — never fabricated.
        if let rr = sample.rrIntervalsMs, !rr.isEmpty {
            message["rr_intervals_ms"] = rr
        }
        // `accel` is included only when the sample carries motion. The
        // `BiosignalSample` channel (HR/RR source) carries no IMU on Apple
        // platforms — HealthKit doesn't stream raw accel — so it is omitted
        // here rather than fabricated. Motion is piped to the runtime separately
        // in computeLocal mode (see WatchSessionEngine.startMotion).
        WCSession.default.sendMessage(message, replyHandler: nil) { error in
            NSLog("[PhoneRelay] bio sample send failed: \(error.localizedDescription)")
        }
    }

    /// Send an artifact envelope — prefer transferUserInfo for durability.
    public func sendArtifact(_ envelope: HsiArtifactEnvelope) {
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(envelope.toMessage(), replyHandler: nil) { error in
                NSLog("[PhoneRelay] artifact send failed: \(error.localizedDescription)")
            }
        } else {
            // Use transferUserInfo for guaranteed delivery
            WCSession.default.transferUserInfo(envelope.toMessage())
        }
    }

    /// Retry all pending artifacts from outbox.
    public func retryPendingArtifacts() {
        guard let outbox = outbox else { return }
        let pending = outbox.pending()
        for envelope in pending {
            sendArtifact(envelope)
        }
    }

    /// Sync all pending edge sessions.
    public func syncEdgeSessions() {
        guard let mgr = sessionManager, let outbox = outbox else { return }

        let pendingSessions = mgr.pendingSessions()
        for manifest in pendingSessions {
            // Step 1: Send manifest
            let manifestMsg = mgr.buildSyncManifest(for: manifest)
            sendEvent(.edgeSessionManifest(manifest: manifestMsg))

            // Artifacts for this session are sent on the SYNC_ALLOWED response.
        }
    }

    /// Handle ACK from phone — delete acknowledged artifacts from outbox.
    public func handleAck(message: [String: Any]) {
        guard let artifactIds = message["artifact_ids"] as? [String] else { return }
        // Bridge ACK to the engine when wired (removes from outbox AND refreshes
        // the engine's published pending count); otherwise ack the outbox
        // directly so the artifacts are still cleared.
        if let onArtifactAck = onArtifactAck {
            onArtifactAck(artifactIds)
        } else {
            outbox?.ackBatch(artifactIds: artifactIds)
        }

        // If session is fully synced, mark it
        if let sessionId = message["session_id"] as? String,
           let status = message["sync_status"] as? String, status == "complete" {
            sessionManager?.markSynced(sessionId: sessionId)
        }
    }

    /// Handle a sync response from the phone.
    public func handleSyncResponse(message: [String: Any]) {
        guard let sessionId = message["session_id"] as? String,
              let response = message["response"] as? String else { return }

        if response == "SYNC_ALLOWED" {
            // Send the artifact batch.
            guard let outbox = outbox else { return }
            let artifacts = outbox.pending().filter { $0.sessionId == sessionId }
            if !artifacts.isEmpty {
                sendEvent(.artifactBatch(sessionId: sessionId, envelopes: artifacts))
            }
        }
        // SYNC_REJECTED — artifacts remain in outbox for future retry
    }

    // MARK: - Preset Caching

    private func loadCachedPresets() {
        guard let data = defaults.data(forKey: presetsKey),
              let cached = try? JSONDecoder().decode([SessionPreset].self, from: data),
              !cached.isEmpty else {
            presets = SessionPreset.defaults
            return
        }
        presets = cached
    }

    private func cachePresets(_ presets: [SessionPreset]) {
        if let data = try? JSONEncoder().encode(presets) {
            defaults.set(data, forKey: presetsKey)
        }
    }

    private func handlePresetsUpdate(from message: [String: Any]) {
        let parsed = SessionPreset.parsePresets(from: message)
        guard !parsed.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            self?.presets = parsed
        }
        cachePresets(parsed)
    }

    // MARK: - WCSessionDelegate

    public func session(_ session: WCSession,
                        activationDidCompleteWith activationState: WCSessionActivationState,
                        error: Error?) {
        DispatchQueue.main.async { [weak self] in
            self?.phoneReachable = session.isReachable
        }
        if let error = error {
            NSLog("[PhoneRelay] activation error: \(error.localizedDescription)")
        }
    }

    public func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        DispatchQueue.main.async { [weak self] in
            self?.phoneReachable = reachable
        }
        // When phone becomes reachable, retry pending + sync edge sessions
        if reachable {
            retryPendingArtifacts()
            syncEdgeSessions()
        }
    }

    public func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handleCommand(message)
        DispatchQueue.main.async { [weak self] in
            self?.onCommand?(message)
        }
    }

    /// Route a phone→watch command body (keyed by `command`).
    /// Factored out of the delegate method so it's unit-testable without a live
    /// `WCSession`. Handles `start_session`/`stop_session` (dispatched to the
    /// engine via the bound callbacks) alongside the existing
    /// `sync_presets`/`artifact_ack`/`sync_response` handling.
    func handleCommand(_ message: [String: Any]) {
        PhoneCommandRouter.route(
            message,
            onStart: { [weak self] config in self?.onStartSession?(config) },
            onStop: { [weak self] in self?.onStopSession?() },
            onSyncPresets: { [weak self] msg in self?.handlePresetsUpdate(from: msg) },
            onArtifactAck: { [weak self] msg in self?.handleAck(message: msg) },
            onSyncResponse: { [weak self] msg in self?.handleSyncResponse(message: msg) }
        )
    }

    public func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        if let command = applicationContext["command"] as? String, command == "sync_presets" {
            handlePresetsUpdate(from: applicationContext)
        }
    }
}

#endif // canImport(WatchConnectivity)
