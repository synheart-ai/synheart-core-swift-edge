import Foundation

/// RFC §8.1 — Watch session state machine.
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
    case syncing = "SYNCING"
    case error = "ERROR"

    /// Valid state transitions per RFC §8.1.
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
