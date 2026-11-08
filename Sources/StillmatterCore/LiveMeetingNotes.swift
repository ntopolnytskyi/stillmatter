import Foundation

public enum LiveMeetingNotesError: LocalizedError {
    case draftNotStored(Error)

    public var errorDescription: String? {
        switch self {
        case let .draftNotStored(error): return "The recoverable draft could not be written: \(error.localizedDescription)"
        }
    }
}

/// A capture-session-bound draft for the Meeting-owned My Notes file.
/// The workspace file remains authoritative; a conflicting draft stays in app support.
public final class LiveMeetingNotes {
    /// Returns drafts that still belong to their original Meeting doorway.
    /// Invalid or unreadable drafts remain in app support for manual recovery.
    public static func pendingDocuments(in vault: WorkspaceVault) -> [LiveMeetingNotes] {
        draftFiles(in: vault).compactMap { url in
            guard let draft = try? JSONDecoder().decode(Draft.self, from: Data(contentsOf: url)),
                  let path = resolvedMeetingPath(for: draft, in: vault) else { return nil }
            return LiveMeetingNotes(vault: vault, sessionID: draft.sessionID, meetingPath: path)
        }
    }

    /// Replays drafts left by interrupted app execution only when the original
    /// capture still owns the doorway and the workspace file has not changed.
    public static func recoverPendingDrafts(in vault: WorkspaceVault) -> [String] {
        var unresolved: [String] = []
        for url in draftFiles(in: vault) {
            do {
                let draft = try JSONDecoder().decode(Draft.self, from: Data(contentsOf: url))
                guard let path = resolvedMeetingPath(for: draft, in: vault) else {
                    unresolved.append(draft.meetingPath)
                    continue
                }
                let document = LiveMeetingNotes(vault: vault, sessionID: draft.sessionID, meetingPath: path)
                let state = try document.load()
                if state.hasDraft { _ = try document.save(draft.text, expectedVersion: draft.baseVersion) }
            } catch {
                unresolved.append(url.lastPathComponent)
            }
        }
        return unresolved
    }

