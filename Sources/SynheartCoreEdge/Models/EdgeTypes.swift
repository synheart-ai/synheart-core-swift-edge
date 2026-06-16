// SPDX-License-Identifier: Apache-2.0
// Copyright (c) Synheart authors

import Foundation
import CryptoKit

// NOTE: The string raw values and JSON keys in this file are the canonical
// watch↔phone wire protocol (see docs/EDGE-WIRE-CONTRACT.md). The phone-side
// EdgeIngest receiver and both reference watch apps depend on these exact
// values. Do NOT change them. A white-label fork that renames the protocol
// namespace must change it consistently across all producers and consumers.

/// Delivery mode.
public enum DeliveryMode: String, Codable {
    case realtime = "REALTIME"
    case passiveSync = "PASSIVE_SYNC"
}

/// Session origin.
public enum SessionOrigin: String, Codable {
    case phone = "PHONE"
    case edge = "EDGE"
}

/// Session kinds (presets).
public enum SessionKind: String, Codable, CaseIterable {
    case nap = "NAP"
    case sleep = "SLEEP"
    case workout = "WORKOUT"
    case focus = "FOCUS"
    case breathing = "BREATHING"
    case deepWork = "DEEP_WORK"
}

/// HSI artifact envelope (see docs/EDGE-WIRE-CONTRACT.md).
public struct HsiArtifactEnvelope: Codable {
    public let artifactId: String
    public let sessionId: String
    public let seq: Int
    public let createdAtMs: Int64
    /// Envelope (wrapper) schema version. Distinct from `hsiVersion` — this
    /// describes the envelope shape; `hsiVersion` describes the wrapped payload.
    public let schemaVersion: String
    /// Inner HSI payload version, extracted from `payload_json`'s top-level
    /// `hsi_version` so consumers can validate without parsing the opaque
    /// payload. Defaults to `"unknown"` when the payload can't be parsed.
    /// Additive — existing consumers ignore it.
    public let hsiVersion: String
    public let payloadHashSha256: String
    public let payloadJson: String
    public let deliveryMode: DeliveryMode
    public let sessionOrigin: SessionOrigin
    public let sessionKind: SessionKind?

    enum CodingKeys: String, CodingKey {
        case artifactId = "artifact_id"
        case sessionId = "session_id"
        case seq
        case createdAtMs = "created_at_ms"
        case schemaVersion = "schema_version"
        case hsiVersion = "hsi_version"
        case payloadHashSha256 = "payload_hash_sha256"
        case payloadJson = "payload_json"
        case deliveryMode = "delivery_mode"
        case sessionOrigin = "session_origin"
        case sessionKind = "session_kind"
    }

    /// Tolerant decode: `hsi_version` is additive, so older payloads that
    /// predate it decode with `"unknown"` rather than failing.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.artifactId = try c.decode(String.self, forKey: .artifactId)
        self.sessionId = try c.decode(String.self, forKey: .sessionId)
        self.seq = try c.decode(Int.self, forKey: .seq)
        self.createdAtMs = try c.decode(Int64.self, forKey: .createdAtMs)
        self.schemaVersion = try c.decode(String.self, forKey: .schemaVersion)
        self.payloadHashSha256 = try c.decode(String.self, forKey: .payloadHashSha256)
        let payload = try c.decode(String.self, forKey: .payloadJson)
        self.payloadJson = payload
        // `hsi_version` is additive. When a top-level field is present use it;
        // otherwise (older outbox files written before the field existed)
        // re-extract the real version from `payload_json` so the envelope still
        // resolves its true version rather than defaulting to "unknown" (parity
        // with Kotlin `HsiArtifactEnvelope.fromJson`).
        if let v = try c.decodeIfPresent(String.self, forKey: .hsiVersion), !v.isEmpty {
            self.hsiVersion = v
        } else {
            self.hsiVersion = Self.extractHsiVersion(from: payload)
        }
        self.deliveryMode = try c.decode(DeliveryMode.self, forKey: .deliveryMode)
        self.sessionOrigin = try c.decode(SessionOrigin.self, forKey: .sessionOrigin)
        self.sessionKind = try c.decodeIfPresent(SessionKind.self, forKey: .sessionKind)
    }

    public init(
        artifactId: String,
        sessionId: String,
        seq: Int,
        createdAtMs: Int64,
        schemaVersion: String,
        hsiVersion: String,
        payloadHashSha256: String,
        payloadJson: String,
        deliveryMode: DeliveryMode,
        sessionOrigin: SessionOrigin,
        sessionKind: SessionKind?
    ) {
        self.artifactId = artifactId
        self.sessionId = sessionId
        self.seq = seq
        self.createdAtMs = createdAtMs
        self.schemaVersion = schemaVersion
        self.hsiVersion = hsiVersion
        self.payloadHashSha256 = payloadHashSha256
        self.payloadJson = payloadJson
        self.deliveryMode = deliveryMode
        self.sessionOrigin = sessionOrigin
        self.sessionKind = sessionKind
    }

    /// Parse the top-level `hsi_version` out of an opaque HSI JSON payload.
    /// Returns `"unknown"` when the payload isn't an object or lacks the key.
    static func extractHsiVersion(from hsiJson: String) -> String {
        guard let data = hsiJson.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = obj["hsi_version"] as? String else {
            return "unknown"
        }
        return version
    }

    /// Create an envelope wrapping an HSI JSON payload.
    public static func wrap(
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
            hsiVersion: extractHsiVersion(from: hsiJson),
            payloadHashSha256: hashHex,
            payloadJson: hsiJson,
            deliveryMode: deliveryMode,
            sessionOrigin: origin,
            sessionKind: kind
        )
    }

    /// Serialize to dictionary for WCSession transmission.
    public func toMessage() -> [String: Any] {
        var msg: [String: Any] = [
            "type": "hsi_artifact",
            "artifact_id": artifactId,
            "session_id": sessionId,
            "seq": seq,
            "created_at_ms": createdAtMs,
            "schema_version": schemaVersion,
            "hsi_version": hsiVersion,
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
