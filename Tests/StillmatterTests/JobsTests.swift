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

    func testJobStoreObservationPublishesRelevantMeetingTransitionsAndCanBeCancelled() throws {
        let fixture = try JobsFixture()
        let store = try fixture.openStore()
        let lock = NSLock()
        var changes: [JobStoreChange] = []
        let observer = store.observeChanges { change in
            lock.lock(); changes.append(change); lock.unlock()
        }
        let manifest = JobManifest(type: "meeting.test", title: "Observe meeting", executionClass: .lightweight,
            stages: [JobStageDefinition(id: "run", title: "Run")],
            sourceArtifacts: [JobArtifactReference(relativePath: "Meetings/kickoff/meeting.md", role: "meeting-doorway")])
        let executor = ControlledJobExecutor()
        let scheduler = JobScheduler(store: store, executor: executor)
        _ = try scheduler.enqueue(id: "observed-meeting-job", manifest: manifest)
        waitUntil { lock.lock(); defer { lock.unlock() }; return changes.contains { $0.status == .running } }
        lock.lock(); let beforeRemoval = changes; lock.unlock()
        XCTAssertTrue(beforeRemoval.contains { $0.status == .queued && $0.meetingPaths == ["Meetings/kickoff/meeting.md"] })
        XCTAssertTrue(beforeRemoval.contains { $0.status == .running && $0.meetingPaths == ["Meetings/kickoff/meeting.md"] })

        store.removeChangeObserver(observer)
        executor.complete(jobID: "observed-meeting-job", with: .success(JobStageResult()))
        waitUntil { (try? store.job(id: "observed-meeting-job")?.status) == .succeeded }
        lock.lock(); let afterRemoval = changes; lock.unlock()
        _ = try store.enqueue(id: "unobserved-meeting-job", manifest: manifest)
        XCTAssertEqual(afterRemoval, beforeRemoval)
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

    func testWorkspaceBoundSchedulerQuarantinesLegacyAndOtherWorkspaceJobsAcrossReopen() throws {
        let fixture = try JobsFixture()
        var writer: JobStore? = try fixture.openStore()
        let old = fixture.rootURL.appendingPathComponent("Old")
        let next = fixture.rootURL.appendingPathComponent("Next")
        let manifest = fixture.manifest(id: "job", executionClass: .heavy)
        _ = try writer?.enqueue(id: "legacy", manifest: manifest)
        _ = try writer?.enqueue(id: "old", manifest: manifest.owned(by: old))
        _ = try writer?.enqueue(id: "next", manifest: manifest.owned(by: next))
        writer = nil
        let store = try fixture.openStore()
        let executor = ControlledJobExecutor()
        let scheduler = JobScheduler(store: store, executor: executor, workspaceRootURL: next)
        scheduler.start()
        waitUntil { executor.startedIDs == ["next"] }
        XCTAssertEqual(try store.job(id: "legacy")?.status, .queued)
        XCTAssertEqual(try store.job(id: "old")?.status, .queued)
        XCTAssertThrowsError(try scheduler.retry(id: "legacy"))
        XCTAssertThrowsError(try scheduler.retry(id: "old"))
        executor.complete(jobID: "next", with: .success(JobStageResult()))
        waitUntil { (try? store.job(id: "next")?.status) == .succeeded }
        XCTAssertEqual(executor.startedIDs, ["next"])
    }

    func testPausedOldWorkspaceJobSurvivesSwitchAndRestartAndResumesOnlyOnReturn() throws {
        let fixture = try JobsFixture()
        let old = fixture.rootURL.appendingPathComponent("Old")
        let next = fixture.rootURL.appendingPathComponent("Next")
        var store: JobStore? = try fixture.openStore()
        let oldWorker = ControlledJobExecutor()
        var oldScheduler: JobScheduler? = JobScheduler(store: try XCTUnwrap(store), executor: oldWorker,
            workspaceRootURL: old)
        let manifest = fixture.manifest(id: "durable", executionClass: .heavy).owned(by: old)
        _ = try oldScheduler?.enqueue(id: "active", manifest: manifest)
        _ = try oldScheduler?.enqueue(id: "waiting", manifest: manifest)
        waitUntil { oldWorker.startedIDs == ["active"] }
        oldScheduler?.pauseSynchronously()
        oldWorker.complete(jobID: "active", with: .success(JobStageResult()))
        waitUntil { (try? store?.job(id: "active")?.status) == .succeeded }
        XCTAssertEqual(try store?.job(id: "waiting")?.status, .queued)
        oldScheduler?.stop()
        oldScheduler = nil
        store = nil

        // A new process opens the same operational SQLite store, without changing owners.
        let reopened = try fixture.openStore()
        let nextWorker = ControlledJobExecutor()
        let nextScheduler = JobScheduler(store: reopened, executor: nextWorker, workspaceRootURL: next)
        nextScheduler.start()
        XCTAssertEqual(try reopened.job(id: "waiting")?.manifest.workspaceOwner,
            old.standardizedFileURL.resolvingSymlinksInPath().path)
        XCTAssertEqual(try reopened.job(id: "waiting")?.status, .queued)
        XCTAssertTrue(nextWorker.startedIDs.isEmpty)
        XCTAssertThrowsError(try nextScheduler.retry(id: "waiting"))
        nextScheduler.stop()
        let returnWorker = ControlledJobExecutor()
        let returned = JobScheduler(store: reopened, executor: returnWorker, workspaceRootURL: old)
        returned.start()
        waitUntil { returnWorker.startedIDs == ["waiting"] }
        returnWorker.complete(jobID: "waiting", with: .success(JobStageResult()))
        waitUntil { (try? reopened.job(id: "waiting")?.status) == .succeeded }
        XCTAssertEqual(try reopened.job(id: "waiting")?.manifest.workspaceOwner,
            old.standardizedFileURL.resolvingSymlinksInPath().path)
        returned.stop()
    }

    func testWorkspaceRuntimeBarrierCancelInvalidDestinationAndRetry() throws {
        let fixture = try JobsFixture()
        let old = fixture.rootURL.appendingPathComponent("Old")
        let next = fixture.rootURL.appendingPathComponent("Next")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: next, withIntermediateDirectories: true)
        let suite = "WorkspaceBarrier-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(userDefaults: defaults)
        settings.settings.stillmatterRootURL = old
        let runtime = WorkspaceRuntime()
        XCTAssertTrue(runtime.activate(settings.settings))
        let store = try fixture.openStore()
        let worker = ControlledJobExecutor()
        let scheduler = JobScheduler(store: store, executor: worker, workspaceRootURL: old)
        _ = try scheduler.enqueue(id: "active", manifest: fixture.manifest(id: "active", executionClass: .heavy).owned(by: old))
        waitUntil { worker.startedIDs == ["active"] }
        settings.requestWorkspace(.init(root: next, media: nil))
        XCTAssertFalse(runtime.retryPendingSelection(settingsStore: settings, jobStore: store, schedulers: [scheduler]))
        XCTAssertEqual(settings.settings.stillmatterRootURL, old)
        settings.cancelPendingWorkspace()
        runtime.resumeAfterCancellation(settingsStore: settings, schedulers: [scheduler])
        XCTAssertFalse(runtime.processingPausedForPendingSwitch)
        settings.requestWorkspace(.init(root: next, media: nil))
        XCTAssertFalse(runtime.retryPendingSelection(settingsStore: settings, jobStore: store, schedulers: [scheduler]))
        worker.complete(jobID: "active", with: .success(JobStageResult()))
        waitUntil { (try? store.job(id: "active")?.status) == .succeeded }
        _ = try store.enqueue(id: "waiting", manifest: fixture.manifest(id: "waiting", executionClass: .heavy).owned(by: old))
        let missing = fixture.rootURL.appendingPathComponent("Missing")
        settings.requestWorkspace(.init(root: missing, media: nil))
        XCTAssertFalse(runtime.retryPendingSelection(settingsStore: settings, jobStore: store, schedulers: [scheduler]))
        XCTAssertNotNil(settings.pendingWorkspaceError)
        XCTAssertEqual(settings.settings.stillmatterRootURL, old)
        waitUntil { worker.startedIDs.contains("waiting") }
        settings.requestWorkspace(.init(root: next, media: nil))
        XCTAssertFalse(runtime.retryPendingSelection(settingsStore: settings, jobStore: store, schedulers: [scheduler]))
        worker.complete(jobID: "waiting", with: .success(JobStageResult()))
        waitUntil { (try? store.job(id: "waiting")?.status) == .succeeded }
        XCTAssertTrue(runtime.retryPendingSelection(settingsStore: settings, jobStore: store, schedulers: [scheduler]))
        runtime.didActivateSelection()
        XCTAssertEqual(settings.settings.stillmatterRootURL, next)
        XCTAssertEqual(try store.job(id: "waiting")?.manifest.workspaceOwner,
            old.standardizedFileURL.resolvingSymlinksInPath().path)
        scheduler.stop()
    }

    func testMeetingRenameDoesNotRewriteOtherWorkspaceOrUnownedJobs() throws {
        let fixture = try JobsFixture()
        let store = try fixture.openStore()
        let first = fixture.rootURL.appendingPathComponent("First")
        let second = fixture.rootURL.appendingPathComponent("Second")
        let manifest = JobManifest(type: "meeting.transcription", title: "Rename", executionClass: .heavy,
            stages: [JobStageDefinition(id: "run", title: "Run")],
            sourceArtifacts: [JobArtifactReference(relativePath: "Meetings/old/meeting.md", role: "meeting-doorway")])
        _ = try store.enqueue(id: "first", manifest: manifest.owned(by: first))
        _ = try store.enqueue(id: "second", manifest: manifest.owned(by: second))
        _ = try store.enqueue(id: "legacy", manifest: manifest)
        let worker = ControlledJobExecutor()
        let scheduler = JobScheduler(store: store, executor: worker, workspaceRootURL: first)
        scheduler.start()
        waitUntil { worker.startedIDs == ["first"] }
        worker.complete(jobID: "first", with: .success(JobStageResult()))
        waitUntil { (try? store.job(id: "first")?.status) == .succeeded }
        // Queued work in the other workspace must not prevent this rename.
        try store.rewriteMeetingReferences(from: "Meetings/old", to: "Meetings/new", workspaceRootURL: first)
        XCTAssertEqual(try store.job(id: "first")?.manifest.sourceArtifacts.first?.relativePath, "Meetings/new/meeting.md")
        XCTAssertEqual(try store.job(id: "second")?.manifest.sourceArtifacts.first?.relativePath, "Meetings/old/meeting.md")
        XCTAssertEqual(try store.job(id: "legacy")?.manifest.sourceArtifacts.first?.relativePath, "Meetings/old/meeting.md")
    }

    func testWorkspaceHandoffBarrierWaitsForRunningStageWithoutStartingAnotherOldJob() throws {
        let fixture = try JobsFixture()
        let store = try fixture.openStore()
        let worker = ControlledJobExecutor()
        let oldRoot = fixture.rootURL.appendingPathComponent("Old")
        let scheduler = JobScheduler(store: store, executor: worker, workspaceRootURL: oldRoot)
        for id in ["first", "second"] {
            _ = try scheduler.enqueue(id: id, manifest: fixture.manifest(id: id, executionClass: .heavy).owned(by: oldRoot))
        }
        waitUntil { worker.startedIDs == ["first"] }
        scheduler.pauseSynchronously()
        XCTAssertEqual(try store.jobs(status: .running).map(\.id), ["first"])
        worker.complete(jobID: "first", with: .success(JobStageResult()))
        waitUntil { (try? store.job(id: "first")?.status) == .succeeded }
        XCTAssertTrue(try store.jobs(status: .running).isEmpty)
        XCTAssertEqual(try store.job(id: "second")?.status, .queued)
        XCTAssertEqual(worker.startedIDs, ["first"])
    }

    func testStoppedSchedulerDoesNotStartQueuedWorkAfterLateCompletionOrRestart() throws {
        let fixture = try JobsFixture()
        let store = try fixture.openStore()
        let worker = ControlledJobExecutor()
        let scheduler = JobScheduler(store: store, executor: worker)
        _ = try scheduler.enqueue(id: "first", manifest: fixture.manifest(id: "first", executionClass: .heavy))
        _ = try scheduler.enqueue(id: "second", manifest: fixture.manifest(id: "second", executionClass: .heavy))
        waitUntil { worker.startedIDs == ["first"] }
        scheduler.stop()
        worker.complete(jobID: "first", with: .success(JobStageResult()))
        waitUntil { (try? store.job(id: "first")?.status) == .succeeded }
        scheduler.start()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(worker.startedIDs, ["first"])
        XCTAssertEqual(try store.job(id: "second")?.status, .queued)
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
