// SPDX-License-Identifier: Apache-2.0
// Copyright (c) Synheart authors

import Foundation

/// How the watch's edge HSI should be reported relative to a paired phone.
/// The `rawValue` IS the wire string (lowercase) the native runtime config
/// reads. See the Synheart Edge wire contract (EDGE-WIRE-CONTRACT.md in the synheart-edge repo).
public enum EdgeMode: String {
    /// Edge runtime does not start. Watch streams raw samples to phone.
    case off
    /// Edge runtime computes HSI; raw samples also stream to phone. Phone HSI
    /// is canonical; edge envelopes carry `session_role: shadow`.
    case shadow
    /// Edge HSI is product-of-record. Raw samples are not streamed.
    case canonical
}

public struct ComputeProfile: Codable {
    public let windowSec: Int
    public let emitIntervalSec: Int
    /// How the edge runtime's HSI should be reported relative to a paired
    /// phone. Forwarded to the native runtime as `compute_profile.edge_mode`
    /// in the FFI config JSON, where it controls the `session_role` stamped on
    /// `meta.synheart.compute`. Default `.canonical` (watch HSI is
    /// product-of-record).
    public let edgeMode: EdgeMode

    enum CodingKeys: String, CodingKey {
        case windowSec = "window_sec"
        case emitIntervalSec = "emit_interval_sec"
        case edgeMode = "edge_mode"
    }

    public init(windowSec: Int = 60, emitIntervalSec: Int = 5, edgeMode: EdgeMode = .canonical) {
        self.windowSec = windowSec
        self.emitIntervalSec = emitIntervalSec
        self.edgeMode = edgeMode
    }

    public init(from map: [String: Any]) {
        self.windowSec = map["window_sec"] as? Int ?? 60
        self.emitIntervalSec = map["emit_interval_sec"] as? Int ?? 5
        self.edgeMode = (map["edge_mode"] as? String).flatMap(EdgeMode.init(rawValue:)) ?? .canonical
    }

    // MARK: - Codable

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.windowSec = try c.decodeIfPresent(Int.self, forKey: .windowSec) ?? 60
        self.emitIntervalSec = try c.decodeIfPresent(Int.self, forKey: .emitIntervalSec) ?? 5
        let wire = try c.decodeIfPresent(String.self, forKey: .edgeMode)
        self.edgeMode = wire.flatMap(EdgeMode.init(rawValue:)) ?? .canonical
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(windowSec, forKey: .windowSec)
        try c.encode(emitIntervalSec, forKey: .emitIntervalSec)
        try c.encode(edgeMode.rawValue, forKey: .edgeMode)
    }
}

public struct SessionConfig {
    public let sessionId: String
    public let mode: String
    public let durationSec: Int
    public let profile: ComputeProfile
    public let windowLabel: String?
    public let origin: SessionOrigin
    public let kind: SessionKind

    public init(sessionId: String, mode: String, durationSec: Int,
                profile: ComputeProfile = ComputeProfile(), windowLabel: String? = nil,
                origin: SessionOrigin = .phone, kind: SessionKind = .focus) {
        self.sessionId = sessionId
        self.mode = mode
        self.durationSec = durationSec
        self.profile = profile
        self.windowLabel = windowLabel
        self.origin = origin
        self.kind = kind
    }

    /// Initialize from a phone-initiated command body.
    public init(fromPhoneCommand map: [String: Any]) throws {
        guard let sessionId = map["session_id"] as? String else {
            throw SessionConfigError.missing("session_id")
        }
        guard let mode = map["mode"] as? String else {
            throw SessionConfigError.missing("mode")
        }
        // Accept a numeric duration whether the phone sent an Int (`300`) or a
        // Double (`300.0`); a JSON-bridged number can arrive as either, and
        // `as? Int` silently rejects `300.0`. NSNumber covers both bridged
        // representations.
        guard let durationNum = map["duration_sec"] as? NSNumber else {
            throw SessionConfigError.missing("duration_sec")
        }
        let durationSec = durationNum.intValue
        self.sessionId = sessionId
        self.mode = mode
        self.durationSec = durationSec
        self.origin = .phone
        self.kind = SessionKind(rawValue: (map["kind"] as? String ?? "FOCUS").uppercased()) ?? .focus
        if let profileMap = map["profile"] as? [String: Any] {
            self.profile = ComputeProfile(from: profileMap)
        } else {
            self.profile = ComputeProfile()
        }
        self.windowLabel = map["window_label"] as? String
    }

    /// Delivery mode derived from origin.
    public var deliveryMode: DeliveryMode {
        origin == .phone ? .realtime : .passiveSync
    }
}

public enum SessionConfigError: Error {
    case missing(String)
}
