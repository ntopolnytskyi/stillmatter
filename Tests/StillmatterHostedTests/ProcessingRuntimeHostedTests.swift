import AppKit
import XCTest
import StillmatterCore
@testable import StillmatterHostedTestHost

final class ProcessingRuntimeHostedTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("processing-runtime-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private var workspace: URL { root.appendingPathComponent("workspace") }
    private var support: URL { root.appendingPathComponent("support") }
    private func settings(_ root: URL?) -> AppSettings { var s = AppSettings(); s.stillmatterRootURL = root; return s }
    private func installer() -> TranscriptionComponentInstaller {
        TranscriptionComponentInstaller(paths: TranscriptionComponentPaths(applicationSupportURL: support), acquirer: UnusedModelAcquirer())
    }
    private func legacy(_ id: String) -> JobManifest {
        JobManifest(type: TranscriptionJob.type, title: "Transcribe \(id)", executionClass: .heavy,
            stages: [.init(id: "transcribe", title: "Transcribe \(id)")],
            sourceArtifacts: [.init(relativePath: "Meetings/\(id)/meeting.md", role: "meeting-doorway")],
            metadata: ["capture_session_id": id, "language": "en"]).owned(by: workspace)
    }
    private func wait(_ condition: @escaping () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if (try? condition()) == true { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        XCTFail("Timed out", file: file, line: line)
    }

    func testSingleRegisteredSchedulerPersistsActualStagesAndDoesNotHoldCapture() throws {
        let store = try JobStore(databaseURL: support.appendingPathComponent("jobs.sqlite"))
        let handler = HostedWorkflowControl()
        var mayResume = true
        let runtime = ProcessingRuntime(applicationSupportURL: support, componentInstaller: installer(),
            jobStore: { store }, mayResumeTranscription: { _ in mayResume },
            makeTranscription: { _, _ in handler }, analysis: handler)
        defer { runtime.stop() }
        _ = try store.enqueue(id: "A", manifest: legacy("A"))
        _ = try store.enqueue(id: "B", manifest: legacy("B"))
        runtime.configure(settings: settings(workspace), searchIndex: nil, indexGeneration: 0)
        wait { handler.events == ["A/transcribe"] }
        XCTAssertEqual(runtime.schedulers.count, 1)
        let scheduler = try XCTUnwrap(runtime.scheduler(for: MeetingWorkflowJob.type))
        XCTAssertTrue(runtime.scheduler(for: MeetingSummaryJob.type) === scheduler)
        XCTAssertTrue(runtime.scheduler(for: TranscriptionJob.type) === scheduler)
        XCTAssertNil(runtime.scheduler(for: "unregistered"))
        runtime.configure(settings: settings(workspace), searchIndex: nil, indexGeneration: 0)
        XCTAssertTrue(runtime.transcriptionScheduler === scheduler)
        runtime.pauseSynchronously()
        handler.complete()
        wait { try store.job(id: "A")?.stages.first?.status == .succeeded }
        // Paused completion resumes through the captured workspace policy, without
        // acquiring a capture permit or making a second scheduler.
        wait { handler.events.last == "A/summarize-and-extract" }
        let a = try XCTUnwrap(store.job(id: "A"))
        XCTAssertEqual(a.stages.first(where: { $0.status == .running })?.definition.id, MeetingSummaryJob.stageID)
        let capture = MeetingCaptureService(vault: WorkspaceVault(workspaceRootURL: workspace,
            appSupportRootURL: root.appendingPathComponent("capture-support")), preflight: { .readyForTesting })
        _ = try capture.startManual()
        XCTAssertEqual(capture.snapshot.state, .recording)
        XCTAssertEqual(try store.job(id: "A")?.status, .running)
        _ = try capture.stopManual()
        mayResume = false
        runtime.pauseSynchronously()
        handler.complete()
        wait { try store.job(id: "A")?.status == .succeeded }
        XCTAssertEqual(try store.job(id: "B")?.status, .queued)
        runtime.start()
        wait { handler.events.last == "B/transcribe" }
        runtime.stop()
        handler.complete()
        wait { try store.job(id: "B")?.stages.first?.status == .succeeded }
        runtime.start()
        runtime.configure(settings: settings(workspace), searchIndex: nil, indexGeneration: 1)
        XCTAssertNil(runtime.transcriptionScheduler)
        XCTAssertEqual(try store.job(id: "B")?.stages.last?.attemptCount, 0)
    }

    func testSameWorkspaceIndexReconfigurationKeepsPartialTurnWithEqualAndReversedClockTimestamps() throws {
        for reversed in [false, true] {
            let location = support.appendingPathComponent(reversed ? "reversed.sqlite" : "equal.sqlite")
            var timestamp = "2026-11-01T10:00:00Z"
            let store = try JobStore(databaseURL: location, now: { timestamp })
            let handler = HostedWorkflowControl()
            let runtime = ProcessingRuntime(applicationSupportURL: support, componentInstaller: installer(),
                jobStore: { store }, mayResumeTranscription: { _ in true },
                makeTranscription: { _, _ in handler }, analysis: handler)
            _ = try store.enqueue(id: "A", manifest: legacy("A"))
            runtime.configure(settings: settings(workspace), searchIndex: nil, indexGeneration: 0)
            wait { handler.events == ["A/transcribe"] }
            if reversed { timestamp = "2026-11-01T09:00:00Z" }
            _ = try store.enqueue(id: "B", manifest: legacy("B"))
            runtime.configure(settings: settings(workspace), searchIndex: nil, indexGeneration: 1)
            XCTAssertEqual(try store.job(id: "B")?.stages.first?.attemptCount, 0)
            handler.complete()
            wait { handler.events == ["A/transcribe", "A/summarize-and-extract"] }
            XCTAssertEqual(try store.job(id: "B")?.stages.first?.attemptCount, 0)
            handler.complete()
            wait { handler.events.last == "B/transcribe" }
            runtime.pauseSynchronously(); handler.complete()
            wait { try store.job(id: "B")?.stages.first?.status == .succeeded }
            runtime.stop()
        }
    }

    func testInstalledAndDeveloperLocalAdapterAssemblyNeverStartsInferenceWithoutJobs() throws {
        let store = try JobStore(databaseURL: support.appendingPathComponent("adapters.sqlite"))
        let paths = TranscriptionComponentPaths(applicationSupportURL: support)
        for relative in TranscriptionComponentInstaller.requiredModelEntries {
            let path = paths.modelURL.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("synthetic readiness fixture; not usable model weights".utf8).write(to: path)
        }
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "variant": "large-v3-turbo",
            "runtimeVersion": TranscriptionComponentPaths.runtimeVersion, "modelDirectory": "faster-whisper-large-v3-turbo"])
            .write(to: paths.readinessMarkerURL)
        let installed = ProcessingRuntime(applicationSupportURL: support, componentInstaller: installer(),
            jobStore: { store }, mayResumeTranscription: { _ in true })
        installed.configure(settings: settings(workspace), searchIndex: nil, indexGeneration: 0)
        XCTAssertNotNil(installed.transcriptionScheduler); installed.stop()
        let previous = getenv("STILLMATTER_WHISPER_CLI").map { String(cString: $0) }
        setenv("STILLMATTER_WHISPER_CLI", root.appendingPathComponent("synthetic-cli-not-executed").path, 1)
        defer {
            if let previous { setenv("STILLMATTER_WHISPER_CLI", previous, 1) }
            else { unsetenv("STILLMATTER_WHISPER_CLI") }
        }
        let cli = ProcessingRuntime(applicationSupportURL: support, componentInstaller: installer(),
            jobStore: { store }, mayResumeTranscription: { _ in true })
        cli.configure(settings: settings(workspace), searchIndex: nil, indexGeneration: 0)
        XCTAssertNotNil(cli.transcriptionScheduler); cli.stop()
        XCTAssertTrue(try store.jobs().isEmpty)
    }

    func testUnconfiguredLocalCapabilitiesFailTruthfullyAndLeaveOtherJobsRunnable() throws {
        let store = try JobStore(databaseURL: support.appendingPathComponent("jobs.sqlite"))
        _ = try store.enqueue(id: "missing-asr", manifest: legacy("missing-asr"))
        let runtime = ProcessingRuntime(applicationSupportURL: support, componentInstaller: installer(),
            jobStore: { store }, mayResumeTranscription: { _ in true })
        runtime.configure(settings: settings(workspace), searchIndex: nil, indexGeneration: 0)
        wait { try store.job(id: "missing-asr")?.status == .failed }
        XCTAssertTrue(try store.job(id: "missing-asr")?.failureDetails?.contains("Install the local transcription model") == true)
        XCTAssertEqual(try store.job(id: "missing-asr")?.stages.map(\.attemptCount), [2, 0])
        runtime.stop()
        let transcription = HostedWorkflowControl()
        let next = ProcessingRuntime(applicationSupportURL: support, componentInstaller: installer(),
            jobStore: { store }, mayResumeTranscription: { _ in true }, makeTranscription: { _, _ in transcription })
        defer { next.stop() }
        _ = try store.enqueue(id: "missing-analysis", manifest: legacy("missing-analysis"))
        next.configure(settings: settings(workspace), searchIndex: nil, indexGeneration: 0)
        wait { transcription.events == ["missing-analysis/transcribe"] }
        transcription.complete()
        wait { try store.job(id: "missing-analysis")?.status == .failed }
        let failure = try XCTUnwrap(store.job(id: "missing-analysis"))
        XCTAssertEqual(failure.stages.map(\.status), [.succeeded, .failed])
        XCTAssertTrue(failure.failureDetails?.contains("fully local analysis provider") == true)
        XCTAssertTrue(failure.failureDetails?.contains("no Meeting text was uploaded") == true)
    }

    func testConfigurationGuardsAndMigrationFailureRetainOriginalWork() throws {
        var probe = false
        let store = try JobStore(databaseURL: support.appendingPathComponent("jobs.sqlite"))
        let runtime = ProcessingRuntime(applicationSupportURL: support, componentInstaller: installer(),
            jobStore: { store }, mayResumeTranscription: { _ in false }, isProbe: { probe })
        runtime.configure(settings: settings(workspace), searchIndex: nil, indexGeneration: 0)
        XCTAssertNotNil(runtime.transcriptionScheduler)
        runtime.configure(settings: settings(nil), searchIndex: nil, indexGeneration: 0)
        XCTAssertNil(runtime.transcriptionScheduler)
        probe = true
        runtime.configure(settings: settings(workspace), searchIndex: nil, indexGeneration: 0)
        XCTAssertNil(runtime.transcriptionScheduler)
        probe = false
        let malformed = JobManifest(type: TranscriptionJob.type, title: "Needs migration review", executionClass: .heavy,
            stages: [.init(id: "unknown", title: "Unknown")]).owned(by: workspace)
        _ = try store.enqueue(id: "incompatible", manifest: malformed)
        runtime.configure(settings: settings(workspace), searchIndex: nil, indexGeneration: 0)
        XCTAssertNil(runtime.transcriptionScheduler)
        XCTAssertTrue(runtime.configurationError?.contains("migration needs attention") == true)
        XCTAssertEqual(try store.job(id: "incompatible")?.manifest, malformed)
        XCTAssertEqual(try store.job(id: "incompatible")?.status, .queued)
        runtime.stop()
        let noStore = ProcessingRuntime(applicationSupportURL: support, componentInstaller: installer(),
            jobStore: { nil }, mayResumeTranscription: { _ in true })
        noStore.configure(settings: settings(workspace), searchIndex: nil, indexGeneration: 0)
        XCTAssertNil(noStore.transcriptionScheduler)
        noStore.stop()
    }
}

