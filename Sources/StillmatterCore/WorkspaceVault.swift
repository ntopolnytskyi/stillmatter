import Foundation

public struct WorkspaceFileVersion: Equatable {
    public let contentHash: String
    public let modificationDate: Date
    public let byteCount: Int

    public init(contentHash: String, modificationDate: Date, byteCount: Int) {
        self.contentHash = contentHash
        self.modificationDate = modificationDate
        self.byteCount = byteCount
    }
}

public struct WorkspaceSnapshotRetentionPolicy: Equatable {
    public let maxAge: TimeInterval
    public let maxTotalBytes: Int

    public init(maxAge: TimeInterval = 30 * 24 * 60 * 60, maxTotalBytes: Int = 50 * 1024 * 1024) {
        self.maxAge = maxAge
        self.maxTotalBytes = maxTotalBytes
    }
}

public struct WorkspaceSnapshot: Equatable {
    public let url: URL
    public let capturedRelativePaths: [String]
}

public struct WorkspaceMarkdownReplacement {
    public let relativePath: String
    public let data: Data
    public let expectedVersion: WorkspaceFileVersion?

    public init(relativePath: String, data: Data, expectedVersion: WorkspaceFileVersion?) {
        self.relativePath = relativePath
        self.data = data
        self.expectedVersion = expectedVersion
    }
}

public enum WorkspaceVaultError: Error, Equatable {
    case pathEscapesWorkspace(String)
    case conflict(relativePath: String, expected: WorkspaceFileVersion?, actual: WorkspaceFileVersion?)
    case missingFile(String)
    case duplicateTransactionPath(String)
    case transactionRollbackFailed(String)
}

public final class WorkspaceVault {
    private let workspaceRootURL: URL
    private let appSupportRootURL: URL
    private let snapshotsURL: URL
    private let retentionPolicy: WorkspaceSnapshotRetentionPolicy
    private let fileManager: FileManager
    private let now: () -> Date

    public init(
        workspaceRootURL: URL,
        appSupportRootURL: URL,
        retentionPolicy: WorkspaceSnapshotRetentionPolicy = WorkspaceSnapshotRetentionPolicy(),
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.workspaceRootURL = workspaceRootURL.standardizedFileURL
        self.appSupportRootURL = appSupportRootURL.standardizedFileURL
        self.snapshotsURL = appSupportRootURL.appendingPathComponent("Snapshots", isDirectory: true).standardizedFileURL
        self.retentionPolicy = retentionPolicy
        self.fileManager = fileManager
        self.now = now
    }

