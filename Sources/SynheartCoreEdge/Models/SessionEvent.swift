// SPDX-License-Identifier: Apache-2.0
// Copyright (c) Synheart authors

import Foundation

/// Events sent from watch to phone (and phone to watch for ACKs/sync).
/// Message `type` values and JSON keys are part of the canonical wire protocol
/// (see EDGE-WIRE-CONTRACT.md in the synheart-edge repo).
/// How a session was started. A host that did not send the start command
/// itself (a session started on the watch, or by another process on the phone)
/// has no other way to learn these, so without them it can neither tell a
/// watch-started session from a phone-started one nor tell completed from
/// abandoned. Optional on the wire: omitted keys leave older readers unaffected.
public struct SessionStartFacts {
    public let origin: SessionOrigin
    public let kind: SessionKind
    public let durationTargetSec: Int

    public init(origin: SessionOrigin, kind: SessionKind, durationTargetSec: Int) {
        self.origin = origin
        self.kind = kind
        self.durationTargetSec = durationTargetSec
    }

    func merged(into message: [String: Any]) -> [String: Any] {
        var m = message
        m["origin"] = origin.rawValue
        m["kind"] = kind.rawValue
        m["duration_target_sec"] = durationTargetSec
        return m
    }
}

public enum SessionEvent {
    case started(sessionId: String, startedAtMs: Int64, start: SessionStartFacts? = nil)
    case frame(sessionId: String, seq: Int, emittedAtMs: Int64, metrics: [String: Any])
    case artifact(envelope: HsiArtifactEnvelope)
    case summary(
        sessionId: String,
        durationActualSec: Int,
        metrics: [String: Any],
        start: SessionStartFacts? = nil
    )
    case error(sessionId: String, code: String, message: String)
    // Sync protocol events
    case edgeSessionManifest(manifest: [String: Any])
    case artifactBatch(sessionId: String, envelopes: [HsiArtifactEnvelope])
    // ACK from phone
    case sessionAck(sessionId: String, artifactIds: [String])

    /// Serialize to dictionary for WCSession transmission.
    public func toMessage() -> [String: Any] {
        switch self {
        case .started(let sessionId, let startedAtMs, let start):
            let message: [String: Any] = [
                "type": "session_started",
                "session_id": sessionId,
                "started_at_ms": startedAtMs
            ]
            return start?.merged(into: message) ?? message
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
        case .summary(let sessionId, let durationActualSec, let metrics, let start):
            let message: [String: Any] = [
                "type": "session_summary",
                "session_id": sessionId,
                "duration_actual_sec": durationActualSec,
                "metrics": metrics
            ]
            return start?.merged(into: message) ?? message
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
