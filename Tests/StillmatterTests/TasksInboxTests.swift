import Foundation
import XCTest
import SQLite3
@testable import StillmatterCore

final class TasksInboxTests: XCTestCase {
    func testUnsupportedStoredKindsRemainDurableWithoutBlockingCurrentWorkspacePlanning() throws {
        let fixture = try InboxFixture()
        let base = try fixture.open()
        let root = fixture.rootURL.appendingPathComponent("workspace")
        let otherRoot = fixture.rootURL.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let owned = try base.scoped(to: root)
        let other = try base.scoped(to: otherRoot)
        try owned.requireTitleReview(id: "retired", title: "Old record", sourceRef: "Meetings/one/meeting.md")
        try owned.requireTitleReview(id: "current", title: "Current title", sourceRef: "Meetings/two/meeting.md")
        try other.requireTitleReview(id: "current", title: "Other title", sourceRef: "Meetings/two/meeting.md")
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(fixture.databaseURL.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database,
            "UPDATE inbox_items SET kind = 'retired-kind' WHERE title = 'Old record'", nil, nil, nil), SQLITE_OK)
        let reopened = try fixture.open()
        let scoped = try reopened.scoped(to: root)
        XCTAssertEqual(try scoped.items().map(\.title), ["Current title"])
        XCTAssertEqual(try scoped.items(category: .required).map(\.workspaceOwner), [root.standardizedFileURL.resolvingSymlinksInPath().path])
        XCTAssertEqual(try reopened.scoped(to: otherRoot).items().map(\.title), ["Other title"])
        let snapshot = try TodayDashboard(workspaceRootURL: root, inbox: scoped, today: { "2026-01-19" }).load()
        XCTAssertEqual(snapshot.inbox.first?.items.map(\.title), ["Current title"])
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, "SELECT count(*) FROM inbox_items WHERE kind = 'retired-kind'", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 1)
    }

    func testOwnedRecordsAndCollidingIDsSurviveSwitchAndLegacyRemainsUnclaimed() throws {
        let fixture = try InboxFixture()
        let base = try fixture.open()
        let a = fixture.rootURL.appendingPathComponent("A")
        let b = fixture.rootURL.appendingPathComponent("B")
        let inboxA = try base.scoped(to: a)
        let inboxB = try base.scoped(to: b)
        let source = "Meetings/same/meeting.md"
        try base.requireTitleReview(id: "same", title: "Legacy", sourceRef: source)
        try inboxA.requireTitleReview(id: "same", title: "A", sourceRef: source)
        try inboxB.requireTitleReview(id: "same", title: "B", sourceRef: source)
        XCTAssertTrue(try inboxA.queueProposal(id: "proposal", title: "A proposal", sourceRef: source))
        XCTAssertNil(try inboxB.pendingProposal(id: "proposal"))
        XCTAssertThrowsError(try inboxB.setProposalReviewState(id: "proposal", state: .accepted))
        try inboxB.removeItem(id: "same")
        XCTAssertEqual(try inboxA.items(category: .required).map(\.title), ["A"])
        XCTAssertEqual(try inboxA.items(category: .required).first?.workspaceOwner, a.standardizedFileURL.resolvingSymlinksInPath().path)
        XCTAssertEqual(try inboxB.items(category: .required).count, 0)
        XCTAssertEqual(try base.items(category: .required).map(\.title), ["Legacy"])
        XCTAssertTrue(try inboxB.queueProposal(id: "proposal", title: "B proposal", sourceRef: source))
        try inboxB.saveProposalDraft(id: "proposal", title: "B draft", comment: "")
        XCTAssertEqual(try inboxA.pendingProposal(id: "proposal")?.title, "A proposal")
        XCTAssertEqual(try inboxB.pendingProposal(id: "proposal")?.title, "B draft")
        let reviewID = "title-review:planning"
        func prompt(_ title: String) -> InboxItem {
            InboxItem(id: reviewID, category: .required, kind: .titleReview, title: title,
                sourceRef: "Meetings/planning/meeting.md", details: nil, createdAt: "2026-01-19")
        }
        try inboxA.save(prompt("A review"))
        try inboxB.save(prompt("B review"))
        try inboxB.removeItem(id: reviewID)
        XCTAssertEqual(Set(try inboxA.items(category: .required).map(\.title)), Set(["A", "A review"]))
        XCTAssertEqual(try inboxB.items(category: .required).map(\.title), [])
        let reopened = try fixture.open()
        XCTAssertEqual(Set(try reopened.scoped(to: a).items(category: .required).map(\.title)), Set(["A", "A review"]))
        XCTAssertEqual(try reopened.items(category: .required).map(\.title), ["Legacy"])
    }

    func testOperationalInboxPersistsCategorizedItemsAcrossReopen() throws {
        let fixture = try InboxFixture()
        var inbox: TasksInbox? = try fixture.open()

        try inbox?.save(InboxItem(
            id: "title-review:planning",
            category: .required,
            kind: .titleReview,
            title: "Review planning title",
            sourceRef: "Meetings/planning/meeting.md",
            details: nil,
            createdAt: "2026-01-19T09:00:00Z"
        ))
        try inbox?.requireTitleReview(id: "meeting:standup", title: "Review meeting title", sourceRef: "Meetings/untitled/meeting.md")
        try inbox?.recordFailedJob(id: "job:transcribe:1", title: "Transcription failed", details: "runner exited 1")
        XCTAssertTrue(try inbox?.queueProposal(id: "proposal:1", title: "Send recap", sourceRef: "Meetings/standup/summary.md") == true)
        inbox = nil

        let reopened = try fixture.open()

        XCTAssertEqual(try reopened.items(category: .required).map(\.kind), [.titleReview, .titleReview])
        XCTAssertEqual(try reopened.items(category: .review).map(\.kind), [.proposal])
        XCTAssertEqual(try reopened.items(category: .attention).map(\.kind), [.failedJob])
        XCTAssertEqual(try reopened.proposalReviewState(id: "proposal:1"), .pending)
        XCTAssertEqual(try reopened.items().count, 4)
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
