import Foundation
import XCTest
@testable import StillmatterCore

final class MeetingArtifactEdgeCaseTests: XCTestCase {
    private func withStore(_ body: (WorkspaceVault, MeetingArtifactStore) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stillmatter-08-edge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = WorkspaceVault(workspaceRootURL: root.appendingPathComponent("workspace"),
                                   appSupportRootURL: root.appendingPathComponent("support"))
        try body(vault, MeetingArtifactStore(vault: vault, inbox: nil))
    }

    private func write(_ text: String, path: String, vault: WorkspaceVault) throws {
        _ = try vault.writeMarkdown(Data(text.utf8), relativePath: path,
                                   expectedVersion: vault.versionOfMarkdown(relativePath: path))
    }

    func testArtifactMarkerExamplesInNotesRemainLiteralUserContent() throws {
        try withStore { vault, store in
            let notes = "Prose\n```markdown\n<!-- stillmatter-artifact:notes:v1 -->\n```\n"
            try write("# Edge\n## Notes\n" + notes, path: "Meetings/edge/meeting.md", vault: vault)
            let loaded = try store.load(meetingPath: "Meetings/edge/meeting.md", meetingID: "edge")
            XCTAssertEqual(loaded.notes, notes)
            XCTAssertEqual(try store.load(meetingPath: "Meetings/edge/meeting.md", meetingID: "edge").notes, notes)
        }
    }

    func testOtherArtifactMarkerMentionDoesNotChangeFileIdentity() throws {
        try withStore { vault, store in
            let notes = "A literal example: `<!-- stillmatter-artifact:actions:v1 -->`.\n"
            try write("# Edge\n## Notes\n" + notes, path: "Meetings/edge/meeting.md", vault: vault)
            XCTAssertEqual(try store.load(meetingPath: "Meetings/edge/meeting.md", meetingID: "edge").notes, notes)
        }
    }

    func testIdenticalSeparateAndEmbeddedNotesDoNotRequireConflictResolution() throws {
        try withStore { vault, store in
            let notes = "\nIdentical user notes.\n\n"
            try write("# Edge\n## Notes\n" + notes, path: "Meetings/edge/meeting.md", vault: vault)
            try write(notes, path: "Meetings/edge/my-notes.md", vault: vault)
            XCTAssertEqual(try store.load(meetingPath: "Meetings/edge/meeting.md", meetingID: "edge").notes, notes)
        }
    }

    func testValidCRLFCanonicalActionCanBeApprovedWithoutLosingItsIdentity() throws {
        try withStore { vault, store in
            let meeting = "Meetings/edge/meeting.md"
            try write("# Edge\n", path: meeting, vault: vault)
            let extraction = MeetingSummaryExtraction(meeting: meeting, transcript: "Meetings/edge/transcript.json",
                decisions: [], myActionItems: [MeetingOutcome(id: "action", text: "Send recap", citations: [])],
                otherActionItems: [], openQuestions: [])
            try write(String(decoding: JSONEncoder().encode(extraction), as: UTF8.self),
                      path: "Meetings/edge/summary-extraction.json", vault: vault)
            let loaded = try store.load(meetingPath: meeting, meetingID: "edge")
            let actionPath = try XCTUnwrap(loaded.paths["actions"])
            let source = try vault.readMarkdown(relativePath: actionPath)
            let crlf = String(decoding: source.data, as: UTF8.self).replacingOccurrences(of: "\n", with: "\r\n")
            try write(crlf, path: actionPath, vault: vault)
            try store.review(proposalID: "meeting-action:edge:action", accept: true, meetingPath: meeting, meetingID: "edge")
            let approved = try store.load(meetingPath: meeting, meetingID: "edge")
            XCTAssertEqual(approved.reviewStates["action"], .accepted)
            XCTAssertEqual(try TodoItemIndex(workspaceRootURL: vault.rootURL).loadTaskViews(today: "2026-01-01").queue.count, 1)
        }
    }

    func testCRLFSummaryFrontmatterRemainsSeparateFromEditableBody() throws {
        try withStore { vault, store in
            let meeting = "Meetings/edge/meeting.md"
            let summary = "Meetings/edge/summary.md"
            let front = "---\r\ncustom: keep-this\r\n---\r\n"
            try write("# Edge\n", path: meeting, vault: vault)
            try write(front + "# Original summary\r\n", path: summary, vault: vault)
            let loaded = try store.load(meetingPath: meeting, meetingID: "edge")
            XCTAssertEqual(loaded.sections.summary, "# Original summary\r\n")
            var edited = loaded.sections
            edited.summary = "User edit\r\n"
            try store.saveSummary(edited, meetingPath: meeting, meetingID: "edge", expected: loaded.summaryVersion)
            let current = String(decoding: try vault.readMarkdown(relativePath: summary).data, as: UTF8.self)
            XCTAssertTrue(current.hasPrefix(front))
            XCTAssertEqual(try store.load(meetingPath: meeting, meetingID: "edge").sections.summary, "User edit\r\n")
        }
    }

    func testMalformedReferencedCanonicalMetadataIsAnErrorRatherThanAMissingTask() throws {
        try withStore { vault, _ in
            let id = "10000000-0000-4000-8000-000000000001"
            try write("- [ ] Keep this task <!-- sm-item:broken -->\n",
                      path: "Meetings/edge/action-items.md", vault: vault)
            try write("## Queue\n- [[item:\(id)|Keep this task]]\n", path: "Todos/todo.md", vault: vault)
            XCTAssertThrowsError(try TodoItemIndex(workspaceRootURL: vault.rootURL).loadAllItems())
        }
    }

    func testMissingCanonicalProducerPathReturnsActionableError() throws {
        try withStore { vault, store in
            let meeting = "Meetings/edge/meeting.md"
            try write("---\ntitle: Edge\ntype: meeting\n---\n\n## Notes\n\nNotes\n",
                      path: meeting, vault: vault)
            let loaded = try store.load(meetingPath: meeting, meetingID: meeting)
            let incomplete = MeetingArtifactStore.Loaded(notes: loaded.notes, notesVersion: loaded.notesVersion,
                sections: loaded.sections, summaryVersion: loaded.summaryVersion, extraction: loaded.extraction,
                transcript: loaded.transcript, paths: [:], versions: loaded.versions,
                reviewStates: loaded.reviewStates, completionStates: loaded.completionStates)
            XCTAssertThrowsError(try store.publishGenerated(summary: Data(), extraction: loaded.extraction,
                extractionData: Data(), base: incomplete, meetingPath: meeting, meetingID: meeting,
                expectedExtraction: nil)) { error in
                XCTAssertTrue(error.localizedDescription.contains("action-items path"))
            }
        }
    }

    func testNonObjectTranscriptJSONIsAnActionableError() {
        XCTAssertThrowsError(try MeetingTranscriptCodec.text(Data("[]".utf8))) { error in
            XCTAssertTrue(error.localizedDescription.contains("Transcript JSON structure"))
        }
    }

    func testTranscriptHashRetainsLowercaseTwoDigitHexEncoding() {
        XCTAssertEqual(MeetingTranscriptCodec.hash(Data("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
