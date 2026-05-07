import Foundation

/// RFC §3.5 + §7.1 — Durable artifact outbox.
/// File-based persistence. Survives restart. Deletes on ACK.
final class EdgeOutbox {
    private let directory: URL
    private let queue = DispatchQueue(label: "ai.synheart.edge.outbox")

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.directory = docs.appendingPathComponent("edge_outbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Persist an artifact envelope to disk.
    func enqueue(_ envelope: HsiArtifactEnvelope) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let file = self.directory.appendingPathComponent("\(envelope.artifactId).json")
            if let data = try? JSONEncoder().encode(envelope) {
                try? data.write(to: file, options: .atomic)
            }
        }
    }

    /// Acknowledge receipt — delete from outbox.
    func ack(artifactId: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let file = self.directory.appendingPathComponent("\(artifactId).json")
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Acknowledge multiple artifacts.
    func ackBatch(artifactIds: [String]) {
        for id in artifactIds {
            ack(artifactId: id)
        }
    }

    /// Load all pending (un-ACKed) envelopes.
    func pending() -> [HsiArtifactEnvelope] {
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

    /// Number of pending artifacts.
    var pendingCount: Int {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return 0
        }
        return files.filter { $0.pathExtension == "json" }.count
    }

    /// Clear all artifacts (e.g. on full sync completion).
    func clear() {
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
}
