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
        let liveElements = visibleElements(in: liveView)
        XCTAssertTrue(liveElements.contains { $0.contains("Recording is active") })
        XCTAssertFalse(liveElements.contains { $0.contains("Notes from Recording") || $0 == "Meeting audio" })

        let jobs = try JobStore(databaseURL: root.appendingPathComponent("jobs.sqlite"))
        _ = try jobs.enqueue(id: "processing", manifest: JobManifest(type: "meeting.transcription", title: "Processing",
            executionClass: .heavy, stages: [JobStageDefinition(id: "run", title: "Run")],
            sourceArtifacts: [JobArtifactReference(relativePath: meetingPath, role: "meeting")],
            metadata: ["capture_session_id": "session-a"]))
        let processing = MeetingManagementService(vault: vault, jobStore: jobs)
        let processingView = try await selectedView(for: processing)
        processingView.openTimeline()
        XCTAssertTrue(processingView.status.isHidden)
        let refreshed = expectation(description: "Processing detail refreshes after Transcript selection")
        processingView.meetingsModel.detail.refreshSelectedDetail { result in
            if case .success = result { refreshed.fulfill() }
        }
        await fulfillment(of: [refreshed], timeout: 5)
        XCTAssertFalse(processingView.status.isHidden)
        let processingElements = visibleElements(in: processingView)
        XCTAssertTrue(processingElements.contains { $0.contains("Processing is in progress") })
        XCTAssertFalse(processingElements.contains { $0.contains("Notes from Recording") || $0 == "Meeting audio" })

        let later = MeetingManagementService(vault: vault)
        XCTAssertEqual(try later.detail(for: meetingPath).humanNotes.trimmingCharacters(in: .newlines), "Notes from Recording")
        let laterView = try await selectedView(for: later)
        XCTAssertEqual(laterView.meetingsModel.detail.page, .summary)
        XCTAssertTrue(laterView.pinnedAudio.isHidden, "Summary keeps audio controls out of the workspace")
        laterView.openTimeline()
        XCTAssertFalse(laterView.pinnedAudio.isHidden, "Transcript owns the audio controls")
        let laterElements = visibleElements(in: laterView)
        XCTAssertTrue(laterElements.contains("Meeting audio"), "Visible elements: \(laterElements)")
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

    @MainActor
    private func visibleElements(in view: NSView) -> [String] {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.frame = window.contentView?.bounds ?? .zero
        view.layoutSubtreeIfNeeded()
        var elements: [String] = []
        var visited = Set<ObjectIdentifier>()
        func collect(_ object: Any) {
            guard let element = object as? NSObject,
                  element.responds(to: NSSelectorFromString("accessibilityChildren")) else { return }
            let id = ObjectIdentifier(element)
            guard visited.insert(id).inserted else { return }
            let value = String(describing: element.value(forKey: "accessibilityValue") ?? "")
            elements.append(value)
            for child in element.value(forKey: "accessibilityChildren") as? [Any] ?? [] { collect(child) }
        }
        collect(window)
        return elements
    }
}
