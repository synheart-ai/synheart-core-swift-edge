import Foundation

#if canImport(WatchConnectivity)
import WatchConnectivity

/// Watch-side WCSession relay with outbox integration and sync protocol (RFC §5).
public final class PhoneRelay: NSObject, WCSessionDelegate, ObservableObject {

    @Published public private(set) var isPhoneReachable = false
    @Published public private(set) var presets: [SessionPreset] = []

    private var onCommand: (([String: Any]) -> Void)?
    private var outbox: EdgeOutbox?
    private var sessionManager: EdgeSessionManager?

    private static let presetsKey = "synheart_cached_presets"

    public override init() {
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

    /// Send a real-time HR sample to the phone.
    public func sendHrSample(_ message: [String: Any]) {
        guard WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(message, replyHandler: nil) { error in
            NSLog("[PhoneRelay] HR sample send failed: \(error.localizedDescription)")
        }
    }

    /// Send an artifact envelope — prefer transferUserInfo for durability (RFC §11).
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

    /// Retry all pending artifacts from outbox (RFC §7.1).
    public func retryPendingArtifacts() {
        guard let outbox = outbox else { return }
        let pending = outbox.pending()
        for envelope in pending {
            sendArtifact(envelope)
        }
    }

    /// Sync all pending edge sessions (RFC §5.1).
    public func syncEdgeSessions() {
        guard let mgr = sessionManager, let outbox = outbox else { return }

        let pendingSessions = mgr.pendingSessions()
        for manifest in pendingSessions {
            // Step 1: Send manifest
            let manifestMsg = mgr.buildSyncManifest(for: manifest)
            sendEvent(.edgeSessionManifest(manifest: manifestMsg))

            // Artifacts for this session will be sent on SYNC_ALLOWED response
        }
    }

    /// Handle ACK from phone — delete acknowledged artifacts from outbox.
    public func handleAck(message: [String: Any]) {
        guard let artifactIds = message["artifact_ids"] as? [String] else { return }
        outbox?.ackBatch(artifactIds: artifactIds)

        // If session is fully synced, mark it
        if let sessionId = message["session_id"] as? String,
           let status = message["sync_status"] as? String, status == "complete" {
            sessionManager?.markSynced(sessionId: sessionId)
        }
    }

    /// Handle sync response from phone (RFC §5.1 Step 2).
    public func handleSyncResponse(message: [String: Any]) {
        guard let sessionId = message["session_id"] as? String,
              let response = message["response"] as? String else { return }

        if response == "SYNC_ALLOWED" {
            // Send artifact batch (Step 3)
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
        guard let data = UserDefaults.standard.data(forKey: Self.presetsKey),
              let cached = try? JSONDecoder().decode([SessionPreset].self, from: data),
              !cached.isEmpty else {
            presets = SessionPreset.defaults
            return
        }
        presets = cached
    }

    private func cachePresets(_ presets: [SessionPreset]) {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: Self.presetsKey)
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
            self?.isPhoneReachable = session.isReachable
        }
        if let error = error {
            NSLog("[PhoneRelay] activation error: \(error.localizedDescription)")
        }
    }

    public func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        DispatchQueue.main.async { [weak self] in
            self?.isPhoneReachable = reachable
        }
        // When phone becomes reachable, retry pending + sync edge sessions
        if reachable {
            retryPendingArtifacts()
            syncEdgeSessions()
        }
    }

    public func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        if let command = message["command"] as? String {
            switch command {
            case "sync_presets":
                handlePresetsUpdate(from: message)
            case "artifact_ack":
                handleAck(message: message)
            case "sync_response":
                handleSyncResponse(message: message)
            default:
                break
            }
        }
        DispatchQueue.main.async { [weak self] in
            self?.onCommand?(message)
        }
    }

    public func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        if let command = applicationContext["command"] as? String, command == "sync_presets" {
            handlePresetsUpdate(from: applicationContext)
        }
    }
}

#endif // canImport(WatchConnectivity)