    public func readMarkdown(relativePath: String) throws -> (data: Data, version: WorkspaceFileVersion) {
        let fileURL = try workspaceURL(for: relativePath)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            throw WorkspaceVaultError.missingFile(relativePath)
        }
        let data = try Data(contentsOf: fileURL)
        return (data, try version(for: fileURL, data: data))
    }

    /// Returns workspace Markdown paths below the requested directory. Paths are returned relative
    /// to the vault and are safe to pass back to the other vault APIs.
    public func markdownPaths(relativeTo relativeDirectory: String = "") throws -> [String] {
        let directory = try workspaceURL(for: relativeDirectory)
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        return try enumerator.compactMap { item -> String? in
            guard let url = item as? URL,
                  url.pathExtension.lowercased() == "md",
                  (try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
            let prefix = workspaceRootURL.path.hasSuffix("/") ? workspaceRootURL.path : workspaceRootURL.path + "/"
            return String(url.standardizedFileURL.path.dropFirst(prefix.count))
        }
    }

    /// Workspace-relative editable text artifacts (including Transcript and extraction JSON).
    public func textPaths(relativeTo directory: String = "") throws -> [String] {
        let root = try workspaceURL(for: directory)
        guard fileManager.fileExists(atPath: root.path),
              let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        let prefix = workspaceRootURL.path + "/"
        return try enumerator.compactMap { value -> String? in
            guard let url = value as? URL, ["md", "json", "vtt"].contains(url.pathExtension.lowercased()),
                  !url.path.hasPrefix(appSupportRootURL.path + "/"),
                  try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { return nil }
            return String(url.standardizedFileURL.path.dropFirst(prefix.count))
        }
    }

    public func versionOfMarkdown(relativePath: String) throws -> WorkspaceFileVersion? {
        let fileURL = try workspaceURL(for: relativePath)
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: fileURL)
        return try version(for: fileURL, data: data)
    }

    public func createDirectory(relativePath: String) throws {
        let directoryURL = try workspaceURL(for: relativePath)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    /// Replaces a set of canonical Markdown files as one recoverable operation.
    /// Every version is checked and every replacement is staged before any live file changes.
    /// If a commit step fails, all paths are restored from the pre-transaction snapshot.
    public func replaceMarkdownTransaction(_ replacements: [WorkspaceMarkdownReplacement],
                                           onCommitted: () throws -> Void = {}) throws {
        guard !replacements.isEmpty else { return }
        var seenPaths: Set<String> = []
        var destinations: [(replacement: WorkspaceMarkdownReplacement, url: URL, existed: Bool)] = []
        for replacement in replacements {
            guard seenPaths.insert(replacement.relativePath).inserted else {
                throw WorkspaceVaultError.duplicateTransactionPath(replacement.relativePath)
            }
            let url = try workspaceURL(for: replacement.relativePath)
            let actualVersion = try versionOfMarkdown(relativePath: replacement.relativePath)
            guard actualVersion == replacement.expectedVersion else {
                throw WorkspaceVaultError.conflict(
                    relativePath: replacement.relativePath,
                    expected: replacement.expectedVersion,
                    actual: actualVersion
                )
            }
            destinations.append((replacement, url, actualVersion != nil))
        }

        var stagedURLs: [URL] = []
        defer { stagedURLs.forEach { try? fileManager.removeItem(at: $0) } }
        for destination in destinations {
            try fileManager.createDirectory(at: destination.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let stagedURL = destination.url.deletingLastPathComponent()
                .appendingPathComponent(".\(destination.url.lastPathComponent).\(UUID().uuidString).transaction")
            try destination.replacement.data.write(to: stagedURL, options: .atomic)
            stagedURLs.append(stagedURL)
        }

        let snapshot = try createSnapshot(relativePaths: replacements.map(\.relativePath))
        do {
            for (index, destination) in destinations.enumerated() {
                if destination.existed {
                    _ = try fileManager.replaceItemAt(destination.url, withItemAt: stagedURLs[index])
                } else {
                    try fileManager.moveItem(at: stagedURLs[index], to: destination.url)
                }
            }
            try onCommitted()
        } catch {
            do {
                for destination in destinations {
                    let backupURL = snapshot.url.appendingPathComponent(destination.replacement.relativePath)
                    if fileManager.fileExists(atPath: destination.url.path) {
                        try fileManager.removeItem(at: destination.url)
                    }
                    if destination.existed {
                        try fileManager.createDirectory(
                            at: destination.url.deletingLastPathComponent(),
                            withIntermediateDirectories: true
                        )
                        try fileManager.copyItem(at: backupURL, to: destination.url)
                    }
                }
            } catch let rollbackError {
                throw WorkspaceVaultError.transactionRollbackFailed(
                    "Commit failed with \(error); rollback failed with \(rollbackError)"
                )
            }
            throw error
        }
    }

    public func writeMarkdown(_ data: Data, relativePath: String, expectedVersion: WorkspaceFileVersion?) throws -> WorkspaceFileVersion {
        let fileURL = try workspaceURL(for: relativePath)
        let actualVersion = try versionOfMarkdown(relativePath: relativePath)
        guard actualVersion == expectedVersion else {
            throw WorkspaceVaultError.conflict(relativePath: relativePath, expected: expectedVersion, actual: actualVersion)
        }

        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporaryURL = fileURL.deletingLastPathComponent().appendingPathComponent(".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporaryURL, options: .atomic)

        if fileManager.fileExists(atPath: fileURL.path) {
            _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: fileURL)
        }

        return try version(for: fileURL, data: data)
    }

    @discardableResult
    public func deleteMarkdown(relativePath: String, expectedVersion: WorkspaceFileVersion) throws -> WorkspaceSnapshot {
        let fileURL = try workspaceURL(for: relativePath)
        let actualVersion = try versionOfMarkdown(relativePath: relativePath)
        guard actualVersion == expectedVersion else {
            throw WorkspaceVaultError.conflict(relativePath: relativePath, expected: expectedVersion, actual: actualVersion)
        }

        let snapshot = try createSnapshot(relativePaths: [relativePath])
        try fileManager.removeItem(at: fileURL)
        try enforceSnapshotRetention()
        return snapshot
    }

    @discardableResult
    public func moveMarkdown(from sourceRelativePath: String, to destinationRelativePath: String, expectedSourceVersion: WorkspaceFileVersion) throws -> WorkspaceSnapshot {
        let sourceURL = try workspaceURL(for: sourceRelativePath)
        let destinationURL = try workspaceURL(for: destinationRelativePath)
        let actualVersion = try versionOfMarkdown(relativePath: sourceRelativePath)
        guard actualVersion == expectedSourceVersion else {
            throw WorkspaceVaultError.conflict(relativePath: sourceRelativePath, expected: expectedSourceVersion, actual: actualVersion)
        }
        guard try versionOfMarkdown(relativePath: destinationRelativePath) == nil else {
            throw WorkspaceVaultError.conflict(relativePath: destinationRelativePath, expected: nil, actual: try versionOfMarkdown(relativePath: destinationRelativePath))
        }

        let snapshot = try createSnapshot(relativePaths: [sourceRelativePath, destinationRelativePath])
        try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: sourceURL, to: destinationURL)
        try enforceSnapshotRetention()
        return snapshot
    }

    /// Rename the canonical Meeting and rewrite workspace references without an old-path alias.
    /// Restore the folder and every rewritten reference if any write fails.
    public func renameMeetingDirectory(
        from sourcePath: String,
        to destinationPath: String,
        updatedDoorway: Data,
        expectedVersion: WorkspaceFileVersion,
        referenceReplacements: [WorkspaceMarkdownReplacement] = [],
        onRenamed: () throws -> Void = {}
    ) throws {
        let source = try workspaceURL(for: sourcePath)
        let destination = try workspaceURL(for: destinationPath)
        guard source.lastPathComponent == "meeting.md", destination.lastPathComponent == "meeting.md",
              source.deletingLastPathComponent().deletingLastPathComponent() == destination.deletingLastPathComponent().deletingLastPathComponent() else {
            throw WorkspaceVaultError.pathEscapesWorkspace(destinationPath)
        }
        let oldDirectory = source.deletingLastPathComponent()
        let newDirectory = destination.deletingLastPathComponent()
        guard (try? fileManager.destinationOfSymbolicLink(atPath: oldDirectory.path)) == nil else {
            throw WorkspaceVaultError.conflict(relativePath: sourcePath, expected: expectedVersion, actual: try versionOfMarkdown(relativePath: sourcePath))
        }
        guard !fileManager.fileExists(atPath: newDirectory.path),
              (try? fileManager.destinationOfSymbolicLink(atPath: newDirectory.path)) == nil else {
            throw WorkspaceVaultError.conflict(relativePath: destinationPath, expected: nil, actual: try versionOfMarkdown(relativePath: destinationPath))
        }
        guard try versionOfMarkdown(relativePath: sourcePath) == expectedVersion else {
            throw WorkspaceVaultError.conflict(relativePath: sourcePath, expected: expectedVersion, actual: try versionOfMarkdown(relativePath: sourcePath))
        }
        let original = try Data(contentsOf: source)
        let oldRelativeDirectory = (sourcePath as NSString).deletingLastPathComponent
        let referencePaths = referenceReplacements.map(\.relativePath)
        guard Set(referencePaths).count == referencePaths.count,
              !referencePaths.contains(sourcePath) else {
            throw WorkspaceVaultError.duplicateTransactionPath(oldRelativeDirectory)
        }
        let references = try referenceReplacements.map { replacement -> (WorkspaceMarkdownReplacement, Data) in
            let current = try readMarkdown(relativePath: replacement.relativePath)
            guard current.version == replacement.expectedVersion else {
                throw WorkspaceVaultError.conflict(relativePath: replacement.relativePath,
                    expected: replacement.expectedVersion, actual: current.version)
            }
            return (replacement, current.data)
        }
        let snapshot = try createSnapshot(relativePaths: [oldRelativeDirectory] +
            referencePaths.filter { !$0.hasPrefix(oldRelativeDirectory + "/") })
        guard fileManager.fileExists(atPath: snapshot.url.appendingPathComponent(oldRelativeDirectory).path) else {
            throw WorkspaceVaultError.transactionRollbackFailed("Meeting folder snapshot was not retained")
        }
        var moved = false
        do {
            _ = try writeMarkdown(updatedDoorway, relativePath: sourcePath, expectedVersion: expectedVersion)
            for (replacement, _) in references where replacement.relativePath.hasPrefix(oldRelativeDirectory + "/") {
                _ = try writeMarkdown(replacement.data, relativePath: replacement.relativePath,
                    expectedVersion: replacement.expectedVersion)
            }
            try fileManager.moveItem(at: oldDirectory, to: newDirectory)
            moved = true
            for (replacement, _) in references where !replacement.relativePath.hasPrefix(oldRelativeDirectory + "/") {
                _ = try writeMarkdown(replacement.data, relativePath: replacement.relativePath,
                    expectedVersion: replacement.expectedVersion)
            }
            try onRenamed()
        } catch {
            do {
                if moved {
                    if (try? fileManager.destinationOfSymbolicLink(atPath: oldDirectory.path)) != nil {
                        try fileManager.removeItem(at: oldDirectory)
                    }
                    try fileManager.moveItem(at: newDirectory, to: oldDirectory)
                }
                let current = try versionOfMarkdown(relativePath: sourcePath)
                _ = try writeMarkdown(original, relativePath: sourcePath, expectedVersion: current)
                for (replacement, originalData) in references {
                    let current = try versionOfMarkdown(relativePath: replacement.relativePath)
                    _ = try writeMarkdown(originalData, relativePath: replacement.relativePath, expectedVersion: current)
                }
            } catch let rollbackError {
                throw WorkspaceVaultError.transactionRollbackFailed("Rename failed with \(error); rollback failed with \(rollbackError)")
            }
            throw error
        }
    }

    public func createSnapshot(relativePaths: [String]) throws -> WorkspaceSnapshot {
        try fileManager.createDirectory(at: snapshotsURL, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let snapshotURL = snapshotsURL.appendingPathComponent("\(formatter.string(from: now()))-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: snapshotURL, withIntermediateDirectories: true)

        var captured: [String] = []
        for relativePath in relativePaths {
            let sourceURL = try workspaceURL(for: relativePath)
            guard fileManager.fileExists(atPath: sourceURL.path) else {
                continue
            }
            let destinationURL = snapshotURL.appendingPathComponent(relativePath)
            try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            captured.append(relativePath)
        }

        let manifest = captured.joined(separator: "\n").data(using: .utf8) ?? Data()
        try manifest.write(to: snapshotURL.appendingPathComponent("manifest.txt"), options: .atomic)
        try enforceSnapshotRetention()
        return WorkspaceSnapshot(url: snapshotURL, capturedRelativePaths: captured)
    }

    private func workspaceURL(for relativePath: String) throws -> URL {
        let candidate = workspaceRootURL.appendingPathComponent(relativePath).standardizedFileURL
        let rootPath = workspaceRootURL.path.hasSuffix("/") ? workspaceRootURL.path : workspaceRootURL.path + "/"
        guard candidate.path == workspaceRootURL.path || candidate.path.hasPrefix(rootPath) else {
            throw WorkspaceVaultError.pathEscapesWorkspace(relativePath)
        }
        return candidate
    }

    private func version(for fileURL: URL, data: Data) throws -> WorkspaceFileVersion {
        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        let modificationDate = attributes[.modificationDate] as? Date ?? Date(timeIntervalSince1970: 0)
        return WorkspaceFileVersion(contentHash: WorkspaceVault.hash(data), modificationDate: modificationDate, byteCount: data.count)
    }

    private static func hash(_ data: Data) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return String(format: "%016llx", hash)
    }

    private func enforceSnapshotRetention() throws {
        guard fileManager.fileExists(atPath: snapshotsURL.path) else { return }
        var snapshots = try snapshotDirectories()
        let cutoff = now().addingTimeInterval(-retentionPolicy.maxAge)

        for snapshot in snapshots where snapshot.modificationDate < cutoff {
            try fileManager.removeItem(at: snapshot.url)
        }

        snapshots = try snapshotDirectories().sorted { $0.modificationDate < $1.modificationDate }
        var totalBytes = snapshots.reduce(0) { $0 + $1.byteCount }
        for snapshot in snapshots where totalBytes > retentionPolicy.maxTotalBytes {
            try fileManager.removeItem(at: snapshot.url)
            totalBytes -= snapshot.byteCount
        }
    }

    private func snapshotDirectories() throws -> [(url: URL, modificationDate: Date, byteCount: Int)] {
        guard fileManager.fileExists(atPath: snapshotsURL.path) else { return [] }
        let urls = try fileManager.contentsOfDirectory(at: snapshotsURL, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey])

        var directories: [(URL, Date, Int)] = []
        for url in urls {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            guard values.isDirectory == true else { continue }
            directories.append((url, values.contentModificationDate ?? Date(timeIntervalSince1970: 0), try byteCount(of: url)))
        }
        return directories
    }

    private func byteCount(of url: URL) throws -> Int {
        var total = 0
        if let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) {
            for case let fileURL as URL in enumerator {
                let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                if values.isRegularFile == true {
                    total += values.fileSize ?? 0
                }
            }
        }
        return total
    }
}
