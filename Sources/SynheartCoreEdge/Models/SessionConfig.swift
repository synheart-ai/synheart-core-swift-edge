import Foundation

struct ComputeProfile: Codable {
    let windowSec: Int
    let emitIntervalSec: Int

    enum CodingKeys: String, CodingKey {
        case windowSec = "window_sec"
        case emitIntervalSec = "emit_interval_sec"
    }

    init(windowSec: Int = 60, emitIntervalSec: Int = 5) {
        self.windowSec = windowSec
        self.emitIntervalSec = emitIntervalSec
    }

    init(from map: [String: Any]) {
        self.windowSec = map["window_sec"] as? Int ?? 60
        self.emitIntervalSec = map["emit_interval_sec"] as? Int ?? 5
    }
}

struct SessionConfig {
    let sessionId: String
    let mode: String
    let durationSec: Int
    let profile: ComputeProfile
    let windowLabel: String?
    let origin: SessionOrigin
    let kind: SessionKind

    init(sessionId: String, mode: String, durationSec: Int,
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
    init(fromPhoneCommand map: [String: Any]) throws {
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
    var deliveryMode: DeliveryMode {
        origin == .phone ? .realtime : .passiveSync
    }
}

enum SessionConfigError: Error {
    case missing(String)
}
