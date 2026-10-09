import Foundation

public enum ActivityStatus: String, CaseIterable, Equatable {
    case active
    case blocked
    case completed
    case canceled

    public var isTerminal: Bool { self == .completed || self == .canceled }
}

public struct ActivityItem: Equatable {
    public let title: String
    public let project: String
    public let status: ActivityStatus
    public let startedAt: String
    public let endedAt: String?
    public let goal: String
    public let notes: String
    public let outputs: [String]
    public let linkedTodos: [String]
    public let activityLog: [String]
    public let relativePath: String
    public let version: WorkspaceFileVersion

    public init(
        title: String,
        project: String,
        status: ActivityStatus,
        startedAt: String,
        endedAt: String?,
        goal: String,
        notes: String,
        outputs: [String],
        linkedTodos: [String],
        activityLog: [String],
        relativePath: String,
        version: WorkspaceFileVersion
    ) {
        self.title = title
        self.project = project
        self.status = status
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.goal = goal
        self.notes = notes
        self.outputs = outputs
        self.linkedTodos = linkedTodos
        self.activityLog = activityLog
        self.relativePath = relativePath
        self.version = version
    }
}

public struct ActivityProject: Equatable {
    public let name: String
    public let relativePath: String

    public init(name: String, relativePath: String) {
        self.name = name
        self.relativePath = relativePath
    }
}

public struct ActivityDraft: Equatable {
    public let title: String
    public let project: String
    public let goal: String

    public init(title: String, project: String = "General", goal: String = "") {
        self.title = title
        self.project = project
        self.goal = goal
    }
}

public enum ActivityServiceError: Error, Equatable {
    case invalidTitle
    case projectNotFound(String)
    case invalidActivityFile(String)
}

/// Application service for canonical, file-backed Activity Items.
public final class ActivityService {
    private let workspaceRootURL: URL
    private let vault: WorkspaceVault
    private let fileManager: FileManager
    private let now: () -> String

    public init(
        workspaceRootURL: URL,
        vault: WorkspaceVault,
        fileManager: FileManager = .default,
        now: @escaping () -> String = ActivityService.systemTimestamp
    ) {
        self.workspaceRootURL = workspaceRootURL.standardizedFileURL
        self.vault = vault
        self.fileManager = fileManager
        self.now = now
    }

