import Foundation

public struct WeeklyReportDraft: Equatable {
    public let id: String
    public let relativePath: String
    public let text: String
    public let expectedVersion: WorkspaceFileVersion?

    public init(
        id: String,
        relativePath: String,
        text: String,
        expectedVersion: WorkspaceFileVersion? = nil
    ) {
        self.id = id
        self.relativePath = relativePath
        self.text = text
        self.expectedVersion = expectedVersion
    }
}

public enum WeeklyReportCheckResult: Equatable {
    case notDue
    case ready(WeeklyReportDraft)
}

/// Produces one editable Weekly Report draft for each configured work week.
/// It only reads Todo Items; moving terminal items belongs to report acceptance.
public final class WeeklyReportService {
    private let workspaceRootURL: URL
    private let vault: WorkspaceVault
    private let inbox: TasksInbox
    private var calendar: Calendar
    private let generatedAt: () -> String
    private let fileManager: FileManager

    public init(
        workspaceRootURL: URL,
        vault: WorkspaceVault,
        inbox: TasksInbox,
        calendar: Calendar = .current,
        generatedAt: @escaping () -> String = TasksInbox.systemTimestamp,
        fileManager: FileManager = .default
    ) {
        self.workspaceRootURL = workspaceRootURL.standardizedFileURL
        self.vault = vault
        self.inbox = inbox
        self.calendar = calendar
        self.generatedAt = generatedAt
        self.fileManager = fileManager
    }

    public func check(at date: Date, workingHours: WorkingHoursSettings) throws -> WeeklyReportCheckResult {
        guard let periodEnd = mostRecent(workingHours.endOfWeekDay, onOrBefore: date),
              let triggerDate = triggerDate(for: periodEnd, workingHours: workingHours),
              date >= triggerDate else {
            return .notDue
        }

        let id = reportID(for: periodEnd)
        let relativePath = "Briefs/Weekly/\(id).md"
        let text: String
        let version: WorkspaceFileVersion
        if try vault.versionOfMarkdown(relativePath: relativePath) != nil {
            let existing = try vault.readMarkdown(relativePath: relativePath)
            text = String(decoding: existing.data, as: UTF8.self)
            if Self.frontmatterValue("generation_status", in: text) == "accepted" {
                try inbox.removeItem(id: "weekly-report:\(id)")
                return .notDue
            }
            version = existing.version
        } else {
            text = try render(id: id, periodEnd: periodEnd)
            version = try vault.writeMarkdown(Data(text.utf8), relativePath: relativePath, expectedVersion: nil)
        }

        try inbox.save(InboxItem(
            id: "weekly-report:\(id)",
            category: .required,
            kind: .weeklyReport,
            title: "Review Weekly Report \(id)",
            sourceRef: relativePath,
            details: "Edit the draft, then Accept or Remind next time.",
            createdAt: generatedAt()
        ))
        return .ready(WeeklyReportDraft(
            id: id,
            relativePath: relativePath,
            text: text,
            expectedVersion: version
        ))
    }

    /// Accepts the user's edited report and drains terminal items from the canonical
    /// Todo queue in one recoverable vault transaction.
    public func accept(_ request: WeeklyReportAcceptanceRequest) throws {
        guard let reportVersion = request.draft.expectedVersion else {
            throw WorkspaceVaultError.missingFile(request.draft.relativePath)
        }
        let todoRead = try vault.readMarkdown(relativePath: TodoItemIndex.mainTodoRelativePath)
        let todoText = String(decoding: todoRead.data, as: UTF8.self)
        let drain = WeeklyReportTodoDrain(markdown: todoText).drain()
        let acceptedReport = Self.acceptedReport(
            from: request.editedText,
            terminalBlocks: drain.terminalBlocks,
            acceptedAt: generatedAt()
        )

        try vault.replaceMarkdownTransaction([
            WorkspaceMarkdownReplacement(
                relativePath: request.draft.relativePath,
                data: Data(acceptedReport.utf8),
                expectedVersion: reportVersion
            ),
            WorkspaceMarkdownReplacement(
                relativePath: TodoItemIndex.mainTodoRelativePath,
                data: Data(drain.remainingMarkdown.utf8),
                expectedVersion: todoRead.version
            )
        ])
    }

