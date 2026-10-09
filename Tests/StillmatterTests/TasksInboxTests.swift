import Foundation
import XCTest
@testable import StillmatterCore

final class TasksInboxTests: XCTestCase {
    func testOperationalInboxPersistsCategorizedItemsAcrossReopen() throws {
        let fixture = try InboxFixture()
        var inbox: TasksInbox? = try fixture.open()

        try inbox?.save(InboxItem(
            id: "weekly-report:2026-W03",
            category: .required,
            kind: .weeklyReport,
            title: "Accept weekly report",
            sourceRef: "Reports/Weekly/2026-W03.md",
            details: nil,
            createdAt: "2026-01-19T09:00:00Z"
        ))
        try inbox?.requireTitleReview(id: "meeting:standup", title: "Review meeting title", sourceRef: "Meetings/untitled/meeting.md")
        try inbox?.recordFailedJob(id: "job:transcribe:1", title: "Transcription failed", details: "runner exited 1")
        XCTAssertTrue(try inbox?.queueProposal(id: "proposal:1", title: "Send recap", sourceRef: "Meetings/standup/summary.md") == true)
        inbox = nil

        let reopened = try fixture.open()

        XCTAssertEqual(try reopened.items(category: .required).map(\.kind), [.weeklyReport, .titleReview])
        XCTAssertEqual(try reopened.items(category: .review).map(\.kind), [.proposal])
        XCTAssertEqual(try reopened.items(category: .attention).map(\.kind), [.failedJob])
        XCTAssertEqual(try reopened.proposalReviewState(id: "proposal:1"), .pending)
        XCTAssertEqual(try reopened.items().count, 4)
    }

    func testOverdueAttentionComesOnlyFromExplicitDatesAndRemovesStaleItems() throws {
        let fixture = try InboxFixture()
        let inbox = try fixture.open()
        let parser = TodoItemParser()
        let todos = parser.parse(markdown: """
        # Project

        - [ ] Explicitly overdue due: 2026-01-18
        - [ ] Sounds urgent but has no date
        - [ ] Due today due: 2026-01-19
        - [x] Completed late due: 2026-01-01
        - [C] Canceled late due: 2026-01-01
        - [B] Blocked but overdue due: 2026-01-17
        """, relativePath: "Projects/General.md")

        try inbox.syncOverdueTodos(todos, today: "2026-01-19")

        XCTAssertEqual(
            try inbox.items(category: .attention).filter { $0.kind == .overdueTodo }.map(\.title),
            ["Explicitly overdue", "Blocked but overdue"]
        )

        try inbox.syncOverdueTodos(Array(todos.dropFirst()), today: "2026-01-19")

        XCTAssertEqual(
            try inbox.items(category: .attention).filter { $0.kind == .overdueTodo }.map(\.title),
            ["Blocked but overdue"]
        )
    }

    func testDismissedProposalSuppressesRepeatedProposalAcrossReopen() throws {
        let fixture = try InboxFixture()
        var inbox: TasksInbox? = try fixture.open()

        XCTAssertTrue(try inbox?.queueProposal(
            id: "proposal:recap",
            title: "Send meeting recap",
            sourceRef: "Meetings/kickoff/summary.md",
            suppressionKey: "kickoff:send-recap"
        ) == true)
        try inbox?.setProposalReviewState(id: "proposal:recap", state: .dismissed)
        XCTAssertEqual(try inbox?.proposalReviewState(id: "proposal:recap"), .dismissed)
        XCTAssertTrue(try inbox?.items(category: .review).isEmpty == true)
        inbox = nil

        let reopened = try fixture.open()

        XCTAssertTrue(try reopened.isProposalDismissed(suppressionKey: "kickoff:send-recap"))
        XCTAssertFalse(try reopened.queueProposal(
            id: "proposal:recap-regenerated",
            title: "Send meeting recap",
            sourceRef: "Meetings/kickoff/summary.md",
            suppressionKey: "kickoff:send-recap"
        ))
        XCTAssertTrue(try reopened.items(category: .review).isEmpty)
    }
}

private final class InboxFixture {
    let rootURL: URL
    let databaseURL: URL

    init() throws {
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        databaseURL = rootURL.appendingPathComponent("Stillmatter.sqlite")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func open() throws -> TasksInbox {
        try TasksInbox(databaseURL: databaseURL, now: { "2026-01-19T09:00:00Z" })
    }
}
