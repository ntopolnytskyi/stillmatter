import Foundation
import XCTest
@testable import StillmatterCore

final class JobsTests: XCTestCase {
    func testTypedManifestAndStageStatePersistAcrossReopen() throws {
        let fixture = try JobsFixture()
        var store: JobStore? = try fixture.openStore()
        let manifest = JobManifest(
            type: "meeting.transcription",
            title: "Transcribe kickoff",
            executionClass: .heavy,
            stages: [
                JobStageDefinition(id: "prepare", title: "Prepare audio"),
                JobStageDefinition(id: "transcribe", title: "Transcribe")
            ],
            sourceArtifacts: [JobArtifactReference(relativePath: "Meetings/kickoff/mic.m4a", role: "microphone")],
            metadata: ["meeting": "kickoff"]
        )

        _ = try store?.enqueue(id: "transcribe-1", manifest: manifest)
        store = nil

        let reopened = try fixture.openStore()
        let job = try XCTUnwrap(reopened.job(id: "transcribe-1"))
        XCTAssertEqual(job.manifest, manifest)
        XCTAssertEqual(job.status, .queued)
        XCTAssertEqual(job.stages.map(\.status), [.pending, .pending])
        XCTAssertEqual(job.stages.map(\.attemptCount), [0, 0])
        XCTAssertEqual(try reopened.details(id: job.id).logs.map(\.message), ["Job queued"])
    }

