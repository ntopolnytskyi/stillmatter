import AppKit
import XCTest
import StillmatterCore
import StillmatterPresentation
@testable import StillmatterHostedTestHost

final class LiveNotesMeetingVisibilityHostedTests: XCTestCase {
    @MainActor
    func testRecordingAndProcessingHideMeetingContentThenLaterNotesReadSameFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stillmatter-notes-visibility-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = WorkspaceVault(workspaceRootURL: root.appendingPathComponent("workspace"),
                                   appSupportRootURL: root.appendingPathComponent("support"))
        let meetingPath = "Meetings/live/meeting.md"
        try vault.createDirectory(relativePath: "Meetings/live")
        let doorway = "---\ntitle: Live\ncapture_session_id: session-a\n---\n# Live\n\n## Live notes\n\n"
        _ = try vault.writeMarkdown(Data(doorway.utf8), relativePath: meetingPath, expectedVersion: nil)
        _ = try LiveMeetingNotes(vault: vault, sessionID: "session-a", meetingPath: meetingPath)
            .save("Notes from Recording", expectedVersion: nil)

        let liveSnapshot = CaptureSnapshot(state: .recording, meetingTitle: "Live", meetingRelativePath: meetingPath,
            source: .teams, elapsedSeconds: 1, failureMessage: nil, processingStatus: [], preflightReport: nil,
            micRecording: nil, systemAudioRecording: nil, recordingBundle: nil, transcriptionAudio: nil)
        let live = MeetingManagementService(vault: vault, captureSnapshot: { liveSnapshot })
        let liveView = try await selectedView(for: live)
        XCTAssertTrue(liveView.overviewPage.isHidden)
        XCTAssertTrue(liveView.timelinePage.isHidden)
        XCTAssertTrue(liveView.toolbar.isHidden)
        XCTAssertTrue(liveView.pageSelector.isHidden)
        XCTAssertTrue(liveView.status.stringValue.contains("Recording is active"))

        let jobs = try JobStore(databaseURL: root.appendingPathComponent("jobs.sqlite"))
        _ = try jobs.enqueue(id: "processing", manifest: JobManifest(type: "meeting.transcription", title: "Processing",
            executionClass: .heavy, stages: [JobStageDefinition(id: "run", title: "Run")],
            sourceArtifacts: [JobArtifactReference(relativePath: meetingPath, role: "meeting")],
            metadata: ["capture_session_id": "session-a"]))
        let processing = MeetingManagementService(vault: vault, jobStore: jobs)
        let processingView = try await selectedView(for: processing)
        XCTAssertTrue(processingView.overviewPage.isHidden)
        XCTAssertTrue(processingView.timelinePage.isHidden)
        XCTAssertTrue(processingView.status.stringValue.contains("Processing is in progress"))

        let later = MeetingManagementService(vault: vault)
        XCTAssertEqual(try later.detail(for: meetingPath).humanNotes.trimmingCharacters(in: .newlines), "Notes from Recording")
        let laterView = try await selectedView(for: later)
        XCTAssertFalse(laterView.overviewPage.isHidden)
        XCTAssertEqual(laterView.displayedDetail?.humanNotes.trimmingCharacters(in: .newlines), "Notes from Recording")
    }

    @MainActor
    private func selectedView(for service: MeetingManagementService) async throws -> MeetingManagementView {
        let readModel = MeetingReadModel(workspaceID: UUID().uuidString) {
            MeetingManagementReadSource(serviceProvider: { service })
        }
        let view = MeetingManagementView(readModelProvider: { readModel }, mutationExecutorProvider: { nil },
            playbackTransportProvider: { nil }, openRecording: {}, openWorkspaceFile: { _ in })
        view.refresh(isVisible: true)
        let rows = expectation(for: NSPredicate { _, _ in !view.meetingsModel.visibleRows.isEmpty }, evaluatedWith: view)
        await fulfillment(of: [rows], timeout: 5)
        let row = try XCTUnwrap(view.meetingsModel.visibleRows.first)
        _ = view.meetingsModel.select(meetingID: row.id, selectedIDs: [row.id])
        let detail = expectation(for: NSPredicate { _, _ in view.displayedDetail?.row.id == row.id }, evaluatedWith: view)
        await fulfillment(of: [detail], timeout: 5)
        return view
    }
}
