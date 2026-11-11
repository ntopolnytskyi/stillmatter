import XCTest
@testable import StillmatterCore

final class MeetingSpeakerCorrectionTests: XCTestCase {
    private var root: URL!
    private var vault: WorkspaceVault!
    private let meeting = "Meetings/correction/meeting.md"
    private var service: MeetingManagementService { MeetingManagementService(vault: vault, inbox: inbox) }
    private var inbox: TasksInbox!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("speaker-correction-\(UUID())")
        vault = WorkspaceVault(workspaceRootURL: root.appendingPathComponent("workspace"), appSupportRootURL: root.appendingPathComponent("support"))
        inbox = try TasksInbox(databaseURL: root.appendingPathComponent("support/inbox.sqlite")).scoped(to: vault.rootURL)
        try write("---\ntitle: Correction\ncapture_session_id: correction\n---\n# Correction\n", "meeting.md")
        try write("# Summary\nOriginal analysis", "summary.md")
        try write("Transcript ready", "transcript.md")
        let extraction = MeetingSummaryExtraction(meeting: meeting, transcript: "Meetings/correction/transcript.json", decisions: [], myActionItems: [.init(id: "task", text: "Keep approved task", citations: [])], otherActionItems: [], openQuestions: [])
        try write(String(decoding: JSONEncoder().encode(extraction), as: UTF8.self), "summary-extraction.json")
        try writeTranscript()
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func write(_ text: String, _ name: String) throws {
        let path = "Meetings/correction/" + name
        _ = try vault.writeMarkdown(Data(text.utf8), relativePath: path, expectedVersion: vault.versionOfMarkdown(relativePath: path))
    }
    private func writeTranscript(label: String = "Speaker 1", id: String = "s1", start: Double = 1) throws {
        let document = TranscriptDocument(schemaVersion: 1, captureSessionID: "correction", meetingRelativePath: meeting,
            language: .english, detectedLanguages: [.english], engine: "synthetic", model: "synthetic", generatedAt: Date(timeIntervalSince1970: 0), audioSources: [],
            segments: [.init(id: id, startSeconds: start, endSeconds: start + 1, text: "Keep spoken words", language: .english, track: .systemAudio, speaker: label)], diagnostics: [])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try write(String(decoding: encoder.encode(document), as: UTF8.self), "transcript.json")
    }

