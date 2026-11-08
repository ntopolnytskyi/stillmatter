import Foundation

/// Publishes note-authored checkboxes as identity references in the personal Todo queue.
/// My Notes remains the only mutable source for these items.
public final class MeetingNoteTodoBridge {
    private let vault: WorkspaceVault

    public init(vault: WorkspaceVault) {
        self.vault = vault
    }

    /// Adopts checkboxes at an explicit save boundary. Reads never mint identities or
    /// rewrite an externally edited notes file.
    @discardableResult
    public func adoptSavedNotes(at notesPath: String, removingItemIDs: Set<String> = []) throws -> WorkspaceFileVersion {
        let notes = try vault.readMarkdown(relativePath: notesPath)
        let queue = try currentQueue()
        let result = try Self.adopt(notes: String(decoding: notes.data, as: UTF8.self),
                                    path: notesPath,
                                    queue: queue.text,
                                    removingItemIDs: removingItemIDs)
        guard result.notes != String(decoding: notes.data, as: UTF8.self) || result.queue != queue.text else {
            return notes.version
        }
        try vault.replaceMarkdownTransaction([
            .init(relativePath: notesPath, data: Data(result.notes.utf8), expectedVersion: notes.version),
            .init(relativePath: TodoItemIndex.mainTodoRelativePath, data: Data(result.queue.utf8), expectedVersion: queue.version)
        ])
        return try vault.readMarkdown(relativePath: notesPath).version
    }

    /// Saves the editor text and its Todo references as one version-checked workspace
    /// transaction. Any conflict leaves the current workspace files intact.
    @discardableResult
    public func saveNotes(_ text: String, at notesPath: String,
                          expectedNotesVersion: WorkspaceFileVersion?,
                          removingItemIDs: Set<String> = []) throws -> WorkspaceFileVersion {
        let oldNotes = try vault.versionOfMarkdown(relativePath: notesPath).map { _ in
            String(decoding: try vault.readMarkdown(relativePath: notesPath).data, as: UTF8.self)
        } ?? ""
        let queue = try currentQueue()
        let result = try Self.adopt(notes: text, path: notesPath, queue: queue.text,
                                    removingItemIDs: removingItemIDs.union(Self.itemIDs(in: oldNotes, path: notesPath).subtracting(Self.itemIDs(in: text, path: notesPath))))
        try vault.replaceMarkdownTransaction([
            .init(relativePath: notesPath, data: Data(result.notes.utf8), expectedVersion: expectedNotesVersion),
            .init(relativePath: TodoItemIndex.mainTodoRelativePath, data: Data(result.queue.utf8), expectedVersion: queue.version)
        ])
        return try vault.readMarkdown(relativePath: notesPath).version
    }

    /// Prepares a Meeting artifact save so its notes and Todo projection can be
    /// published together by MeetingArtifactTransaction.
    func prepareArtifactSave(_ text: String, at notesPath: String, replacing oldNotes: String) throws ->
        (notes: String, todoReplacement: WorkspaceMarkdownReplacement?) {
        let queue = try currentQueue()
        let removedIDs = Self.itemIDs(in: oldNotes, path: notesPath)
            .subtracting(Self.itemIDs(in: text, path: notesPath))
        let result = try Self.adopt(notes: text, path: notesPath, queue: queue.text, removingItemIDs: removedIDs)
        let todoReplacement = result.queue == queue.text ? nil : WorkspaceMarkdownReplacement(
            relativePath: TodoItemIndex.mainTodoRelativePath,
            data: Data(result.queue.utf8),
            expectedVersion: queue.version
        )
        return (result.notes, todoReplacement)
    }

    /// Replaces the canonical checkbox text while retaining its identity and state metadata.
    @discardableResult
    public func updateText(item: TodoItem, text: String,
                           expectedQueueVersion: WorkspaceFileVersion) throws -> WorkspaceFileVersion {
        try update(item: item, expectedQueueVersion: expectedQueueVersion) { line, metadata in
            guard TodoMarkdownCheckbox.parse(line) != nil else { throw TodoItemMutationError.itemNotFound(item.id) }
            let lineEnding = line.hasSuffix("\r") ? "\r" : ""
            let prefix = Self.checkboxPrefix(in: line)
            let preserved = [item.dueDate.map { "due: \($0)" }, item.sourceRef].compactMap { $0 }
            let editedText = text.trimmingCharacters(in: .newlines)
            let suffix = preserved.filter { !editedText.contains($0) }
            let canonicalText = ([editedText] + suffix).filter { !$0.isEmpty }.joined(separator: " ")
            return (prefix + canonicalText + " <!-- sm-item:" + Self.encode(metadata) + " -->" + lineEnding,
                    metadata.owner == "me")
        }
    }

