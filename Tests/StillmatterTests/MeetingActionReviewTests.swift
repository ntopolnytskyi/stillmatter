import XCTest
import SQLite3
@testable import StillmatterCore

final class MeetingActionReviewTests: XCTestCase {
    private var root: URL!
    private var vault: WorkspaceVault!
    private let meeting = "Meetings/review/meeting.md"
    private var store: MeetingArtifactStore { MeetingArtifactStore(vault: vault, inbox: nil) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("action-review-\(UUID().uuidString)")
        vault = WorkspaceVault(workspaceRootURL: root.appendingPathComponent("workspace"), appSupportRootURL: root.appendingPathComponent("support"))
        try write(meeting, "---\ntitle: Review\ncapture_session_id: review\n---\n## Notes\n- [ ] Note task\n")
        let extraction = MeetingSummaryExtraction(meeting: meeting, transcript: "Meetings/review/transcript.json", decisions: [],
            myActionItems: [.init(id: "first", text: "First #ai-gen #need-approve", citations: []), .init(id: "second", text: "Second #ai-gen #need-approve", citations: [])],
            otherActionItems: [.init(id: "unknown", text: "Unknown task", citations: [])], openQuestions: [])
        try write("Meetings/review/summary-extraction.json", String(decoding: JSONEncoder().encode(extraction), as: UTF8.self))
        _ = try store.load(meetingPath: meeting, meetingID: "review")
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func write(_ path: String, _ text: String) throws {
        _ = try vault.writeMarkdown(Data(text.utf8), relativePath: path, expectedVersion: vault.versionOfMarkdown(relativePath: path))
    }
    private func items() throws -> [MeetingReviewItem] { try store.reviewItems(meetingPath: meeting, meetingID: "review") }

    func testBatchApprovesInDisplayedOrderWithSameIdentityAndIdempotentRetry() throws {
        let pending = try items().filter { $0.owner == "me" && $0.review == "pending" }
        try store.reviewItems(pending.reversed(), accept: true, meetingPath: meeting, meetingID: "review")
        try store.reviewItems(pending.reversed(), accept: true, meetingPath: meeting, meetingID: "review")
        let queue = try TodoItemIndex(workspaceRootURL: vault.rootURL).loadTaskViews(today: "2026-11-13").queue
        XCTAssertEqual(queue.prefix(2).map(\.id), pending.reversed().map(\.id))
        XCTAssertFalse(queue.contains { $0.rawText.contains("#need-approve") })
        XCTAssertTrue(queue.prefix(2).allSatisfy { $0.rawText.contains("#ai-gen") && $0.canonicalLocation != nil })
        XCTAssertEqual(try items().filter { $0.review == "approved" }.count, 3)
    }
    func testUnknownOwnerCannotApproveAndOtherOwnerStaysMeetingOnly() throws {
        let unknown = try XCTUnwrap(items().first { !$0.hasOwner })
        XCTAssertThrowsError(try store.reviewItems([unknown], accept: true, meetingPath: meeting, meetingID: "review"))
        try store.editReviewItem(unknown, text: "Assigned task #ai-gen #need-approve", owner: "Alice", dueDate: "2026-12-02", status: .open, meetingPath: meeting, meetingID: "review")
        let assigned = try XCTUnwrap(items().first { $0.id == unknown.id })
        XCTAssertEqual(assigned.dueDate, "2026-12-02")
        try store.reviewItems([assigned], accept: true, meetingPath: meeting, meetingID: "review")
        XCTAssertEqual(try items().first { $0.id == assigned.id }?.review, "approved")
        XCTAssertFalse(try TodoItemIndex(workspaceRootURL: vault.rootURL).loadAllItems().contains { $0.id == assigned.id })
    }

    func testEditNotePostponeOpenCompleteAndTodoWriteBack() throws {
        var note = try XCTUnwrap(items().first { $0.origin == "note" })
        for status in [TodoStatus.blocked, .open, .done] {
            try store.editReviewItem(note, text: "Edited note #work", owner: "me", dueDate: nil, status: status, meetingPath: meeting, meetingID: "review")
            note = try XCTUnwrap(items().first { $0.id == note.id })
            XCTAssertEqual(note.status, status)
            let todo = try XCTUnwrap(TodoItemIndex(workspaceRootURL: vault.rootURL).loadAllItems().first { $0.id == note.id })
            XCTAssertEqual(todo.status, status)
            XCTAssertEqual(todo.title, "Edited note #work")
            XCTAssertTrue(todo.canonicalLocation?.relativePath.hasSuffix("my-notes.md") == true)
        }
        XCTAssertThrowsError(try store.editReviewItem(note, text: note.text, owner: "me", dueDate: nil, status: .open, meetingPath: meeting, meetingID: "review"))
    }

    func testRejectedAndStaleBatchCannotProducePartialApproval() throws {
        let pending = try items().filter(\.isPending)
        try store.reviewItems([pending[0]], accept: false, meetingPath: meeting, meetingID: "review")
        try store.reviewItems([pending[0]], accept: false, meetingPath: meeting, meetingID: "review")
        XCTAssertThrowsError(try store.reviewItems(Array(pending.prefix(2)), accept: true, meetingPath: meeting, meetingID: "review"))
        XCTAssertEqual(try items().filter { $0.review == "approved" }.count, 1)
        XCTAssertEqual(try items().first { $0.id == pending[0].id }?.review, "rejected")
        let second = pending[1]
        try store.editReviewItem(second, text: "Externally revised", owner: "me", dueDate: nil, status: .open, meetingPath: meeting, meetingID: "review")
        XCTAssertThrowsError(try store.reviewItems([second], accept: true, meetingPath: meeting, meetingID: "review"))
        XCTAssertThrowsError(try store.editReviewItem(second, text: "Stale", owner: "me", dueDate: nil, status: .open, meetingPath: meeting, meetingID: "review"))
    }

    func testInvalidEditsPreserveCanonicalFilesAndDueUncertainty() throws {
        let item = try XCTUnwrap(items().first)
        for (text, owner, due) in [("", "me", ""), ("Bad\ntext", "me", ""), ("Task", "bad\nowner", ""), ("Task <!-- injected -->", "me", ""), ("Task", "me", "2026-02-30")] {
            XCTAssertThrowsError(try store.editReviewItem(item, text: text, owner: owner, dueDate: due.isEmpty ? nil : due, status: .open, meetingPath: meeting, meetingID: "review"))
        }
        XCTAssertEqual(try items().first?.rawLine, item.rawLine)
    }

    func testBatchRecoversAfterEveryFileBoundaryWithoutDuplicateTodo() throws {
        enum Crash: Error { case injected }
        let pending = try items().filter { $0.owner == "me" && $0.isPending }
        for stop in 0...3 {
            let isolatedRoot = root.appendingPathComponent("recovery-\(stop)")
            try FileManager.default.copyItem(at: vault.rootURL, to: isolatedRoot)
            let isolated = WorkspaceVault(workspaceRootURL: isolatedRoot, appSupportRootURL: root.appendingPathComponent("recovery-support-\(stop)"))
            let failing = MeetingArtifactStore(vault: isolated, inbox: nil, checkpoint: { if $0 == stop { throw Crash.injected } })
            XCTAssertThrowsError(try failing.reviewItems(pending, accept: true, meetingPath: meeting, meetingID: "review"))
            let reopened = MeetingArtifactStore(vault: isolated, inbox: nil)
            XCTAssertEqual(try reopened.reviewItems(meetingPath: meeting, meetingID: "review").filter { $0.review == "approved" }.count, 3)
            try reopened.reviewItems(pending, accept: true, meetingPath: meeting, meetingID: "review")
            let queue = try TodoItemIndex(workspaceRootURL: isolatedRoot).loadTaskViews(today: "2026-11-13").queue
            XCTAssertEqual(queue.prefix(2).map(\.id), pending.map(\.id))
            XCTAssertEqual(queue.count, 3)
        }
    }

    func testTodoEditsAndCompletionWriteBackToGeneratedCheckbox() throws {
        let pending = try XCTUnwrap(items().first { $0.isPending && $0.owner == "me" })
        try store.reviewItems([pending], accept: true, meetingPath: meeting, meetingID: "review")
        var todo = try XCTUnwrap(TodoItemIndex(workspaceRootURL: vault.rootURL).loadAllItems().first { $0.id == pending.id })
        var queue = try vault.readMarkdown(relativePath: TodoItemIndex.mainTodoRelativePath)
        _ = try MeetingNoteTodoBridge(vault: vault).updateText(item: todo, text: "Edited through Todo #ai-gen", expectedQueueVersion: queue.version)
        todo = try XCTUnwrap(TodoItemIndex(workspaceRootURL: vault.rootURL).loadAllItems().first { $0.id == pending.id })
        queue = try vault.readMarkdown(relativePath: TodoItemIndex.mainTodoRelativePath)
        _ = try TodoItemMutator(vault: vault, today: { "2026-11-13" }).updateStatus(item: todo, status: .done, expectedVersion: queue.version)
        let canonical = try XCTUnwrap(items().first { $0.id == pending.id })
        XCTAssertEqual(canonical.text, "Edited through Todo #ai-gen done: 2026-11-13")
        XCTAssertEqual(canonical.status, .done)
        XCTAssertTrue(canonical.path.hasSuffix("action-items.md"))
    }

    func testIndividualOwnerCorrectionIsIndependentOfTranscriptSpeakerCorrection() throws {
        let document = TranscriptDocument(schemaVersion: 1, captureSessionID: "review", meetingRelativePath: meeting,
            language: .english, detectedLanguages: [.english], engine: "fixture", model: "synthetic", generatedAt: Date(timeIntervalSince1970: 0),
            audioSources: [], segments: [.init(id: "s1", startSeconds: 0, endSeconds: 1, text: "A commitment", language: .english, track: .microphone, speaker: "Me")], diagnostics: [])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try write("Meetings/review/transcript.json", String(decoding: encoder.encode(document), as: UTF8.self))
        let service = MeetingManagementService(vault: vault)
        let initial = try service.detail(for: meeting)
        let item = try XCTUnwrap(initial.reviewItems.first { $0.isPending && $0.owner == "me" })
        _ = try service.editMeetingItem(meetingID: meeting, item: item, text: item.text, owner: "Olena", dueDate: nil, status: .open)
        let source = try XCTUnwrap(service.detail(for: meeting).transcript.first)
        let corrected = try service.correctSpeaker(meetingID: meeting, source: source, name: "Alice")
        XCTAssertEqual(corrected.transcript.first?.speaker, "Alice")
        XCTAssertEqual(corrected.reviewItems.first { $0.id == item.id }?.owner, "Olena")
        let accepted = try service.reviewMeetingItems(meetingID: meeting, items: [try XCTUnwrap(corrected.reviewItems.first { $0.id == item.id })], accept: true)
        XCTAssertEqual(accepted.reviewItems.first { $0.id == item.id }?.review, "approved")
        XCTAssertFalse(try TodoItemIndex(workspaceRootURL: vault.rootURL).loadAllItems().contains { $0.id == item.id })
        try write("Meetings/review/archive.json", "{\"archived\":true}")
        XCTAssertThrowsError(try service.editMeetingItem(meetingID: meeting, item: item, text: "Blocked", owner: "me", dueDate: nil, status: .open))
        XCTAssertThrowsError(try service.reviewMeetingItems(meetingID: meeting, items: [item], accept: false))
    }

    func testReviewDatabaseFailureIsReportedAndDurableIntentRetriesWithoutDuplication() throws {
        let databaseURL = root.appendingPathComponent("reviews.sqlite")
        let inbox = try TasksInbox(databaseURL: databaseURL)
        let proposal = "meeting-action:review:first"
        XCTAssertTrue(try inbox.queueProposal(id: proposal, title: "First", sourceRef: "[[Meetings/review/summary]]"))
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "CREATE TRIGGER fail_review BEFORE UPDATE ON proposal_reviews BEGIN SELECT RAISE(ABORT, 'injected review failure'); END", nil, nil, nil), SQLITE_OK)
        let reviewer = MeetingArtifactStore(vault: vault, inbox: inbox)
        let pending = try XCTUnwrap(reviewer.reviewItems(meetingPath: meeting, meetingID: "review").first { $0.isPending && $0.owner == "me" })
        XCTAssertThrowsError(try reviewer.reviewItems([pending, pending], accept: true, meetingPath: meeting, meetingID: "review"))
        XCTAssertEqual(try inbox.proposalReviewState(id: proposal), .pending)
        XCTAssertEqual(sqlite3_exec(database, "DROP TRIGGER fail_review", nil, nil, nil), SQLITE_OK)
        try reviewer.reviewItems([pending], accept: true, meetingPath: meeting, meetingID: "review")
        XCTAssertEqual(try inbox.proposalReviewState(id: proposal), .accepted)
        XCTAssertEqual(try TodoItemIndex(workspaceRootURL: vault.rootURL).loadAllItems().filter { $0.id == pending.id }.count, 1)
    }

    func testTodoTextEditFindsRenamedCanonicalActionArtifact() throws {
        let pending = try XCTUnwrap(items().first { $0.isPending && $0.owner == "me" })
        try store.reviewItems([pending], accept: true, meetingPath: meeting, meetingID: "review")
        let renamed = "Meetings/review/renamed-actions.md"
        try FileManager.default.moveItem(at: vault.rootURL.appendingPathComponent(pending.path), to: vault.rootURL.appendingPathComponent(renamed))
        let todo = try XCTUnwrap(TodoItemIndex(workspaceRootURL: vault.rootURL).loadAllItems().first { $0.id == pending.id })
        XCTAssertEqual(todo.canonicalLocation?.relativePath, renamed)
        let queue = try vault.readMarkdown(relativePath: TodoItemIndex.mainTodoRelativePath)
        _ = try MeetingNoteTodoBridge(vault: vault).updateText(item: todo, text: "Renamed source edit #ai-gen", expectedQueueVersion: queue.version)
        let updated = try XCTUnwrap(items().first { $0.id == pending.id })
        XCTAssertEqual(updated.text, "Renamed source edit #ai-gen")
        XCTAssertEqual(updated.path, renamed)
    }

    func testReassignmentRemovesAndRestoresSamePersonalTodoReference() throws {
        var note = try XCTUnwrap(items().first { $0.origin == "note" })
        for owner in ["Alice", "me"] {
            try store.editReviewItem(note, text: note.text, owner: owner, dueDate: nil, status: .open, meetingPath: meeting, meetingID: "review")
            note = try XCTUnwrap(items().first { $0.id == note.id })
            let personal = try TodoItemIndex(workspaceRootURL: vault.rootURL).loadAllItems().filter { $0.id == note.id }
            XCTAssertEqual(personal.count, owner == "me" ? 1 : 0)
        }
        XCTAssertThrowsError(try store.editReviewItem(note, text: note.text, owner: nil, dueDate: nil, status: .open, meetingPath: meeting, meetingID: "review"))
        XCTAssertEqual(try items().first { $0.id == note.id }?.owner, "me")
    }

}
