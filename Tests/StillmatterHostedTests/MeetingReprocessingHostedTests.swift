import AppKit
import XCTest
import StillmatterCore
import StillmatterPresentation
@testable import StillmatterHostedTestHost

final class MeetingReprocessingHostedTests: XCTestCase {
    @MainActor
    func testConfirmationDispatchesSelectedLanguageOnceAndCancelLeavesConfigurationUnchanged() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reprocess-hosted-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = WorkspaceVault(workspaceRootURL: root.appendingPathComponent("workspace"), appSupportRootURL: root.appendingPathComponent("support"))
        _ = try vault.writeMarkdown(Data("# Fixture\n".utf8), relativePath: "Meetings/fixture/meeting.md", expectedVersion: nil)
        let service = MeetingManagementService(vault: vault)
        let model = MeetingReadModel(workspaceID: root.path, sourceFactory: { MeetingManagementReadSource(serviceProvider: { service }) })
        let executor = ReprocessingControlExecutor()
        let otherVault = WorkspaceVault(workspaceRootURL: root.appendingPathComponent("other-workspace"), appSupportRootURL: root.appendingPathComponent("other-support"))
        let otherBytes = Data("# Other workspace\n".utf8)
        _ = try otherVault.writeMarkdown(otherBytes, relativePath: "Meetings/fixture/meeting.md", expectedVersion: nil)
        let otherService = MeetingManagementService(vault: otherVault)
        let otherModel = MeetingReadModel(workspaceID: "other", sourceFactory: { MeetingManagementReadSource(serviceProvider: { otherService }) })
        var providedModel: MeetingReadModel? = model
        var switchWorkspace = false
        var confirm = false
        let view = MeetingManagementView(readModelProvider: { providedModel }, mutationExecutorProvider: { executor },
            playbackTransportProvider: { nil }, openRecording: {}, openWorkspaceFile: { _ in }, presentConfirmationAlert: { alert in
                XCTAssertTrue(alert.informativeText.contains("no inspectable revision history in Release 1.0"))
                XCTAssertTrue(alert.informativeText.contains("My Notes prose and task content"))
                XCTAssertTrue(alert.informativeText.contains("Automatic additive tags"))
                let languages = alert.accessoryView as! NSPopUpButton
                XCTAssertEqual(languages.itemTitles, ["Auto", "English", "Ukrainian"])
                XCTAssertEqual(languages.indexOfSelectedItem, 0)
                languages.selectItem(at: 2)
                if switchWorkspace { providedModel = otherModel }
                return confirm ? .alertFirstButtonReturn : .alertSecondButtonReturn
            })
        view.refresh(isVisible: true)
        let loaded = expectation(for: NSPredicate { _, _ in view.displayedDetail != nil && view.reprocessButton.isEnabled }, evaluatedWith: nil)
        await fulfillment(of: [loaded], timeout: 5)
        let selected = view.selectedID
        view.confirmReprocess()
        XCTAssertTrue(executor.mutations.isEmpty)
        confirm = true
        switchWorkspace = true
        view.confirmReprocess()
        XCTAssertTrue(executor.mutations.isEmpty, "A confirmation from the previous workspace must expire")
        XCTAssertEqual(try otherVault.readMarkdown(relativePath: "Meetings/fixture/meeting.md").data, otherBytes)
        providedModel = model
        switchWorkspace = false
        view.confirmReprocess()
        // A second click while completion is withheld cannot dispatch a competing operation.
        view.confirmReprocess()
        XCTAssertEqual(executor.mutations.count, 1)
        guard case let .reprocess(meetingID, language) = executor.mutations.first else { return XCTFail("Expected confirmed reprocessing") }
        XCTAssertEqual(meetingID, selected)
        XCTAssertEqual(language, .ukrainian)
        executor.finish()
        let finished = expectation(for: NSPredicate { _, _ in view.retryFeedback?.message.contains("queued") == true }, evaluatedWith: nil)
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertEqual(view.selectedID, selected)
        XCTAssertFalse(view.reprocessButton.isEnabled, "Keep disabled until the queued run is observed")
        _ = try vault.writeMarkdown(Data("{\"archived\":true}".utf8), relativePath: "Meetings/fixture/archive.json", expectedVersion: nil)
        view.archiveFilter.selectItem(at: 1)
        view.filtersChanged(nil)
        model.invalidate(.rescanRequired(reason: "Archived fixture"))
        let archived = expectation(for: NSPredicate { _, _ in view.displayedDetail?.row.isArchived == true }, evaluatedWith: nil)
        await fulfillment(of: [archived], timeout: 5)
        XCTAssertFalse(view.reprocessButton.isEnabled)
        XCTAssertTrue(view.reprocessButton.toolTip?.contains("Archived") == true)
        view.confirmReprocess()
        XCTAssertEqual(executor.mutations.count, 1)
        view.refresh(isVisible: false); model.stop(); otherModel.stop()
    }
    @MainActor
    func testArchiveFailureExplainsErrorAndAllowsRetryWithoutMovingMeeting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("archive-hosted-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = WorkspaceVault(workspaceRootURL: root.appendingPathComponent("workspace"), appSupportRootURL: root.appendingPathComponent("support"))
        let path = "Meetings/fixture/meeting.md"
        let transcript = TranscriptDocument(schemaVersion: 1, captureSessionID: "fixture", meetingRelativePath: path,
            language: .english, detectedLanguages: [], engine: "fixture", model: "fixture", generatedAt: Date(), audioSources: [], segments: [], diagnostics: [])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let extraction = MeetingSummaryExtraction(meeting: path, transcript: "Meetings/fixture/transcript.json",
            decisions: [], myActionItems: [], otherActionItems: [], openQuestions: [])
        for (file, data) in [(path, Data("# Fixture\n".utf8)), ("Meetings/fixture/transcript.json", try encoder.encode(transcript)),
                             ("Meetings/fixture/transcript.md", Data("# Transcript\n".utf8)),
                             ("Meetings/fixture/summary.md", Data("# Summary\n".utf8)),
                             ("Meetings/fixture/summary-extraction.json", try encoder.encode(extraction))] {
            _ = try vault.writeMarkdown(data, relativePath: file, expectedVersion: nil)
        }
        let service = MeetingManagementService(vault: vault)
        let model = MeetingReadModel(workspaceID: root.path, sourceFactory: { MeetingManagementReadSource(serviceProvider: { service }) })
        let executor = ReprocessingControlExecutor()
        let view = MeetingManagementView(readModelProvider: { model }, mutationExecutorProvider: { executor },
            playbackTransportProvider: { nil }, openRecording: {}, openWorkspaceFile: { _ in })
        defer { view.refresh(isVisible: false); model.stop() }
        view.refresh(isVisible: true)
        await fulfillment(of: [expectation(for: NSPredicate { _, _ in view.archiveButton.isEnabled }, evaluatedWith: nil)], timeout: 10)
        XCTAssertEqual(view.archiveButton.toolTip, "Archive meeting")
        view.archiveButton.performClick(nil)
        XCTAssertEqual(executor.mutations.count, 1)
        executor.completion?(.failure(MeetingManagementError.retryRejected("Synthetic write failure")))
        await fulfillment(of: [expectation(for: NSPredicate { _, _ in view.retryFeedback?.message.contains("Synthetic write failure") == true }, evaluatedWith: nil)], timeout: 10)
        XCTAssertTrue(view.archiveButton.isEnabled)
        XCTAssertEqual(try service.list().count, 1)
        XCTAssertFalse(try service.detail(for: path).row.isArchived)
        view.archiveButton.performClick(nil)
        XCTAssertEqual(executor.mutations.count, 2)
        executor.completion?(.failure(MeetingManagementError.retryRejected("Still unavailable")))
    }

}

private final class ReprocessingControlExecutor: MeetingMutationExecuting {
    var mutations: [MeetingMutation] = []
    var completion: ((Result<MeetingMutationOutput, Error>) -> Void)?
    func execute(_ mutation: MeetingMutation, completion: @escaping (Result<MeetingMutationOutput, Error>) -> Void) {
        mutations.append(mutation); self.completion = completion
    }
    func finish() {
        completion?(.success(.job(JobRecord(id: "controlled", manifest: JobManifest(type: "meeting.workflow", title: "Reprocess", executionClass: .heavy,
            stages: [.init(id: "transcribe", title: "Transcribe")]), status: .queued, stages: [], createdAt: "2026-11-15", updatedAt: "2026-11-15", failureDetails: nil))))
    }
}
