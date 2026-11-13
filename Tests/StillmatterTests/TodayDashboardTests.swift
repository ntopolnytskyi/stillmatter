import XCTest
@testable import StillmatterCore

final class TodayDashboardTests: XCTestCase {
    func testEmptyDashboardKeepsEveryWorktableSectionVisible() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let inbox = try TasksInbox(databaseURL: workspace.appendingPathComponent("operational.sqlite"))
        let dashboard = try TodayDashboard(
            workspaceRootURL: workspace,
            inbox: inbox,
            today: { "2026-09-16" }
        ).load()

        XCTAssertEqual(dashboard.recordingStatus, "Not recording")
        XCTAssertEqual(dashboard.jobStatus, "Jobs idle")
        XCTAssertEqual(dashboard.inbox.map(\.category), [.required, .review, .attention])
        XCTAssertTrue(dashboard.inbox.allSatisfy { $0.items.isEmpty })
        XCTAssertEqual(dashboard.queue, [])
        XCTAssertEqual(dashboard.upcomingMeetings, [])
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
        let dashboard = try TodayDashboard(
            workspaceRootURL: workspace,
            inbox: inbox,
            recordingStatus: { "Recording Team sync" },
            jobStatus: { "1 job running" },
            upcomingMeetings: { [TodayMeeting(title: "Planning", time: "14:00")] },
            today: { "2026-09-16" }
        ).load()

