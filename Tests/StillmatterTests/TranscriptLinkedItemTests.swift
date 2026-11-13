import XCTest
@testable import StillmatterCore

final class TranscriptLinkedItemTests: XCTestCase {
    private var root: URL!
    override func tearDownWithError() throws { if let root { try FileManager.default.removeItem(at: root) } }
    private func fixture() throws -> (WorkspaceVault, MeetingManagementService, MeetingBrowserDetail, MeetingTranscriptSegment) {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("linked-item-\(UUID())")
        let vault = WorkspaceVault(workspaceRootURL: root.appendingPathComponent("workspace"), appSupportRootURL: root.appendingPathComponent("support"))
        let path = "Meetings/linked/meeting.md"
        _ = try vault.writeMarkdown(Data("---\ntitle: Linked\ncapture_session_id: linked\n---\n# Linked\n".utf8), relativePath: path, expectedVersion: nil)
        let document = TranscriptDocument(schemaVersion: 1, captureSessionID: "linked", meetingRelativePath: path,
            language: .english, detectedLanguages: [.english], engine: "fixture", model: "fixture", generatedAt: Date(timeIntervalSince1970: 0), audioSources: [],
            segments: [.init(id: "late", startSeconds: 7200, endSeconds: 7205, text: "Send the report", language: .english, track: .systemAudio, speaker: "Guest")], diagnostics: [])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        _ = try vault.writeMarkdown(encoder.encode(document), relativePath: "Meetings/linked/transcript.json", expectedVersion: nil)
        let service = MeetingManagementService(vault: vault)
        let detail = try service.detail(for: path)
        let source = try XCTUnwrap(detail.transcript.first)
        return (vault, service, detail, source)
    }
    func testDecisionAndExplicitNoteSavePreserveUserTextAndRejectStaleOrMissingSources() throws {
        let (vault, service, initial, source) = try fixture()
        let path = "Meetings/linked/meeting.md"
        let decision = TranscriptLinkedItem(kind: .decision, text: "Ship it", source: source)
        let saved = try service.createTranscriptItem(decision, for: path, expectedVersion: initial.summaryVersion!)
        let entry = try XCTUnwrap(MeetingOutcomeDocument.entries(in: saved.summary!.decisions, defaultKind: .decision).first)
        XCTAssertEqual(entry.id, decision.id)
        XCTAssertEqual(entry.citations.first?.startSeconds, 7200)
        var edited = entry; edited.text = "Ship next week"
        let changed = try service.saveOutcome(edited, for: path, expectedVersion: saved.summaryVersion!)
        XCTAssertEqual(try MeetingOutcomeDocument.entries(in: changed.summary!.decisions, defaultKind: .decision).first?.citations, entry.citations)
        XCTAssertThrowsError(try service.createTranscriptItem(TranscriptLinkedItem(kind: .action, text: "Stale", source: source), for: path, expectedVersion: initial.summaryVersion!))
        let note = TranscriptLinkedItem(kind: .note, text: "My original-language note\nSecond line", source: source)
        let notes = try service.createTranscriptItem(note, for: path, expectedVersion: changed.notesVersion!)
        XCTAssertTrue(notes.humanNotes.contains("My original-language note\nSecond line"))
        XCTAssertTrue(notes.humanNotes.contains("sm-source:"))
        XCTAssertTrue(notes.humanNotes.contains("late"))
        XCTAssertTrue(notes.humanNotes.contains("7200"))
        XCTAssertEqual(notes.reviewItems.count, 0)
        XCTAssertThrowsError(try service.createTranscriptItem(note, for: path, expectedVersion: changed.notesVersion!))
        XCTAssertEqual(try MeetingManagementService(vault: vault).detail(for: path).humanNotes, notes.humanNotes)
        for value in [" ", "Injected <!-- metadata", "Multiline\nitem"] {
            XCTAssertThrowsError(try service.createTranscriptItem(TranscriptLinkedItem(kind: .action, text: value, source: source), for: path, expectedVersion: notes.summaryVersion!))
        }
        var object = try JSONSerialization.jsonObject(with: vault.readMarkdown(relativePath: "Meetings/linked/transcript.json").data) as! [String: Any]
        object["segments"] = []
        _ = try vault.writeMarkdown(JSONSerialization.data(withJSONObject: object), relativePath: "Meetings/linked/transcript.json", expectedVersion: vault.versionOfMarkdown(relativePath: "Meetings/linked/transcript.json"))
        XCTAssertThrowsError(try service.createTranscriptItem(note, for: path, expectedVersion: notes.notesVersion!))
    }
    func testCreatedActionRetainsCitationAndIdentityThroughEditApprovalAndRestart() throws {
        let (vault, service, detail, source) = try fixture()
        let path = "Meetings/linked/meeting.md"
        let draft = TranscriptLinkedItem(kind: .action, text: "Send edited report", source: source)
        let saved = try service.createTranscriptItem(draft, for: path, expectedVersion: detail.summaryVersion!)
        let action = try XCTUnwrap(saved.reviewItems.first)
        XCTAssertEqual(action.id, draft.id)
        XCTAssertEqual(action.text, "Send edited report")
        XCTAssertNil(action.owner)
        XCTAssertEqual(action.review, "pending")
        XCTAssertEqual(action.origin, "manual")
        XCTAssertEqual(action.citations, [.init(segmentID: "late", startSeconds: 7200, endSeconds: 7205)])
        let edited = try service.editMeetingItem(meetingID: path, item: action, text: "Send final report", owner: "me", dueDate: nil, status: .open)
        let approved = try service.reviewMeetingItems(meetingID: path, items: edited.reviewItems, accept: true)
        XCTAssertEqual(approved.reviewItems.first?.review, "approved")
        let reopened = try MeetingManagementService(vault: vault).detail(for: path)
        XCTAssertEqual(reopened.reviewItems.first?.id, draft.id)
        XCTAssertEqual(reopened.reviewItems.first?.citations, action.citations)
    }
}
