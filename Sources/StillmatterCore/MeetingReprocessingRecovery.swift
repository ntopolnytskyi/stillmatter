import Foundation

/// Operational recovery only: prior working bytes survive stage failure/restart until analysis publishes.
/// These snapshots are never exposed as revision history or replayed over authoritative user files.
final class MeetingReprocessingRecovery {
    private let vault: WorkspaceVault
    init(vault: WorkspaceVault) { self.vault = vault }

    func location(jobID: String) -> URL {
        vault.meetingArtifactStateURL.appendingPathComponent("Reprocessing")
            .appendingPathComponent(SHA256Hex.digest(Data(jobID.utf8)) + ".json")
    }

    func retain(jobID: String, paths: Set<String>) throws {
        let bytes = try paths.reduce(into: [String: Data]()) { result, path in
            if try vault.versionOfMarkdown(relativePath: path) != nil {
                result[path] = try vault.readMarkdown(relativePath: path).data
            }
        }
        let target = location(jobID: jobID)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(bytes).write(to: target, options: .atomic)
    }

    func discard(jobID: String) {
        try? FileManager.default.removeItem(at: location(jobID: jobID))
    }
}
