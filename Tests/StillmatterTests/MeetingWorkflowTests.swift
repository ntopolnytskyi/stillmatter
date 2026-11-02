import Foundation
import XCTest
@testable import StillmatterCore

final class MeetingWorkflowTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-workflow-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private var workspace: URL { root.appendingPathComponent("workspace") }
    private func store() throws -> JobStore { try JobStore(databaseURL: root.appendingPathComponent("support/jobs.sqlite")) }
    private func legacy(_ id: String) -> JobManifest {
        JobManifest(type: TranscriptionJob.type, title: "Transcribe \(id)", executionClass: .heavy,
            stages: [.init(id: TranscriptionJob.stageID, title: "Transcribe \(id)")],
            sourceArtifacts: [.init(relativePath: "Meetings/\(id)/meeting.md", role: "meeting-doorway")],
            metadata: ["capture_session_id": id, "language": "uk"], maxAutomaticRetries: 1).owned(by: workspace)
    }
    private func workflow(_ id: String) throws -> JobManifest { try MeetingWorkflowJob.manifest(transcription: legacy(id)) }
    private func wait(_ condition: @escaping () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if (try? condition()) == true { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        XCTFail("Timed out", file: file, line: line)
    }

    func testRegisteredWholeMeetingOrderingNonMeetingDispatchAndIndependentCapture() throws {
        let store = try store(), stages = WorkflowStageControl()
        let registry = JobHandlerRegistry(handlers: [MeetingWorkflowJob.type: MeetingWorkflowHandler(transcription: stages, analysis: stages), "synthetic.maintenance": stages])
        let gate = JobHeavyExecutionGate()
        let scheduler = JobScheduler(store: store, executor: registry, eligibleJobTypes: registry.jobTypes,
            workspaceRootURL: workspace, heavyExecutionGate: gate)
        defer { scheduler.stop() }
        _ = try store.enqueue(id: "A", manifest: workflow("A"))
        _ = try store.enqueue(id: "B", manifest: workflow("B"))
        _ = try store.enqueue(id: "maintenance", manifest: JobManifest(type: "synthetic.maintenance", title: "Maintain", executionClass: .heavy,
            stages: [.init(id: "clean", title: "Clean")]).owned(by: workspace))
        _ = try store.enqueue(id: "other-workspace", manifest: try workflow("other").owned(by: root.appendingPathComponent("other")))
        scheduler.start()
        wait { stages.events == ["A/transcribe"] }
        stages.complete()
        wait { stages.events == ["A/transcribe", "A/summarize-and-extract"] }
        XCTAssertEqual(try store.job(id: "B")?.stages.map(\.attemptCount), [0, 0])
        let capture = MeetingCaptureService(vault: WorkspaceVault(workspaceRootURL: workspace,
            appSupportRootURL: root.appendingPathComponent("capture-support")), jobStore: store,
            preflight: { .readyForTesting })
        _ = try capture.startManual()
        XCTAssertEqual(capture.snapshot.state, .recording, "Capture must start while analysis owns its processing turn")
        XCTAssertEqual(try store.job(id: "A")?.status, .running)
        _ = try capture.stopManual()
        stages.complete()
        wait { stages.events.last == "B/transcribe" }
        stages.complete()
        wait { stages.events.last == "B/summarize-and-extract" }
        stages.complete()
        wait { stages.events.last == "maintenance/clean" }
        stages.complete()
        wait { try store.job(id: "maintenance")?.status == .succeeded }
        XCTAssertEqual(stages.events, ["A/transcribe", "A/summarize-and-extract", "B/transcribe", "B/summarize-and-extract", "maintenance/clean"])
        XCTAssertEqual(try store.job(id: "other-workspace")?.status, .queued)
    }

    func testRestartAfterCheckpointResumesOnlyOutstandingStageBeforeNextMeeting() throws {
        let firstStore = try store(), first = WorkflowStageControl()
        _ = try firstStore.enqueue(id: "A", manifest: workflow("A"))
        _ = try firstStore.enqueue(id: "B", manifest: workflow("B"))
        let scheduler = JobScheduler(store: firstStore, executor: first, workspaceRootURL: workspace)
        scheduler.start()
        wait { first.events == ["A/transcribe"] }
        scheduler.pauseSynchronously()
        first.complete()
        wait { try firstStore.job(id: "A")?.stages.first?.status == .succeeded }
        scheduler.stop()
        let reopened = try store(), second = WorkflowStageControl()
        let resumed = JobScheduler(store: reopened, executor: second, workspaceRootURL: workspace)
        defer { resumed.stop() }
        resumed.start()
        wait { second.events == ["A/summarize-and-extract"] }
        let a = try XCTUnwrap(reopened.job(id: "A"))
        XCTAssertEqual(a.stages.map(\.attemptCount), [1, 1])
        XCTAssertEqual(a.manifest.metadata["language"], "uk")
        XCTAssertEqual(a.manifest.workspaceOwner, workspace.path)
        second.complete()
        wait { second.events.last == "B/transcribe" }
        resumed.pauseSynchronously()
        second.complete()
    }

    func testRepeatedInterruptedStageAttemptsBecomeFailedAndReleaseMeetingQueue() throws {
        let firstStore = try store()
        let retryManifest = JobManifest(
            type: MeetingWorkflowJob.type,
            title: "Process A",
            executionClass: .heavy,
            stages: [.init(id: "prepare", title: "Prepare"), .init(id: "analyze", title: "Analyze")],
            sourceArtifacts: [.init(relativePath: "Meetings/A/meeting.md", role: "meeting")],
            maxAutomaticRetries: 1
        ).owned(by: workspace)
        let nextManifest = JobManifest(type: MeetingWorkflowJob.type, title: "Process B", executionClass: .heavy,
            stages: [.init(id: "prepare", title: "Prepare")],
            sourceArtifacts: [.init(relativePath: "Meetings/B/meeting.md", role: "meeting")], maxAutomaticRetries: 1).owned(by: workspace)
        _ = try firstStore.enqueue(id: "A", manifest: retryManifest)
        _ = try firstStore.enqueue(id: "B", manifest: nextManifest)

        let firstExecutor = WorkflowStageControl()
        let firstScheduler = JobScheduler(store: firstStore, executor: firstExecutor, workspaceRootURL: workspace)
        firstScheduler.start()
        wait { firstExecutor.events == ["A/prepare"] }
        firstExecutor.complete()
        wait { firstExecutor.events == ["A/prepare", "A/analyze"] }
        firstScheduler.stop() // Simulate process exit while the durable stage is running.

        let secondStore = try store()
        let secondExecutor = WorkflowStageControl()
        let secondScheduler = JobScheduler(store: secondStore, executor: secondExecutor, workspaceRootURL: workspace)
        secondScheduler.start()
        wait { secondExecutor.events == ["A/analyze"] }
        secondScheduler.stop() // A second process exit interrupts attempt two.

        let recoveredStore = try store()
        let recoveredA = try XCTUnwrap(recoveredStore.job(id: "A"))
        XCTAssertEqual(recoveredA.stages.map(\.status), [.succeeded, .failed])
        XCTAssertEqual(recoveredA.stages.map(\.attemptCount), [1, 2])
        XCTAssertTrue(recoveredA.failureDetails?.contains("Interrupted before completion") == true)

        let nextExecutor = WorkflowStageControl()
        let nextScheduler = JobScheduler(store: recoveredStore, executor: nextExecutor, workspaceRootURL: workspace)
        defer { nextScheduler.stop() }
        nextScheduler.start()
        wait { nextExecutor.events == ["B/prepare"] }
        XCTAssertEqual(try recoveredStore.job(id: "A")?.stages.last?.attemptCount, 2)
    }

    func testMissingModelFailureCanRetryOutstandingStageAfterSetup() throws {
        let store = try store()
        _ = try store.enqueue(id: "A", manifest: workflow("A"))

        let transcription = WorkflowStageControl()
        let unavailable = JobScheduler(store: store, executor: MeetingWorkflowHandler(
            transcription: transcription, analysis: UnavailableJobHandler(guidance: "Install the local model")),
            workspaceRootURL: workspace)
        unavailable.start()
        wait { transcription.events == ["A/\(TranscriptionJob.stageID)"] }
        transcription.complete()
        wait { try store.job(id: "A")?.status == .failed }
        unavailable.stop()
        XCTAssertEqual(try store.job(id: "A")?.stages.map(\.status), [.succeeded, .failed])
        XCTAssertTrue(try store.job(id: "A")?.failureDetails?.contains("Install the local model") == true)

        let setupExecutor = WorkflowStageControl()
        let configured = JobScheduler(store: store, executor: setupExecutor, workspaceRootURL: workspace)
        defer { configured.stop() }
        try configured.retry(id: "A", meetingRelativePath: "Meetings/A/meeting.md")
        configured.start()
        wait { setupExecutor.events == ["A/\(MeetingSummaryJob.stageID)"] }
        setupExecutor.complete()
        wait { try store.job(id: "A")?.status == .succeeded }
        XCTAssertEqual(try store.job(id: "A")?.stages.map(\.status), [.succeeded, .succeeded])
        XCTAssertEqual(try store.job(id: "A")?.stages.map(\.attemptCount), [1, 3])
    }

    func testLegacyContinuationAdoptionPreservesAttemptsSettingsAndFailure() throws {
        let store = try store(), executor = WorkflowStageControl()
        let original = try store.enqueue(id: "A", manifest: legacy("A"))
        let first = JobScheduler(store: store, executor: executor, eligibleJobTypes: [TranscriptionJob.type])
        first.start(); wait { executor.events == ["A/transcribe"] }
        executor.complete(); wait { try store.job(id: "A")?.status == .succeeded }; first.stop()
        let analysis = try MeetingSummaryJob.manifest(meetingRelativePath: "Meetings/A/meeting.md", captureSessionID: "A", transcriptJSONRelativePath: "Meetings/A/transcript.json").owned(by: workspace)
        _ = try store.enqueue(id: "meeting-summary:A", manifest: analysis)
        let failed = JobScheduler(store: store, executor: UnavailableJobHandler(guidance: "Missing local model"), eligibleJobTypes: [MeetingSummaryJob.type])
        failed.start(); wait { try store.job(id: "meeting-summary:A")?.status == .failed }; failed.stop()
        let prior = try XCTUnwrap(store.job(id: "meeting-summary:A"))
        try MeetingWorkflowJob.migrate(store: store, workspaceRootURL: workspace)
        let migrated = try XCTUnwrap(store.job(id: "A"))
        XCTAssertEqual(migrated.manifest.type, MeetingWorkflowJob.type)
        XCTAssertEqual(migrated.createdAt, original.createdAt)
        XCTAssertEqual(migrated.stages.map(\.status), [.succeeded, .failed])
        XCTAssertEqual(migrated.stages.map(\.attemptCount), [1, 2])
        XCTAssertEqual(migrated.stages.last?.lastError, prior.stages.last?.lastError)
        XCTAssertEqual(migrated.manifest.metadata[PiWorkflowManifest.metadataKey], analysis.metadata[PiWorkflowManifest.metadataKey])
        XCTAssertEqual(migrated.manifest.metadata["language"], "uk")
        XCTAssertEqual(try store.job(id: prior.id)?.status, .dismissed)
        XCTAssertEqual(try store.job(id: prior.id)?.stages, prior.stages)
        XCTAssertTrue(try store.details(id: prior.id).logs.contains { $0.message.contains("adopted by Job A") })
        try MeetingWorkflowJob.migrate(store: store, workspaceRootURL: workspace)
        XCTAssertEqual(try store.job(id: "A")?.stages, migrated.stages)
    }

    func testPendingMigrationAndOwnershipQuarantineDoNotInferCompletionFromFiles() throws {
        let store = try store()
        _ = try store.enqueue(id: "A", manifest: legacy("A"))
        let unowned = JobManifest(type: TranscriptionJob.type, title: "Unknown owner", executionClass: .heavy, stages: [.init(id: "transcribe", title: "Transcribe")])
        _ = try store.enqueue(id: "unknown", manifest: unowned)
        _ = try store.enqueue(id: "other", manifest: legacy("other").owned(by: root.appendingPathComponent("other")))
        let directory = workspace.appendingPathComponent("Meetings/A")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("old stale output".utf8).write(to: directory.appendingPathComponent("summary.md"))
        try MeetingWorkflowJob.migrate(store: store, workspaceRootURL: workspace)
        let migrated = try XCTUnwrap(store.job(id: "A"))
        XCTAssertEqual(migrated.stages.map(\.status), [.pending, .pending])
        XCTAssertEqual(migrated.stages.map(\.attemptCount), [0, 0])
        XCTAssertEqual(try store.job(id: "unknown")?.manifest, unowned)
        XCTAssertEqual(try store.job(id: "other")?.manifest.type, TranscriptionJob.type)
    }

    func testMigrationRejectsCrossWorkspaceRunningAndChangedCheckpointContractsAtomically() throws {
        let store = try store(), control = WorkflowStageControl()
        _ = try store.enqueue(id: "A", manifest: legacy("A"))
        let scheduler = JobScheduler(store: store, executor: control, workspaceRootURL: workspace)
        scheduler.start(); wait { control.events == ["A/transcribe"] }
        let prior = try XCTUnwrap(store.job(id: "A"))
        XCTAssertThrowsError(try store.adoptManifest(id: "A", manifest: workflow("A"), checkpoints: ["transcribe": .init(jobID: "A", stageID: "transcribe")]))
        XCTAssertEqual(try store.job(id: "A"), prior)
        scheduler.pauseSynchronously(); control.complete(); wait { try store.job(id: "A")?.status == .succeeded }; scheduler.stop()
        let completed = try XCTUnwrap(store.job(id: "A"))
        XCTAssertThrowsError(try store.adoptManifest(id: "A", manifest: try workflow("A").owned(by: root.appendingPathComponent("other")), checkpoints: [:]))
        XCTAssertThrowsError(try store.adoptManifest(id: "A", manifest: workflow("A"), checkpoints: ["unknown": .init(jobID: "A", stageID: "transcribe")]))
        XCTAssertThrowsError(try store.adoptManifest(id: "A", manifest: workflow("A"), checkpoints: [:], retiringJobIDs: ["A"]))
        XCTAssertThrowsError(try store.adoptManifest(id: "A", manifest: workflow("A"), checkpoints: ["transcribe": .init(jobID: "A", stageID: "missing")]))
        let incompatible = JobManifest(type: MeetingWorkflowJob.type, title: "Different outputs", executionClass: .heavy,
            stages: [.init(id: "transcribe", title: "Transcribe")],
            expectedOutputs: [.init(stageID: "transcribe", relativePath: "different.json", validatorID: "json")]).owned(by: workspace)
        XCTAssertThrowsError(try store.adoptManifest(id: "A", manifest: incompatible, checkpoints: ["transcribe": .init(jobID: "A", stageID: "transcribe")]))
        XCTAssertEqual(try store.job(id: "A"), completed)
        try store.adoptManifest(id: "A", manifest: legacy("A"), checkpoints: ["transcribe": .init(jobID: "A", stageID: "transcribe")])
        XCTAssertEqual(try store.job(id: "A")?.status, .succeeded)
        XCTAssertEqual(try store.job(id: "A")?.stages, completed.stages)
    }

    func testCompletedLegacyHistoryIsNotRescheduledAndUnfinishedContentStaysEmpty() throws {
        let store = try store(), control = WorkflowStageControl()
        _ = try store.enqueue(id: "completed", manifest: legacy("completed"))
        let scheduler = JobScheduler(store: store, executor: control, eligibleJobTypes: [TranscriptionJob.type])
        scheduler.start(); wait { control.events.count == 1 }; control.complete()
        wait { try store.job(id: "completed")?.status == .succeeded }; scheduler.stop()
        try MeetingWorkflowJob.migrate(store: store, workspaceRootURL: workspace)
        XCTAssertEqual(try store.job(id: "completed")?.manifest.type, TranscriptionJob.type)
        _ = try store.enqueue(id: "A", manifest: workflow("A"))
        let directory = workspace.appendingPathComponent("Meetings/A")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "---\ntitle: Workflow A\ncapture_session_id: A\n---\n# Workflow A\n\n## Notes\nHidden note\n".write(to: directory.appendingPathComponent("meeting.md"), atomically: true, encoding: .utf8)
        try "## Summary\n\nOld generated Summary\n".write(to: directory.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        let service = MeetingManagementService(vault: WorkspaceVault(workspaceRootURL: workspace, appSupportRootURL: root.appendingPathComponent("support")), jobStore: store)
        let detail = try service.detail(for: "A")
        XCTAssertEqual(detail.row.processingState, .processing)
        XCTAssertEqual(detail.job?.stage, "Transcribe A")
        XCTAssertNil(detail.summary); XCTAssertTrue(detail.humanNotes.isEmpty)
        XCTAssertTrue(detail.transcript.isEmpty); XCTAssertTrue(detail.doorwayText.isEmpty)
        let unavailable = JobScheduler(store: store, executor: UnavailableJobHandler(guidance: "Missing local provider"), workspaceRootURL: workspace)
        unavailable.start(); wait { try store.job(id: "A")?.status == .failed }; unavailable.stop()
        let failed = try service.detail(for: "A")
        XCTAssertNil(failed.summary)
        XCTAssertTrue(failed.job?.error?.contains("Missing local provider") == true)
        XCTAssertEqual(failed.job?.retryReason, "Retry unavailable: processing is not configured.")
    }

    func testWorkflowDetailHidesExistingArtifactsUntilAllStagesSucceed() throws {
        let store = try store(), control = WorkflowStageControl()
        let definition = try workflow("A")
        // The stage controller does not generate content; existing files must remain untouched.
        let manifest = JobManifest(type: definition.type, title: definition.title, executionClass: definition.executionClass,
            stages: definition.stages, sourceArtifacts: definition.sourceArtifacts, metadata: definition.metadata).owned(by: workspace)
        _ = try store.enqueue(id: "A", manifest: manifest)
        let vault = WorkspaceVault(workspaceRootURL: workspace, appSupportRootURL: root.appendingPathComponent("support"))
        let meeting = "Meetings/A/meeting.md"
        _ = try vault.writeMarkdown(Data("---\ntitle: Workflow A\ncapture_session_id: A\n---\n## Notes\nKeep my notes\n".utf8), relativePath: meeting, expectedVersion: nil)
        let summary = "Meetings/A/summary.md"
        let summaryData = Data("## Summary\n\nSaved summary\n".utf8)
        _ = try vault.writeMarkdown(summaryData, relativePath: summary, expectedVersion: nil)
        let service = MeetingManagementService(vault: vault, jobStore: store)
        func assertHidden(file: StaticString = #filePath, line: UInt = #line) throws {
            let detail = try service.detail(for: "A")
            XCTAssertNil(detail.summary, file: file, line: line)
            XCTAssertNil(detail.extraction, file: file, line: line)
            XCTAssertNil(detail.notesVersion, file: file, line: line)
            XCTAssertTrue(detail.humanNotes.isEmpty, file: file, line: line)
            XCTAssertTrue(detail.doorwayText.isEmpty, file: file, line: line)
            XCTAssertTrue(detail.transcript.isEmpty, file: file, line: line)
            XCTAssertTrue(detail.myActionItems.isEmpty, file: file, line: line)
            XCTAssertTrue(detail.artifacts.isEmpty, file: file, line: line)
            XCTAssertEqual(try vault.readMarkdown(relativePath: summary).data, summaryData, file: file, line: line)
            XCTAssertNil(try vault.versionOfMarkdown(relativePath: "Meetings/A/meeting-artifacts.json"), file: file, line: line)
        }
        try assertHidden()
        let scheduler = JobScheduler(store: store, executor: control, workspaceRootURL: workspace)
        defer { scheduler.stop() }
        scheduler.start()
        wait { control.events == ["A/transcribe"] }
        try assertHidden()
        control.complete()
        wait { control.events.count == 2 }
        try assertHidden()
        control.complete()
        wait { try store.job(id: "A")?.status == .succeeded }
        let completed = try service.detail(for: "A")
        XCTAssertTrue(completed.summary?.summary.contains("Saved summary") == true)
        XCTAssertTrue(completed.humanNotes.contains("Keep my notes"))
        XCTAssertFalse(completed.doorwayText.isEmpty)
    }

    func testRegistryUnavailableAndUnknownStagesFailWithoutProviderTransfer() throws {
        let store = try store(), registry = JobHandlerRegistry(handlers: [:])
        let job = try store.enqueue(id: "A", manifest: workflow("A"))
        let handler = MeetingWorkflowHandler(transcription: registry, analysis: UnavailableJobHandler(guidance: "Install a fully local provider"))
        var errors: [String] = []
        for stage in [JobStageDefinition(id: "unknown", title: "Unknown"), job.manifest.stages[0], job.manifest.stages[1]] {
            handler.execute(job: job, stage: stage) { result in
                if case let .failure(error) = result { errors.append(String(describing: error)) }
            }
        }
        XCTAssertEqual(errors.count, 3)
        XCTAssertTrue(errors[0].contains("Unsupported Meeting workflow stage"))
        XCTAssertTrue(errors[1].contains("No registered handler"))
        XCTAssertTrue(errors[2].contains("fully local"))
        XCTAssertThrowsError(try MeetingWorkflowJob.manifest(transcription: JobManifest(type: "unknown", title: "No", executionClass: .heavy, stages: [])))
        XCTAssertThrowsError(try MeetingWorkflowJob.manifest(transcription: legacy("A"), summary: legacy("B")))
    }
}

private final class WorkflowStageControl: JobExecuting {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var pending: [(JobRecord, JobStageDefinition, (Result<JobStageResult, Error>) -> Void)] = []
    var events: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    func execute(job: JobRecord, stage: JobStageDefinition, completion: @escaping (Result<JobStageResult, Error>) -> Void) {
        lock.lock(); recorded.append(job.id + "/" + stage.id); pending.append((job, stage, completion)); lock.unlock()
    }
    func complete() {
        lock.lock(); let next = pending.removeFirst(); lock.unlock()
        let artifacts = next.0.manifest.expectedOutputs.filter { $0.stageID == next.1.id }.map { expectation in
            let text: String
            switch expectation.validatorID {
            case "markdown": text = "---\n" + expectation.requiredFrontmatterFields.map { $0 + ": synthetic" }.joined(separator: "\n") + "\n---\n" + expectation.requiredHeadings.map { "## " + $0 }.joined(separator: "\n")
            case "webvtt": text = "WEBVTT\n"
            default: text = "{}"
            }
            return GeneratedArtifact(relativePath: expectation.relativePath, data: Data(text.utf8))
        }
        next.2(.success(JobStageResult(artifacts: artifacts)))
    }
}
