import XCTest
@testable import StillmatterCore

final class LiveMeetingNotesTests: XCTestCase {
    func testDraftSurvivesReopenAndAutosavePublishesSeparateMeetingFile() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let first = fixture.document(session: "session-a")
        XCTAssertEqual(try first.load().text, "")
        try first.stage("Call notes\n- [ ] Follow up", baseVersion: nil)
        let reopened = fixture.document(session: "session-a")
        XCTAssertEqual(try reopened.load().text, "Call notes\n- [ ] Follow up")
        XCTAssertTrue(try reopened.load().hasDraft)
        _ = try reopened.save("Call notes\n- [ ] Follow up", expectedVersion: nil)
        XCTAssertEqual(try fixture.notesText(), "Call notes\n- [ ] Follow up")
        XCTAssertFalse(try reopened.load().hasDraft)
        XCTAssertFalse(try fixture.doorwayText().contains("Call notes"))
    }

    func testExternalEditRejectsSaveAndPreservesBothVersions() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let document = fixture.document(session: "session-a")
        let base = try document.save("Original", expectedVersion: nil)
        try document.stage("Local draft", baseVersion: base)
        _ = try fixture.vault.writeMarkdown(Data("External edit".utf8), relativePath: fixture.notesPath, expectedVersion: base)
        XCTAssertTrue(try document.load().conflictsWithFile)
        XCTAssertThrowsError(try document.save("Local draft", expectedVersion: base))
        XCTAssertEqual(try fixture.notesText(), "External edit")
        XCTAssertEqual(try fixture.document(session: "session-a").load().text, "Local draft")
        XCTAssertEqual(try fixture.document(session: "session-b").load().text, "External edit")
        XCTAssertEqual(try document.reloadLatest().text, "External edit")
        XCTAssertFalse(try document.load().hasDraft)
    }

    func testExplicitConflictResolutionKeepsExternalCopyBeforeUsingDraft() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let document = fixture.document(session: "session-a")
        let base = try document.save("Original", expectedVersion: nil)
        try document.stage("My resolved text", baseVersion: base)
        _ = try fixture.vault.writeMarkdown(Data("External text".utf8), relativePath: fixture.notesPath, expectedVersion: base)
        let resolved = try document.useDraftPreservingExternal("My resolved text after typing", expectedBaseVersion: base)
        XCTAssertEqual(try fixture.notesText(), "My resolved text after typing")
        XCTAssertEqual(try String(contentsOf: resolved.preservedCopy), "External text")
        XCTAssertFalse(try document.load().hasDraft)
    }

    func testDraftCannotAttachToNewCaptureAtSameMeetingPath() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.document(session: "session-a").stage("A only", baseVersion: nil)
        XCTAssertEqual(try fixture.document(session: "session-b").load().text, "")
    }

    func testPendingConflictFollowsRenamedMeetingFolder() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let document = fixture.document(session: "session-a")
        let base = try document.save("Original", expectedVersion: nil)
        try document.stage("Local draft", baseVersion: base)
        _ = try fixture.vault.writeMarkdown(Data("External edit".utf8), relativePath: fixture.notesPath, expectedVersion: base)
        let oldFolder = fixture.root.appendingPathComponent("workspace/Meetings/live")
        let newFolder = fixture.root.appendingPathComponent("workspace/Meetings/renamed")
        try FileManager.default.moveItem(at: oldFolder, to: newFolder)

        let pending = try XCTUnwrap(LiveMeetingNotes.pendingDocuments(in: fixture.vault).first)
        XCTAssertEqual(pending.meetingRelativePath, "Meetings/renamed/meeting.md")
        XCTAssertEqual(try pending.load().text, "Local draft")
        XCTAssertTrue(try pending.load().conflictsWithFile)
        let resolved = try pending.useDraftPreservingExternal("Local draft", expectedBaseVersion: base)
        XCTAssertEqual(try String(contentsOf: newFolder.appendingPathComponent("my-notes.md")), "Local draft")
        XCTAssertEqual(try String(contentsOf: resolved.preservedCopy), "External edit")
        XCTAssertTrue(LiveMeetingNotes.pendingDocuments(in: fixture.vault).isEmpty)
    }

    func testStartupRecoversInterruptedDraftOnlyForOriginalCaptureAndUnchangedFile() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let document = fixture.document(session: "session-a")
        try document.stage("Recovered after interruption", baseVersion: nil)
        let restarted = MeetingCaptureService(vault: fixture.vault, preflight: { .readyForTesting })
        XCTAssertTrue(restarted.canStartCapture)
        let recovered = expectation(for: NSPredicate { _, _ in
            (try? fixture.notesText()) == "Recovered after interruption"
        }, evaluatedWith: restarted)
        wait(for: [recovered], timeout: 5)
        XCTAssertNil(restarted.snapshot.notesRecoveryWarning)
        XCTAssertEqual(try fixture.notesText(), "Recovered after interruption")
        XCTAssertFalse(try document.load().hasDraft)

        let base = try fixture.vault.readMarkdown(relativePath: fixture.notesPath).version
        try document.stage("Local conflict", baseVersion: base)
        _ = try fixture.vault.writeMarkdown(Data("External".utf8), relativePath: fixture.notesPath, expectedVersion: base)
        XCTAssertFalse(LiveMeetingNotes.recoverPendingDrafts(in: fixture.vault).isEmpty)
        XCTAssertEqual(try fixture.notesText(), "External")
        XCTAssertEqual(try document.load().text, "Local conflict")
    }

    func testWriteFailureRetainsDraftWithoutClaimingCanonicalSave() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let document = fixture.document(session: "session-a")
        let blocker = fixture.root.appendingPathComponent("workspace/Meetings/live/my-notes.md")
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        XCTAssertThrowsError(try document.save("Still here", expectedVersion: nil))
        try FileManager.default.removeItem(at: blocker)
        let recovered = try fixture.document(session: "session-a").load()
        XCTAssertTrue(recovered.hasDraft)
        XCTAssertEqual(recovered.text, "Still here")
        XCTAssertNil(try fixture.vault.versionOfMarkdown(relativePath: fixture.notesPath))
    }

    func testFailedDraftStagingDoesNotClaimRecoverableContent() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let blocker = fixture.root.appendingPathComponent("support/MeetingArtifacts/LiveNotes")
        try FileManager.default.createDirectory(at: blocker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("blocked".utf8).write(to: blocker)
        XCTAssertThrowsError(try fixture.document(session: "session-a").save("Unsaved", expectedVersion: nil)) { error in
            guard case .draftNotStored = error as? LiveMeetingNotesError else {
                return XCTFail("Expected a truthful draft-staging error, got \(error)")
            }
        }
        XCTAssertNil(try fixture.vault.versionOfMarkdown(relativePath: fixture.notesPath))
    }

    func testRecoveryNeverAttachesAnOldDraftToAnotherCapture() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.document(session: "session-b").stage("B draft", baseVersion: nil)
        let restarted = MeetingCaptureService(vault: fixture.vault, preflight: { .readyForTesting })
        let warned = expectation(for: NSPredicate { _, _ in
            restarted.snapshot.notesRecoveryWarning != nil
        }, evaluatedWith: restarted)
        wait(for: [warned], timeout: 5)
        XCTAssertNotNil(restarted.snapshot.notesRecoveryWarning)
        XCTAssertNil(try fixture.vault.versionOfMarkdown(relativePath: fixture.notesPath))
        XCTAssertEqual(try fixture.document(session: "session-b").load().text, "B draft")
    }

    func testReloadFailureLeavesRecoverableDraftIntact() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let document = fixture.document(session: "session-a")
        try document.stage("Local draft", baseVersion: nil)
        let blocker = fixture.root.appendingPathComponent("workspace/Meetings/live/my-notes.md")
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: true)
        XCTAssertThrowsError(try document.reloadLatest())
        try FileManager.default.removeItem(at: blocker)
        XCTAssertEqual(try fixture.document(session: "session-a").load().text, "Local draft")
    }

    func testAlreadyPublishedDraftClearsOnLoadAfterInterruptedCleanup() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let document = fixture.document(session: "session-a")
        let version = try document.save("Published", expectedVersion: nil)
        try document.stage("Published", baseVersion: version)
        let state = try document.load()
        XCTAssertFalse(state.hasDraft)
        XCTAssertEqual(state.text, "Published")
    }

    func testMeetingEditorUsesSameFileWhileCaptureIsLive() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        _ = try fixture.document(session: "session-a").save("Live first", expectedVersion: nil)
        let snapshot = CaptureSnapshot(state: .recording, meetingTitle: "Live", meetingRelativePath: fixture.meetingPath,
            source: .teams, elapsedSeconds: 1, failureMessage: nil, processingStatus: [], preflightReport: nil,
            micRecording: nil, systemAudioRecording: nil, recordingBundle: nil, transcriptionAudio: nil)
        let meetings = MeetingManagementService(vault: fixture.vault, captureSnapshot: { snapshot })
        let first = try meetings.detail(for: fixture.meetingPath)
        XCTAssertEqual(first.humanNotes, "Live first")
        _ = try meetings.saveHumanNotes("Edited in Meeting", for: fixture.meetingPath,
                                        expectedVersion: XCTUnwrap(first.notesVersion))
        XCTAssertEqual(try fixture.notesText(), "Edited in Meeting")
        XCTAssertFalse(try fixture.doorwayText().contains("Edited in Meeting"))
    }

    func testServiceStopFlushesStagedDraftWithoutRecordingView() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let service = MeetingCaptureService(vault: fixture.vault, preflight: { .readyForTesting })
        let session = try service.startManual()
        try XCTUnwrap(service.liveNotesDocument()).stage("Last typed words", baseVersion: nil)
        _ = try service.stopManual()
        let notesPath = (session.meetingRelativePath as NSString).deletingLastPathComponent + "/my-notes.md"
        XCTAssertEqual(String(decoding: try fixture.vault.readMarkdown(relativePath: notesPath).data, as: UTF8.self),
                       "Last typed words")
    }

    func testServiceStopPreservesConflictingDraftAndWarnsWithoutReplacingExternalFile() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let service = MeetingCaptureService(vault: fixture.vault, preflight: { .readyForTesting })
        let session = try service.startManual()
        let document = try XCTUnwrap(service.liveNotesDocument())
        try document.stage("Local last words", baseVersion: nil)
        let path = (session.meetingRelativePath as NSString).deletingLastPathComponent + "/my-notes.md"
        _ = try fixture.vault.writeMarkdown(Data("External last words".utf8), relativePath: path, expectedVersion: nil)
        _ = try service.stopManual()
        XCTAssertEqual(String(decoding: try fixture.vault.readMarkdown(relativePath: path).data, as: UTF8.self),
                       "External last words")
        XCTAssertEqual(try document.load().text, "Local last words")
        XCTAssertNotNil(service.snapshot.notesRecoveryWarning)
    }

    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stillmatter-live-notes-\(UUID().uuidString)")
        let vault: WorkspaceVault
        let meetingPath = "Meetings/live/meeting.md"
        let notesPath = "Meetings/live/my-notes.md"

        init() throws {
            vault = WorkspaceVault(workspaceRootURL: root.appendingPathComponent("workspace"),
                                   appSupportRootURL: root.appendingPathComponent("support"))
            try vault.createDirectory(relativePath: "Meetings/live")
            _ = try vault.writeMarkdown(Data("capture_session_id: session-a\n# Meeting\n".utf8), relativePath: meetingPath, expectedVersion: nil)
        }

        func document(session: String) -> LiveMeetingNotes {
            LiveMeetingNotes(vault: vault, sessionID: session, meetingPath: meetingPath)
        }

        func notesText() throws -> String { String(decoding: try vault.readMarkdown(relativePath: notesPath).data, as: UTF8.self) }
        func doorwayText() throws -> String { String(decoding: try vault.readMarkdown(relativePath: meetingPath).data, as: UTF8.self) }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
}