    func testRepeatedCorrectionSurvivesReopenWithoutChangingSourceOrApprovedItems() throws {
        _ = try service.detail(for: "correction")
        try service.reviewAction(id: "meeting-action:correction:task", accept: true)
        let original = try service.detail(for: "correction")
        _ = try service.correctSpeaker(meetingID: "correction", segmentID: "s1", name: "Alice")
        let renamed = try service.correctSpeaker(meetingID: "correction", segmentID: "s1", name: "Олена")
        XCTAssertEqual(renamed.transcript.first?.speaker, "Олена")
        let reopened = try service.detail(for: "correction")
        XCTAssertEqual(reopened.transcript.first?.speaker, "Олена")
        XCTAssertEqual(reopened.transcript.first?.id, "s1")
        XCTAssertEqual(reopened.transcript.first?.startSeconds, 1)
        XCTAssertEqual(reopened.transcript.first?.text, "Keep spoken words")
        XCTAssertEqual(reopened.myActionItems, original.myActionItems)
        XCTAssertEqual(reopened.summary, original.summary)
        XCTAssertTrue(reopened.analysisOutdated)
    }
    func testAcousticSpeakerCorrectionUpdatesEverySupportedPhraseAndSurvivesNewLabels() throws {
        let path = "Meetings/correction/transcript.json"
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: vault.readMarkdown(relativePath: path).data) as? [String: Any])
        var segments = try XCTUnwrap(object["segments"] as? [[String: Any]])
        var second = segments[0]; second["id"] = "s2"; second["start"] = 5; second["end"] = 6
        segments.append(second); object["segments"] = segments
        object["audio_sources"] = [["track": "system-audio", "filePath": "/synthetic", "selection": "fixture"]]
        object["speaker_turns"] = [["start": 0, "end": 7, "track": "system-audio", "cluster_id": 3]]
        try write(String(decoding: JSONSerialization.data(withJSONObject: object), as: UTF8.self), "transcript.json")
        let updated = try service.correctSpeaker(meetingID: "correction", segmentID: "s1", name: "Alice")
        XCTAssertEqual(updated.transcript.map(\.speaker), ["Alice", "Alice"])
        // Simulate an old worker publishing a renamed cluster and regenerated IDs.
        for index in segments.indices { segments[index]["speaker"] = "Speaker 99"; segments[index]["id"] = "new-\(index)" }
        object["segments"] = segments
        try write(String(decoding: JSONSerialization.data(withJSONObject: object), as: UTF8.self), "transcript.json")
        XCTAssertEqual(try service.detail(for: "correction").transcript.map(\.speaker), ["Alice", "Alice"])
        XCTAssertEqual(try service.correctSpeaker(meetingID: "correction", segmentID: "new-1", name: "Bob").transcript.map(\.speaker), ["Bob", "Bob"])
    }

    func testChangedTimingNeverTransfersAnIdentityByReusedIDOrLabel() throws {
        _ = try service.correctSpeaker(meetingID: "correction", segmentID: "s1", name: "Alice")
        try writeTranscript(label: "Speaker 1", id: "s1", start: 10)
        let remapped = try service.detail(for: "correction")
        XCTAssertEqual(remapped.transcript.first?.speaker, "Speaker 1")
        XCTAssertTrue(remapped.speakerReviewRequired)
        XCTAssertTrue(remapped.analysisOutdated)
        XCTAssertEqual(try service.correctSpeaker(meetingID: "correction", segmentID: "s1", name: "Bob").transcript.first?.speaker, "Bob")
        // Original evidence and choice stay available if the original segmentation returns.
        try writeTranscript()
        XCTAssertEqual(try service.detail(for: "correction").transcript.first?.speaker, "Alice")
    }

    func testInvalidNameMissingSourceAndArchivedMeetingDoNotMutateIdentity() throws {
        for name in ["", "  ", "Alice\nBob", "Alice\tBob", String(repeating: "x", count: 201)] {
            XCTAssertThrowsError(try service.correctSpeaker(meetingID: "correction", segmentID: "s1", name: name))
        }
        XCTAssertThrowsError(try service.correctSpeaker(meetingID: "correction", segmentID: "missing", name: "Alice"))
        XCTAssertFalse(try service.detail(for: "correction").analysisOutdated)
        XCTAssertEqual(try service.detail(for: "correction").transcript.first?.speaker, "Speaker 1")
        try write("{\"archived\":true}", "archive.json")
        XCTAssertThrowsError(try service.correctSpeaker(meetingID: "correction", segmentID: "s1", name: "Alice"))
    }

    func testExternalTranscriptTextEditKeepsManualChoiceAndUnknownMetadata() throws {
        _ = try service.correctSpeaker(meetingID: "correction", segmentID: "s1", name: "Alice")
        let path = "Meetings/correction/transcript.txt"
        let text = String(decoding: try vault.readMarkdown(relativePath: path).data, as: UTF8.self)
        try write(text.replacingOccurrences(of: "Keep spoken words", with: "External words"), "transcript.txt")
        let updated = try service.detail(for: "correction")
        XCTAssertEqual(updated.transcript.first?.speaker, "Alice")
        XCTAssertEqual(updated.transcript.first?.text, "External words")
        let json = try vault.readMarkdown(relativePath: "Meetings/correction/transcript.json").data
        let plain = try vault.readMarkdown(relativePath: path).data
        XCTAssertEqual(try MeetingTranscriptCodec.json(plain, path: path), try MeetingTranscriptCodec.canonicalJSON(json))
    }

    func testExplicitExternalIdentityEditAdvancesManualChoiceButAnOlderWorkerCannot() throws {
        _ = try service.correctSpeaker(meetingID: "correction", segmentID: "s1", name: "Alice")
        let path = "Meetings/correction/transcript.txt"
        let text = String(decoding: try vault.readMarkdown(relativePath: path).data, as: UTF8.self)
        try write(text.replacingOccurrences(of: "Alice", with: "Olena"), "transcript.txt")
        XCTAssertEqual(try service.detail(for: "correction").transcript.first?.speaker, "Olena")
        try writeTranscript(label: "Worker name")
        XCTAssertEqual(try service.detail(for: "correction").transcript.first?.speaker, "Olena")
    }

}
