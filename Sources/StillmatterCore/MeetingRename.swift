import Foundation

/// Owns a complete canonical Meeting rename: plans reference changes, commits them
/// under the Jobs/vault locks and restores non-transactional writes on failure.
/// Storage implementations remain concrete so failure tests use real files and SQLite.
struct MeetingRename {
    struct Commit {
        let meetingID: String
        let changedPaths: [String]
    }

    let vault: WorkspaceVault
    let jobs: JobStore?
    let inbox: TasksInbox?
    let index: SearchIndex?
    let enforceWorkspaceOwner: Bool

    func commit(selected: MeetingBrowserDetail, context: MeetingCalendarContext,
                        expectedVersion: WorkspaceFileVersion) throws -> Commit {
        let cleaned = context.appliedTitle
        let old = selected.row.meetingRelativePath
        guard selected.doorwayVersion == expectedVersion else {
            throw WorkspaceVaultError.conflict(relativePath: old, expected: expectedVersion, actual: selected.doorwayVersion)
        }
        guard !selected.row.isArchived else {
            throw MeetingManagementError.retryRejected("Archived Meeting metadata is read-only.")
        }
        guard selected.row.captureState == .stopped else { throw MeetingManagementError.retryRejected("Stop recording before renaming.") }
        let session = MeetingDoorwayMetadata(selected.doorwayText).sessionID
        let owner = vault.rootURL.standardizedFileURL.resolvingSymlinksInPath().path
        let owned = try (jobs?.jobs() ?? []).filter {
            (!enforceWorkspaceOwner || $0.manifest.workspaceOwner == owner) &&
                MeetingDoorwayMetadata.owns($0, session: session, path: old)
        }
        guard !owned.contains(where: { $0.status == .queued || $0.status == .running }) else {
            throw MeetingManagementError.retryRejected("This Meeting has processing work in progress.")
        }
        let titleSlug = cleaned.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.prefix(8).joined(separator: "-")
        let slug = titleSlug.isEmpty ? "untitled-meeting" : titleSlug
        let directory = (old as NSString).deletingLastPathComponent
        let parent = (directory as NSString).deletingLastPathComponent
        let name = (directory as NSString).lastPathComponent
        let prefix = name.range(of: #"^\d{2}-\d{2}-"#, options: .regularExpression).map { String(name[$0]) } ?? ""
        let target = selected.row.title == cleaned ? old : "\(parent)/\(prefix)\(slug)/meeting.md"
        let newDirectory = (target as NSString).deletingLastPathComponent
        guard let titleLine = selected.doorwayText.range(of: #"(?m)^title:.*$"#, options: .regularExpression) else {
            throw MeetingManagementError.malformed("Meeting title metadata missing")
        }
        var doorway = selected.doorwayText.replacingCharacters(in: titleLine, with: "title: \(MeetingCalendarContext.titleLine(cleaned))")
        if let heading = doorway.range(of: #"(?m)^# .*$"#, options: .regularExpression) {
            doorway.replaceSubrange(heading, with: "# \(MeetingCalendarContext.titleLine(cleaned))")
        }
        doorway = try context.writing(to: doorway)
        guard target != old else {
            try vault.replaceMarkdownTransaction([
                WorkspaceMarkdownReplacement(relativePath: old, data: Data(doorway.utf8), expectedVersion: expectedVersion)
            ]) {
                try self.index?.update(relativePath: old)
            }
            return Commit(meetingID: selected.row.id, changedPaths: [])
        }
        let rewrite: (String) -> String = {
            $0.replacingOccurrences(of: directory + "/", with: newDirectory + "/")
                .replacingOccurrences(of: directory + "|", with: newDirectory + "|")
                .replacingOccurrences(of: directory + "]]", with: newDirectory + "]]" )
                .replacingOccurrences(of: "[[" + name + "/", with: "[[" + (newDirectory as NSString).lastPathComponent + "/")
        }
        doorway = rewrite(doorway)
        var changes: [WorkspaceMarkdownReplacement] = []
        for path in try vault.textPaths() where path != old {
            let current = try vault.readMarkdown(relativePath: path)
            guard let text = String(data: current.data, encoding: .utf8) else { continue }
            var updated = Data(rewrite(text).utf8)
            if path.hasSuffix(".json"), let object = try? JSONSerialization.jsonObject(with: current.data) {
                func rewriteJSON(_ value: Any) -> Any {
                    if let string = value as? String { return rewrite(string) }
                    if let entries = value as? [String: Any] { return entries.mapValues(rewriteJSON) }
                    if let entries = value as? [Any] { return entries.map(rewriteJSON) }
                    return value
                }
                updated = try JSONSerialization.data(withJSONObject: rewriteJSON(object))
                if let originalJSON = try? JSONSerialization.jsonObject(with: current.data) as? NSDictionary,
                   let newJSON = try? JSONSerialization.jsonObject(with: updated) as? NSDictionary,
                   originalJSON == newJSON { continue }
            }
            if updated != current.data {
                changes.append(WorkspaceMarkdownReplacement(relativePath: path, data: updated, expectedVersion: current.version))
            }
        }
        let bundlePath = MeetingDoorwayMetadata(selected.doorwayText).bundlePath
        var mediaDocuments: [(url: URL, original: Data, updated: Data)] = []
        if let bundlePath {
            let url = URL(fileURLWithPath: bundlePath)
            let original = try Data(contentsOf: url)
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let bundle = try decoder.decode(RecordingBundle.self, from: original)
            guard bundle.bundleFilePath == bundlePath, bundle.meetingRelativePath == old,
                  session == nil || bundle.captureSessionID == session else {
                throw MeetingManagementError.retryRejected("Recording Bundle does not match this Meeting.")
            }
            for path in [bundlePath, bundle.mic.metadataFilePath, bundle.system?.metadataFilePath].compactMap({ $0 }) {
                let file = URL(fileURLWithPath: path)
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                let original = try Data(contentsOf: file)
                guard var json = try JSONSerialization.jsonObject(with: original) as? [String: Any] else {
                    throw MeetingManagementError.retryRejected("Recording metadata is invalid.")
                }
                if let referenced = json["meetingRelativePath"] as? String, referenced != old {
                    throw MeetingManagementError.retryRejected("Recording metadata does not match this Meeting.")
                }
                guard json["meetingRelativePath"] != nil else { continue }
                json["meetingRelativePath"] = target
                mediaDocuments.append((file, original, try JSONSerialization.data(withJSONObject: json)))
            }
        }
        let applyRename = {
            try self.vault.renameMeetingDirectory(from: old, to: target, updatedDoorway: Data(doorway.utf8),
                expectedVersion: expectedVersion, referenceReplacements: changes) {
                var inboxRewritten = false
                var writtenMedia: [(url: URL, original: Data)] = []
                do {
                    try self.jobs?.rewriteMeetingReferences(from: directory, to: newDirectory,
                                                             workspaceRootURL: self.enforceWorkspaceOwner ? self.vault.rootURL : nil)
                    if let jobs = self.jobs, let inbox = self.inbox, jobs.sharesDatabase(with: inbox) {
                        try jobs.rewriteInboxReferencesInRename(from: directory, to: newDirectory, inbox: inbox)
                        // The Job transaction rolls these references back on failure.
                    } else {
                        try self.inbox?.rewriteMeetingReferences(from: directory, to: newDirectory)
                        inboxRewritten = self.inbox != nil
                    }
                    for document in mediaDocuments {
                        // Include a failing write in rollback: an I/O error can occur after
                        // the destination was replaced.
                        writtenMedia.append((document.url, document.original))
                        try document.updated.write(to: document.url, options: .atomic)
                    }
                    // A failed rebuild leaves its SQLite transaction unchanged. The vault and
                    // operational references are restored before the rename can report success.
                    try self.index?.rebuild()
                } catch {
                    var rollbackFailures: [String] = []
                    for document in writtenMedia.reversed() {
                        do { try document.original.write(to: document.url, options: .atomic) }
                        catch { rollbackFailures.append("Media \(document.url.path): \(error)") }
                    }
                    if inboxRewritten {
                        do { try self.inbox?.rewriteMeetingReferences(from: newDirectory, to: directory) }
                        catch { rollbackFailures.append("Inbox: \(error)") }
                    }
                    // Job references are in performRenameUnlessActive's enclosing transaction;
                    // throwing rolls them back, including on another JobStore connection.
                    if !rollbackFailures.isEmpty {
                        throw WorkspaceVaultError.transactionRollbackFailed(
                            "Rename failed with \(error); operational rollback failed: \(rollbackFailures.joined(separator: "; "))"
                        )
                    }
                    throw error
                }
            }
        }
        if let jobs {
            try jobs.performRenameUnlessActive(belongsToMeeting: { MeetingDoorwayMetadata.owns($0, session: session, path: old) }, applyRename)
        } else {
            try applyRename()
        }
        return Commit(meetingID: session ?? target, changedPaths: [old, target])
    }
}
