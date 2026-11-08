import Foundation

/// A capture-session-bound draft for the Meeting-owned My Notes file.
/// The workspace file remains authoritative; a conflicting draft stays in app support.
public final class LiveMeetingNotes {
    /// Replays drafts left by interrupted app execution only when the original
    /// capture still owns the doorway and the workspace file has not changed.
    public static func recoverPendingDrafts(in vault: WorkspaceVault) -> [String] {
        let directory = vault.meetingArtifactStateURL.appendingPathComponent("LiveNotes", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var unresolved: [String] = []
        for url in files where url.pathExtension == "json" {
            do {
                let draft = try JSONDecoder().decode(Draft.self, from: Data(contentsOf: url))
                let doorway = try vault.readMarkdown(relativePath: draft.meetingPath).data
                guard let text = String(data: doorway, encoding: .utf8),
                      text.contains("capture_session_id: \(draft.sessionID)\n") else {
                    unresolved.append(draft.meetingPath)
                    continue
                }
                let document = LiveMeetingNotes(vault: vault, sessionID: draft.sessionID, meetingPath: draft.meetingPath)
                let state = try document.load()
                if state.hasDraft { _ = try document.save(draft.text, expectedVersion: draft.baseVersion) }
            } catch {
                unresolved.append(url.lastPathComponent)
            }
        }
        return unresolved
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

    public func stage(_ text: String, baseVersion: WorkspaceFileVersion?) throws {
        try FileManager.default.createDirectory(at: draftURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Draft(sessionID: sessionID, meetingPath: meetingPath,
                                       text: text, baseVersion: baseVersion)).write(to: draftURL, options: .atomic)
    }

    @discardableResult
    public func save(_ text: String, expectedVersion: WorkspaceFileVersion?) throws -> WorkspaceFileVersion {
        try stage(text, baseVersion: expectedVersion)
        let version = try vault.writeMarkdown(Data(text.utf8), relativePath: notesPath, expectedVersion: expectedVersion)
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

    private func currentFile() throws -> (text: String, version: WorkspaceFileVersion?) {
        guard let version = try vault.versionOfMarkdown(relativePath: notesPath) else { return ("", nil) }
        let data = try vault.readMarkdown(relativePath: notesPath).data
        guard let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        return (text, version)
    }

    private func storedDraft() throws -> Draft? {
        guard FileManager.default.fileExists(atPath: draftURL.path) else { return nil }
        let draft = try JSONDecoder().decode(Draft.self, from: Data(contentsOf: draftURL))
        guard draft.sessionID == sessionID, draft.meetingPath == meetingPath else { return nil }
        return draft
    }
}
