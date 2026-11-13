import Foundation

/// Reads and patches canonical checkboxes, never their Todo reference labels.
/// Every write is version checked and published through the recoverable file plan.
public final class ItemTagStore {
    private struct Record { let id: String; let path: String; let line: String }
    private static let catalogPath = "Tags/tags.json"
    private let vault: WorkspaceVault
    private let transaction: MeetingArtifactTransaction
    public convenience init(vault: WorkspaceVault) { self.init(vault: vault, checkpoint: { _ in }) }
    init(vault: WorkspaceVault, checkpoint: @escaping (Int) throws -> Void) {
        self.vault = vault
        transaction = MeetingArtifactTransaction(vault: vault, identity: "workspace-tags", checkpoint: checkpoint)
    }
    func recover() throws { try transaction.recover() }
    public func tags() throws -> [String] {
        try transaction.recover()
        return Set(try records().flatMap { ItemTags.read($0.line) } + catalog().tags).subtracting(ItemTags.reserved).sorted()
    }
    public func selection(itemID: String) throws -> ItemTagSelection {
        try transaction.recover()
        guard let record = try records().first(where: { $0.id == itemID }) else { throw TodoItemMutationError.itemNotFound(itemID) }
        return ItemTagSelection(itemID: itemID, tags: ItemTags.read(record.line), catalog: try tags())
    }
    public func applyAIAdditions(_ additions: [AIItemTagAddition]) throws {
        try transaction.recover()
        let replacements = try prepareAIAdditions(additions)
        try transaction.publish(replacements, dependencies: readOnlyChecks(for: Set(replacements.map(\.relativePath))))
    }
    func prepareAIAdditions(_ additions: [AIItemTagAddition], allowedPaths: Set<String>? = nil) throws -> [WorkspaceMarkdownReplacement] {
        guard !additions.isEmpty else { return [] }
        let current = try records()
        var changes: [(Record, [String])] = []
        for addition in additions {
            try ItemTags.validate(addition.tags)
            guard UUID(uuidString: addition.itemID) != nil,
                  let record = current.first(where: { $0.id == addition.itemID.lowercased() }),
                  allowedPaths == nil || allowedPaths!.contains(record.path) else {
                throw TodoItemMutationError.itemNotFound(addition.itemID)
            }
            changes.append((record, ItemTags.read(record.line) + addition.tags))
        }
        return try replacements(changes, additive: true)
    }
    public func mutate(_ mutation: ItemTagMutation) throws {
        try transaction.recover()
        let current = try records()
        let catalog = try catalog()
        var names = Set(catalog.tags + current.flatMap { ItemTags.read($0.line) }).subtracting(ItemTags.reserved)
        var changes: [(Record, [String])] = []
        switch mutation {
        case let .set(id, expected, tags):
            try ItemTags.validate(tags)
            guard let record = current.first(where: { $0.id == id }) else { throw TodoItemMutationError.itemNotFound(id) }
            let existing = ItemTags.read(record.line)
            guard existing == expected else { throw TodoItemMutationError.staleCanonicalItem(id) }
            changes = [(record, existing.filter { ItemTags.reserved.contains($0) } + tags)]
            names.formUnion(tags)
        case let .create(tag):
            try ItemTags.validate([tag]); names.insert(tag)
        case let .rename(tag, new):
            try ItemTags.validate([tag, new])
            guard names.contains(tag) else { throw MeetingManagementError.notFound(tag) }
            names.remove(tag); names.insert(new)
            changes = current.compactMap { record in
                let tags = ItemTags.read(record.line)
                return tags.contains(tag) ? (record, tags.map { $0 == tag ? new : $0 }) : nil
            }
        case let .delete(tag):
            try ItemTags.validate([tag]); names.remove(tag)
            changes = current.compactMap { record in
                let tags = ItemTags.read(record.line)
                return tags.contains(tag) ? (record, tags.filter { $0 != tag }) : nil
            }
        }
        var replacements = try replacements(changes)
        let data = try JSONEncoder().encode(names.sorted())
        replacements.append(.init(relativePath: Self.catalogPath, data: data, expectedVersion: catalog.version))
        try transaction.publish(replacements, dependencies: readOnlyChecks(for: Set(changes.map { $0.0.path })))
    }
    private func catalog() throws -> (tags: [String], version: WorkspaceFileVersion?) {
        guard try vault.versionOfMarkdown(relativePath: Self.catalogPath) != nil else { return ([], nil) }
        let source = try vault.readMarkdown(relativePath: Self.catalogPath)
        let tags = try JSONDecoder().decode([String].self, from: source.data)
        try ItemTags.validate(tags)
        return (tags, source.version)
    }
    private func readOnlyChecks(for paths: Set<String>) throws -> [WorkspaceMarkdownReplacement] {
        try paths.filter { $0.hasPrefix("Meetings/") }.sorted().map { path in
            let archive = (path as NSString).deletingLastPathComponent + "/archive.json"
            let version = try vault.versionOfMarkdown(relativePath: archive)
            let data = try version.map { _ in try vault.readMarkdown(relativePath: archive).data }
            if let data, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], object["archived"] as? Bool == true {
                throw MeetingManagementError.retryRejected("Tags in archived Meetings are read-only. This global change was not saved.")
            }
            return WorkspaceMarkdownReplacement(relativePath: archive, data: data ?? Data(), expectedVersion: version)
        }.reduce(into: []) { result, entry in
            if !result.contains(where: { $0.relativePath == entry.relativePath }) { result.append(entry) }
        }
    }
    private func records() throws -> [Record] {
        var result: [Record] = []
        var seen: Set<String> = []
        for path in try vault.markdownPaths().sorted() {
            let source = try vault.readMarkdown(relativePath: path)
            var fence: Character?
            for (index, line) in String(decoding: source.data, as: UTF8.self).components(separatedBy: "\n").enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                    if fence == trimmed.first { fence = nil } else if fence == nil { fence = trimmed.first }
                    continue
                }
                guard fence == nil, TodoMarkdownCheckbox.parse(line) != nil else { continue }
                let metadata = TodoItemParser.metadata(in: line.hasSuffix("\r") ? String(line.dropLast()) : line)
                if line.contains("<!-- sm-item:"), metadata == nil { throw TodoItemMutationError.invalidCanonicalMetadata(path) }
                let id = metadata?.id.lowercased() ?? "\(path):\(index + 1)"
                guard seen.insert(id).inserted else { throw TodoItemMutationError.duplicateIdentity(id) }
                result.append(Record(id: id, path: path, line: line))
            }
        }
        return result
    }
    private func replacements(_ changes: [(Record, [String])], additive: Bool = false) throws -> [WorkspaceMarkdownReplacement] {
        try Set(changes.map { $0.0.path }).sorted().compactMap { path in
            let source = try vault.readMarkdown(relativePath: path)
            var lines = String(decoding: source.data, as: UTF8.self).components(separatedBy: "\n")
            for group in Dictionary(grouping: changes.filter { $0.0.path == path }, by: { $0.0.id }).values {
                let record = group[0].0
                let tags = group.flatMap { $0.1 }
                guard let index = lines.firstIndex(of: record.line) else { throw TodoItemMutationError.staleCanonicalItem(record.id) }
                lines[index] = ItemTags.replacing(in: lines[index], with: (additive ? ItemTags.read(lines[index]) : []) + tags)
            }
            let data = Data(lines.joined(separator: "\n").utf8)
            return data == source.data ? nil : .init(relativePath: path, data: data, expectedVersion: source.version)
        }
    }
}
