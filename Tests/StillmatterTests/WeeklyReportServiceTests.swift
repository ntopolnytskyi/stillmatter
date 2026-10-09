import XCTest
@testable import StillmatterCore

final class WeeklyReportServiceTests: XCTestCase {
    func testConfiguredEndOfWeekTimeGeneratesOneEditableDraftAndRequiredPrompt() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.base) }
        try write("""
            # Todos

            ## Queue

            - [ ] Plan launch
            - [x] Ship beta completed: 2026-09-17
            - [C] Drop obsolete task

            ## Done
            """ + "\n", to: "Todos/todo.md", in: workspace.root)
        try write("# Daily Brief 2026-09-17\n", to: "Briefs/Daily/2026-09-17.md", in: workspace.root)
        try write("""
            ---
            status: active
            project: Stillmatter
            ---
            # Ship reporting
            """, to: "Activities/reporting.md", in: workspace.root)

        let inbox = try TasksInbox(
            databaseURL: workspace.appSupport.appendingPathComponent("operational.sqlite"),
            now: { "2026-09-18T19:00:00Z" }
        )
        let service = WeeklyReportService(
            workspaceRootURL: workspace.root,
            vault: WorkspaceVault(workspaceRootURL: workspace.root, appSupportRootURL: workspace.appSupport),
            inbox: inbox,
            calendar: utcCalendar,
            generatedAt: { "2026-09-18T19:00:00Z" }
        )
        let settings = WorkingHoursSettings()

        XCTAssertEqual(
            try service.check(at: date("2026-09-18T18:59:00Z"), workingHours: settings),
            .notDue
        )

        guard case let .ready(draft) = try service.check(
            at: date("2026-09-18T19:00:00Z"),
            workingHours: settings
        ) else {
            return XCTFail("Expected a Weekly Report draft")
        }
        XCTAssertEqual(draft.id, "2026-W38")
        XCTAssertEqual(draft.relativePath, "Briefs/Weekly/2026-W38.md")
        XCTAssertNotNil(draft.expectedVersion)
        XCTAssertTrue(draft.text.contains("stillmatter_type: weekly_report"))
        XCTAssertTrue(draft.text.contains("generation_status: draft"))
        XCTAssertTrue(draft.text.contains("# Weekly Report 2026-W38"))
        XCTAssertTrue(draft.text.contains("Ship beta"))
        XCTAssertTrue(draft.text.contains("Drop obsolete task"))
        XCTAssertTrue(draft.text.contains("Plan launch"))
        XCTAssertFalse(draft.text.contains("- [x] Ship beta"))
        XCTAssertTrue(draft.text.contains("Ship reporting — Stillmatter — [[Activities/reporting.md|source]]"))
        XCTAssertTrue(draft.text.contains("[[Briefs/Daily/2026-09-17.md|Daily Brief 2026-09-17]]"))

        let required = try inbox.items(category: .required)
        XCTAssertEqual(required.count, 1)
        XCTAssertEqual(required.first?.id, "weekly-report:2026-W38")
        XCTAssertEqual(required.first?.kind, .weeklyReport)
        XCTAssertEqual(required.first?.sourceRef, draft.relativePath)

        let edited = draft.text + "User edit\n"
        try edited.write(
            to: workspace.root.appendingPathComponent(draft.relativePath),
            atomically: true,
            encoding: .utf8
        )
        guard case let .ready(existing) = try service.check(
            at: date("2026-09-19T09:00:00Z"),
            workingHours: settings
        ) else {
            return XCTFail("Expected the existing Weekly Report draft")
        }
        XCTAssertEqual(existing.text, edited)
    }

    func testAcceptanceMovesAllTerminalTodosAndPreservesEditedReportAndOngoingOrder() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.base) }
        let originalTodos = """
            # Todos

            ## Queue

            - [ ] First open
            - [C] Canceled from queue
              Cancellation context.
            - [B] Blocked in the middle
            - [x] Done outside dated section done: 2026-08-01
            - [ ] Last open

            ## Done

            ### 2026-07-01

            - [x] Old completed item done: 2026-07-01
              Completion context.
            """ + "\n"
        try write(originalTodos, to: "Todos/todo.md", in: workspace.root)

        let inbox = try TasksInbox(
            databaseURL: workspace.appSupport.appendingPathComponent("operational.sqlite"),
            now: { "2026-09-18T19:00:00Z" }
        )
        let service = WeeklyReportService(
            workspaceRootURL: workspace.root,
            vault: WorkspaceVault(workspaceRootURL: workspace.root, appSupportRootURL: workspace.appSupport),
            inbox: inbox,
            calendar: utcCalendar,
            generatedAt: { "2026-09-18T19:00:00Z" }
        )
        guard case let .ready(draft) = try service.check(
            at: date("2026-09-18T19:00:00Z"),
            workingHours: WorkingHoursSettings()
        ) else {
            return XCTFail("Expected a Weekly Report draft")
        }

        let edited = draft.text.replacingOccurrences(of: "## Notes\n", with: "## Notes\n\nKeep this user edit.\n")
        try service.accept(WeeklyReportAcceptanceRequest(draft: draft, editedText: edited))

        XCTAssertEqual(try String(contentsOf: workspace.root.appendingPathComponent("Todos/todo.md")), """
            # Todos

            ## Queue

            - [ ] First open
            - [B] Blocked in the middle
            - [ ] Last open

            ## Done
            """ + "\n")
        let acceptedReport = try String(contentsOf: workspace.root.appendingPathComponent(draft.relativePath))
        XCTAssertTrue(acceptedReport.contains("generation_status: accepted"))
        XCTAssertTrue(acceptedReport.contains("status: closed"))
        XCTAssertTrue(acceptedReport.contains("accepted_at: 2026-09-18T19:00:00Z"))
        XCTAssertTrue(acceptedReport.contains("Keep this user edit."))
        XCTAssertTrue(acceptedReport.contains("- [C] Canceled from queue"))
        XCTAssertTrue(acceptedReport.contains("  Cancellation context."))
        XCTAssertTrue(acceptedReport.contains("- [x] Done outside dated section done: 2026-08-01"))
        XCTAssertTrue(acceptedReport.contains("- [x] Old completed item done: 2026-07-01"))
        XCTAssertTrue(acceptedReport.contains("  Completion context."))

        XCTAssertEqual(try service.check(
            at: date("2026-09-19T09:00:00Z"),
            workingHours: WorkingHoursSettings()
        ), .notDue)
        XCTAssertTrue(try inbox.items(category: .required).isEmpty)
    }

    func testAcceptancePreservesNestedOngoingItemsAndUnrelatedEmptyHeadings() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.base) }
        try write("""
            # Todos

            ## Queue

            - [x] Completed parent
              Parent note.
              - [ ] Open child
                Child note.
                - [B] Blocked grandchild
            - [ ] Open parent
              - [x] Completed child
                Completed child note.
              Open parent note after child.

            ## Reference

            ### Empty custom heading
            """ + "\n", to: "Todos/todo.md", in: workspace.root)
        let inbox = try TasksInbox(databaseURL: workspace.appSupport.appendingPathComponent("operational.sqlite"))
        let service = WeeklyReportService(
            workspaceRootURL: workspace.root,
            vault: WorkspaceVault(workspaceRootURL: workspace.root, appSupportRootURL: workspace.appSupport),
            inbox: inbox,
            calendar: utcCalendar
        )
        guard case let .ready(draft) = try service.check(
            at: date("2026-09-18T19:00:00Z"),
            workingHours: WorkingHoursSettings()
        ) else {
            return XCTFail("Expected a Weekly Report draft")
        }

        try service.accept(WeeklyReportAcceptanceRequest(draft: draft, editedText: draft.text))

        XCTAssertEqual(try String(contentsOf: workspace.root.appendingPathComponent("Todos/todo.md")), """
            # Todos

            ## Queue

            - [ ] Open child
              Child note.
              - [B] Blocked grandchild
            - [ ] Open parent
              Open parent note after child.

            ## Reference

            ### Empty custom heading
            """ + "\n")
    }

    func testAcceptanceRestoresRequiredMetadataWhenUserRemovesFrontmatter() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.base) }
        try write("# Todos\n\n## Queue\n\n- [x] Done\n", to: "Todos/todo.md", in: workspace.root)
        let inbox = try TasksInbox(databaseURL: workspace.appSupport.appendingPathComponent("operational.sqlite"))
        let service = WeeklyReportService(
            workspaceRootURL: workspace.root,
            vault: WorkspaceVault(workspaceRootURL: workspace.root, appSupportRootURL: workspace.appSupport),
            inbox: inbox,
            calendar: utcCalendar,
            generatedAt: { "2026-09-18T19:00:00Z" }
        )
        guard case let .ready(draft) = try service.check(
            at: date("2026-09-18T19:00:00Z"),
            workingHours: WorkingHoursSettings()
        ) else {
            return XCTFail("Expected a Weekly Report draft")
        }
        let editedWithoutFrontmatter = "# My edited report\n\nKeep all of this.\n"

        try service.accept(WeeklyReportAcceptanceRequest(
            draft: draft,
            editedText: editedWithoutFrontmatter
        ))

        let accepted = try String(contentsOf: workspace.root.appendingPathComponent(draft.relativePath))
        XCTAssertTrue(accepted.hasPrefix("---\ngeneration_status: accepted\nstatus: closed\naccepted_at: 2026-09-18T19:00:00Z\n---\n"))
        XCTAssertTrue(accepted.contains("# My edited report\n\nKeep all of this."))
        XCTAssertEqual(try service.check(
            at: date("2026-09-19T09:00:00Z"),
            workingHours: WorkingHoursSettings()
        ), .notDue)
    }

    func testAcceptanceConflictLeavesReportAndTodosUnchanged() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.base) }
        let originalTodos = "# Todos\n\n## Queue\n\n- [ ] Keep open\n- [x] Keep until acceptance succeeds\n"
        try write(originalTodos, to: "Todos/todo.md", in: workspace.root)
        let inbox = try TasksInbox(databaseURL: workspace.appSupport.appendingPathComponent("operational.sqlite"))
        let vault = WorkspaceVault(workspaceRootURL: workspace.root, appSupportRootURL: workspace.appSupport)
        let service = WeeklyReportService(
            workspaceRootURL: workspace.root,
            vault: vault,
            inbox: inbox,
            calendar: utcCalendar
        )
        guard case let .ready(draft) = try service.check(
            at: date("2026-09-18T19:00:00Z"),
            workingHours: WorkingHoursSettings()
        ) else {
            return XCTFail("Expected a Weekly Report draft")
        }
        let externalReport = draft.text + "External edit\n"
        _ = try vault.writeMarkdown(
            Data(externalReport.utf8),
            relativePath: draft.relativePath,
            expectedVersion: draft.expectedVersion
        )

        XCTAssertThrowsError(try service.accept(
            WeeklyReportAcceptanceRequest(draft: draft, editedText: draft.text + "User edit\n")
        ))
        XCTAssertEqual(try String(contentsOf: workspace.root.appendingPathComponent("Todos/todo.md")), originalTodos)
        XCTAssertEqual(try String(contentsOf: workspace.root.appendingPathComponent(draft.relativePath)), externalReport)
    }

    func testNonWorkingEndOfWeekDayDefersDraftUntilNextWorkingDay() throws {
        let workspace = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace.base) }
        try write("# Todos\n\n## Queue\n\n## Done\n", to: "Todos/todo.md", in: workspace.root)
        let inbox = try TasksInbox(databaseURL: workspace.appSupport.appendingPathComponent("operational.sqlite"))
        let service = WeeklyReportService(
            workspaceRootURL: workspace.root,
            vault: WorkspaceVault(workspaceRootURL: workspace.root, appSupportRootURL: workspace.appSupport),
            inbox: inbox,
            calendar: utcCalendar
        )
        let settings = WorkingHoursSettings(
            weekdays: [.monday, .tuesday, .wednesday, .thursday],
            endOfWeekDay: .friday,
            endOfWeekTime: TimeOfDay(hour: 17, minute: 30)
        )

        XCTAssertEqual(
            try service.check(at: date("2026-09-18T17:30:00Z"), workingHours: settings),
            .notDue
        )
        XCTAssertEqual(
            try service.check(at: date("2026-09-21T17:29:00Z"), workingHours: settings),
            .notDue
        )
        guard case let .ready(draft) = try service.check(
            at: date("2026-09-21T17:30:00Z"),
            workingHours: settings
        ) else {
            return XCTFail("Expected deferred Friday report on Monday")
        }
        XCTAssertEqual(draft.id, "2026-W38")
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func makeWorkspace() throws -> (base: URL, root: URL, appSupport: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("WeeklyReportServiceTests-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("Vault", isDirectory: true)
        let appSupport = base.appendingPathComponent("AppSupport", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return (base, root, appSupport)
    }

    private func write(_ contents: String, to relativePath: String, in workspace: URL) throws {
        let url = workspace.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
