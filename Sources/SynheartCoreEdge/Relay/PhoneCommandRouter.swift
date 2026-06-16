// SPDX-License-Identifier: Apache-2.0
// Copyright (c) Synheart authors

import Foundation

/// Platform-independent dispatcher for phone→watch command bodies.
/// Lives outside the `WatchConnectivity`-gated `PhoneRelay` so command routing
/// works on any platform (`PhoneRelay` is unavailable where
/// `WatchConnectivity` is). `internal` — not part of the public API; host apps
/// route commands through ``PhoneRelay``.
///
/// Bodies are keyed by `command`. `start_session` parses a ``SessionConfig``
/// from the body and invokes `onStart`; `stop_session` invokes `onStop`. The
/// caller (``PhoneRelay``) supplies handlers for the sync/ack/preset commands
/// since those need its WCSession-bound state. Command verbs are part of the
/// canonical wire protocol (see docs/EDGE-WIRE-CONTRACT.md).
enum PhoneCommandRouter {

    /// The set of recognised command verbs.
    enum Command: String {
        case startSession = "start_session"
        case stopSession = "stop_session"
        case syncPresets = "sync_presets"
        case artifactAck = "artifact_ack"
        case syncResponse = "sync_response"
    }

    /// Route a command body. Returns the matched ``Command`` (or `nil` when the
    /// body carries no recognised `command`) so callers/tests can assert on it.
    ///
    /// - `onStart` is called with a parsed ``SessionConfig`` only when the
    ///   `start_session` body is well-formed; a malformed body is ignored
    ///   (no fabricated session) and logged.
    @discardableResult
    static func route(
        _ message: [String: Any],
        onStart: (SessionConfig) -> Void,
        onStop: () -> Void,
        onSyncPresets: ([String: Any]) -> Void,
        onArtifactAck: ([String: Any]) -> Void,
        onSyncResponse: ([String: Any]) -> Void
    ) -> Command? {
        guard let raw = message["command"] as? String,
              let command = Command(rawValue: raw) else { return nil }
        switch command {
        case .startSession:
            if let config = try? SessionConfig(fromPhoneCommand: message) {
                onStart(config)
            } else {
                NSLog("[PhoneCommandRouter] start_session ignored: malformed config body")
            }
        case .stopSession:
            onStop()
        case .syncPresets:
            onSyncPresets(message)
        case .artifactAck:
            onArtifactAck(message)
        case .syncResponse:
            onSyncResponse(message)
        }
        return command
    }
}
