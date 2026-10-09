import Foundation
import XCTest
@testable import StillmatterCore

final class ActionItemProposalReviewTests: XCTestCase {
    func testAcceptCreatesNormalTodoAtTopOfQueueAndRemovesProposalFromReview() throws {
        let fixture = try ProposalReviewFixture()
        try fixture.queue(id: "proposal:recap", title: "Send recap #ai-proposed", sourceRef: "[[Meetings/kickoff/summary#My action items|ref]]")

        _ = try fixture.reviewer.accept(proposalID: "proposal:recap", expectedTodoVersion: fixture.todoVersion())

        XCTAssertEqual(try fixture.todoMarkdown(), """
        # Todos

        ## Queue

        - [ ] Send recap [[Meetings/kickoff/summary#My action items|ref]]
        - [ ] Existing task
        """ + "\n")
        XCTAssertEqual(try fixture.inbox.proposalReviewState(id: "proposal:recap"), .accepted)
        XCTAssertTrue(try fixture.inbox.items(category: .review).isEmpty)
    }

    func testEditThenAcceptChangesOnlyResultingTodoAndNotSourceArtifact() throws {
        let fixture = try ProposalReviewFixture()
        let sourcePath = "Meetings/kickoff/summary.md"
        let sourceMarkdown = "# Summary\n\n- [ ] Draft follow-up #ai-proposed\n"
        try fixture.writeSource(sourceMarkdown, relativePath: sourcePath)
        try fixture.queue(id: "proposal:draft", title: "Draft follow-up #ai-proposed", sourceRef: "[[Meetings/kickoff/summary#My action items|ref]]")

        _ = try fixture.reviewer.accept(
            proposalID: "proposal:draft",
            editedTitle: "Send the final follow-up",
            expectedTodoVersion: fixture.todoVersion()
        )

        XCTAssertTrue(try fixture.todoMarkdown().contains("- [ ] Send the final follow-up [[Meetings/kickoff/summary#My action items|ref]]"))
        XCTAssertEqual(try fixture.readSource(relativePath: sourcePath), sourceMarkdown)
    }

    func testReferenceOnlyDismissAndCancelResolveWithoutCreatingTodos() throws {
        let fixture = try ProposalReviewFixture()
        try fixture.queue(id: "proposal:reference", title: "Other person's task", sourceRef: "[[Meetings/kickoff/summary|ref]]")
        try fixture.queue(id: "proposal:dismiss", title: "Duplicate task", sourceRef: "[[Meetings/kickoff/summary|ref]]")
        try fixture.queue(id: "proposal:cancel", title: "Obsolete task", sourceRef: "[[Meetings/kickoff/summary|ref]]")
        let originalTodo = try fixture.todoMarkdown()

        try fixture.reviewer.markReferenceOnly(proposalID: "proposal:reference")
        try fixture.reviewer.dismiss(proposalID: "proposal:dismiss")
        try fixture.reviewer.cancel(proposalID: "proposal:cancel")

        XCTAssertEqual(try fixture.inbox.proposalReviewState(id: "proposal:reference"), .referenceOnly)
        XCTAssertEqual(try fixture.inbox.proposalReviewState(id: "proposal:dismiss"), .dismissed)
        XCTAssertEqual(try fixture.inbox.proposalReviewState(id: "proposal:cancel"), .dismissed)
        XCTAssertEqual(try fixture.todoMarkdown(), originalTodo)
        XCTAssertTrue(try fixture.inbox.items(category: .review).isEmpty)
    }

    func testMergeCreatesOneTodoAndResolvesEveryMergedProposal() throws {
        let fixture = try ProposalReviewFixture()
        try fixture.queue(id: "proposal:agenda", title: "Draft agenda #ai-proposed", sourceRef: "[[Meetings/planning/summary#Agenda|ref]]")
        try fixture.queue(id: "proposal:invite", title: "Invite attendees #ai-proposed", sourceRef: "[[Meetings/planning/summary#Invites|ref]]")

        _ = try fixture.reviewer.merge(
            proposalIDs: ["proposal:agenda", "proposal:invite"],
            title: "Prepare the planning session",
            expectedTodoVersion: fixture.todoVersion()
        )

        let queue = try TodoItemIndex(workspaceRootURL: fixture.rootURL).loadTaskViews(today: "2026-01-19").queue
        XCTAssertEqual(queue.map(\.title), ["Prepare the planning session", "Existing task"])
        XCTAssertEqual(queue.first?.sourceRef, "[[Meetings/planning/summary#Agenda|ref]]")
        XCTAssertTrue(try fixture.todoMarkdown().contains("[[Meetings/planning/summary#Agenda|ref]] [[Meetings/planning/summary#Invites|ref]]"))
        XCTAssertEqual(try fixture.inbox.proposalReviewState(id: "proposal:agenda"), .merged)
        XCTAssertEqual(try fixture.inbox.proposalReviewState(id: "proposal:invite"), .merged)
    }

