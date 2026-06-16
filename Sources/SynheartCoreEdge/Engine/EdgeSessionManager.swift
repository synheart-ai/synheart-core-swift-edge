// SPDX-License-Identifier: Apache-2.0
// Copyright (c) Synheart authors

import Foundation

/// Manages standalone edge sessions.
/// Creates edge session IDs, tracks manifests, manages local session storage.
public final class EdgeSessionManager {
    private let sessionsDir: URL
    private let deviceId: String

    /// Default `UserDefaults` key for the persisted per-device opaque id.
    public static let defaultDeviceKey = "synheart_device_opaque"

    /// - Parameters:
    ///   - defaults: backing store for the persisted per-device opaque id.
    ///     Defaults to `.standard`. Pass an app-specific suite
    ///     (`UserDefaults(suiteName:)`) so two SDK-based apps on one device do
    ///     not collide on the shared key namespace.
    ///   - deviceKey: key the opaque id is stored under. Defaults to
    ///     ``defaultDeviceKey`` (`"synheart_device_opaque"`); override (or
    ///     prefix) it for additional namespacing within a shared suite.
    public init(defaults: UserDefaults = .standard,
                deviceKey: String = EdgeSessionManager.defaultDeviceKey) {
        // Manifests live under Application Support (not user-visible
        // Documents) with complete-unless-open file protection (encrypted at
        // rest while the device is locked). The on-disk JSON shape is unchanged.
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.sessionsDir = base.appendingPathComponent("edge_sessions", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: sessionsDir,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUnlessOpen]
        )

        // Stable device identifier (persisted)
        if let existing = defaults.string(forKey: deviceKey) {
            self.deviceId = existing
        } else {
            let id = UUID().uuidString.lowercased().prefix(8)
            defaults.set(String(id), forKey: deviceKey)
            self.deviceId = String(id)
        }
    }

    /// Stable, per-device opaque id used as the runtime `subject_id` for edge
    /// personalization. Reuses the same persisted device-opaque value that seeds
    /// `generateSessionId`, so runtime personalization is keyed to this physical
    /// device. Of the form `"sub_<deviceOpaque>"`.
    public var subjectId: String { "sub_\(deviceId)" }

    /// Generate an edge session ID.
    /// Format: edge_w_<deviceOpaque>_<timestamp>_<random>
    public func generateSessionId() -> String {
        let ts = Int64(Date().timeIntervalSince1970)
        let rand = UUID().uuidString.lowercased().prefix(6)
        return "edge_w_\(deviceId)_\(ts)_\(rand)"
    }

    /// Session manifest persisted per standalone edge session.
    public struct SessionManifest: Codable {
        public let sessionId: String
        public let kind: SessionKind
        public let startMs: Int64
        public var endMs: Int64?
        public let schemaVersion: String
        public var artifactCount: Int
        public var syncStatus: String  // "pending", "syncing", "synced"

        enum CodingKeys: String, CodingKey {
            case sessionId = "session_id"
            case kind
            case startMs = "start_ms"
            case endMs = "end_ms"
            case schemaVersion = "schema_version"
            case artifactCount = "artifact_count"
            case syncStatus = "sync_status"
        }
    }

    /// Create a new edge session manifest.
    public func createSession(sessionId: String, kind: SessionKind) -> SessionManifest {
        let manifest = SessionManifest(
            sessionId: sessionId,
            kind: kind,
            startMs: Int64(Date().timeIntervalSince1970 * 1000),
            endMs: nil,
            schemaVersion: "1.1",
            artifactCount: 0,
            syncStatus: "pending"
        )
        saveManifest(manifest)
        return manifest
    }

    /// Update a session manifest (e.g. increment artifact count, set end time).
    public func updateManifest(_ manifest: SessionManifest) {
        saveManifest(manifest)
    }

    /// Load all session manifests with pending sync status.
    public func pendingSessions() -> [SessionManifest] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil) else {
            return []
        }
        return dirs.compactMap { dir -> SessionManifest? in
            let manifestFile = dir.appendingPathComponent("manifest.json")
            guard let data = try? Data(contentsOf: manifestFile) else { return nil }
            return try? JSONDecoder().decode(SessionManifest.self, from: data)
        }.filter { $0.syncStatus == "pending" }
    }

    /// Mark a session as synced.
    public func markSynced(sessionId: String) {
        guard var manifest = loadManifest(sessionId: sessionId) else { return }
        manifest.syncStatus = "synced"
        saveManifest(manifest)
    }

    /// Build a sync manifest message (first step of the edge-session sync flow).
    public func buildSyncManifest(for manifest: SessionManifest) -> [String: Any] {
        var msg: [String: Any] = [
            "type": "edge_session_manifest",
            "session_id": manifest.sessionId,
            "kind": manifest.kind.rawValue,
            "start_ms": manifest.startMs,
            "schema_version": manifest.schemaVersion,
            "artifact_count": manifest.artifactCount,
            "ingest_mode": "BACKFILL",
            "session_origin": "EDGE",
            "origin_device": "WATCH",
        ]
        if let endMs = manifest.endMs {
            msg["end_ms"] = endMs
        }
        return msg
    }

    // MARK: - Private

    private func saveManifest(_ manifest: SessionManifest) {
        let sessionDir = sessionsDir.appendingPathComponent(manifest.sessionId, isDirectory: true)
        try? FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let file = sessionDir.appendingPathComponent("manifest.json")
        if let data = try? JSONEncoder().encode(manifest) {
            // Atomic + encrypted-at-rest write.
            try? data.write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
        }
    }

    private func loadManifest(sessionId: String) -> SessionManifest? {
        let file = sessionsDir
            .appendingPathComponent(sessionId, isDirectory: true)
            .appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(SessionManifest.self, from: data)
    }
}
