import Foundation

/// RFC §8.1 — Watch session state machine.
enum WatchSessionState: String, CaseIterable {
    case idle = "IDLE"
    case starting = "STARTING"
    case running = "RUNNING"
    case stopping = "STOPPING"
    case syncing = "SYNCING"
    case error = "ERROR"

    /// Valid state transitions per RFC §8.1.
    func canTransition(to next: WatchSessionState) -> Bool {
        switch (self, next) {
        case (.idle, .starting),
             (.starting, .running),
             (.starting, .error),
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
