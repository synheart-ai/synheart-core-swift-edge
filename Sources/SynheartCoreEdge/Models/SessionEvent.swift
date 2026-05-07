import Foundation

/// Events sent from watch to phone (and phone to watch for ACKs/sync).
enum SessionEvent {
    case started(sessionId: String, startedAtMs: Int64)
    case frame(sessionId: String, seq: Int, emittedAtMs: Int64, metrics: [String: Any])
    case artifact(envelope: HsiArtifactEnvelope)
    case summary(sessionId: String, durationActualSec: Int, metrics: [String: Any])
    case error(sessionId: String, code: String, message: String)
    // Sync protocol events (RFC §5)
    case edgeSessionManifest(manifest: [String: Any])
    case artifactBatch(sessionId: String, envelopes: [HsiArtifactEnvelope])
    // ACK from phone
    case sessionAck(sessionId: String, artifactIds: [String])

    /// Serialize to dictionary for WCSession transmission.
    func toMessage() -> [String: Any] {
        switch self {
        case .started(let sessionId, let startedAtMs):
            return [
                "type": "session_started",
                "session_id": sessionId,
                "started_at_ms": startedAtMs
            ]
        case .frame(let sessionId, let seq, let emittedAtMs, let metrics):
            return [
                "type": "session_frame",
                "session_id": sessionId,
                "seq": seq,
                "emitted_at_ms": emittedAtMs,
                "metrics": metrics
            ]
        case .artifact(let envelope):
            return envelope.toMessage()
        case .summary(let sessionId, let durationActualSec, let metrics):
            return [
                "type": "session_summary",
                "session_id": sessionId,
                "duration_actual_sec": durationActualSec,
                "metrics": metrics
            ]
        case .error(let sessionId, let code, let message):
            return [
                "type": "session_error",
                "session_id": sessionId,
                "code": code,
                "message": message
            ]
        case .edgeSessionManifest(let manifest):
            return manifest
        case .artifactBatch(let sessionId, let envelopes):
            return [
                "type": "hsi_artifact_batch",
                "session_id": sessionId,
                "artifacts": envelopes.map { $0.toMessage() }
            ]
        case .sessionAck(let sessionId, let artifactIds):
            return [
                "type": "session_ack",
                "session_id": sessionId,
                "artifact_ids": artifactIds
            ]
        }
    }
}
