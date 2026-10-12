import Foundation

public struct TodayInboxSection: Equatable {
    public let category: InboxCategory
    public let items: [InboxItem]

    public init(category: InboxCategory, items: [InboxItem]) {
        self.category = category
        self.items = items
    }
}

public struct TodayMeeting: Equatable {
    public let title: String
    public let time: String?
    public let eventIdentifier: String?
    public let calendarIdentifier: String?
    public let eventStart: Date?

    public init(title: String, time: String? = nil, eventIdentifier: String? = nil,
                calendarIdentifier: String? = nil, eventStart: Date? = nil) {
        self.title = title
        self.time = time
        self.eventIdentifier = eventIdentifier
        self.calendarIdentifier = calendarIdentifier
        self.eventStart = eventStart
    }
}

public struct TodayDashboardSnapshot: Equatable {
    public let workspaceOwner: String?
    public let recordingStatus: String
    public let jobStatus: String
    public let inbox: [TodayInboxSection]
    public let queue: [TodoItem]
    public let upcomingMeetings: [TodayMeeting]

    public init(
        recordingStatus: String,
        jobStatus: String,
        workspaceOwner: String? = nil,
        inbox: [TodayInboxSection],
        queue: [TodoItem],
        upcomingMeetings: [TodayMeeting]
    ) {
        self.workspaceOwner = workspaceOwner
        self.recordingStatus = recordingStatus
        self.jobStatus = jobStatus
        self.inbox = inbox
        self.queue = queue
        self.upcomingMeetings = upcomingMeetings
    }
}

/// Read-only projection for the Today worktable. Canonical task state remains in Todos/todo.md.
public final class TodayDashboard {
    private let workspaceRootURL: URL
    private let inbox: TasksInbox
    private let recordingStatus: () -> String
    private let jobStatus: () -> String
    private let upcomingMeetings: () -> [TodayMeeting]
    private let today: () -> String
    private let queueLimit: Int

    public init(
        workspaceRootURL: URL,
        inbox: TasksInbox,
        recordingStatus: @escaping () -> String = { "Not recording" },
        jobStatus: @escaping () -> String = { "Jobs idle" },
        upcomingMeetings: @escaping () -> [TodayMeeting] = { [] },
        today: @escaping () -> String = TodoItemMutator.systemToday,
        queueLimit: Int = 5
    ) {
        self.workspaceRootURL = workspaceRootURL
        self.inbox = inbox
        self.recordingStatus = recordingStatus
        self.jobStatus = jobStatus
        self.upcomingMeetings = upcomingMeetings
        self.today = today
        self.queueLimit = queueLimit
    }

    public func load() throws -> TodayDashboardSnapshot {
        let date = today()
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
            workspaceOwner: workspaceRootURL.standardizedFileURL.resolvingSymlinksInPath().path,
            inbox: sections,
            queue: Array(queue),
            upcomingMeetings: upcomingMeetings()
        )
    }

}