    public func projects() throws -> [ActivityProject] {
        let directory = workspaceRootURL.appendingPathComponent("Projects", isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let urls = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        return try urls.compactMap { url in
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true, url.pathExtension.lowercased() == "md" else { return nil }
            let relativePath = "Projects/" + url.lastPathComponent
            let markdown = try String(contentsOf: url)
            let fallback = url.deletingPathExtension().lastPathComponent
            return ActivityProject(name: Self.firstHeading(in: markdown) ?? fallback, relativePath: relativePath)
        }.sorted {
            if $0.name == "General" { return true }
            if $1.name == "General" { return false }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    @discardableResult
    public func create(_ draft: ActivityDraft) throws -> ActivityItem {
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ActivityServiceError.invalidTitle }
        let requestedProject = draft.project.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = try projects().first {
            $0.name.caseInsensitiveCompare(requestedProject.isEmpty ? "General" : requestedProject) == .orderedSame
                || URL(fileURLWithPath: $0.relativePath).deletingPathExtension().lastPathComponent.caseInsensitiveCompare(requestedProject) == .orderedSame
        }
        guard let owner = project else {
            throw ActivityServiceError.projectNotFound(requestedProject.isEmpty ? "General" : requestedProject)
        }

        let timestamp = now()
        let day = String(timestamp.prefix(10))
        let components = day.split(separator: "-")
        let year = components.count > 0 ? String(components[0]) : "unknown"
        let month = components.count > 1 ? String(components[1]) : "unknown"
        let base = "\(day)-\(Self.slug(title))"
        var relativePath = "Activities/\(year)/\(month)/\(base).md"
        var suffix = 2
        while try vault.versionOfMarkdown(relativePath: relativePath) != nil {
            relativePath = "Activities/\(year)/\(month)/\(base)-\(suffix).md"
            suffix += 1
        }

        let markdown = Self.newMarkdown(title: title, project: owner.name, goal: draft.goal, timestamp: timestamp)
        let projectRead = try vault.readMarkdown(relativePath: owner.relativePath)
        let projectMarkdown = String(data: projectRead.data, encoding: .utf8) ?? ""
        let linkedProject = Self.addingActivityLink(
            "[[\(relativePath)|\(title)]]",
            to: projectMarkdown
        )
        try vault.replaceMarkdownTransaction([
            WorkspaceMarkdownReplacement(relativePath: relativePath, data: Data(markdown.utf8), expectedVersion: nil),
            WorkspaceMarkdownReplacement(relativePath: owner.relativePath, data: Data(linkedProject.utf8), expectedVersion: projectRead.version)
        ])
        return try read(relativePath: relativePath)
    }

    public func read(relativePath: String) throws -> ActivityItem {
        let read = try vault.readMarkdown(relativePath: relativePath)
        let markdown = String(data: read.data, encoding: .utf8) ?? ""
        guard Self.frontmatterValue("stillmatter_type", in: markdown)?.caseInsensitiveCompare("activity") == .orderedSame,
              let statusText = Self.frontmatterValue("status", in: markdown),
              let status = ActivityStatus(rawValue: statusText.lowercased()),
              let project = Self.frontmatterValue("project", in: markdown), !project.isEmpty,
              let startedAt = Self.frontmatterValue("started_at", in: markdown),
              let title = Self.firstHeading(in: markdown) else {
            throw ActivityServiceError.invalidActivityFile(relativePath)
        }
        return ActivityItem(
            title: title,
            project: project,
            status: status,
            startedAt: startedAt,
            endedAt: Self.frontmatterValue("ended_at", in: markdown),
            goal: Self.sectionText("Goal", in: markdown),
            notes: Self.sectionText("Notes", in: markdown),
            outputs: Self.listItems(in: "Outputs", markdown: markdown),
            linkedTodos: Self.listItems(in: "Linked todos", markdown: markdown),
            activityLog: Self.listItems(in: "Activity log", markdown: markdown),
            relativePath: relativePath,
            version: read.version
        )
    }

    public func all() throws -> [ActivityItem] {
        let directory = workspaceRootURL.appendingPathComponent("Activities", isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path),
              let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var paths: [String] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true, url.pathExtension.lowercased() == "md", url.lastPathComponent.lowercased() != "readme.md" else { continue }
            let markdown = try String(contentsOf: url)
            guard Self.frontmatterValue("stillmatter_type", in: markdown)?.caseInsensitiveCompare("activity") == .orderedSame else { continue }
            let root = workspaceRootURL.path.hasSuffix("/") ? workspaceRootURL.path : workspaceRootURL.path + "/"
            guard url.standardizedFileURL.path.hasPrefix(root) else { continue }
            paths.append(String(url.standardizedFileURL.path.dropFirst(root.count)))
        }
        return try paths.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map(read)
    }

    public func active() throws -> [ActivityItem] {
        try all().filter { $0.status == .active }
    }

    @discardableResult
    public func updateStatus(_ item: ActivityItem, status: ActivityStatus) throws -> ActivityItem {
        let read = try vault.readMarkdown(relativePath: item.relativePath)
        guard read.version == item.version else {
            throw WorkspaceVaultError.conflict(relativePath: item.relativePath, expected: item.version, actual: read.version)
        }
        var markdown = String(data: read.data, encoding: .utf8) ?? ""
        markdown = try Self.replacingFrontmatterValue("status", with: status.rawValue, in: markdown, relativePath: item.relativePath)
        markdown = Self.replacingSectionText("Status", with: status.rawValue.capitalized, in: markdown)
        if status.isTerminal {
            markdown = try Self.replacingFrontmatterValue("ended_at", with: now(), in: markdown, relativePath: item.relativePath)
        } else {
            markdown = Self.removingFrontmatterValue("ended_at", in: markdown)
        }
        _ = try vault.writeMarkdown(Data(markdown.utf8), relativePath: item.relativePath, expectedVersion: item.version)
        return try self.read(relativePath: item.relativePath)
    }

    @discardableResult
    public func appendOutput(_ text: String, to item: ActivityItem) throws -> ActivityItem {
        try append(text, toSection: "Outputs", item: item)
    }

    @discardableResult
    public func appendLog(_ text: String, to item: ActivityItem) throws -> ActivityItem {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return try append("\(now()) — \(value)", toSection: "Activity log", item: item)
    }

    private func append(_ text: String, toSection section: String, item: ActivityItem) throws -> ActivityItem {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return item }
        let read = try vault.readMarkdown(relativePath: item.relativePath)
        guard read.version == item.version else {
            throw WorkspaceVaultError.conflict(relativePath: item.relativePath, expected: item.version, actual: read.version)
        }
        let markdown = String(data: read.data, encoding: .utf8) ?? ""
        let updated = Self.appendingListItem(value, toSection: section, in: markdown)
        _ = try vault.writeMarkdown(Data(updated.utf8), relativePath: item.relativePath, expectedVersion: item.version)
        return try self.read(relativePath: item.relativePath)
    }

