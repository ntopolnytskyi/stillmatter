import XCTest
@testable import StillmatterCore

final class MeetingOutcomeEditingTests: XCTestCase {
    private var root: URL!
    private var vault: WorkspaceVault!
    private var service: MeetingManagementService!
    private let path = "Meetings/test/meeting.md"
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("outcome-edit-\(UUID().uuidString)")
        vault = WorkspaceVault(workspaceRootURL: root.appendingPathComponent("workspace"), appSupportRootURL: root.appendingPathComponent("support"))
        _ = try vault.writeMarkdown(Data("---\ntitle: Test\ncapture_session_id: test\n---\n# Test\n".utf8), relativePath: path, expectedVersion: nil)
        service = MeetingManagementService(vault: vault)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func entries(_ detail: MeetingBrowserDetail, _ kind: MeetingOutcomeKind) throws -> [MeetingOutcomeEntry] {
        try MeetingOutcomeDocument.entries(in: kind == .decision ? detail.summary!.decisions : detail.summary!.openQuestions, defaultKind: kind)
    }
    private func save(_ entry: MeetingOutcomeEntry, delete: Bool = false) throws -> MeetingBrowserDetail {
        try service.saveOutcome(entry, delete: delete, for: path, expectedVersion: service.detail(for: path).summaryVersion!)
    }
    func testDecisionAndOpenItemsRoundTripIdentityOwnerTypeStatusAndDeletionAcrossRestart() throws {
        let decision = MeetingOutcomeEntry(text: "Ship on Monday", kind: .decision)
        var detail = try save(decision)
        XCTAssertEqual(try entries(detail, .decision), [decision])
        var issue = MeetingOutcomeEntry(text: "Deployment issue", owner: "Alice", kind: .issue)
        detail = try save(issue)
        var question = MeetingOutcomeEntry(text: "Who reviews?", kind: .question)
        detail = try save(question)
        XCTAssertEqual(try entries(detail, .question).map(\.owner), ["Alice", nil])
        issue.resolved = true; issue.text = "Deployment confirmed"
        _ = try save(issue)
        question.owner = "Me"; question.kind = .issue
        _ = try save(question)
        service = MeetingManagementService(vault: WorkspaceVault(workspaceRootURL: vault.rootURL, appSupportRootURL: root.appendingPathComponent("reopen-support")))
        detail = try service.detail(for: path)
        XCTAssertEqual(try entries(detail, .question), [issue, question])
        XCTAssertTrue(String(decoding: try vault.readMarkdown(relativePath: "Meetings/test/open-items.md").data, as: UTF8.self).contains("Deployment confirmed"))
        var edited = decision; edited.text = "Ship on Tuesday"
        detail = try save(edited)
        XCTAssertEqual(try entries(detail, .decision).first?.id, decision.id)
        XCTAssertTrue(try entries(save(edited, delete: true), .decision).isEmpty)
        XCTAssertEqual(try entries(save(question, delete: true), .question), [issue])
        issue.resolved = false
        XCTAssertThrowsError(try save(issue))
    }
    func testConflictKeepsExternalArtifactAndLocalDraftCanBeRetriedOrCancelled() throws {
        let decision = MeetingOutcomeEntry(text: "Original", kind: .decision)
        let detail = try save(decision)
        var external = decision; external.text = "External choice"
        _ = try save(external)
        var draft = decision; draft.text = "My unsaved choice"
        XCTAssertThrowsError(try service.saveOutcome(draft, for: path, expectedVersion: detail.summaryVersion!))
        XCTAssertEqual(try entries(service.detail(for: path), .decision).first?.text, "External choice")
        XCTAssertEqual(draft.text, "My unsaved choice")
        XCTAssertEqual(try entries(save(draft), .decision).first?.text, "My unsaved choice")
        let before = try vault.readMarkdown(relativePath: "Meetings/test/decisions.md").data
        draft.text = "\n"
        XCTAssertThrowsError(try save(draft))
        draft.text = "Injected\n- second item"
        XCTAssertThrowsError(try save(draft))
        draft.text = "Bad <!-- metadata"
        XCTAssertThrowsError(try save(draft))
        XCTAssertEqual(try vault.readMarkdown(relativePath: "Meetings/test/decisions.md").data, before)
        let missing = MeetingOutcomeEntry(text: "Missing", kind: .decision)
        XCTAssertThrowsError(try save(missing, delete: true))
        let sourced = MeetingOutcomeEntry(text: "No evidence", kind: .question, citations: [.init(segmentID: "absent", startSeconds: 0, endSeconds: 1)])
        XCTAssertThrowsError(try save(sourced))
    }
    func testLegacyCitationsAndSurroundingProseSurviveEditsAndRegenerationRetainsID() throws {
        let citation = MeetingOutcomeCitation(segmentID: "s1", startSeconds: 1, endSeconds: 2)
        let extraction = MeetingSummaryExtraction(meeting: path, transcript: "Meetings/test/transcript.json",
            decisions: [.init(id: "d1", text: "Original", citations: [citation])], myActionItems: [], otherActionItems: [],
            openQuestions: [.init(id: "q1", text: "Unknown?", citations: [citation])])
        _ = try vault.writeMarkdown(JSONEncoder().encode(extraction), relativePath: "Meetings/test/summary-extraction.json", expectedVersion: nil)
        let detail = try service.detail(for: path)
        var decision = try XCTUnwrap(entries(detail, .decision).first)
        decision.text = "Edited with original evidence"
        let updated = try save(decision)
        XCTAssertEqual(try entries(updated, .decision).first?.citations, [citation])
        let store = MeetingArtifactStore(vault: vault, inbox: nil)
        let base = try store.load(meetingPath: path, meetingID: "test")
        try store.publishGenerated(summary: Data("New Summary".utf8), extraction: extraction, extractionData: JSONEncoder().encode(extraction), base: base,
            meetingPath: path, meetingID: "test", expectedExtraction: vault.versionOfMarkdown(relativePath: "Meetings/test/summary-extraction.json"))
        XCTAssertEqual(try entries(service.detail(for: path), .decision).first?.id, decision.id)
        let body = "# Decisions\nSome prose.\n" + updated.summary!.decisions
        let replaced = try MeetingOutcomeDocument.replacing(decision, in: body)
        XCTAssertTrue(replaced.hasPrefix("# Decisions\nSome prose.\n"))
        XCTAssertEqual(try MeetingOutcomeDocument.entries(in: replaced, defaultKind: .decision).first?.citations, [citation])
        XCTAssertThrowsError(try MeetingOutcomeDocument.entries(in: "- Broken <!-- sm-item:{}", defaultKind: .decision))
        XCTAssertThrowsError(try MeetingOutcomeDocument.replacing(decision, in: body + "\n" + updated.summary!.decisions))
    }
}