    private static func draftFiles(in vault: WorkspaceVault) -> [URL] {
        let directory = vault.meetingArtifactStateURL.appendingPathComponent("LiveNotes", isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
    }

    public static func hasPendingDraftFiles(in vault: WorkspaceVault) -> Bool {
        !draftFiles(in: vault).isEmpty
    }

    private static func resolvedMeetingPath(for draft: Draft, in vault: WorkspaceVault) -> String? {
        func owns(_ path: String) -> Bool {
            guard let data = try? vault.readMarkdown(relativePath: path).data,
                  let text = String(data: data, encoding: .utf8) else { return false }
            return text.contains("capture_session_id: \(draft.sessionID)\n")
        }
        if owns(draft.meetingPath) { return draft.meetingPath }
        guard let paths = try? vault.markdownPaths(relativeTo: "Meetings") else { return nil }
        let matches = paths.filter { ($0 as NSString).lastPathComponent == "meeting.md" && owns($0) }
        return matches.count == 1 ? matches[0] : nil
    }

    public struct State {
        public let text: String
        public let savedText: String
        public let version: WorkspaceFileVersion?
        public let hasDraft: Bool
        public let conflictsWithFile: Bool
    }

    private struct Draft: Codable {
        let sessionID: String
        let meetingPath: String
        let text: String
        let baseVersion: WorkspaceFileVersion?
    }

    private let vault: WorkspaceVault
    private let sessionID: String
    private let meetingPath: String
    private let notesPath: String
    private let draftURL: URL

    public init(vault: WorkspaceVault, sessionID: String, meetingPath: String) {
        self.vault = vault
        self.sessionID = sessionID
        self.meetingPath = meetingPath
        notesPath = (meetingPath as NSString).deletingLastPathComponent + "/my-notes.md"
        draftURL = vault.meetingArtifactStateURL.appendingPathComponent("LiveNotes", isDirectory: true)
            .appendingPathComponent(sessionID + ".json")
    }

    public func load() throws -> State {
        let source = try currentFile()
        let draft = try storedDraft()
        if draft?.text == source.text {
            try? discardDraft()
            return State(text: source.text, savedText: source.text, version: source.version,
                         hasDraft: false, conflictsWithFile: false)
        }
        return State(text: draft?.text ?? source.text, savedText: source.text,
                     version: draft == nil ? source.version : draft?.baseVersion, hasDraft: draft != nil,
                     conflictsWithFile: draft != nil && draft?.baseVersion != source.version)
    }

    public var meetingRelativePath: String { meetingPath }

    public func stage(_ text: String, baseVersion: WorkspaceFileVersion?) throws {
        try FileManager.default.createDirectory(at: draftURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Draft(sessionID: sessionID, meetingPath: meetingPath,
                                       text: text, baseVersion: baseVersion)).write(to: draftURL, options: .atomic)
    }

    @discardableResult
    public func save(_ text: String, expectedVersion: WorkspaceFileVersion?) throws -> WorkspaceFileVersion {
        do { try stage(text, baseVersion: expectedVersion) }
        catch { throw LiveMeetingNotesError.draftNotStored(error) }
        let version = try MeetingNoteTodoBridge(vault: vault).saveNotes(
            text, at: notesPath, expectedNotesVersion: expectedVersion
        )
        try? FileManager.default.removeItem(at: draftURL)
        return version
    }

    public func discardDraft() throws {
        if FileManager.default.fileExists(atPath: draftURL.path) { try FileManager.default.removeItem(at: draftURL) }
    }

    public func reloadLatest() throws -> State {
        let source = try currentFile()
        try discardDraft()
        return State(text: source.text, savedText: source.text, version: source.version,
                     hasDraft: false, conflictsWithFile: false)
    }

    /// Publishes the last keystroke's durable draft when capture ends through
    /// automation or another control that does not own the Recording editor.
    public func flushStagedDraft() throws {
        guard let draft = try storedDraft() else { return }
        let source = try currentFile()
        if source.text == draft.text { try discardDraft(); return }
        _ = try MeetingNoteTodoBridge(vault: vault).saveNotes(
            draft.text, at: notesPath, expectedNotesVersion: draft.baseVersion
        )
        try discardDraft()
    }

    /// An explicit conflict decision keeps the displaced external version as a
    /// readable copy before publishing the user's staged draft.
    public func useDraftPreservingExternal(_ currentText: String, expectedBaseVersion: WorkspaceFileVersion?) throws -> (version: WorkspaceFileVersion, preservedCopy: URL) {
        do { try stage(currentText, baseVersion: expectedBaseVersion) }
        catch { throw LiveMeetingNotesError.draftNotStored(error) }
        guard let draft = try storedDraft() else { throw CocoaError(.fileNoSuchFile) }
        let source = try currentFile()
        let preserved = draftURL.deletingLastPathComponent().appendingPathComponent("Preserved", isDirectory: true)
            .appendingPathComponent("\(sessionID)-\(UUID().uuidString).md")
        try FileManager.default.createDirectory(at: preserved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(source.text.utf8).write(to: preserved, options: .atomic)
        let version = try MeetingNoteTodoBridge(vault: vault).saveNotes(
            draft.text, at: notesPath, expectedNotesVersion: source.version
        )
        try? discardDraft()
        return (version, preserved)
    }

    private func currentFile() throws -> (text: String, version: WorkspaceFileVersion?) {
        guard let version = try vault.versionOfMarkdown(relativePath: notesPath) else { return ("", nil) }
        let data = try vault.readMarkdown(relativePath: notesPath).data
        guard let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        return (text, version)
    }

    private func storedDraft() throws -> Draft? {
        guard FileManager.default.fileExists(atPath: draftURL.path) else { return nil }
        let draft = try JSONDecoder().decode(Draft.self, from: Data(contentsOf: draftURL))
        guard draft.sessionID == sessionID else { return nil }
        if draft.meetingPath != meetingPath {
            guard Self.resolvedMeetingPath(for: draft, in: vault) == meetingPath else { return nil }
        }
        return draft
    }
}
