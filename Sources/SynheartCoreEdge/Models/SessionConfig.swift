import Foundation

public struct ComputeProfile: Codable {
    public let windowSec: Int
    public let emitIntervalSec: Int
    /// How the edge runtime's HSI should be reported relative to a paired
    /// phone (edge-tiering RFC §3.2). Forwarded to the native runtime as
    /// `compute_profile.edge_mode` in the FFI config JSON, where it
    /// controls the `session_role` stamped on `meta.synheart.compute`.
    /// Default ``EdgeMode/canonical`` preserves pre-RFC behaviour (watch
    /// HSI is product-of-record).
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
        if let wire = map["edge_mode"] as? String, let parsed = EdgeMode(wire: wire) {
            self.edgeMode = parsed
        } else {
            self.edgeMode = .canonical
        }
    }
}

/// How the watch's edge HSI should be reported relative to a paired phone.
/// Mirror of `EdgeMode` in `synheart-core-runtime`'s `SynheartConfig`. See
/// edge-tiering RFC §3.2.
public enum EdgeMode: String, Codable {
    /// Edge runtime does not start. Watch streams raw samples to phone.
    case off
    /// Edge runtime computes HSI; raw samples also stream to phone. Phone
    /// HSI is canonical; edge envelopes carry `session_role: shadow`.
    case shadow
    /// Edge HSI is product-of-record. Raw samples are not streamed.
    case canonical

    /// Wire form for the native runtime JSON (snake_case lowercased name).
    public var wireValue: String { rawValue }

    /// Parse the wire form used in JSON config + the §3.3 pairing advert.
    public init?(wire: String) {
        self.init(rawValue: wire.lowercased())
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

    /// Initialize from a phone command (Mode A — phone-initiated).
    public init(fromPhoneCommand map: [String: Any]) throws {
        guard let sessionId = map["session_id"] as? String else {
            throw SessionConfigError.missing("session_id")
        }
        guard let mode = map["mode"] as? String else {
            throw SessionConfigError.missing("mode")
        }
        guard let durationSec = map["duration_sec"] as? Int else {
            throw SessionConfigError.missing("duration_sec")
        }
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

    /// Delivery mode derived from origin (RFC §6).
    public var deliveryMode: DeliveryMode {
        origin == .phone ? .realtime : .passiveSync
    }
}

public enum SessionConfigError: Error {
    case missing(String)
}
