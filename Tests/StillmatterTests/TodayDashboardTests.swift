import XCTest
@testable import StillmatterCore

final class TodayDashboardTests: XCTestCase {
    func testEmptyDashboardKeepsEveryWorktableSectionVisible() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let inbox = try TasksInbox(databaseURL: workspace.appendingPathComponent("operational.sqlite"))
        let index = try SearchIndex(
            databaseURL: workspace.appendingPathComponent("search.sqlite"),
            workspaceRootURL: workspace
        )
        try index.rebuild()

        let dashboard = try TodayDashboard(
            workspaceRootURL: workspace,
            inbox: inbox,
            searchIndex: index,
            today: { "2026-09-16" }
        ).load()

        XCTAssertEqual(dashboard.recordingStatus, "Not recording")
        XCTAssertEqual(dashboard.jobStatus, "Jobs idle")
        XCTAssertEqual(dashboard.inbox.map(\.category), [.required, .review, .attention])
        XCTAssertTrue(dashboard.inbox.allSatisfy { $0.items.isEmpty })
        XCTAssertEqual(dashboard.dailyBrief, .notGenerated(relativePath: "Briefs/Daily/2026-09-16.md"))
        XCTAssertEqual(dashboard.queue, [])
        XCTAssertEqual(dashboard.upcomingMeetings, [])
        XCTAssertEqual(dashboard.activeActivities, [])
    }

    func testDashboardProjectsCanonicalWorkWithoutCreatingAnotherTaskList() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try write("""
            # Todos

            ## Queue

            - [ ] First
            - [B] Blocked but still queued
            - [x] Completed
            - [ ] Third open
            - [ ] Fourth open
            - [ ] Fifth open
            - [ ] Beyond limit

            ## Done
            """, to: "Todos/todo.md", in: workspace)
        try write("""
            ---
            status: active
            project: General
            ---
            # Ship dashboard
            """, to: "Activities/ship-dashboard.md", in: workspace)
        try write("""
            ---
            status: completed
            project: General
            ---
            # Old activity
            """, to: "Activities/old.md", in: workspace)
        try write("""
            ---
            status: active
            ---
            # Unassigned activity
            """, to: "Activities/unassigned.md", in: workspace)
        try write("# Daily Brief\n", to: "Briefs/Daily/2026-09-16.md", in: workspace)

        let inbox = try TasksInbox(databaseURL: workspace.appendingPathComponent("operational.sqlite"))
        try inbox.save(InboxItem(
            id: "title-review",
            category: .required,
            kind: .titleReview,
            title: "Name meeting",
            sourceRef: "Meetings/one/meeting.md",
            details: nil,
            createdAt: "2026-09-16T08:00:00Z"
        ))
        try inbox.save(InboxItem(
            id: "failed-job",
            category: .attention,
            kind: .failedJob,
            title: "Transcription failed",
            sourceRef: nil,
            details: "Worker exited",
            createdAt: "2026-09-16T09:00:00Z"
        ))
        let index = try SearchIndex(
            databaseURL: workspace.appendingPathComponent("search.sqlite"),
            workspaceRootURL: workspace
        )
        try index.rebuild()

        let dashboard = try TodayDashboard(
            workspaceRootURL: workspace,
            inbox: inbox,
            searchIndex: index,
            recordingStatus: { "Recording Team sync" },
            jobStatus: { "1 job running" },
            upcomingMeetings: { [TodayMeeting(title: "Planning", time: "14:00")] },
            today: { "2026-09-16" }
        ).load()

        XCTAssertEqual(dashboard.recordingStatus, "Recording Team sync")
        XCTAssertEqual(dashboard.jobStatus, "1 job running")
        XCTAssertEqual(dashboard.inbox.first?.items.map(\.title), ["Name meeting"])
        XCTAssertEqual(dashboard.inbox.last?.items.map(\.title), ["Transcription failed"])
        XCTAssertEqual(dashboard.dailyBrief, .available(relativePath: "Briefs/Daily/2026-09-16.md"))
        XCTAssertEqual(dashboard.queue.map(\.title), [
            "First", "Blocked but still queued", "Third open", "Fourth open", "Fifth open"
        ])
        XCTAssertEqual(dashboard.upcomingMeetings, [TodayMeeting(title: "Planning", time: "14:00")])
        XCTAssertEqual(dashboard.activeActivities, [
            TodayActivity(
                title: "Ship dashboard",
                relativePath: "Activities/ship-dashboard.md",
                project: "General"
            )
        ])

        let unchangedTodos = try String(contentsOf: workspace.appendingPathComponent("Todos/todo.md"))
        XCTAssertTrue(unchangedTodos.contains("- [ ] Beyond limit"))
        XCTAssertTrue(unchangedTodos.contains("- [x] Completed"))
    }

    private func write(_ contents: String, to relativePath: String, in workspace: URL) throws {
        let url = workspace.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("TodayDashboardTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
