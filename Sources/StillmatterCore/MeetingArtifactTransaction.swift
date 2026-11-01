import Foundation

/// A durable publication plan retains exact prior/intended bytes before changing live files.
/// File coordination serializes cooperating editors; byte preconditions reject stale plans.
final class MeetingArtifactTransaction {
    private struct Entry: Codable { let path: String; let before: Data?; let after: Data }
    private struct Plan: Codable { let entries: [Entry]; let dependencies: [Entry] }
    private let vault: WorkspaceVault
    private let journal: URL
    private let checkpoint: (Int) throws -> Void

    init(vault: WorkspaceVault, identity: String, checkpoint: @escaping (Int) throws -> Void = { _ in }) {
        self.vault = vault
        let key = SHA256Hex.digest(Data((vault.rootURL.path + "\n" + identity).utf8))
        journal = vault.meetingArtifactStateURL.appendingPathComponent(key + ".json")
        self.checkpoint = checkpoint
    }

    func recover() throws { try coordinated { try recoverPlan() } }

    private func recoverPlan() throws {
        guard FileManager.default.fileExists(atPath: journal.path) else { return }
        let plan = try JSONDecoder().decode(Plan.self, from: Data(contentsOf: journal))
        // Validate the whole plan before the first replacement, including read-only inputs.
        for entry in plan.dependencies + plan.entries {
            let current = try bytes(at: entry.path)
            guard current == entry.before || (!plan.dependencies.contains(where: { $0.path == entry.path }) && current == entry.after) else {
                throw MeetingManagementError.malformed("\(entry.path) changed during artifact recovery. Both versions are retained at \(journal.path); resolve the external change before retrying.")
            }
        }
        for (index, entry) in plan.entries.enumerated() {
            let version = try vault.versionOfMarkdown(relativePath: entry.path)
            let current = try bytes(at: entry.path)
            guard current == entry.before || current == entry.after else {
                throw WorkspaceVaultError.conflict(relativePath: entry.path, expected: nil, actual: version)
            }
            if current != entry.after { _ = try vault.writeMarkdown(entry.after, relativePath: entry.path, expectedVersion: version) }
            try checkpoint(index + 1)
        }
        try FileManager.default.removeItem(at: journal)
    }

    func publish(_ replacements: [WorkspaceMarkdownReplacement], dependencies: [WorkspaceMarkdownReplacement] = []) throws {
        guard !replacements.isEmpty else { return }
        try coordinated {
            try recoverPlan()
            var seen: Set<String> = []
            func capture(_ replacement: WorkspaceMarkdownReplacement) throws -> Entry {
                guard seen.insert(replacement.relativePath).inserted else { throw WorkspaceVaultError.duplicateTransactionPath(replacement.relativePath) }
                let source = try optionalRead(replacement.relativePath)
                guard source?.version == replacement.expectedVersion else {
                    throw WorkspaceVaultError.conflict(relativePath: replacement.relativePath, expected: replacement.expectedVersion, actual: source?.version)
                }
                return Entry(path: replacement.relativePath, before: source?.data, after: replacement.data)
            }
            let entries = try replacements.map(capture)
            let inputs = try dependencies.filter { !seen.contains($0.relativePath) }.map(capture)
            try FileManager.default.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Plan(entries: entries, dependencies: inputs)).write(to: journal, options: .atomic)
            try checkpoint(0)
            try recoverPlan()
        }
    }

    private func optionalRead(_ path: String) throws -> (data: Data, version: WorkspaceFileVersion)? {
        guard try vault.versionOfMarkdown(relativePath: path) != nil else { return nil }
        return try vault.readMarkdown(relativePath: path)
    }
    private func bytes(at path: String) throws -> Data? { try optionalRead(path)?.data }

    private func coordinated(_ body: () throws -> Void) throws {
        var coordinationError: NSError?
        var outcome: Result<Void, Error>?
        NSFileCoordinator().coordinate(writingItemAt: vault.rootURL, options: .forMerging, error: &coordinationError) { _ in
            outcome = Result { try body() }
        }
        if let coordinationError { throw coordinationError }
        try outcome?.get()
    }
}
