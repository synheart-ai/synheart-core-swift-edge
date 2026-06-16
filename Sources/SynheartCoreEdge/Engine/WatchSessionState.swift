// SPDX-License-Identifier: Apache-2.0
// Copyright (c) Synheart authors

import Foundation

/// Watch session state machine.
///
/// `paused` is a host-driven transient state for breath / interrupt / call /
/// any other UX moment the user wants to suspend the session without ending
/// it. Engine loops self-exit on the next tick when state != running; resume
/// restarts the loops and adjusts `startedAtMs` so elapsed-time accounting
/// skips the paused interval.
public enum WatchSessionState: String, CaseIterable {
    case idle = "IDLE"
    case starting = "STARTING"
    case running = "RUNNING"
    case paused = "PAUSED"
    case stopping = "STOPPING"
    /// Reserved for the edge-session sync flow. The transition graph permits
    /// entering it (e.g. when a future host drives an explicit sync phase), but
    /// the current engine does not transition into it on its own. Retained as a
    /// declared, transitionable state for cross-platform parity.
    case syncing = "SYNCING"
    case error = "ERROR"

    /// Valid state transitions.
    public func canTransition(to next: WatchSessionState) -> Bool {
        switch (self, next) {
        case (.idle, .starting),
             (.starting, .running),
             (.starting, .error),
             (.running, .paused),
             (.paused, .running),
             (.paused, .stopping),
             (.running, .stopping),
             (.running, .syncing),
             (.running, .error),
             (.stopping, .idle),
             (.stopping, .syncing),
             (.syncing, .idle),
             (.error, .idle):
            return true
        default:
            return false
        }
    }
}