private struct UnusedModelAcquirer: TranscriptionModelAcquiring {
    func acquireModel(_ model: TranscriptionModelChoice, in stagingURL: URL, cancellation: TranscriptionInstallCancellation,
                      progress: @escaping (TranscriptionInstallProgress) -> Void) throws -> URL {
        throw JobsError.invalidManifest("Tests never download models")
    }
}

private final class HostedWorkflowControl: JobExecuting {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var pending: [(JobRecord, JobStageDefinition, (Result<JobStageResult, Error>) -> Void)] = []
    var events: [String] { lock.lock(); defer { lock.unlock() }; return recorded }
    func execute(job: JobRecord, stage: JobStageDefinition, completion: @escaping (Result<JobStageResult, Error>) -> Void) {
        lock.lock(); recorded.append(job.id + "/" + stage.id); pending.append((job, stage, completion)); lock.unlock()
    }
    func complete() {
        lock.lock(); let (job, stage, completion) = pending.removeFirst(); lock.unlock()
        let artifacts = job.manifest.expectedOutputs.filter { $0.stageID == stage.id }.map { output in
            let text = output.validatorID == "markdown" ? "---\n" + output.requiredFrontmatterFields.map { $0 + ": fixture" }.joined(separator: "\n") + "\n---\n" + output.requiredHeadings.map { "## " + $0 }.joined(separator: "\n") : "{}"
            return GeneratedArtifact(relativePath: output.relativePath, data: Data(text.utf8))
        }
        completion(.success(JobStageResult(artifacts: artifacts)))
    }
}
