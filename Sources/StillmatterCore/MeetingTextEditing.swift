import Foundation

/// Owns My Notes and Summary edits across active legacy writers and canonical
/// artifacts. Callers keep only the Meeting identity, draft and captured version;
/// representation selection, Todo references and derived refresh stay here.
struct MeetingTextEditing {
    private let vault: WorkspaceVault
    private let artifacts: MeetingArtifactStore
    private let index: SearchIndex?
    private let readDetail: (String) throws -> MeetingBrowserDetail
    private let onMeetingChanged: ([String]) -> Void

    init(vault: WorkspaceVault, inbox: TasksInbox?, index: SearchIndex?,
         readDetail: @escaping (String) throws -> MeetingBrowserDetail,
         onMeetingChanged: @escaping ([String]) -> Void) {
        self.vault = vault
        artifacts = MeetingArtifactStore(vault: vault, inbox: inbox)
        self.index = index
        self.readDetail = readDetail
        self.onMeetingChanged = onMeetingChanged
    }

    func saveNotes(_ notes: String, for id: String, expectedVersion: WorkspaceFileVersion) throws -> MeetingBrowserDetail {
        do {
            let detail = try readDetail(id)
            guard !detail.row.isArchived else { throw MeetingManagementError.retryRejected("Archived Meeting content is read-only.") }
            if try artifacts.usesLegacyWriter(for: detail.row) {
                let liveNotesPath = Self.sibling(detail.row.meetingRelativePath, "my-notes.md")
                if try vault.versionOfMarkdown(relativePath: liveNotesPath) != nil {
                    _ = try MeetingNoteTodoBridge(vault: vault).saveNotes(
                        notes, at: liveNotesPath, expectedNotesVersion: expectedVersion
                    )
                    try? index?.update(relativePath: liveNotesPath)
                    onMeetingChanged([detail.row.meetingRelativePath])
                    return try readDetail(id)
                }
                // Capture still appends to the doorway until the live-notes writer is
                // migrated. Keep this representation authoritative for that session.
                let updated = Self.replaceNotes(in: detail.doorwayText, notes: notes)
                do {
                    _ = try vault.writeMarkdown(Data(updated.utf8), relativePath: detail.row.meetingRelativePath, expectedVersion: expectedVersion)
                } catch {
                    try artifacts.keepConflict(notes, external: Self.notes(from: String(decoding: try vault.readMarkdown(relativePath: detail.row.meetingRelativePath).data, as: UTF8.self)),
                        meetingID: detail.row.id, path: detail.row.meetingRelativePath)
                    throw error
                }
                try? index?.update(relativePath: detail.row.meetingRelativePath)
            } else {
                try artifacts.saveNotes(notes, meetingPath: detail.row.meetingRelativePath, meetingID: detail.row.id, expected: expectedVersion)
                try? index?.update(relativePath: Self.sibling(detail.row.meetingRelativePath, "my-notes.md"))
            }
            onMeetingChanged([detail.row.meetingRelativePath])
            return try readDetail(id)
        } catch {
            // Preserve a draft even when the newer external source cannot be parsed.
            if !(error is WorkspaceVaultError) { try artifacts.keepConflict(notes, external: error.localizedDescription, meetingID: id, path: "My Notes") }
            throw error
        }
    }
    func saveSummary(_ sections: MeetingSummarySections, for id: String, expectedVersion: WorkspaceFileVersion) throws -> MeetingBrowserDetail {
        do {
            let detail = try readDetail(id)
            guard !detail.row.isArchived else { throw MeetingManagementError.retryRejected("Archived Meeting content is read-only.") }
            let summaryPath = Self.sibling(detail.row.meetingRelativePath, "summary.md")
            if try artifacts.usesLegacyWriter(for: detail.row) {
                do {
                    _ = try vault.writeMarkdown(Data(sections.summary.utf8), relativePath: summaryPath, expectedVersion: expectedVersion)
                } catch {
                    try artifacts.keepConflict(sections.summary, external: detail.summary?.summary ?? "", meetingID: detail.row.id, path: summaryPath)
                    throw error
                }
            } else {
                try artifacts.saveSummary(sections, meetingPath: detail.row.meetingRelativePath, meetingID: detail.row.id, expected: expectedVersion)
            }
            try? index?.update(relativePath: summaryPath)
            onMeetingChanged([detail.row.meetingRelativePath])
            return try readDetail(id)
        } catch {
            if !(error is WorkspaceVaultError) { try artifacts.keepConflict(sections.summary, external: error.localizedDescription, meetingID: id, path: "Summary") }
            throw error
        }
    }
    private static func notesRange(in text: String) -> Range<String.Index>? {
        // Captured Meetings use Live notes; older manually written Meetings may use Notes.
        guard let heading = text.range(of: #"(?m)^## (?:Live notes|Notes)[ \t]*$"#, options: .regularExpression) else { return nil }
        let end = text.range(of: #"(?m)^## [^\n]+$"#, options: .regularExpression, range: heading.upperBound..<text.endIndex)?.lowerBound ?? text.endIndex
        return heading.upperBound..<end
    }
    private static func notes(from text: String) -> String {
        guard let range = notesRange(in: text) else { return "" }
        return text[range].trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func replaceNotes(in text: String, notes: String) -> String {
        let clean = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = notesRange(in: text) else {
            return text.trimmingCharacters(in: .newlines) + "\n\n## Notes\n\n" + clean + "\n"
        }
        return text.replacingCharacters(in: range, with: "\n\n" + clean + "\n\n")
    }
    private static func sibling(_ path: String, _ name: String) -> String {
        (path as NSString).deletingLastPathComponent + "/" + name
    }
}