    private static func acceptedReport(from editedText: String, terminalBlocks: [String], acceptedAt: String) -> String {
        var lines = editedText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let acceptedMetadata = [
            "generation_status: accepted",
            "status: closed",
            "accepted_at: \(acceptedAt)"
        ]
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let frontmatterEnd = lines.dropFirst().firstIndex(where: {
               $0.trimmingCharacters(in: .whitespaces) == "---"
           }) {
            let replacedKeys = ["generation_status:", "status:", "accepted_at:"]
            for index in (1..<frontmatterEnd).reversed() {
                let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
                if replacedKeys.contains(where: { trimmed.hasPrefix($0) }) {
                    lines.remove(at: index)
                }
            }
            let refreshedEnd = lines.dropFirst().firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces) == "---"
            })!
            lines.insert(contentsOf: acceptedMetadata, at: refreshedEnd)
        } else {
            lines.insert(contentsOf: ["---"] + acceptedMetadata + ["---", ""], at: 0)
        }
        while lines.last == "" { lines.removeLast() }
        if !terminalBlocks.isEmpty {
            lines += ["", "## Accepted Todo Items", ""]
            for (index, block) in terminalBlocks.enumerated() {
                if index > 0 { lines.append("") }
                lines += block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func mostRecent(_ weekday: Weekday, onOrBefore date: Date) -> Date? {
        let day = calendar.startOfDay(for: date)
        let currentWeekday = calendar.component(.weekday, from: day)
        let daysBack = (currentWeekday - weekday.rawValue + 7) % 7
        return calendar.date(byAdding: .day, value: -daysBack, to: day)
    }

    private func triggerDate(for periodEnd: Date, workingHours: WorkingHoursSettings) -> Date? {
        let workingDays = Set(workingHours.weekdays.map(\.rawValue))
        guard !workingDays.isEmpty else { return nil }

        var triggerDay = periodEnd
        if !workingDays.contains(workingHours.endOfWeekDay.rawValue) {
            guard let nextWorkingDay = (1...7).compactMap({ offset -> Date? in
                guard let candidate = calendar.date(byAdding: .day, value: offset, to: periodEnd),
                      workingDays.contains(calendar.component(.weekday, from: candidate)) else { return nil }
                return candidate
            }).first else { return nil }
            triggerDay = nextWorkingDay
        }

        return calendar.date(
            bySettingHour: workingHours.endOfWeekTime.hour,
            minute: workingHours.endOfWeekTime.minute,
            second: 0,
            of: triggerDay
        )
    }

    private func reportID(for periodEnd: Date) -> String {
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: periodEnd)
        return String(format: "%04d-W%02d", components.yearForWeekOfYear ?? 0, components.weekOfYear ?? 0)
    }

    private func render(id: String, periodEnd: Date) throws -> String {
        let periodStart = calendar.date(byAdding: .day, value: -6, to: periodEnd) ?? periodEnd
        let dateFormatter = DateFormatter()
        dateFormatter.calendar = calendar
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = calendar.timeZone
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let start = dateFormatter.string(from: periodStart)
        let end = dateFormatter.string(from: periodEnd)
        let todos = try TodoItemIndex(workspaceRootURL: workspaceRootURL).loadAllItems()
        let terminal = todos.filter { $0.status == .done || $0.status == .canceled }
        let ongoing = todos.filter { $0.status == .open || $0.status == .blocked }
        let dailyBriefs = try dailyBriefPaths(from: start, through: end)
        let activities = try activeActivities()

        return [
            "---",
            "stillmatter_type: weekly_report",
            "schema_version: 1",
            "week: \(id)",
            "period_start: \(start)",
            "period_end: \(end)",
            "generated_at: \(generatedAt())",
            "generation_status: draft",
            "---",
            "# Weekly Report \(id)",
            "",
            "## Week in review",
            "",
            list(dailyBriefs.map { path in
                let date = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                return "- [[\(path)|Daily Brief \(date)]]"
            }),
            "",
            "## Completed and canceled Todo Items",
            "",
            list(terminal.map { "- \($0.status.reportLabel): \($0.title)" }),
            "",
            "## Ongoing work",
            "",
            list(ongoing.map { "- \($0.status.reportLabel): \($0.title)" }),
            "",
            "## Active activities",
            "",
            list(activities.map { "- \($0.title) — \($0.project) — [[\($0.relativePath)|source]]" }),
            "",
            "## Coming week",
            "",
            "### Priorities",
            "",
            "",
            "### Proposed follow-up Todo Items",
            "",
            "",
            "## Notes",
            "",
            ""
        ].joined(separator: "\n")
    }

    private func dailyBriefPaths(from start: String, through end: String) throws -> [String] {
        let directory = workspaceRootURL.appendingPathComponent("Briefs/Daily", isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        return try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "md" }
            .compactMap { url -> String? in
                let date = url.deletingPathExtension().lastPathComponent
                guard date >= start && date <= end else { return nil }
                return "Briefs/Daily/\(url.lastPathComponent)"
            }
            .sorted()
    }

    private func activeActivities() throws -> [WeeklyReportActivity] {
        let directory = workspaceRootURL.appendingPathComponent("Activities", isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path),
              let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else { return [] }

        var activities: [WeeklyReportActivity] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension.lowercased() == "md" {
            let markdown = try String(contentsOf: fileURL)
            guard Self.frontmatterValue("status", in: markdown)?.caseInsensitiveCompare("active") == .orderedSame,
                  let project = Self.frontmatterValue("project", in: markdown),
                  !project.isEmpty else { continue }
            let relativePath = String(fileURL.standardizedFileURL.path.dropFirst(workspaceRootURL.path.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            activities.append(WeeklyReportActivity(
                title: Self.firstHeading(in: markdown) ?? fileURL.deletingPathExtension().lastPathComponent,
                project: project,
                relativePath: relativePath
            ))
        }
        return activities.sorted { $0.relativePath < $1.relativePath }
    }

    private static func frontmatterValue(_ key: String, in markdown: String) -> String? {
        let lines = markdown.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces) == "---"
              }) else { return nil }
        let prefix = key.lowercased() + ":"
        guard let line = lines[1..<end].first(where: {
            $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix(prefix)
        }) else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    private static func firstHeading(in markdown: String) -> String? {
        markdown.components(separatedBy: .newlines).lazy.compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("# ") else { return nil }
            return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }.first
    }

    private func list(_ lines: [String]) -> String {
        lines.isEmpty ? "_None._" : lines.joined(separator: "\n")
    }
}

