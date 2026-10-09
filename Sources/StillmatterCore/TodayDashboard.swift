import Foundation

public struct TodayInboxSection: Equatable {
    public let category: InboxCategory
    public let items: [InboxItem]

    public init(category: InboxCategory, items: [InboxItem]) {
        self.category = category
        self.items = items
    }
}

public enum TodayDailyBrief: Equatable {
    case available(relativePath: String)
    case notGenerated(relativePath: String)
}

public struct TodayMeeting: Equatable {
    public let title: String
    public let time: String?

    public init(title: String, time: String? = nil) {
        self.title = title
        self.time = time
    }
}

public struct TodayActivity: Equatable {
    public let title: String
    public let relativePath: String
    public let project: String

    public init(title: String, relativePath: String, project: String) {
        self.title = title
        self.relativePath = relativePath
        self.project = project
    }
}

public struct TodayDashboardSnapshot: Equatable {
    public let recordingStatus: String
    public let jobStatus: String
    public let inbox: [TodayInboxSection]
    public let dailyBrief: TodayDailyBrief
    public let queue: [TodoItem]
    public let upcomingMeetings: [TodayMeeting]
    public let activeActivities: [TodayActivity]

    public init(
        recordingStatus: String,
        jobStatus: String,
        inbox: [TodayInboxSection],
        dailyBrief: TodayDailyBrief,
        queue: [TodoItem],
        upcomingMeetings: [TodayMeeting],
        activeActivities: [TodayActivity]
    ) {
        self.recordingStatus = recordingStatus
        self.jobStatus = jobStatus
        self.inbox = inbox
        self.dailyBrief = dailyBrief
        self.queue = queue
        self.upcomingMeetings = upcomingMeetings
        self.activeActivities = activeActivities
    }
}

/// Read-only projection for the Today worktable. Canonical task state remains in Todos/todo.md.
public final class TodayDashboard {
    private let workspaceRootURL: URL
    private let inbox: TasksInbox
    private let searchIndex: SearchIndex?
    private let recordingStatus: () -> String
    private let jobStatus: () -> String
    private let upcomingMeetings: () -> [TodayMeeting]
    private let today: () -> String
    private let queueLimit: Int

    public init(
        workspaceRootURL: URL,
        inbox: TasksInbox,
        searchIndex: SearchIndex? = nil,
        recordingStatus: @escaping () -> String = { "Not recording" },
        jobStatus: @escaping () -> String = { "Jobs idle" },
        upcomingMeetings: @escaping () -> [TodayMeeting] = { [] },
        today: @escaping () -> String = TodoItemMutator.systemToday,
        queueLimit: Int = 5
    ) {
        self.workspaceRootURL = workspaceRootURL
        self.inbox = inbox
        self.searchIndex = searchIndex
        self.recordingStatus = recordingStatus
        self.jobStatus = jobStatus
        self.upcomingMeetings = upcomingMeetings
        self.today = today
        self.queueLimit = queueLimit
    }

    public func load() throws -> TodayDashboardSnapshot {
        let date = today()
        let briefPath = "Briefs/Daily/\(date).md"
        let briefURL = workspaceRootURL.appendingPathComponent(briefPath)
        let sections = try InboxCategory.allDisplayCases.map {
            TodayInboxSection(category: $0, items: try inbox.items(category: $0))
        }
        let taskViews = try TodoItemIndex(workspaceRootURL: workspaceRootURL).loadTaskViews(today: date)
        let queue = taskViews.queue
            .filter { $0.status != .done && $0.status != .canceled }
            .prefix(max(0, queueLimit))

        return TodayDashboardSnapshot(
            recordingStatus: recordingStatus(),
            jobStatus: jobStatus(),
            inbox: sections,
            dailyBrief: FileManager.default.fileExists(atPath: briefURL.path)
                ? .available(relativePath: briefPath)
                : .notGenerated(relativePath: briefPath),
            queue: Array(queue),
            upcomingMeetings: upcomingMeetings(),
            activeActivities: try loadActiveActivities()
        )
    }

    private func loadActiveActivities() throws -> [TodayActivity] {
        guard let searchIndex = searchIndex else { return [] }
        let paths = Set(try searchIndex.search(
            "",
            filter: SearchFilter(kinds: [.activity], pathPrefix: "Activities/")
        ).map(\.sourcePath))
        return try paths.compactMap { path in
            let markdown = try String(contentsOf: workspaceRootURL.appendingPathComponent(path))
            guard Self.frontmatterValue("status", in: markdown)?.caseInsensitiveCompare("active") == .orderedSame,
                  let project = Self.frontmatterValue("project", in: markdown),
                  !project.isEmpty else { return nil }
            let title = Self.firstHeading(in: markdown)
                ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            return TodayActivity(title: title, relativePath: path, project: project)
        }.sorted { $0.relativePath < $1.relativePath }
    }

    private static func frontmatterValue(_ key: String, in markdown: String) -> String? {
        let lines = markdown.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return nil
        }
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