    /// Reassigns a note-authored item. Owners other than Me stay in the Meeting and
    /// are removed from the personal queue projection.
    @discardableResult
    public func reassign(itemID: String, to owner: String,
                         expectedQueueVersion: WorkspaceFileVersion) throws -> WorkspaceFileVersion {
        let normalizedOwner = owner.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedOwner.isEmpty else { throw TodoItemMutationError.invalidOwner(owner) }
        guard let item = try canonicalNoteItem(itemID) else { throw TodoItemMutationError.itemNotFound(itemID) }
        return try update(item: item, expectedQueueVersion: expectedQueueVersion) { line, metadata in
            let reassigned = MeetingItemMetadata(v: metadata.v, id: metadata.id, owner: normalizedOwner,
                review: metadata.review, origin: metadata.origin, legacyID: metadata.legacyID, citations: metadata.citations)
            let parsed = TodoMarkdownCheckbox.parse(line)
            guard let parsed else { throw TodoItemMutationError.itemNotFound(itemID) }
            let ending = line.hasSuffix("\r") ? "\r" : ""
            let body = Self.removingMetadata(parsed.text)
            return (Self.checkboxPrefix(in: line) + body + " <!-- sm-item:" + Self.encode(reassigned) + " -->" + ending,
                    normalizedOwner == "me")
        }
    }

    private func update(item: TodoItem, expectedQueueVersion: WorkspaceFileVersion,
                        transform: (String, MeetingItemMetadata) throws -> (line: String, isPersonal: Bool)) throws -> WorkspaceFileVersion {
        let queuePath = TodoItemIndex.mainTodoRelativePath
        let queue = try vault.readMarkdown(relativePath: queuePath)
        guard queue.version == expectedQueueVersion else {
            throw WorkspaceVaultError.conflict(relativePath: queuePath, expected: expectedQueueVersion, actual: queue.version)
        }
        guard let current = try canonicalNoteItem(item.id),
              current.rawText == item.rawText, current.status == item.status else { throw TodoItemMutationError.staleCanonicalItem(item.id) }
        let location = current.location
        let source = try vault.readMarkdown(relativePath: location.relativePath)
        var lines = String(decoding: source.data, as: UTF8.self).components(separatedBy: "\n")
        let index = current.location.lineNumber - 1
        guard lines.indices.contains(index), let metadata = TodoItemParser.metadata(in: current.rawText) else {
            throw TodoItemMutationError.itemNotFound(item.id)
        }
        let changed = try transform(lines[index], metadata)
        lines[index] = changed.line
        let updatedSource = lines.joined(separator: "\n")
        let queueLines = String(decoding: queue.data, as: UTF8.self).components(separatedBy: "\n")
        let updatedQueue: String
        if changed.isPersonal {
            updatedQueue = Self.insertingReferences([item.id], notes: updatedSource,
                path: location.relativePath, into: queueLines.joined(separator: "\n"))
        } else {
            updatedQueue = Self.removingReference(item.id, from: queueLines).joined(separator: "\n")
        }
        try vault.replaceMarkdownTransaction([
            .init(relativePath: location.relativePath, data: Data(updatedSource.utf8), expectedVersion: source.version),
            .init(relativePath: queuePath, data: Data(updatedQueue.utf8), expectedVersion: queue.version)
        ])
        return try vault.readMarkdown(relativePath: queuePath).version
    }

    private func currentQueue() throws -> (text: String, version: WorkspaceFileVersion?) {
        guard let version = try vault.versionOfMarkdown(relativePath: TodoItemIndex.mainTodoRelativePath) else {
            return ("# Todos\n\n## Queue\n\n## Done\n", nil)
        }
        return (String(decoding: try vault.readMarkdown(relativePath: TodoItemIndex.mainTodoRelativePath).data, as: UTF8.self), version)
    }

    private func canonicalNoteItem(_ id: String) throws -> TodoItem? {
        for path in try vault.markdownPaths(relativeTo: "Meetings") where (path as NSString).lastPathComponent == "my-notes.md" {
            let source = try vault.readMarkdown(relativePath: path)
            let text = String(decoding: source.data, as: UTF8.self)
            if let item = TodoItemParser().parse(markdown: text, relativePath: path).first(where: { $0.id == id }) {
                return item
            }
        }
        return nil
    }

