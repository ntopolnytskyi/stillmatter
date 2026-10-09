import XCTest
@testable import StillmatterCore

final class DailyBriefServiceTests: XCTestCase {
    func testAppFocusGeneratesOneStableDailyBriefAndNeverOverwritesIt() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let inbox = try TasksInbox(databaseURL: workspace.appSupport.appendingPathComponent("operational.sqlite"))
        try write(
            "# Morning sync\n",
            to: "Meetings/2026/09/16/09-30-morning-sync/meeting.md",
            in: workspace.root
        )
        let service = makeService(workspace: workspace, inbox: inbox)

        XCTAssertEqual(
            try service.handleAppFocus(),
            .generated(relativePath: "Briefs/Daily/2026-09-16.md")
        )

        let briefURL = workspace.root.appendingPathComponent("Briefs/Daily/2026-09-16.md")
        let generated = try String(contentsOf: briefURL)
        XCTAssertTrue(generated.contains("stillmatter_type: daily_brief"))
        XCTAssertTrue(generated.contains("schema_version: 1"))
        XCTAssertTrue(generated.contains("date: 2026-09-16"))
        XCTAssertTrue(generated.contains("generated_at: 2026-09-16T08:00:00Z"))
        XCTAssertTrue(generated.contains("# Daily Brief 2026-09-16"))
        XCTAssertTrue(generated.contains("09:30 — Morning sync — [[Meetings/2026/09/16/09-30-morning-sync/meeting.md|source]]"))
        XCTAssertEqual(Self.levelTwoHeadings(in: generated), [
            "Today’s meetings",
            "Pending Inbox items",
            "Top queue",
            "Overdue",
            "Blocked",
            "Active activities",
            "Notes"
        ])

        try "User planning notes\n".write(to: briefURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(
            try service.handleAppFocus(),
            .alreadyExists(relativePath: "Briefs/Daily/2026-09-16.md")
        )
        XCTAssertEqual(try String(contentsOf: briefURL), "User planning notes\n")
    }

    func testGeneratedBriefCollectsPlanningContextWithoutMutatingTodos() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let todoMarkdown = """
            # Todos

            ## Queue

            - [ ] Ship release due: 2026-09-15 [[Projects/App#Release]]
            - [B] Waiting for review
            - [ ] Plan next sprint
            - [ ] Beyond brief limit

            ## Done
            """ + "\n"
        try write(todoMarkdown, to: "Todos/todo.md", in: workspace.root)
        try write("""
            ---
            status: active
            project: General
            ---
            # Improve onboarding
            """, to: "Activities/onboarding.md", in: workspace.root)
        try write("""
            ---
            status: completed
            project: General
            ---
            # Finished work
            """, to: "Activities/finished.md", in: workspace.root)

        let inbox = try TasksInbox(databaseURL: workspace.appSupport.appendingPathComponent("operational.sqlite"))
        try inbox.save(InboxItem(
            id: "review",
            category: .review,
            kind: .proposal,
            title: "Review extracted follow-up",
            sourceRef: "Meetings/sync/summary.md",
            details: nil,
            createdAt: "2026-09-16T08:00:00Z"
        ))
        try inbox.save(InboxItem(
            id: "failure",
            category: .attention,
            kind: .failedJob,
            title: "Transcription failed",
            sourceRef: nil,
            details: "Worker exited",
            createdAt: "2026-09-16T09:00:00Z"
        ))

        let service = makeService(
            workspace: workspace,
            inbox: inbox,
            meetings: {
                [
                    DailyBriefMeeting(title: "Team sync", time: "09:30", sourceRef: "Meetings/sync/meeting.md"),
                    DailyBriefMeeting(title: "Planning", time: nil, sourceRef: nil)
                ]
            },
            queueLimit: 3
        )
        _ = try service.handleAppFocus()

