import Foundation

public enum TodoStatus: Equatable {
    case open
    case done
    case blocked
    case canceled

    var isTerminal: Bool { self == .done || self == .canceled }
}

struct TodoMarkdownCheckbox {
    let indentation: Int
    let status: TodoStatus
    let text: String

    static func parse(_ line: String) -> TodoMarkdownCheckbox? {
        let pattern = #"^(\s*)[-*]\s+\[([ xXbBcC])\]\s+(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let whitespaceRange = Range(match.range(at: 1), in: line),
              let markerRange = Range(match.range(at: 2), in: line),
              let textRange = Range(match.range(at: 3), in: line),
              let status = status(for: String(line[markerRange])) else { return nil }
        return TodoMarkdownCheckbox(
            indentation: indentation(of: String(line[whitespaceRange])),
            status: status,
            text: String(line[textRange])
        )
    }

    static func indentation(of line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { count, character in
            count + (character == "\t" ? 4 : 1)
        }
    }

    private static func status(for marker: String) -> TodoStatus? {
        switch marker {
        case " ": return .open
        case "x", "X": return .done
        case "B", "b": return .blocked
        case "C", "c": return .canceled
        default: return nil
        }
    }
}

public struct TodoSourceLocation: Equatable {
    public let relativePath: String
    public let lineNumber: Int

    public init(relativePath: String, lineNumber: Int) {
        self.relativePath = relativePath
        self.lineNumber = lineNumber
    }
}

public struct TodoItem: Equatable {
    public let id: String
    public let title: String
    public let rawText: String
    public let status: TodoStatus
    public let dueDate: String?
    public let sourceRef: String?
    public let location: TodoSourceLocation
    public let section: String?
    public let indentation: Int
    public let parentID: String?
    public var comments: [String]

    public init(
        id: String,
        title: String,
        rawText: String,
        status: TodoStatus,
        dueDate: String?,
        sourceRef: String?,
        location: TodoSourceLocation,
        section: String?,
        indentation: Int,
        parentID: String?,
        comments: [String] = []
    ) {
        self.id = id
        self.title = title
        self.rawText = rawText
        self.status = status
        self.dueDate = dueDate
        self.sourceRef = sourceRef
        self.location = location
        self.section = section
        self.indentation = indentation
        self.parentID = parentID
        self.comments = comments
    }

    public var isFromMainTodoFile: Bool {
        location.relativePath.caseInsensitiveCompare(TodoItemIndex.mainTodoRelativePath) == .orderedSame
    }
    public var isNested: Bool { parentID != nil }
}

public struct TodoTaskViews: Equatable {
    public let queue: [TodoItem]
    public let done: [TodoItem]
    public let blocked: [TodoItem]
    public let overdue: [TodoItem]
    public let allIndexed: [TodoItem]

    public init(
        queue: [TodoItem],
        done: [TodoItem],
        blocked: [TodoItem],
        overdue: [TodoItem],
        allIndexed: [TodoItem]
    ) {
        self.queue = queue
        self.done = done
        self.blocked = blocked
        self.overdue = overdue
        self.allIndexed = allIndexed
    }

    public func sourceFiltered(_ query: String) -> [TodoItem] {
        let normalizedQuery = query.lowercased()
        return allIndexed.filter { item in
            item.location.relativePath.lowercased().contains(normalizedQuery)
                || (item.sourceRef?.lowercased().contains(normalizedQuery) ?? false)
        }
    }
}

public struct TodoItemParser {
    public init() {}

