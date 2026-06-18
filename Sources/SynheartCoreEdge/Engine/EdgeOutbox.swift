// SPDX-License-Identifier: Apache-2.0
// Copyright (c) Synheart authors

import Foundation

/// Durable artifact outbox.
/// File-based persistence. Survives restart. Deletes on ACK.
/// See the Synheart Edge wire contract (EDGE-WIRE-CONTRACT.md in the synheart-edge repo) for the ACK + dedupe behaviour.
///
/// ## Storage & protection
/// Files live under Application Support (not user-visible Documents) and are
/// written with `.completeFileProtectionUnlessOpen` so an un-ACKed artifact is
/// encrypted at rest while the device is locked. The on-the-wire / on-disk JSON
/// shape is unchanged.
///
/// ## Concurrency
/// All filesystem access — reads AND writes — is funneled through one serial
/// `queue`, so `pending()` / `pendingCount` can never observe a partially
/// applied mutation made by `enqueue` / `ack` / `clear`.
///
/// ## Path safety
/// `artifact_id` originates from the wire. Any id that is not strictly
/// `^[A-Za-z0-9_-]+$` is rejected before it is ever joined into a path, so a
/// crafted id (e.g. `../../foo`) can't escape the outbox directory.
public final class EdgeOutbox {
    private let directory: URL
    private let queue = DispatchQueue(label: "ai.synheart.edge.outbox")

    /// Max age (seconds) an un-ACKed artifact is retained before the retention
    /// sweep deletes it. Defaults to 14 days. A long-disconnected phone can
    /// still drain the recent backlog; ancient artifacts are reaped so the
    /// outbox can't grow without bound.
    private let retentionInterval: TimeInterval

    /// Write protection level applied to every artifact file: encrypted at rest
    /// while the device is locked, but readable if already open.
    private static let fileProtection: FileProtectionType = .completeUnlessOpen

    public init(retentionInterval: TimeInterval = 14 * 24 * 60 * 60) {
        self.retentionInterval = retentionInterval
        // Application Support, not Documents (not user-visible / not synced
        // to iCloud Docs). Create the dir with complete-unless-open protection.
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        self.directory = base.appendingPathComponent("edge_outbox", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: Self.fileProtection]
        )
        // Reap stale un-ACKed artifacts on init.
        queue.async { [weak self] in self?.sweepExpiredLocked() }
    }

    /// True iff `artifactId` is safe to use as a path component: a non-empty
    /// run of `[A-Za-z0-9_-]`. Rejects `.`/`..`/slashes/etc so a wire-supplied
    /// id can never traverse out of the outbox directory.
    static func isSafeArtifactId(_ artifactId: String) -> Bool {
        guard !artifactId.isEmpty else { return false }
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        return artifactId.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Persist an artifact envelope to disk.
    public func enqueue(_ envelope: HsiArtifactEnvelope) {
        queue.async { [weak self] in
            guard let self = self else { return }
            // Reject any id that isn't a safe path component.
            guard Self.isSafeArtifactId(envelope.artifactId) else {
                NSLog("[EdgeOutbox] rejecting unsafe artifact_id; not enqueued")
                return
            }
            let file = self.directory.appendingPathComponent("\(envelope.artifactId).json")
            if let data = try? JSONEncoder().encode(envelope) {
                // Atomic + encrypted-at-rest write.
                try? data.write(to: file, options: [.atomic, .completeFileProtectionUnlessOpen])
            }
        }
    }

    /// Acknowledge receipt — delete from outbox.
    public func ack(artifactId: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            // Skip any id that isn't a safe path component.
            guard Self.isSafeArtifactId(artifactId) else {
                NSLog("[EdgeOutbox] skipping ack of unsafe artifact_id")
                return
            }
            let file = self.directory.appendingPathComponent("\(artifactId).json")
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Acknowledge multiple artifacts.
    public func ackBatch(artifactIds: [String]) {
        for id in artifactIds {
            ack(artifactId: id)
        }
    }

    /// Load all pending (un-ACKed) envelopes. Routed through the serial queue
    /// so it never observes a half-applied mutation.
    public func pending() -> [HsiArtifactEnvelope] {
        queue.sync {
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
                return []
            }
            return files
                .filter { $0.pathExtension == "json" }
                .compactMap { url -> HsiArtifactEnvelope? in
                    guard let data = try? Data(contentsOf: url) else { return nil }
                    return try? JSONDecoder().decode(HsiArtifactEnvelope.self, from: data)
                }
                .sorted { $0.seq < $1.seq }
        }
    }

    /// Number of pending artifacts. Routed through the serial queue.
    public var pendingCount: Int {
        queue.sync {
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
                return 0
            }
            return files.filter { $0.pathExtension == "json" }.count
        }
    }

    /// Clear all artifacts (e.g. on full sync completion).
    public func clear() {
        queue.async { [weak self] in
            guard let self = self else { return }
            let fm = FileManager.default
            if let files = try? fm.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: nil) {
                for file in files {
                    try? fm.removeItem(at: file)
                }
            }
        }
    }

    /// Delete artifacts older than `retentionInterval`. Caller must be on
    /// `queue`. Uses the file's content-modification date as the age proxy.
    private func sweepExpiredLocked() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-retentionInterval)
        for file in files where file.pathExtension == "json" {
            let values = try? file.resourceValues(forKeys: [.contentModificationDateKey])
            if let modified = values?.contentModificationDate, modified < cutoff {
                try? fm.removeItem(at: file)
            }
        }
    }

    /// Run the retention sweep on demand (e.g. before a sync). Async on the
    /// serial queue so it never blocks the caller or races a mutation.
    public func sweepExpired() {
        queue.async { [weak self] in self?.sweepExpiredLocked() }
    }
}