    private static func adopt(notes: String, path: String, queue: String,
                              removingItemIDs: Set<String> = []) throws -> (notes: String, queue: String) {
        var lines = notes.components(separatedBy: "\n")
        var personalIDs: [String] = []
        var fence: Character?
        for index in lines.indices {
            let rawLine = lines[index]
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if fence == trimmed.first { fence = nil }
                else if fence == nil { fence = trimmed.first }
                continue
            }
            guard fence == nil, let checkbox = TodoMarkdownCheckbox.parse(line) else { continue }
            let metadata = TodoItemParser.metadata(in: checkbox.text) ?? MeetingItemMetadata(
                v: 1, id: UUID().uuidString.lowercased(), owner: "me", review: "approved",
                origin: "note", legacyID: nil, citations: [])
            guard UUID(uuidString: metadata.id) != nil, metadata.v == 1 else {
                throw TodoItemMutationError.invalidCanonicalMetadata(path)
            }
            let lineEnding = rawLine.hasSuffix("\r") ? "\r" : ""
            let body = removingMetadata(checkbox.text)
            lines[index] = checkboxPrefix(in: line) + body + " <!-- sm-item:" + encode(metadata) + " -->" + lineEnding
            if metadata.owner == "me", metadata.review == "approved" { personalIDs.append(metadata.id.lowercased()) }
        }
        var queueLines = queue.components(separatedBy: "\n")
        let noteItems = TodoItemParser().parse(markdown: lines.joined(separator: "\n"), relativePath: path)
        let currentIDs = Set(noteItems.map { $0.id.lowercased() })
        let nonPersonalIDs = noteItems.compactMap { item -> String? in
            guard let metadata = TodoItemParser.metadata(in: item.rawText),
                  metadata.owner != "me" || metadata.review != "approved" else { return nil }
            return item.id.lowercased()
        }
        for id in removingItemIDs.union(nonPersonalIDs) where !currentIDs.contains(id.lowercased()) || nonPersonalIDs.contains(id.lowercased()) {
            queueLines = removingReference(id, from: queueLines)
        }
        let updatedQueue = insertingReferences(personalIDs, notes: lines.joined(separator: "\n"), path: path, into: queueLines.joined(separator: "\n"))
        return (lines.joined(separator: "\n"), updatedQueue)
    }

    private static func itemIDs(in notes: String, path: String) -> Set<String> {
        Set(TodoItemParser().parse(markdown: notes, relativePath: path).compactMap {
            UUID(uuidString: $0.id)?.uuidString.lowercased()
        })
    }

    private static func insertingReferences(_ ids: [String], notes: String, path: String, into markdown: String) -> String {
        var lines = markdown.components(separatedBy: "\n")
        let existing = Set(lines.compactMap(referenceID(in:)))
        let titles = Dictionary(uniqueKeysWithValues: TodoItemParser().parse(markdown: notes, relativePath: path)
            .compactMap { item -> (String, String)? in
                guard let metadata = TodoItemParser.metadata(in: item.rawText), metadata.owner == "me", metadata.review == "approved" else { return nil }
                return (item.id.lowercased(), item.title.replacingOccurrences(of: "|", with: " "))
            })
        let newReferences = ids.filter { !existing.contains($0) }.compactMap { id in
            titles[id].map { "- [[item:\(id)|\($0)]]" }
        }
        guard !newReferences.isEmpty else { return markdown }
        let queueHeading = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == "## Queue" }
        let insertion: Int
        if let queueHeading {
            var next = queueHeading + 1
            while lines.indices.contains(next), lines[next].trimmingCharacters(in: .whitespaces).isEmpty { next += 1 }
            insertion = next
        } else {
            if !lines.isEmpty, lines.last == "" { lines.removeLast() }
            if !lines.isEmpty { lines.append("") }
            lines.append("## Queue")
            insertion = lines.count
        }
        lines.insert(contentsOf: newReferences, at: insertion)
        return lines.joined(separator: "\n")
    }

    private static func referenceID(in line: String) -> String? {
        guard let range = line.range(of: #"\[\[item:([0-9a-fA-F-]{36})\|"#, options: .regularExpression) else { return nil }
        let value = line[range].dropFirst("[[item:".count).dropLast(1)
        return UUID(uuidString: String(value))?.uuidString.lowercased()
    }

    private static func removingReference(_ id: String, from lines: [String]) -> [String] {
        lines.filter { referenceID(in: $0) != id.lowercased() }
    }

    private static func removingMetadata(_ text: String) -> String {
        // Only consume the ASCII separator before metadata. Unicode line/paragraph
        // separators can be intentional content inside a checkbox title.
        text.replacingOccurrences(of: #"[ \t]*<!-- sm-item:.* -->$"#, with: "", options: .regularExpression)
    }

    private static func checkboxPrefix(in line: String) -> String {
        line.range(of: #"^[\s]*[-*]\s+\[[ xXbBcC]\]\s+"#, options: .regularExpression)
            .map { String(line[$0]) } ?? "- [ ] "
    }

    private static func encode(_ metadata: MeetingItemMetadata) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: (try? encoder.encode(metadata)) ?? Data(), as: UTF8.self)
    }
}