    public func parse(markdown: String, relativePath: String) -> [TodoItem] {
        var items: [TodoItem] = []
        var stack: [(indentation: Int, id: String)] = []
        var currentSection: String?

        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for (index, line) in lines.enumerated() {
            if let heading = Self.headingTitle(in: line) {
                currentSection = heading
                stack.removeAll()
                continue
            }

            if let checkbox = Self.checkbox(in: line) {
                while let last = stack.last, last.indentation >= checkbox.indentation {
                    stack.removeLast()
                }

                let lineNumber = index + 1
                let id = "\(relativePath):\(lineNumber)"
                let rawText = checkbox.text.trimmingCharacters(in: .whitespaces)
                let item = TodoItem(
                    id: id,
                    title: Self.displayTitle(from: rawText),
                    rawText: rawText,
                    status: checkbox.status,
                    dueDate: Self.firstMatch(in: rawText, pattern: #"\bdue:\s*(\d{4}-\d{2}-\d{2})\b"#),
                    sourceRef: Self.firstMatch(in: rawText, pattern: #"(\[\[[^\]]+\]\])"#),
                    location: TodoSourceLocation(relativePath: relativePath, lineNumber: lineNumber),
                    section: currentSection,
                    indentation: checkbox.indentation,
                    parentID: stack.last?.id
                )
                items.append(item)
                stack.append((checkbox.indentation, id))
                continue
            }

            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let indentation = Self.leadingWhitespaceCount(in: line)
            guard let parent = stack.last(where: { $0.indentation < indentation }),
                  let parentIndex = items.firstIndex(where: { $0.id == parent.id }) else { continue }
            items[parentIndex].comments.append(line.trimmingCharacters(in: .whitespaces))
        }

        return items
    }

    private static func checkbox(in line: String) -> (indentation: Int, status: TodoStatus, text: String)? {
        guard let checkbox = TodoMarkdownCheckbox.parse(line) else { return nil }
        return (checkbox.indentation, checkbox.status, checkbox.text)
    }

    private static func headingTitle(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return nil }
        return trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
    }

    private static func displayTitle(from rawText: String) -> String {
        var title = rawText
        title = title.replacingOccurrences(of: #"\bdue:\s*\d{4}-\d{2}-\d{2}\b"#, with: "", options: .regularExpression)
        title = title.replacingOccurrences(of: #"\[\[[^\]]+\]\]"#, with: "", options: .regularExpression)
        return title.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    private static func firstMatch(in value: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range])
    }

    private static func leadingWhitespaceCount(in line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { count, character in
            count + (character == "\t" ? 4 : 1)
        }
    }
}

public enum TodoItemMutationError: Error, Equatable {
    case itemNotFound(String)
}

public struct TodoItemDraft: Equatable {
    public let title: String
    public let dueDate: String?
    public let sourceRefs: [String]

    public init(title: String, dueDate: String? = nil, sourceRefs: [String] = []) {
        self.title = title
        self.dueDate = dueDate
        self.sourceRefs = sourceRefs
    }
}

public final class TodoItemMutator {
    private let vault: WorkspaceVault
    private let today: () -> String

    public init(vault: WorkspaceVault, today: @escaping () -> String = TodoItemMutator.systemToday) {
        self.vault = vault
        self.today = today
    }

    public func createInQueue(
        title: String,
        dueDate: String? = nil,
        sourceRef: String? = nil,
        expectedVersion: WorkspaceFileVersion?
    ) throws -> WorkspaceFileVersion {
        try createInQueue(
            [TodoItemDraft(title: title, dueDate: dueDate, sourceRefs: sourceRef.map { [$0] } ?? [])],
            expectedVersion: expectedVersion
        )
    }

    public func createInQueue(
        _ items: [TodoItemDraft],
        expectedVersion: WorkspaceFileVersion?
    ) throws -> WorkspaceFileVersion {
        let markdown = try readMainTodoMarkdown()
        var lines = Self.lines(from: markdown)
        let itemLines = items.map {
            "- [ ] " + Self.todoText(title: $0.title, dueDate: $0.dueDate, sourceRefs: $0.sourceRefs)
        }
        let queueIndex = Self.sectionHeadingIndex("Queue", in: lines)
        let insertionIndex: Int
        if let queueIndex = queueIndex {
            insertionIndex = Self.firstContentIndex(afterHeadingAt: queueIndex, in: lines)
        } else {
            if !lines.isEmpty, lines.last == "" { lines.removeLast() }
            if !lines.isEmpty { lines.append("") }
            lines.append("## Queue")
            lines.append("")
            insertionIndex = lines.count
        }
        lines.insert(contentsOf: itemLines, at: insertionIndex)
        return try writeMainTodoMarkdown(Self.markdown(from: lines), expectedVersion: expectedVersion)
    }

    public func updateStatus(item: TodoItem, status: TodoStatus, expectedVersion: WorkspaceFileVersion) throws -> WorkspaceFileVersion {
        let markdown = try readMainTodoMarkdown()
        var lines = Self.lines(from: markdown)
        let lineIndex = item.location.lineNumber - 1
        guard lines.indices.contains(lineIndex) else { throw TodoItemMutationError.itemNotFound(item.id) }

        if status == .done {
            return try moveItemToDone(item: item, lineIndex: lineIndex, lines: &lines, expectedVersion: expectedVersion)
        }

        lines[lineIndex] = Self.replacingCheckboxMarker(in: lines[lineIndex], with: Self.marker(for: status))
        return try writeMainTodoMarkdown(Self.markdown(from: lines), expectedVersion: expectedVersion)
    }

    public func updateDueDate(item: TodoItem, dueDate: String?, expectedVersion: WorkspaceFileVersion) throws -> WorkspaceFileVersion {
        let markdown = try readMainTodoMarkdown()
        var lines = Self.lines(from: markdown)
        let lineIndex = item.location.lineNumber - 1
        guard lines.indices.contains(lineIndex) else { throw TodoItemMutationError.itemNotFound(item.id) }
        lines[lineIndex] = Self.replacingDueDate(in: lines[lineIndex], with: dueDate)
        return try writeMainTodoMarkdown(Self.markdown(from: lines), expectedVersion: expectedVersion)
    }

    private func moveItemToDone(
        item: TodoItem,
        lineIndex: Int,
        lines: inout [String],
        expectedVersion: WorkspaceFileVersion
    ) throws -> WorkspaceFileVersion {
        let completionDate = today()
        let blockRange = Self.itemBlockRange(startingAt: lineIndex, indentation: item.indentation, in: lines)
        var block = Self.removingLeadingColumns(item.indentation, from: Array(lines[blockRange]))
        block[0] = Self.replacingCheckboxMarker(in: block[0], with: "x")
        block[0] = Self.appendingCompletionDate(to: block[0], date: completionDate)
        lines.removeSubrange(blockRange)
        Self.removeExtraBlankLinesAroundRemoval(at: blockRange.lowerBound, in: &lines)
        Self.insertDoneBlock(block, date: completionDate, in: &lines)
        return try writeMainTodoMarkdown(Self.markdown(from: lines), expectedVersion: expectedVersion)
    }

    private func readMainTodoMarkdown() throws -> String {
        let read = try vault.readMarkdown(relativePath: TodoItemIndex.mainTodoRelativePath)
        return String(data: read.data, encoding: .utf8) ?? ""
    }

    private func writeMainTodoMarkdown(_ markdown: String, expectedVersion: WorkspaceFileVersion?) throws -> WorkspaceFileVersion {
        try vault.writeMarkdown(Data(markdown.utf8), relativePath: TodoItemIndex.mainTodoRelativePath, expectedVersion: expectedVersion)
    }

    public static func systemToday() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private static func todoText(title: String, dueDate: String?, sourceRefs: [String]) -> String {
        ([title, dueDate.map { "due: \($0)" }].compactMap { $0 } + sourceRefs).joined(separator: " ")
    }

    private static func lines(from markdown: String) -> [String] {
        markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private static func markdown(from lines: [String]) -> String {
        var normalized = lines
        if normalized.last != "" { normalized.append("") }
        return normalized.joined(separator: "\n")
    }

    private static func sectionHeadingIndex(_ title: String, in lines: [String]) -> Int? {
        lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == "## \(title)" }
    }

    private static func firstContentIndex(afterHeadingAt headingIndex: Int, in lines: [String]) -> Int {
        var index = headingIndex + 1
        while lines.indices.contains(index), lines[index].trimmingCharacters(in: .whitespaces).isEmpty {
            index += 1
        }
        return index
    }

    private static func marker(for status: TodoStatus) -> String {
        switch status {
        case .open: return " "
        case .done: return "x"
        case .blocked: return "B"
        case .canceled: return "C"
        }
    }

    private static func replacingCheckboxMarker(in line: String, with marker: String) -> String {
        line.replacingOccurrences(of: #"^([\s]*[-*]\s+\[)[ xXbBcC](\]\s+)"#, with: "$1\(marker)$2", options: .regularExpression)
    }

    private static func replacingDueDate(in line: String, with dueDate: String?) -> String {
        let stripped = line.replacingOccurrences(of: #"\s*\bdue:\s*\d{4}-\d{2}-\d{2}\b"#, with: "", options: .regularExpression)
        guard let dueDate = dueDate else { return stripped }
        return stripped + " due: \(dueDate)"
    }

    private static func appendingCompletionDate(to line: String, date: String) -> String {
        if line.range(of: #"\bdone:\s*\d{4}-\d{2}-\d{2}\b"#, options: .regularExpression) != nil { return line }
        return line + " done: \(date)"
    }

    private static func itemBlockRange(startingAt start: Int, indentation: Int, in lines: [String]) -> Range<Int> {
        var end = start + 1
        while lines.indices.contains(end) {
            let line = lines[end]
            if headingTitle(in: line) != nil { break }
            if line.trimmingCharacters(in: .whitespaces).isEmpty,
               lines.indices.contains(end + 1),
               headingTitle(in: lines[end + 1]) != nil { break }
            if let checkbox = checkboxIndentation(in: line), checkbox <= indentation { break }
            end += 1
        }
        return start..<end
    }

    private static func insertDoneBlock(_ block: [String], date: String, in lines: inout [String]) {
        if sectionHeadingIndex("Done", in: lines) == nil {
            if !lines.isEmpty, lines.last == "" { lines.removeLast() }
            if !lines.isEmpty { lines.append("") }
            lines.append("## Done")
            lines.append("")
        }
        let doneIndex = sectionHeadingIndex("Done", in: lines)!
        let doneEndIndex = nextLevelTwoHeadingIndex(after: doneIndex, in: lines) ?? lines.count
        if let dateHeadingIndex = (doneIndex + 1..<doneEndIndex).first(where: {
            lines[$0].trimmingCharacters(in: .whitespaces) == "### \(date)"
        }) {
            let insertionIndex = firstContentIndex(afterHeadingAt: dateHeadingIndex, in: lines)
            lines.insert(contentsOf: block + [""], at: insertionIndex)
            return
        }

        var firstDoneContentIndex = doneIndex + 1
        while lines.indices.contains(firstDoneContentIndex), lines[firstDoneContentIndex].trimmingCharacters(in: .whitespaces).isEmpty {
            firstDoneContentIndex += 1
        }
        let prefix = lines.indices.contains(doneIndex + 1) && lines[doneIndex + 1].trimmingCharacters(in: .whitespaces).isEmpty ? [] : [""]
        lines.insert(contentsOf: prefix + ["### \(date)", ""] + block + [""], at: firstDoneContentIndex)
    }

    private static func nextLevelTwoHeadingIndex(after index: Int, in lines: [String]) -> Int? {
        guard index + 1 < lines.count else { return nil }
        return (index + 1..<lines.count).first { lineIndex in
            let trimmed = lines[lineIndex].trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("## ")
        }
    }

    private static func removingLeadingColumns(_ columns: Int, from lines: [String]) -> [String] {
        guard columns > 0 else { return lines }
        return lines.map { line in
            var remaining = columns
            var index = line.startIndex
            while remaining > 0, index < line.endIndex {
                if line[index] == " " {
                    remaining -= 1
                    index = line.index(after: index)
                } else if line[index] == "\t" {
                    remaining -= 4
                    index = line.index(after: index)
                } else {
                    break
                }
            }
            return String(line[index...])
        }
    }

    private static func removeExtraBlankLinesAroundRemoval(at index: Int, in lines: inout [String]) {
        guard index > 0, lines.indices.contains(index) else { return }
        while lines.indices.contains(index), lines[index].isEmpty, lines[index - 1].isEmpty {
            lines.remove(at: index)
        }
    }

    private static func checkboxIndentation(in line: String) -> Int? {
        TodoMarkdownCheckbox.parse(line)?.indentation
    }

    private static func headingTitle(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return nil }
        return String(trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces))
    }
}

public final class TodoItemIndex {
    public static let mainTodoRelativePath = "Todos/todo.md"

    private let workspaceRootURL: URL
    private let fileManager: FileManager
    private let parser: TodoItemParser

    public init(workspaceRootURL: URL, fileManager: FileManager = .default, parser: TodoItemParser = TodoItemParser()) {
        self.workspaceRootURL = workspaceRootURL.standardizedFileURL
        self.fileManager = fileManager
        self.parser = parser
    }

    public func loadTaskViews(today: String) throws -> TodoTaskViews {
        let items = try loadAllItems()
        let mainItems = items.filter { $0.isFromMainTodoFile }
        return TodoTaskViews(
            queue: mainItems.filter { $0.section == "Queue" },
            done: mainItems.filter { $0.section == "Done" || $0.status == .done },
            blocked: items.filter { $0.status == .blocked },
            overdue: items.filter { item in
                guard let dueDate = item.dueDate else { return false }
                return dueDate < today && item.status != .done && item.status != .canceled
            },
            allIndexed: items
        )
    }

    public func loadAllItems() throws -> [TodoItem] {
        let paths = try markdownRelativePaths()
        return try paths.flatMap { path in
            let fileURL = workspaceRootURL.appendingPathComponent(path)
            let markdown = try String(contentsOf: fileURL)
            return parser.parse(markdown: markdown, relativePath: path)
        }
    }

    private func markdownRelativePaths() throws -> [String] {
        guard fileManager.fileExists(atPath: workspaceRootURL.path) else { return [] }
        var paths: [String] = []
        if let enumerator = fileManager.enumerator(at: workspaceRootURL, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let fileURL as URL in enumerator {
                let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true, fileURL.pathExtension.lowercased() == "md" else { continue }
                let path = fileURL.standardizedFileURL.path
                let rootPath = workspaceRootURL.path.hasSuffix("/") ? workspaceRootURL.path : workspaceRootURL.path + "/"
                guard path.hasPrefix(rootPath) else { continue }
                paths.append(String(path.dropFirst(rootPath.count)))
            }
        }
        return paths.sorted { lhs, rhs in
            let lhsIsMainTodo = lhs.caseInsensitiveCompare(Self.mainTodoRelativePath) == .orderedSame
            let rhsIsMainTodo = rhs.caseInsensitiveCompare(Self.mainTodoRelativePath) == .orderedSame
            if lhsIsMainTodo { return true }
            if rhsIsMainTodo { return false }
            return lhs < rhs
        }
    }
}
