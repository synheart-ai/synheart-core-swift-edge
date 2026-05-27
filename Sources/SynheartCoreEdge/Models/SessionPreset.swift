import Foundation

/// A session preset — either synced from phone or built-in for standalone use.
public struct SessionPreset: Codable, Identifiable {
    public let id: String
    public let label: String
    public let mode: String
    public let durationSec: Int
    public let profile: ComputeProfile
    public let kind: SessionKind

    enum CodingKeys: String, CodingKey {
        case id, label, mode, kind
        case durationSec = "duration_sec"
        case profile
    }

    public init(id: String, label: String, mode: String, durationSec: Int,
                profile: ComputeProfile, kind: SessionKind = .focus) {
        self.id = id
        self.label = label
        self.mode = mode
        self.durationSec = durationSec
        self.profile = profile
        self.kind = kind
    }

    public init(from map: [String: Any]) throws {
        guard let id = map["id"] as? String else {
            throw SessionConfigError.missing("preset id")
        }
        guard let label = map["label"] as? String else {
            throw SessionConfigError.missing("preset label")
        }
        guard let mode = map["mode"] as? String else {
            throw SessionConfigError.missing("preset mode")
        }
        guard let durationSec = map["duration_sec"] as? Int else {
            throw SessionConfigError.missing("preset duration_sec")
        }
        self.id = id
        self.label = label
        self.mode = mode
        self.durationSec = durationSec
        self.kind = SessionKind(rawValue: (map["kind"] as? String ?? "FOCUS").uppercased()) ?? .focus
        if let profileMap = map["profile"] as? [String: Any] {
            self.profile = ComputeProfile(from: profileMap)
        } else {
            self.profile = ComputeProfile()
        }
    }

    /// Create a phone-initiated SessionConfig from this preset.
    public func toSessionConfig() -> SessionConfig {
        SessionConfig(
            sessionId: UUID().uuidString,
            mode: mode,
            durationSec: durationSec,
            profile: profile,
            windowLabel: "\(mode)_session",
            origin: .phone,
            kind: kind
        )
    }

    /// Create a standalone edge SessionConfig (RFC §4.2).
    public func toEdgeSessionConfig(sessionManager: EdgeSessionManager) -> SessionConfig {
        SessionConfig(
            sessionId: sessionManager.generateSessionId(),
            mode: mode,
            durationSec: durationSec,
            profile: profile,
            windowLabel: "\(mode)_edge",
            origin: .edge,
            kind: kind
        )
    }

    /// Built-in presets for standalone edge sessions + phone-synced.
    public static let defaults: [SessionPreset] = [
        SessionPreset(
            id: "default_focus_5", label: "Focus 5 min", mode: "focus",
            durationSec: 300, profile: ComputeProfile(windowSec: 60, emitIntervalSec: 5),
            kind: .focus),
        SessionPreset(
            id: "default_breathing_3", label: "Breathing 3 min", mode: "breathing",
            durationSec: 180, profile: ComputeProfile(windowSec: 30, emitIntervalSec: 3),
            kind: .breathing),
        SessionPreset(
            id: "default_nap_20", label: "Nap 20 min", mode: "nap",
            durationSec: 1200, profile: ComputeProfile(windowSec: 60, emitIntervalSec: 10),
            kind: .nap),
        SessionPreset(
            id: "default_sleep_8h", label: "Sleep 8h", mode: "sleep",
            durationSec: 28800, profile: ComputeProfile(windowSec: 60, emitIntervalSec: 30),
            kind: .sleep),
        SessionPreset(
            id: "default_workout_30", label: "Workout 30 min", mode: "workout",
            durationSec: 1800, profile: ComputeProfile(windowSec: 30, emitIntervalSec: 5),
            kind: .workout),
    ]

    /// Parse an array of presets from a sync_presets command payload.
    public static func parsePresets(from message: [String: Any]) -> [SessionPreset] {
        guard let presetMaps = message["presets"] as? [[String: Any]] else { return [] }
        return presetMaps.compactMap { try? SessionPreset(from: $0) }
    }
}