    func testConcurrentReprocessEnqueuesAcrossSeparateStoreConnectionsRejectSameMeeting() throws {
        let fixture = try JobsFixture()
        let first = try fixture.openStore()
        let second = try fixture.openStore()
        let unrelated = fixture.manifest(id: "unrelated", executionClass: .heavy)
        _ = try first.enqueue(id: "unrelated", manifest: unrelated)
        let manifest = JobManifest(type: "meeting.transcription", title: "Reprocess", executionClass: .heavy,
            stages: [JobStageDefinition(id: "run", title: "Transcribe")],
            metadata: ["capture_session_id": "meeting-1"])
        let firstInspected = DispatchSemaphore(value: 0)
        let secondInspected = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        let resultLock = NSLock()
        var successes = 0
        for (store, id) in [(first, "first"), (second, "second")] {
            group.enter()
            DispatchQueue.global().async {
                let result = Result {
                    try store.enqueueUnlessActive(id: id, manifest: manifest) { candidate in
                        if candidate.id == "unrelated" {
                            if id == "first" {
                                firstInspected.signal()
                                // Without a database transaction the other connection can also inspect
                                // the idle Meeting before either enqueues its Job.
                                _ = secondInspected.wait(timeout: .now() + 0.3)
                            } else {
                                secondInspected.signal()
                            }
                        }
                        return candidate.manifest.metadata["capture_session_id"] == "meeting-1"
                    }
                }
                resultLock.lock()
                if case .success = result { successes += 1 }
                resultLock.unlock()
                group.leave()
            }
            if id == "first" { XCTAssertEqual(firstInspected.wait(timeout: .now() + 2), .success) }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(successes, 1)
        XCTAssertEqual(try first.jobs().filter { $0.manifest.metadata["capture_session_id"] == "meeting-1" }.count, 1)
        XCTAssertNotNil(try first.job(id: "unrelated"))
    }

    func testSchedulerRunsHeavyJobsSeriallyAndThrottlesLightweightJobs() throws {
        let fixture = try JobsFixture()
        let store = try fixture.openStore()
        let executor = ControlledJobExecutor()
        let scheduler = JobScheduler(store: store, executor: executor, lightweightLimit: 2)

        for id in ["heavy-1", "heavy-2"] {
            _ = try scheduler.enqueue(id: id, manifest: fixture.manifest(id: id, executionClass: .heavy))
        }
        for id in ["light-1", "light-2", "light-3"] {
            _ = try scheduler.enqueue(id: id, manifest: fixture.manifest(id: id, executionClass: .lightweight))
        }

        waitUntil { executor.startedIDs.count == 3 }
        XCTAssertEqual(Set(executor.startedIDs), Set(["heavy-1", "light-1", "light-2"]))
        XCTAssertEqual(executor.maximumActiveHeavy, 1)
        XCTAssertEqual(executor.maximumActiveLightweight, 2)

        executor.complete(jobID: "heavy-1", with: .success(JobStageResult()))
        executor.complete(jobID: "light-1", with: .success(JobStageResult()))

        waitUntil { executor.startedIDs.count == 5 }
        XCTAssertTrue(executor.startedIDs.contains("heavy-2"))
        XCTAssertTrue(executor.startedIDs.contains("light-3"))
        XCTAssertEqual(executor.maximumActiveHeavy, 1)
        XCTAssertEqual(executor.maximumActiveLightweight, 2)
    }

    func testSharedHeavyGateSerializesDifferentJobTypesAndResumesWaitingScheduler() throws {
        let fixture = try JobsFixture()
        let store = try fixture.openStore()
        let transcription = ControlledJobExecutor()
        let summary = ControlledJobExecutor()
        let gate = JobHeavyExecutionGate()
        let transcriptScheduler = JobScheduler(store: store, executor: transcription, eligibleJobTypes: ["meeting.transcription"], heavyExecutionGate: gate)
        let summaryScheduler = JobScheduler(store: store, executor: summary, eligibleJobTypes: ["meeting.summary"], heavyExecutionGate: gate)
        let transcript = JobManifest(type: "meeting.transcription", title: "Transcript", executionClass: .heavy, stages: [JobStageDefinition(id: "run", title: "Run")], maxAutomaticRetries: 0)
        let report = JobManifest(type: "meeting.summary", title: "Summary", executionClass: .heavy, stages: [JobStageDefinition(id: "run", title: "Run")], maxAutomaticRetries: 0)
        _ = try transcriptScheduler.enqueue(id: "transcript", manifest: transcript)
        waitUntil { transcription.startedIDs == ["transcript"] }
        _ = try summaryScheduler.enqueue(id: "summary", manifest: report)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(summary.startedIDs, [])
        XCTAssertEqual(try store.job(id: "summary")?.status, .queued)

        transcription.complete(jobID: "transcript", with: .success(JobStageResult()))
        waitUntil { summary.startedIDs == ["summary"] }
        XCTAssertEqual(try store.job(id: "transcript")?.status, .succeeded)
        summary.complete(jobID: "summary", with: .success(JobStageResult()))
        waitUntil { (try? store.job(id: "summary")?.status) == .succeeded }
    }

    func testPausedSchedulerFinishesActiveStageButDoesNotStartNextHeavyJobUntilResumed() throws {
        let fixture = try JobsFixture()
        let store = try fixture.openStore()
        let executor = ControlledJobExecutor()
        let scheduler = JobScheduler(store: store, executor: executor)
        _ = try scheduler.enqueue(id: "heavy-1", manifest: fixture.manifest(id: "heavy-1", executionClass: .heavy))
        _ = try scheduler.enqueue(id: "heavy-2", manifest: fixture.manifest(id: "heavy-2", executionClass: .heavy))
        waitUntil { executor.startedIDs == ["heavy-1"] }

        scheduler.pause()
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        executor.complete(jobID: "heavy-1", with: .success(JobStageResult()))
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(executor.startedIDs, ["heavy-1"])
        XCTAssertEqual(try store.job(id: "heavy-2")?.status, .queued)
        scheduler.start()
        waitUntil { executor.startedIDs == ["heavy-1", "heavy-2"] }
    }

    func testReleasedPausedSchedulerPersistsActiveCompletionWithoutStartingMoreWork() throws {
        let fixture = try JobsFixture()
        let store = try fixture.openStore()
        let executor = ControlledJobExecutor()
        var scheduler: JobScheduler? = JobScheduler(store: store, executor: executor)
        _ = try scheduler?.enqueue(id: "heavy-1", manifest: fixture.manifest(id: "heavy-1", executionClass: .heavy))
        _ = try scheduler?.enqueue(id: "heavy-2", manifest: fixture.manifest(id: "heavy-2", executionClass: .heavy))
        waitUntil { executor.startedIDs == ["heavy-1"] }

        scheduler?.pause()
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        scheduler = nil
        executor.complete(jobID: "heavy-1", with: .success(JobStageResult()))

        waitUntil { (try? store.job(id: "heavy-1")?.status) == .succeeded }
        XCTAssertEqual(executor.startedIDs, ["heavy-1"])
        XCTAssertEqual(try store.job(id: "heavy-2")?.status, .queued)
    }

    func testReplacementSchedulerIsRestartedWhenPausedSchedulerQueuesRetry() throws {
        let fixture = try JobsFixture()
        let store = try fixture.openStore()
        let oldExecutor = ControlledJobExecutor()
        let replacementExecutor = ControlledJobExecutor()
        var replacementScheduler: JobScheduler?
        let oldScheduler = JobScheduler(
            store: store,
            executor: oldExecutor,
            onWorkQueuedWhilePaused: { replacementScheduler?.start() }
        )
        let manifest = JobManifest(
            type: "meeting.transcription",
            title: "handoff retry",
            executionClass: .heavy,
            stages: [JobStageDefinition(id: "transcribe", title: "Transcribe")],
            maxAutomaticRetries: 1
        )
        _ = try oldScheduler.enqueue(id: "handoff", manifest: manifest)
        waitUntil { oldExecutor.executionCount(jobID: "handoff") == 1 }

        oldScheduler.pause()
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        replacementScheduler = JobScheduler(store: store, executor: replacementExecutor)
        replacementScheduler?.start()
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        XCTAssertEqual(replacementExecutor.executionCount(jobID: "handoff"), 0)

        oldExecutor.complete(jobID: "handoff", with: .failure(TestJobError.runnerFailed))
        waitUntil { replacementExecutor.executionCount(jobID: "handoff") == 1 }
        replacementExecutor.complete(jobID: "handoff", with: .success(JobStageResult()))
        waitUntil { (try? store.job(id: "handoff")?.status) == .succeeded }
    }

    func testSchedulerCanOwnOnlyItsDeclaredJobTypes() throws {
        let fixture = try JobsFixture()
        let store = try fixture.openStore()
        let executor = ControlledJobExecutor()
        let scheduler = JobScheduler(store: store, executor: executor, eligibleJobTypes: ["meeting.transcription"])
        _ = try scheduler.enqueue(id: "other", manifest: fixture.manifest(id: "other", executionClass: .heavy))
        _ = try scheduler.enqueue(id: "transcript", manifest: JobManifest(
            type: "meeting.transcription",
            title: "transcript",
            executionClass: .heavy,
            stages: [JobStageDefinition(id: "run", title: "Run")],
            maxAutomaticRetries: 0
        ))

        waitUntil { executor.startedIDs == ["transcript"] }
        XCTAssertEqual(try store.job(id: "other")?.status, .queued)
    }

    func testFailureRetriesAutomaticallyThenExposesDetailsRetryAndDismissActions() throws {
        let fixture = try JobsFixture()
        let inbox = try fixture.openInbox()
        let store = try fixture.openStore(inbox: inbox)
        let executor = ControlledJobExecutor()
        let scheduler = JobScheduler(store: store, executor: executor)
        let manifest = JobManifest(
            type: "meeting.summary",
            title: "Summarize kickoff",
            executionClass: .heavy,
            stages: [JobStageDefinition(id: "summarize", title: "Summarize")],
            maxAutomaticRetries: 1
        )

        _ = try scheduler.enqueue(id: "summary-1", manifest: manifest)
        waitUntil { executor.executionCount(jobID: "summary-1") == 1 }
        executor.complete(jobID: "summary-1", with: .failure(TestJobError.runnerFailed))
        waitUntil { executor.executionCount(jobID: "summary-1") == 2 }
        executor.complete(jobID: "summary-1", with: .failure(TestJobError.runnerFailed))
        waitUntil { (try? store.job(id: "summary-1")?.status) == .failed }

        var details = try scheduler.openDetails(id: "summary-1")
        XCTAssertEqual(details.job.stages.first?.attemptCount, 2)
        XCTAssertEqual(details.job.stages.first?.status, .failed)
        XCTAssertTrue(details.logs.contains { $0.level == "warning" && $0.message.contains("retrying") })
        XCTAssertTrue(details.logs.contains { $0.level == "error" })
        XCTAssertEqual(try inbox.items(category: .attention).map(\.id), ["job:summary-1"])

        try scheduler.retry(id: "summary-1")
        waitUntil { executor.executionCount(jobID: "summary-1") == 3 }
        XCTAssertTrue(try inbox.items(category: .attention).isEmpty)
        executor.complete(jobID: "summary-1", with: .failure(TestJobError.runnerFailed))
        waitUntil { (try? store.job(id: "summary-1")?.status) == .failed }

        try scheduler.dismiss(id: "summary-1")
        details = try scheduler.openDetails(id: "summary-1")
        XCTAssertEqual(details.job.status, .dismissed)
        XCTAssertTrue(try inbox.items(category: .attention).isEmpty)
    }

    func testMeetingScopedRetryRejectsActiveSameMeetingWorkAtomically() throws {
        let fixture = try JobsFixture()
        let store = try fixture.openStore()
        let executor = ControlledJobExecutor()
        let scheduler = JobScheduler(store: store, executor: executor)
        let path = "Meetings/retry/meeting.md"
        let failedManifest = JobManifest(type: "meeting.summary", title: "Summary", executionClass: .heavy,
            stages: [JobStageDefinition(id: "run", title: "Run")],
            sourceArtifacts: [JobArtifactReference(relativePath: path, role: "meeting")], maxAutomaticRetries: 0)
        _ = try scheduler.enqueue(id: "failed-meeting", manifest: failedManifest)
        waitUntil { executor.executionCount(jobID: "failed-meeting") == 1 }
        executor.complete(jobID: "failed-meeting", with: .failure(TestJobError.runnerFailed))
        waitUntil { (try? store.job(id: "failed-meeting")?.status) == .failed }
        _ = try store.enqueue(id: "active-meeting", manifest: failedManifest)

        XCTAssertThrowsError(try store.retry(id: "failed-meeting", meetingRelativePath: path))
        XCTAssertEqual(try store.job(id: "failed-meeting")?.status, .failed)
        XCTAssertEqual(try store.job(id: "active-meeting")?.status, .queued)
    }

    func testMeetingRetryRejectsActiveWorkOwnedOnlyByCaptureSession() throws {
        let fixture = try JobsFixture()
        let store = try fixture.openStore()
        let manifest = JobManifest(type: "meeting.summary", title: "Summary", executionClass: .heavy,
            stages: [JobStageDefinition(id: "run", title: "Run")],
            metadata: ["capture_session_id": "same-session"], maxAutomaticRetries: 0)
        let executor = ControlledJobExecutor()
        let scheduler = JobScheduler(store: store, executor: executor)
        _ = try scheduler.enqueue(id: "failed", manifest: manifest)
        waitUntil { executor.executionCount(jobID: "failed") == 1 }
        executor.complete(jobID: "failed", with: .failure(TestJobError.runnerFailed))
        waitUntil { (try? store.job(id: "failed")?.status) == .failed }
        _ = try store.enqueue(id: "active", manifest: manifest)

        XCTAssertThrowsError(try store.retry(id: "failed", meetingRelativePath: "Meetings/same/meeting.md", captureSessionID: "same-session"))
        XCTAssertEqual(try store.job(id: "failed")?.status, .failed)
    }

    func testConcurrentMeetingRetryAcrossStoreConnectionsOnlyResetsOnce() throws {
        let fixture = try JobsFixture()
        let first = try fixture.openStore()
        let second = try fixture.openStore()
        let path = "Meetings/retry/meeting.md"
        let executor = ControlledJobExecutor()
        let scheduler = JobScheduler(store: first, executor: executor)
        _ = try scheduler.enqueue(id: "failed", manifest: JobManifest(type: MeetingSummaryJob.type,
            title: "Summary", executionClass: .heavy, stages: [JobStageDefinition(id: "run", title: "Run")],
            sourceArtifacts: [JobArtifactReference(relativePath: path, role: "meeting")], maxAutomaticRetries: 0))
        waitUntil { executor.executionCount(jobID: "failed") == 1 }
        executor.complete(jobID: "failed", with: .failure(TestJobError.runnerFailed))
        waitUntil { (try? first.job(id: "failed")?.status) == .failed }
        let queue = DispatchQueue(label: "retry-concurrent", attributes: .concurrent)
        let group = DispatchGroup()
        let resultLock = NSLock()
        var successCount = 0
        for store in [first, second] {
            group.enter()
            queue.async {
                if (try? store.retry(id: "failed", meetingRelativePath: path)) != nil {
                    resultLock.lock(); successCount += 1; resultLock.unlock()
                }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(successCount, 1)
        XCTAssertEqual(try first.job(id: "failed")?.status, .queued)
    }

    func testRetryAndExplicitRerunResumeAtSelectedStageWithoutRepeatingEarlierStages() throws {
        let fixture = try JobsFixture()
        let store = try fixture.openStore()
        let executor = ControlledJobExecutor()
        let scheduler = JobScheduler(store: store, executor: executor)
        let manifest = JobManifest(
            type: "meeting.pipeline",
            title: "Process kickoff",
            executionClass: .heavy,
            stages: [
                JobStageDefinition(id: "audio", title: "Prepare audio"),
                JobStageDefinition(id: "transcript", title: "Transcribe")
            ],
            maxAutomaticRetries: 0
        )

        _ = try scheduler.enqueue(id: "pipeline-1", manifest: manifest)
        waitUntil { executor.executionCount(jobID: "pipeline-1", stageID: "audio") == 1 }
        executor.complete(jobID: "pipeline-1", with: .success(JobStageResult()))
        waitUntil { executor.executionCount(jobID: "pipeline-1", stageID: "transcript") == 1 }
        executor.complete(jobID: "pipeline-1", with: .failure(TestJobError.runnerFailed))
        waitUntil { (try? store.job(id: "pipeline-1")?.status) == .failed }

        try scheduler.retry(id: "pipeline-1")
        waitUntil { executor.executionCount(jobID: "pipeline-1", stageID: "transcript") == 2 }
        executor.complete(jobID: "pipeline-1", with: .success(JobStageResult()))
        waitUntil { (try? store.job(id: "pipeline-1")?.status) == .succeeded }

        var job = try XCTUnwrap(store.job(id: "pipeline-1"))
        XCTAssertEqual(executor.executionCount(jobID: "pipeline-1", stageID: "audio"), 1)
        XCTAssertEqual(job.stages.map(\.attemptCount), [1, 2])
        XCTAssertEqual(job.stages.map(\.status), [.succeeded, .succeeded])

        try scheduler.rerun(id: "pipeline-1", fromStageID: "transcript")
        waitUntil { executor.executionCount(jobID: "pipeline-1", stageID: "transcript") == 3 }
        executor.complete(jobID: "pipeline-1", with: .success(JobStageResult()))
        waitUntil { (try? store.job(id: "pipeline-1")?.status) == .succeeded }

        job = try XCTUnwrap(store.job(id: "pipeline-1"))
        XCTAssertEqual(executor.executionCount(jobID: "pipeline-1", stageID: "audio"), 1)
        XCTAssertEqual(job.stages.map(\.attemptCount), [1, 3])
    }

    func testGeneratedOutputsMustMatchManifestAndValidateBeforeStageSucceeds() throws {
        let fixture = try JobsFixture()
        let store = try fixture.openStore()
        let executor = ControlledJobExecutor()
        let scheduler = JobScheduler(store: store, executor: executor)
        let manifest = JobManifest(
            type: "meeting.summary",
            title: "Generate summary",
            executionClass: .heavy,
            stages: [JobStageDefinition(id: "generate", title: "Generate")],
            expectedOutputs: [GeneratedArtifactExpectation(
                stageID: "generate",
                relativePath: "Meetings/kickoff/summary.md",
                validatorID: "markdown",
                requiredFrontmatterFields: ["schema_version", "generated_at"],
                requiredHeadings: ["TL;DR", "My Action Items"]
            )],
            maxAutomaticRetries: 0
        )

        _ = try scheduler.enqueue(id: "generate-1", manifest: manifest)
        waitUntil { executor.executionCount(jobID: "generate-1") == 1 }
        executor.complete(jobID: "generate-1", with: .success(JobStageResult(artifacts: [
            GeneratedArtifact(
                relativePath: "Meetings/kickoff/summary.md",
                data: Data("# Unvalidated summary".utf8)
            )
        ])))
        waitUntil { (try? store.job(id: "generate-1")?.status) == .failed }

        let failed = try XCTUnwrap(store.job(id: "generate-1"))
        XCTAssertTrue(failed.failureDetails?.contains("Missing frontmatter") == true)
        XCTAssertEqual(failed.stages.first?.status, .failed)
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @escaping () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTFail("Timed out waiting for asynchronous job state", file: file, line: line)
    }
}

private enum TestJobError: Error {
    case runnerFailed
}

private final class ControlledJobExecutor: JobExecuting {
    private struct PendingExecution {
        let jobID: String
        let stageID: String
        let executionClass: JobExecutionClass
        let completion: (Result<JobStageResult, Error>) -> Void
    }

    private let lock = NSLock()
    private var pending: [PendingExecution] = []
    private var executions: [(jobID: String, stageID: String)] = []
    private var activeHeavy = 0
    private var activeLightweight = 0
    private(set) var maximumActiveHeavy = 0
    private(set) var maximumActiveLightweight = 0

    var startedIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return executions.map(\.jobID)
    }

    func executionCount(jobID: String, stageID: String? = nil) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return executions.filter { $0.jobID == jobID && (stageID == nil || $0.stageID == stageID) }.count
    }

    func execute(
        job: JobRecord,
        stage: JobStageDefinition,
        completion: @escaping (Result<JobStageResult, Error>) -> Void
    ) {
        lock.lock()
        executions.append((job.id, stage.id))
        if job.manifest.executionClass == .heavy {
            activeHeavy += 1
            maximumActiveHeavy = max(maximumActiveHeavy, activeHeavy)
        } else {
            activeLightweight += 1
            maximumActiveLightweight = max(maximumActiveLightweight, activeLightweight)
        }
        pending.append(PendingExecution(
            jobID: job.id,
            stageID: stage.id,
            executionClass: job.manifest.executionClass,
            completion: completion
        ))
        lock.unlock()
    }

    func complete(jobID: String, with result: Result<JobStageResult, Error>) {
        lock.lock()
        guard let index = pending.firstIndex(where: { $0.jobID == jobID }) else {
            lock.unlock()
            XCTFail("No pending execution for \(jobID)")
            return
        }
        let execution = pending.remove(at: index)
        if execution.executionClass == .heavy {
            activeHeavy -= 1
        } else {
            activeLightweight -= 1
        }
        lock.unlock()
        execution.completion(result)
    }
}

private final class JobsFixture {
    let rootURL: URL
    let databaseURL: URL

    init() throws {
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        databaseURL = rootURL.appendingPathComponent("operational.sqlite")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func openInbox() throws -> TasksInbox {
        try TasksInbox(databaseURL: databaseURL, now: { "2026-01-19T09:00:00Z" })
    }

    func openStore(inbox: TasksInbox? = nil) throws -> JobStore {
        try JobStore(databaseURL: databaseURL, inbox: inbox, now: { "2026-01-19T09:00:00Z" })
    }

    func manifest(id: String, executionClass: JobExecutionClass) -> JobManifest {
        JobManifest(
            type: "test.\(id)",
            title: id,
            executionClass: executionClass,
            stages: [JobStageDefinition(id: "run", title: "Run")],
            maxAutomaticRetries: 0
        )
    }
}