private struct WeeklyReportActivity {
    let title: String
    let project: String
    let relativePath: String
}

private struct WeeklyReportTodoDrain {
    private struct ItemRecord {
        let lineIndex: Int
        let indentation: Int
        let status: TodoStatus
        let indentationShift: Int
    }

    let markdown: String

    func drain() -> (remainingMarkdown: String, terminalBlocks: [String]) {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var records: [ItemRecord] = []
        var itemStack: [Int] = []
        var ownerByLine: [Int: Int] = [:]

        for (lineIndex, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
                itemStack.removeAll()
                continue
            }
            if let checkbox = TodoMarkdownCheckbox.parse(line) {
                while let last = itemStack.last, records[last].indentation >= checkbox.indentation {
                    itemStack.removeLast()
                }
                let indentationShift: Int
                if let parentIndex = itemStack.last {
                    let parent = records[parentIndex]
                    indentationShift = parent.status.isTerminal
                        ? checkbox.indentation - (parent.indentation - parent.indentationShift)
                        : parent.indentationShift
                } else {
                    indentationShift = 0
                }
                records.append(ItemRecord(
                    lineIndex: lineIndex,
                    indentation: checkbox.indentation,
                    status: checkbox.status,
                    indentationShift: indentationShift
                ))
                let recordIndex = records.count - 1
                ownerByLine[lineIndex] = recordIndex
                itemStack.append(recordIndex)
                continue
            }

            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let indentation = TodoMarkdownCheckbox.indentation(of: line)
            if let owner = itemStack.last(where: { records[$0].indentation < indentation }) {
                ownerByLine[lineIndex] = owner
            }
        }

        let emptyRemovedHeadings = emptyHeadingsCreatedByDrain(
            lines: lines,
            records: records,
            ownerByLine: ownerByLine
        )
        var remaining: [String] = []
        for (lineIndex, line) in lines.enumerated() {
            if emptyRemovedHeadings.contains(lineIndex) { continue }
            guard let owner = ownerByLine[lineIndex] else {
                remaining.append(line)
                continue
            }
            let record = records[owner]
            guard !record.status.isTerminal else { continue }
            remaining.append(removingLeadingColumns(record.indentationShift, from: line))
        }
        while remaining.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            remaining.removeLast()
        }
        remaining.append("")

        let blocks = records.indices.compactMap { recordIndex -> (Int, String)? in
            let record = records[recordIndex]
            guard record.status.isTerminal else { return nil }
            var ownedLines = lines.indices.compactMap { index in
                ownerByLine[index] == recordIndex ? lines[index] : nil
            }
            while ownedLines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                ownedLines.removeLast()
            }
            return (record.lineIndex, ownedLines.joined(separator: "\n"))
        }
        return (
            remaining.joined(separator: "\n"),
            blocks.sorted { $0.0 < $1.0 }.map(\.1)
        )
    }

    private func emptyHeadingsCreatedByDrain(
        lines: [String],
        records: [ItemRecord],
        ownerByLine: [Int: Int]
    ) -> Set<Int> {
        var removed: Set<Int> = []
        for headingIndex in lines.indices where lines[headingIndex].trimmingCharacters(in: .whitespaces).hasPrefix("### ") {
            let end = (headingIndex + 1..<lines.count).first {
                lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("#")
            } ?? lines.count
            let contentIndexes = headingIndex + 1..<end
            let terminalContent = contentIndexes.contains { index in
                ownerByLine[index].map { records[$0].status.isTerminal } == true
            }
            let survivingContent = contentIndexes.contains { index in
                guard !lines[index].trimmingCharacters(in: .whitespaces).isEmpty else { return false }
                guard let owner = ownerByLine[index] else { return true }
                return !records[owner].status.isTerminal
            }
            if terminalContent && !survivingContent {
                removed.formUnion(headingIndex..<end)
            }
        }
        return removed
    }

    private func removingLeadingColumns(_ columns: Int, from line: String) -> String {
        guard columns > 0 else { return line }
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

private extension TodoStatus {
    var reportLabel: String {
        switch self {
        case .open: return "Open"
        case .done: return "Done"
        case .blocked: return "Blocked"
        case .canceled: return "Canceled"
        }
    }
}