        XCTAssertEqual(dashboard.recordingStatus, "Recording Team sync")
        XCTAssertEqual(dashboard.jobStatus, "1 job running")
        XCTAssertEqual(dashboard.inbox.first?.items.map(\.title), ["Name meeting"])
        XCTAssertEqual(dashboard.inbox.last?.items.map(\.title), ["Transcription failed"])
        XCTAssertEqual(dashboard.queue.map(\.title), [
            "First", "Blocked but still queued", "Third open", "Fourth open", "Fifth open"
        ])
        XCTAssertEqual(dashboard.upcomingMeetings, [TodayMeeting(title: "Planning", time: "14:00")])
        let unchangedTodos = try String(contentsOf: workspace.appendingPathComponent("Todos/todo.md"))
        XCTAssertTrue(unchangedTodos.contains("- [ ] Beyond limit"))
        XCTAssertTrue(unchangedTodos.contains("- [x] Completed"))
    }

    func testReviewRemindersGroupCanonicalItemsWithoutMutatingOnRead() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let inbox = try TasksInbox(databaseURL: workspace.appendingPathComponent("operational.sqlite")).scoped(to: workspace)
        for (slug, title, owners) in [("one", "Planning", ["me", "Alice", "unknown"]), ("two", "Follow-up", ["me"])] {
            try write("---\ntitle: \(title)\ncapture_session_id: \(slug)\n---\n", to: "Meetings/\(slug)/meeting.md", in: workspace)
            let lines = try owners.map { owner in
                let metadata: [String: Any] = ["v": 1, "id": UUID().uuidString.lowercased(), "owner": owner,
                                                "review": "pending", "origin": "generated", "citations": []]
                return "- [ ] Proposed work #ai-gen #need-approve <!-- sm-item:" + String(decoding: try JSONSerialization.data(withJSONObject: metadata), as: UTF8.self) + " -->"
            }
            try write("<!-- stillmatter-artifact:actions:v1 -->\n" + lines.joined(separator: "\n"), to: "Meetings/\(slug)/action-items.md", in: workspace)
            try inbox.queueProposal(id: "meeting-action:\(slug):legacy", title: "Individual proposal must not appear", sourceRef: "[[Meetings/\(slug)/summary]]")
        }
        let before = try Data(contentsOf: workspace.appendingPathComponent("Meetings/one/action-items.md"))
        let dashboard = try TodayDashboard(workspaceRootURL: workspace, inbox: inbox).load()
        let reminders = try XCTUnwrap(dashboard.inbox.first { $0.category == .review }).items
        XCTAssertEqual(reminders.count, 2)
        XCTAssertEqual(Set(reminders.map(\.title)), ["Planning", "Follow-up"])
        XCTAssertEqual(reminders.first { $0.title == "Planning" }?.details, "3 awaiting approval")
        XCTAssertEqual(reminders.first { $0.title == "Follow-up" }?.sourceRef, "Meetings/two/meeting.md")
        XCTAssertTrue(dashboard.queue.isEmpty)
        XCTAssertEqual(try Data(contentsOf: workspace.appendingPathComponent("Meetings/one/action-items.md")), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("Meetings/one/meeting-artifacts.json").path))
    }

    func testReviewRefreshFollowsApprovalRejectionExternalRenameAndWorkspaceIsolation() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let support = workspace.appendingPathComponent("support")
        let vault = WorkspaceVault(workspaceRootURL: workspace, appSupportRootURL: support)
        let inbox = try TasksInbox(databaseURL: support.appendingPathComponent("operational.sqlite")).scoped(to: workspace)
        let meeting = "Meetings/review/meeting.md"
        try write("---\ntitle: Review\ncapture_session_id: review\n---\n", to: meeting, in: workspace)
        let extraction = MeetingSummaryExtraction(meeting: meeting, transcript: "Meetings/review/transcript.json", decisions: [],
            myActionItems: [.init(id: "a", text: "Mine", citations: []), .init(id: "b", text: "Mine too", citations: [])],
            otherActionItems: [.init(id: "c", text: "Unknown", citations: [])], openQuestions: [])
        try write(String(decoding: JSONEncoder().encode(extraction), as: UTF8.self), to: "Meetings/review/summary-extraction.json", in: workspace)
        let service = MeetingManagementService(vault: vault, inbox: inbox)
        let dashboard = TodayDashboard(workspaceRootURL: workspace, inbox: inbox)
        // Legacy discovery is read-only, including unknown-owner proposals absent from SQLite.
        XCTAssertEqual(try dashboard.load().inbox[1].items.first?.details, "3 awaiting approval")
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("Meetings/review/meeting-artifacts.json").path))
        var detail = try service.detail(for: "review")
        let selected = try XCTUnwrap(dashboard.load().inbox[1].items.first)
        let mine = detail.reviewItems.filter { $0.owner == "me" }
        detail = try service.reviewMeetingItems(meetingID: "review", items: [mine[0]], accept: true)
        XCTAssertEqual(try dashboard.load().inbox[1].items.first?.details, "2 awaiting approval")
        XCTAssertEqual(try dashboard.load().queue.map(\.id), [mine[0].id])
        detail = try service.reviewMeetingItems(meetingID: "review", items: detail.reviewItems.filter { $0.isPending && $0.owner == "me" }, accept: true)
        XCTAssertEqual(try dashboard.load().inbox[1].items.first?.details, "1 awaiting approval")
        let unknown = try XCTUnwrap(detail.reviewItems.first { $0.isPending })
        _ = try service.reviewMeetingItems(meetingID: "review", items: [unknown], accept: false)
        XCTAssertTrue(try dashboard.load().inbox[1].items.isEmpty)
        XCTAssertEqual(try dashboard.load().queue.map(\.id), mine.reversed().map(\.id))
        // A valid external edit is authoritative, even after the artifact is renamed.
        let actions = workspace.appendingPathComponent(unknown.path)
        let renamed = actions.deletingLastPathComponent().appendingPathComponent("renamed-actions.md")
        try FileManager.default.moveItem(at: actions, to: renamed)
        let edited = try String(contentsOf: renamed).replacingOccurrences(of: "\"rejected\"", with: "\"pending\"")
        try edited.write(to: renamed, atomically: true, encoding: .utf8)
        XCTAssertEqual(try dashboard.load().inbox[1].items.first?.details, "1 awaiting approval")
        let other = workspace.appendingPathComponent("other-workspace")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let otherInbox = try inbox.scoped(to: other)
        XCTAssertTrue(try TodayDashboard(workspaceRootURL: other, inbox: otherInbox).load().inbox[1].items.isEmpty)
        XCTAssertNil(TodayTargetResolution.meetingReview(selected, owner: other.path, current: try service.reviewReminders()))
        try FileManager.default.removeItem(at: actions.deletingLastPathComponent())
        XCTAssertTrue(try dashboard.load().inbox[1].items.isEmpty)
        XCTAssertNil(TodayTargetResolution.meetingReview(selected, owner: selected.workspaceOwner!, current: try service.reviewReminders()))
    }

    func testReviewReadReportsBrokenArtifactsAndHonorsLegacyDecisionsAndArchive() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let inbox = try TasksInbox(databaseURL: workspace.appendingPathComponent("operational.sqlite")).scoped(to: workspace)
        let dashboard = TodayDashboard(workspaceRootURL: workspace, inbox: inbox)
        let directory = "Meetings/one/"
        try write("---\ntitle: One\ncapture_session_id: one\n---\n", to: directory + "meeting.md", in: workspace)
        let marker = "<!-- stillmatter-artifact:actions:v1 -->\n"
        try write(marker + "- [ ] Newly added external task", to: directory + "action-items.md", in: workspace)
        XCTAssertEqual(try dashboard.load().inbox[1].items.first?.details, "1 awaiting approval")
        try write(marker, to: directory + "duplicate.md", in: workspace)
        XCTAssertThrowsError(try dashboard.load())
        try FileManager.default.removeItem(at: workspace.appendingPathComponent(directory + "duplicate.md"))
        try write(marker + "- [ ] Broken <!-- sm-item:{} -->", to: directory + "action-items.md", in: workspace)
        XCTAssertThrowsError(try dashboard.load())
        try FileManager.default.removeItem(at: workspace.appendingPathComponent(directory + "action-items.md"))
        let extraction = MeetingSummaryExtraction(meeting: directory + "meeting.md", transcript: directory + "transcript.json", decisions: [],
            myActionItems: [.init(id: "a", text: "Reviewed", citations: [])], otherActionItems: [], openQuestions: [])
        try write(String(decoding: JSONEncoder().encode(extraction), as: UTF8.self), to: directory + "summary-extraction.json", in: workspace)
        try inbox.queueProposal(id: "meeting-action:one:a", title: "Reviewed", sourceRef: directory + "summary.md")
        try inbox.setProposalReviewState(id: "meeting-action:one:a", state: .dismissed)
        XCTAssertTrue(try dashboard.load().inbox[1].items.isEmpty)
        let wrong = MeetingSummaryExtraction(meeting: "Meetings/another/meeting.md", transcript: directory + "transcript.json", decisions: [], myActionItems: [], otherActionItems: [], openQuestions: [])
        try write(String(decoding: JSONEncoder().encode(wrong), as: UTF8.self), to: directory + "summary-extraction.json", in: workspace)
        XCTAssertThrowsError(try dashboard.load())
        try write("{\"archived\":true}", to: directory + "archive.json", in: workspace)
        XCTAssertTrue(try dashboard.load().inbox[1].items.isEmpty)
        try FileManager.default.removeItem(at: workspace.appendingPathComponent(directory + "archive.json"))
        try FileManager.default.removeItem(at: workspace.appendingPathComponent(directory + "summary-extraction.json"))
        let service = MeetingManagementService(vault: WorkspaceVault(workspaceRootURL: workspace, appSupportRootURL: workspace.appendingPathComponent("support")), inbox: inbox)
        _ = try service.detail(for: "one")
        try FileManager.default.removeItem(at: workspace.appendingPathComponent(directory + "action-items.md"))
        XCTAssertThrowsError(try dashboard.load())
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
