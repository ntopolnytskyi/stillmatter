import Foundation

public struct DailyBriefMeeting: Equatable {
    public let title: String
    public let time: String?
    public let sourceRef: String?

    public init(title: String, time: String? = nil, sourceRef: String? = nil) {
        self.title = title
        self.time = time
        self.sourceRef = sourceRef
    }
}

public struct DailyBriefCalendarEvent: Equatable {
    public let calendarIdentifier: String
    public let title: String
    public let time: String?

    public init(calendarIdentifier: String, title: String, time: String? = nil) {
        self.calendarIdentifier = calendarIdentifier
        self.title = title
        self.time = time
    }
}

public struct CalendarMeetingSelector {
    private let selection: CalendarSourceSelection

    public init(selection: CalendarSourceSelection) {
        self.selection = selection
    }

    public func meetings(from events: [DailyBriefCalendarEvent]) -> [DailyBriefMeeting] {
        events.compactMap { event in
            guard selection.includes(calendarIdentifier: event.calendarIdentifier) else { return nil }
            return DailyBriefMeeting(title: event.title, time: event.time)
        }
    }
}

public enum DailyBriefFocusResult: Equatable {
    case generated(relativePath: String)
    case alreadyExists(relativePath: String)
}

/// Creates the day's planning artifact from canonical workspace and operational Inbox state.
/// Reading planning context never mutates Todo Items.
public final class DailyBriefService {
    private let workspaceRootURL: URL
    private let vault: WorkspaceVault
    private let inbox: TasksInbox
    private let meetings: (() throws -> [DailyBriefMeeting])?
    private let today: () -> String
    private let generatedAt: () -> String
    private let queueLimit: Int
    private let fileManager: FileManager

    public init(
        workspaceRootURL: URL,
        vault: WorkspaceVault,
        inbox: TasksInbox,
        meetings: (() throws -> [DailyBriefMeeting])? = nil,
        today: @escaping () -> String = TodoItemMutator.systemToday,
        generatedAt: @escaping () -> String = TasksInbox.systemTimestamp,
        queueLimit: Int = 5,
        fileManager: FileManager = .default
    ) {
        self.workspaceRootURL = workspaceRootURL.standardizedFileURL
        self.vault = vault
        self.inbox = inbox
        self.meetings = meetings
        self.today = today
        self.generatedAt = generatedAt
        self.queueLimit = queueLimit
        self.fileManager = fileManager
    }

    public func handleAppFocus() throws -> DailyBriefFocusResult {
        let date = today()
        let relativePath = "Briefs/Daily/\(date).md"
        guard try vault.versionOfMarkdown(relativePath: relativePath) == nil else {
            return .alreadyExists(relativePath: relativePath)
        }

        let taskViews = try TodoItemIndex(workspaceRootURL: workspaceRootURL).loadTaskViews(today: date)
        let queue = taskViews.queue
            .filter { $0.status != .done && $0.status != .canceled }
            .prefix(max(0, queueLimit))
        let workspaceMeetings = try loadWorkspaceMeetings(date: date)
        let suppliedMeetings = try meetings?() ?? []
        let markdown = try render(
            date: date,
            generatedAt: generatedAt(),
            meetings: Self.mergingMeetings(workspaceMeetings + suppliedMeetings),
            inboxItems: inbox.items(),
            queue: Array(queue),
            overdue: taskViews.overdue,
            blocked: taskViews.blocked,
            activities: loadActiveActivities()
        )
        _ = try vault.writeMarkdown(Data(markdown.utf8), relativePath: relativePath, expectedVersion: nil)
        return .generated(relativePath: relativePath)
    }

    private func render(
        date: String,
        generatedAt: String,
        meetings: [DailyBriefMeeting],
        inboxItems: [InboxItem],
        queue: [TodoItem],
        overdue: [TodoItem],
        blocked: [TodoItem],
        activities: [DailyBriefActivity]
    ) -> String {
        var sections = [
            "---",
            "stillmatter_type: daily_brief",
            "schema_version: 1",
            "date: \(date)",
            "generated_at: \(generatedAt)",
            "generation_status: generated",
            "---",
            "# Daily Brief \(date)",
            "",
            "## Today’s meetings",
            "",
            list(meetings.map(renderMeeting)),
            "",
            "## Pending Inbox items",
            ""
        ]

        for category in InboxCategory.allDisplayCases {
            sections.append("### \(category.displayName)")
            sections.append("")
            sections.append(list(inboxItems.filter { $0.category == category }.map(renderInboxItem)))
            sections.append("")
        }

        sections.append(contentsOf: [
            "## Top queue",
            "",
            list(queue.map { "- \($0.title)" }),
            "",
            "## Overdue",
            "",
            list(overdue.map(renderOverdue)),
            "",
            "## Blocked",
            "",
            list(blocked.map { "- \($0.title)" }),
            "",
            "## Active activities",
            "",
            list(activities.map { "- \($0.title) — \($0.project) — \(markdownSourceLink($0.relativePath))" }),
            "",
            "## Notes",
            "",
            ""
        ])
        return sections.joined(separator: "\n")
    }