    func testTodoConflictLeavesProposalPendingForRetry() throws {
        let fixture = try ProposalReviewFixture()
        try fixture.queue(id: "proposal:conflict", title: "Do not duplicate #ai-proposed", sourceRef: "[[Meetings/conflict/summary|ref]]")
        let staleVersion = try fixture.todoVersion()
        _ = try fixture.vault.writeMarkdown(
            Data("""
            # Todos

            ## Queue

            - [ ] External edit
            - [ ] Existing task
            """.utf8),
            relativePath: TodoItemIndex.mainTodoRelativePath,
            expectedVersion: staleVersion
        )

        XCTAssertThrowsError(try fixture.reviewer.accept(
            proposalID: "proposal:conflict",
            expectedTodoVersion: staleVersion
        ))
        XCTAssertEqual(try fixture.inbox.proposalReviewState(id: "proposal:conflict"), .pending)
        XCTAssertFalse(try fixture.todoMarkdown().contains("Do not duplicate"))
    }

    func testBatchApprovalPreservesDisplayedOrderAtTopOfQueue() throws {
        let fixture = try ProposalReviewFixture()
        try fixture.queue(id: "proposal:first", title: "First displayed #ai-proposed", sourceRef: "[[Meetings/one/summary|ref]]")
        try fixture.queue(id: "proposal:second", title: "Second displayed #ai-proposed", sourceRef: "[[Meetings/two/summary|ref]]")
        try fixture.queue(id: "proposal:third", title: "Third displayed #ai-proposed", sourceRef: "[[Meetings/three/summary|ref]]")

        _ = try fixture.reviewer.batchAccept(
            proposalIDsInDisplayedOrder: ["proposal:first", "proposal:second", "proposal:third"],
            expectedTodoVersion: fixture.todoVersion()
        )

        let queue = try TodoItemIndex(workspaceRootURL: fixture.rootURL).loadTaskViews(today: "2026-01-19").queue
        XCTAssertEqual(queue.map(\.title), ["First displayed", "Second displayed", "Third displayed", "Existing task"])
        XCTAssertFalse(try fixture.todoMarkdown().contains("#ai-proposed"))
        XCTAssertEqual(try fixture.inbox.proposalReviewState(id: "proposal:first"), .accepted)
        XCTAssertEqual(try fixture.inbox.proposalReviewState(id: "proposal:second"), .accepted)
        XCTAssertEqual(try fixture.inbox.proposalReviewState(id: "proposal:third"), .accepted)
    }

    func testBatchApprovalUsesEditedTitlesWithoutChangingProposalOrder() throws {
        let fixture = try ProposalReviewFixture()
        try fixture.queue(id: "proposal:first", title: "Original first #ai-proposed", sourceRef: "[[Meetings/one/summary|ref]]")
        try fixture.queue(id: "proposal:second", title: "Original second #ai-proposed", sourceRef: "[[Meetings/two/summary|ref]]")

        _ = try fixture.reviewer.batchAccept(
            proposalEditsInDisplayedOrder: [
                (id: "proposal:first", editedTitle: "Edited first"),
                (id: "proposal:second", editedTitle: "Edited second")
            ],
            expectedTodoVersion: fixture.todoVersion()
        )

        let queue = try TodoItemIndex(workspaceRootURL: fixture.rootURL).loadTaskViews(today: "2026-01-19").queue
        XCTAssertEqual(queue.map(\.title), ["Edited first", "Edited second", "Existing task"])
        XCTAssertEqual(try fixture.inbox.proposalReviewState(id: "proposal:first"), .accepted)
        XCTAssertEqual(try fixture.inbox.proposalReviewState(id: "proposal:second"), .accepted)
    }
}

private final class ProposalReviewFixture {
    let rootURL: URL
    let inbox: TasksInbox
    let vault: WorkspaceVault
    let reviewer: ActionItemProposalReviewer

    init() throws {
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent("StillmatterProposalReview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        vault = WorkspaceVault(
            workspaceRootURL: rootURL,
            appSupportRootURL: rootURL.appendingPathComponent(".stillmatter", isDirectory: true)
        )
        inbox = try TasksInbox(databaseURL: rootURL.appendingPathComponent(".stillmatter/Stillmatter.sqlite"))
        reviewer = ActionItemProposalReviewer(inbox: inbox, todoMutator: TodoItemMutator(vault: vault))
        _ = try vault.writeMarkdown(Data("""
        # Todos

        ## Queue

        - [ ] Existing task
        """.utf8), relativePath: TodoItemIndex.mainTodoRelativePath, expectedVersion: nil)
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func queue(id: String, title: String, sourceRef: String) throws {
        XCTAssertTrue(try inbox.queueProposal(id: id, title: title, sourceRef: sourceRef))
    }

    func todoVersion() throws -> WorkspaceFileVersion {
        try XCTUnwrap(vault.versionOfMarkdown(relativePath: TodoItemIndex.mainTodoRelativePath))
    }

    func todoMarkdown() throws -> String {
        let read = try vault.readMarkdown(relativePath: TodoItemIndex.mainTodoRelativePath)
        return String(decoding: read.data, as: UTF8.self)
    }

    func writeSource(_ markdown: String, relativePath: String) throws {
        _ = try vault.writeMarkdown(Data(markdown.utf8), relativePath: relativePath, expectedVersion: nil)
    }

    func readSource(relativePath: String) throws -> String {
        let read = try vault.readMarkdown(relativePath: relativePath)
        return String(decoding: read.data, as: UTF8.self)
    }
}