    public static func systemTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date())
    }

    private static func newMarkdown(title: String, project: String, goal: String, timestamp: String) -> String {
        """
        ---
        stillmatter_type: activity
        status: active
        project: \(project)
        started_at: \(timestamp)
        ---
        # \(title)

        ## Goal

        \(goal.trimmingCharacters(in: .whitespacesAndNewlines))

        ## Status

        Active

        ## Notes

        ## Outputs

        ## Linked todos

        ## Activity log
        """ + "\n"
    }

    private static func slug(_ value: String) -> String {
        let lower = value.lowercased().folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let slug = lower.replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "activity" : slug
    }

    private static func firstHeading(in markdown: String) -> String? {
        markdown.components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("# ") ? String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces) : nil
        }.first
    }

    private static func frontmatterRange(in lines: [String]) -> ClosedRange<Int>? {
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return nil }
        return 0...end
    }

    private static func frontmatterValue(_ key: String, in markdown: String) -> String? {
        let lines = markdown.components(separatedBy: .newlines)
        guard let range = frontmatterRange(in: lines) else { return nil }
        let prefix = key.lowercased() + ":"
        guard let line = lines[range].dropFirst().dropLast().first(where: {
            $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix(prefix)
        }) else { return nil }
        return String(line.trimmingCharacters(in: .whitespaces).dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    private static func replacingFrontmatterValue(_ key: String, with value: String, in markdown: String, relativePath: String) throws -> String {
        var lines = markdown.components(separatedBy: .newlines)
        guard let range = frontmatterRange(in: lines) else { throw ActivityServiceError.invalidActivityFile(relativePath) }
        let prefix = key.lowercased() + ":"
        if let index = lines[range].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix(prefix) }) {
            lines[index] = "\(key): \(value)"
        } else {
            lines.insert("\(key): \(value)", at: range.upperBound)
        }
        return lines.joined(separator: "\n")
    }

    private static func removingFrontmatterValue(_ key: String, in markdown: String) -> String {
        var lines = markdown.components(separatedBy: .newlines)
        guard let range = frontmatterRange(in: lines) else { return markdown }
        let prefix = key.lowercased() + ":"
        if let index = lines[range].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix(prefix) }) {
            lines.remove(at: index)
        }
        return lines.joined(separator: "\n")
    }

    private static func sectionLines(_ title: String, in markdown: String) -> [String] {
        let lines = markdown.components(separatedBy: .newlines)
        guard let heading = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "## \(title)" }) else { return [] }
        let end = lines[(heading + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("## ") }) ?? lines.count
        return Array(lines[(heading + 1)..<end])
    }

    private static func sectionText(_ title: String, in markdown: String) -> String {
        sectionLines(title, in: markdown).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replacingSectionText(_ title: String, with value: String, in markdown: String) -> String {
        var lines = markdown.components(separatedBy: .newlines)
        guard let heading = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "## \(title)" }) else { return markdown }
        let end = lines[(heading + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("## ") }) ?? lines.count
        lines.replaceSubrange((heading + 1)..<end, with: ["", value, ""])
        return lines.joined(separator: "\n")
    }

    private static func listItems(in title: String, markdown: String) -> [String] {
        sectionLines(title, in: markdown).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- ") else { return nil }
            return String(trimmed.dropFirst(2))
        }
    }

    private static func appendingListItem(_ item: String, toSection title: String, in markdown: String) -> String {
        var lines = markdown.components(separatedBy: .newlines)
        if let heading = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "## \(title)" }) {
            let end = lines[(heading + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("## ") }) ?? lines.count
            var insertion = end
            while insertion > heading + 1 && lines[insertion - 1].trimmingCharacters(in: .whitespaces).isEmpty { insertion -= 1 }
            lines.insert("- \(item)", at: insertion)
        } else {
            while lines.last?.isEmpty == true { lines.removeLast() }
            lines.append(contentsOf: ["", "## \(title)", "", "- \(item)", ""])
        }
        return lines.joined(separator: "\n")
    }

    private static func addingActivityLink(_ link: String, to markdown: String) -> String {
        if markdown.contains(link) { return markdown }
        return appendingListItem(link, toSection: "Activities", in: markdown)
    }
}
