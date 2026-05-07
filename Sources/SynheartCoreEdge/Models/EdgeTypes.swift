import Foundation
import CryptoKit

/// RFC §6 — Delivery mode.
enum DeliveryMode: String, Codable {
    case realtime = "REALTIME"
    case passiveSync = "PASSIVE_SYNC"
}

/// RFC §4 — Session origin.
enum SessionOrigin: String, Codable {
    case phone = "PHONE"
    case edge = "EDGE"
}

/// RFC §4.2.1 — Session kinds (presets).
enum SessionKind: String, Codable, CaseIterable {
    case nap = "NAP"
    case sleep = "SLEEP"
    case workout = "WORKOUT"
    case focus = "FOCUS"
    case breathing = "BREATHING"
    case deepWork = "DEEP_WORK"
}

/// RFC §6 — HSI artifact envelope.
struct HsiArtifactEnvelope: Codable {
    let artifactId: String
    let sessionId: String
    let seq: Int
    let createdAtMs: Int64
    let schemaVersion: String
    let payloadHashSha256: String
    let payloadJson: String
    let deliveryMode: DeliveryMode
    let sessionOrigin: SessionOrigin
    let sessionKind: SessionKind?

    enum CodingKeys: String, CodingKey {
        case artifactId = "artifact_id"
        case sessionId = "session_id"
        case seq
        case createdAtMs = "created_at_ms"
        case schemaVersion = "schema_version"
        case payloadHashSha256 = "payload_hash_sha256"
        case payloadJson = "payload_json"
        case deliveryMode = "delivery_mode"
        case sessionOrigin = "session_origin"
        case sessionKind = "session_kind"
    }

    /// Create an envelope wrapping an HSI JSON payload.
    static func wrap(
        sessionId: String,
        seq: Int,
        hsiJson: String,
        deliveryMode: DeliveryMode,
        origin: SessionOrigin,
        kind: SessionKind?
    ) -> HsiArtifactEnvelope {
        let data = Data(hsiJson.utf8)
        let hash = SHA256.hash(data: data)
        let hashHex = hash.compactMap { String(format: "%02x", $0) }.joined()

        return HsiArtifactEnvelope(
            artifactId: "hsi_\(UUID().uuidString.lowercased().prefix(12))_\(seq)",
            sessionId: sessionId,
            seq: seq,
            createdAtMs: Int64(Date().timeIntervalSince1970 * 1000),
            schemaVersion: "1.1",
            payloadHashSha256: hashHex,
            payloadJson: hsiJson,
            deliveryMode: deliveryMode,
            sessionOrigin: origin,
            sessionKind: kind
        )
    }

    /// Serialize to dictionary for WCSession transmission.
    func toMessage() -> [String: Any] {
        var msg: [String: Any] = [
            "type": "hsi_artifact",
            "artifact_id": artifactId,
            "session_id": sessionId,
            "seq": seq,
            "created_at_ms": createdAtMs,
            "schema_version": schemaVersion,
            "payload_hash_sha256": payloadHashSha256,
            "payload_json": payloadJson,
            "delivery_mode": deliveryMode.rawValue,
            "session_origin": sessionOrigin.rawValue,
        ]
        if let kind = sessionKind {
            msg["session_kind"] = kind.rawValue
        }
        return msg
    }
}