        let brief = try String(contentsOf: workspace.root.appendingPathComponent("Briefs/Daily/2026-09-16.md"))
        XCTAssertTrue(brief.contains("09:30 — Team sync — [[Meetings/sync/meeting.md|source]]"))
        XCTAssertTrue(brief.contains("Planning"))
        XCTAssertTrue(brief.contains("### Review\n\n- Review extracted follow-up — [[Meetings/sync/summary.md|source]]"))
        XCTAssertTrue(brief.contains("### Attention\n\n- Transcription failed — Worker exited"))
        XCTAssertTrue(brief.contains("## Top queue\n\n- Ship release"))
        XCTAssertTrue(brief.contains("- Waiting for review"))
        XCTAssertTrue(brief.contains("- Plan next sprint"))
        XCTAssertFalse(brief.contains("Beyond brief limit"))
        XCTAssertTrue(brief.contains("## Overdue\n\n- Ship release — due: 2026-09-15"))
        XCTAssertTrue(brief.contains("## Blocked\n\n- Waiting for review"))
        XCTAssertTrue(brief.contains("- Improve onboarding — General — [[Activities/onboarding.md|source]]"))
        XCTAssertFalse(brief.contains("Finished work"))
        XCTAssertEqual(try String(contentsOf: workspace.root.appendingPathComponent("Todos/todo.md")), todoMarkdown)
    }

    func testDailyBriefUsesOnlyConfiguredCalendarSources() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let inbox = try TasksInbox(databaseURL: workspace.appSupport.appendingPathComponent("operational.sqlite"))
        let events = [
            DailyBriefCalendarEvent(calendarIdentifier: "work", title: "Work planning", time: "10:00"),
            DailyBriefCalendarEvent(calendarIdentifier: "personal", title: "Dentist", time: "15:00")
        ]

        func generatedBrief(date: String, selection: CalendarSourceSelection) throws -> String {
            let selector = CalendarMeetingSelector(selection: selection)
            let service = DailyBriefService(
                workspaceRootURL: workspace.root,
                vault: WorkspaceVault(workspaceRootURL: workspace.root, appSupportRootURL: workspace.appSupport),
                inbox: inbox,
                meetings: { selector.meetings(from: events) },
                today: { date },
                generatedAt: { "2026-09-16T08:00:00Z" }
            )
            _ = try service.handleAppFocus()
            return try String(contentsOf: workspace.root.appendingPathComponent("Briefs/Daily/\(date).md"))
        }

        let selectedBrief = try generatedBrief(date: "2026-09-16", selection: .selected(["work"]))
        XCTAssertTrue(selectedBrief.contains("Work planning"))
        XCTAssertFalse(selectedBrief.contains("Dentist"))

        let allBrief = try generatedBrief(date: "2026-09-17", selection: .all)
        XCTAssertTrue(allBrief.contains("Work planning"))
        XCTAssertTrue(allBrief.contains("Dentist"))

        let unavailableBrief = try generatedBrief(date: "2026-09-18", selection: .selected(["missing"]))
        XCTAssertFalse(unavailableBrief.contains("Work planning"))
        XCTAssertFalse(unavailableBrief.contains("Dentist"))

        let noneBrief = try generatedBrief(date: "2026-09-19", selection: .none)
        XCTAssertFalse(noneBrief.contains("Work planning"))
        XCTAssertFalse(noneBrief.contains("Dentist"))
    }

    func testFocusOnAnotherDayCreatesThatDaysBrief() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.root) }
        let inbox = try TasksInbox(databaseURL: workspace.appSupport.appendingPathComponent("operational.sqlite"))
        var focusedDate = "2026-09-16"
        let vault = WorkspaceVault(workspaceRootURL: workspace.root, appSupportRootURL: workspace.appSupport)
        let service = DailyBriefService(
            workspaceRootURL: workspace.root,
            vault: vault,
            inbox: inbox,
            today: { focusedDate }
        )

        XCTAssertEqual(try service.handleAppFocus(), .generated(relativePath: "Briefs/Daily/2026-09-16.md"))
        focusedDate = "2026-09-17"
        XCTAssertEqual(try service.handleAppFocus(), .generated(relativePath: "Briefs/Daily/2026-09-17.md"))
    }

    private func makeService(
        workspace: (root: URL, appSupport: URL),
        inbox: TasksInbox,
        meetings: (() throws -> [DailyBriefMeeting])? = nil,
        queueLimit: Int = 5
    ) -> DailyBriefService {
        DailyBriefService(
            workspaceRootURL: workspace.root,
            vault: WorkspaceVault(workspaceRootURL: workspace.root, appSupportRootURL: workspace.appSupport),
            inbox: inbox,
            meetings: meetings,
            today: { "2026-09-16" },
            generatedAt: { "2026-09-16T08:00:00Z" },
            queueLimit: queueLimit
        )
    }

    private func makeWorkspace() throws -> (root: URL, appSupport: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("DailyBriefServiceTests-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("Vault", isDirectory: true)
        let appSupport = base.appendingPathComponent("AppSupport", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return (root, appSupport)
    }

    private func write(_ contents: String, to relativePath: String, in workspace: URL) throws {
        let url = workspace.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func levelTwoHeadings(in markdown: String) -> [String] {
        markdown.components(separatedBy: .newlines).compactMap { line in
            guard line.hasPrefix("## "), !line.hasPrefix("### ") else { return nil }
            return String(line.dropFirst(3))
        }
    }
}