    private func renderMeeting(_ meeting: DailyBriefMeeting) -> String {
        let prefix = meeting.time.map { "\($0) — " } ?? ""
        let source = meeting.sourceRef.map { " — \(markdownSourceLink($0))" } ?? ""
        return "- \(prefix)\(meeting.title)\(source)"
    }

    private func renderInboxItem(_ item: InboxItem) -> String {
        let source = item.sourceRef.map { " — \(markdownSourceLink($0))" } ?? ""
        let details = item.details.map { " — \($0)" } ?? ""
        return "- \(item.title)\(source)\(details)"
    }

    private func renderOverdue(_ item: TodoItem) -> String {
        let due = item.dueDate.map { " — due: \($0)" } ?? ""
        return "- \(item.title)\(due)"
    }

    private func list(_ lines: [String]) -> String {
        lines.isEmpty ? "_None._" : lines.joined(separator: "\n")
    }

    private func markdownSourceLink(_ sourceRef: String) -> String {
        if sourceRef.hasPrefix("[["), sourceRef.hasSuffix("]]"), !sourceRef.contains("|") {
            return String(sourceRef.dropLast(2)) + "|source]]"
        }
        if sourceRef.hasPrefix("[[") { return sourceRef }
        return "[[\(sourceRef)|source]]"
    }

    private static func mergingMeetings(_ meetings: [DailyBriefMeeting]) -> [DailyBriefMeeting] {
        var seen: Set<String> = []
        return meetings.filter { meeting in
            let key = "\(meeting.time ?? "")\u{0}\(meeting.title.lowercased())"
            return seen.insert(key).inserted
        }.sorted {
            if $0.time == $1.time { return $0.title < $1.title }
            return ($0.time ?? "") < ($1.time ?? "")
        }
    }

    private func loadWorkspaceMeetings(date: String) throws -> [DailyBriefMeeting] {
        let dateComponents = date.split(separator: "-").map(String.init)
        guard dateComponents.count == 3 else { return [] }
        let dayPath = (["Meetings"] + dateComponents).joined(separator: "/")
        let dayURL = workspaceRootURL.appendingPathComponent(dayPath, isDirectory: true)
        guard fileManager.fileExists(atPath: dayURL.path),
              let enumerator = fileManager.enumerator(
                at: dayURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else { return [] }

        var results: [DailyBriefMeeting] = []
        for case let fileURL as URL in enumerator where fileURL.lastPathComponent == "meeting.md" {
            let markdown = try String(contentsOf: fileURL)
            let folderName = fileURL.deletingLastPathComponent().lastPathComponent
            let timePrefix = String(folderName.prefix(5))
            let time = timePrefix.range(of: #"^\d{2}-\d{2}$"#, options: .regularExpression) == nil
                ? nil
                : timePrefix.replacingOccurrences(of: "-", with: ":")
            let relativePath = String(fileURL.standardizedFileURL.path.dropFirst(workspaceRootURL.path.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            results.append(DailyBriefMeeting(
                title: Self.firstHeading(in: markdown)
                    ?? fileURL.deletingLastPathComponent().lastPathComponent,
                time: time,
                sourceRef: relativePath
            ))
        }
        return results.sorted {
            if $0.time == $1.time { return $0.title < $1.title }
            return ($0.time ?? "") < ($1.time ?? "")
        }
    }

    private func loadActiveActivities() throws -> [DailyBriefActivity] {
        let activitiesURL = workspaceRootURL.appendingPathComponent("Activities", isDirectory: true)
        guard fileManager.fileExists(atPath: activitiesURL.path),
              let enumerator = fileManager.enumerator(
                at: activitiesURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else { return [] }

        var activities: [DailyBriefActivity] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension.lowercased() == "md" {
            let markdown = try String(contentsOf: fileURL)
            guard Self.frontmatterValue("status", in: markdown)?.caseInsensitiveCompare("active") == .orderedSame,
                  let project = Self.frontmatterValue("project", in: markdown),
                  !project.isEmpty else { continue }
            let relativePath = String(fileURL.standardizedFileURL.path.dropFirst(workspaceRootURL.path.count))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            activities.append(DailyBriefActivity(
                title: Self.firstHeading(in: markdown)
                    ?? fileURL.deletingPathExtension().lastPathComponent,
                relativePath: relativePath,
                project: project
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
}

private struct DailyBriefActivity {
    let title: String
    let relativePath: String
    let project: String
}
