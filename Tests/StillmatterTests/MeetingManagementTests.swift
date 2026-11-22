import XCTest
import SQLite3
import AVFoundation
@testable import StillmatterCore

final class MeetingManagementTests: XCTestCase {
    func testMeetingCitationOwnsTranscriptMatchingAndBoundedSeekValidation() {
        let segment = MeetingTranscriptSegment(id: "segment-1", startSeconds: 12, endSeconds: 15,
            track: "microphone", speaker: "Me", text: "Send the draft", seekSeconds: 12)
        let citation = MeetingCitation(segmentID: "segment-1", startSeconds: 12,
                                      endSeconds: 15, seekSeconds: 12)

        XCTAssertTrue(citation.matches(segment))
        XCTAssertEqual(citation.validatedSeekSeconds(playbackDuration: 20), 12)
        XCTAssertNil(citation.validatedSeekSeconds(playbackDuration: 10))
        XCTAssertFalse(MeetingCitation(segmentID: "other", startSeconds: 12, endSeconds: 15).matches(segment))
        XCTAssertFalse(MeetingCitation(segmentID: "segment-1", startSeconds: .nan, endSeconds: 15).matches(segment))
    }

    func testArchiveBlocksUnresolvedItemsForEveryOwnerAndNeverRunsAutomatically() throws {
        for owner in ["me", "person:other", "unknown"] {
            for (review, marker, blocked) in [("pending", " ", true), ("pending", "x", true), ("approved", " ", true),
                                               ("approved", "b", true), ("approved", "x", false),
                                               ("rejected", " ", false), ("dismissed", " ", false)] {
                let fixture = try Fixture()
                let path = "Meetings/ready/meeting.md"
                try seedArchiveReady(fixture, path: path)
                let service = MeetingManagementService(vault: fixture.vault)
                _ = try service.detail(for: path)
                let metadata = "{\"v\":1,\"id\":\"00000000-0000-0000-0000-000000000036\",\"owner\":\"\(owner)\",\"review\":\"\(review)\",\"origin\":\"generated\",\"citations\":[]}"
                try Data("- [\(marker)] Resolve work <!-- sm-item:\(metadata) -->\n".utf8).write(to: fixture.root.appendingPathComponent("Meetings/ready/action-items.md"))
                XCTAssertFalse(try service.detail(for: path).row.isArchived)
                if blocked {
                    XCTAssertThrowsError(try service.archive(meetingID: path), "\(owner) \(review) \(marker)")
                    XCTAssertFalse(try service.detail(for: path).row.isArchived)
                } else {
                    try service.archive(meetingID: path)
                    XCTAssertTrue(try service.detail(for: path).row.isArchived)
                }
            }
        }
    }

    func testArchiveExcludesIndexedContentImmediatelyAndExternalEditsRemainAuthoritative() throws {
        let fixture = try Fixture()
        let path = "Meetings/ready/meeting.md"
        try seedArchiveReady(fixture, path: path)
        let index = try SearchIndex(databaseURL: fixture.root.appendingPathComponent("Support/search.sqlite"), workspaceRootURL: fixture.root)
        try index.startupScan()
        XCTAssertFalse(try index.search("Ready").isEmpty)
        let service = MeetingManagementService(vault: fixture.vault, searchIndex: index)
        try service.archive(meetingID: path)
        XCTAssertTrue(try index.search("Ready").isEmpty)
        XCTAssertFalse(try index.search("Ready", filter: SearchFilter(includeArchived: true)).isEmpty)
        XCTAssertEqual(try service.list(filters: MeetingBrowserFilters(query: "Ready", archived: true)).map(\.meetingRelativePath), [path])
        try Data("{\"archived\":false}".utf8).write(to: fixture.root.appendingPathComponent("Meetings/ready/archive.json"))
        XCTAssertFalse(try index.search("Ready").isEmpty)
        XCTAssertFalse(try service.detail(for: path).row.isArchived)
    }

    func testArchiveRejectsIncompleteAndQueuedMeetingsWithoutWritingMarker() throws {
        let fixture = try Fixture()
        let path = "Meetings/ready/meeting.md"
        try fixture.write(path, "# Incomplete\n")
        let jobs = try JobStore(databaseURL: fixture.root.appendingPathComponent("Support/jobs.sqlite"))
        let service = MeetingManagementService(vault: fixture.vault, jobStore: jobs)
        XCTAssertThrowsError(try service.archive(meetingID: path))
        try seedArchiveReady(fixture, path: path)
        _ = try jobs.enqueue(id: "active", manifest: JobManifest(type: "meeting.transcription", title: "Queued", executionClass: .heavy,
            stages: [JobStageDefinition(id: "transcribe", title: "Transcribe")], sourceArtifacts: [JobArtifactReference(relativePath: path, role: "meeting")]))
        XCTAssertThrowsError(try service.archive(meetingID: path)) { XCTAssertTrue($0.localizedDescription.contains("processing")) }
        XCTAssertNil(try fixture.vault.versionOfMarkdown(relativePath: "Meetings/ready/archive.json"))
    }

    func testRecordingCannotArchiveEvenWithCompletedArtifacts() throws {
        let fixture = try Fixture()
        let path = "Meetings/ready/meeting.md"
        try seedArchiveReady(fixture, path: path)
        let snapshot = CaptureSnapshot(state: .recording, meetingTitle: "Live", meetingRelativePath: path,
            source: .teams, elapsedSeconds: 2, failureMessage: nil, processingStatus: [], preflightReport: nil,
            micRecording: nil, systemAudioRecording: nil, recordingBundle: nil, transcriptionAudio: nil)
        let service = MeetingManagementService(vault: fixture.vault, captureSnapshot: { snapshot })
        XCTAssertEqual(try service.detail(for: path).archiveUnavailableReason, "Stop recording before archiving this Meeting.")
        XCTAssertThrowsError(try service.archive(meetingID: path))
        XCTAssertNil(try fixture.vault.versionOfMarkdown(relativePath: "Meetings/ready/archive.json"))
    }

    private func seedArchiveReady(_ fixture: Fixture, path: String) throws {
        if try fixture.vault.versionOfMarkdown(relativePath: path) == nil { try fixture.write(path, "# Ready\n") }
        let directory = (path as NSString).deletingLastPathComponent
        let doorway = String(decoding: try fixture.vault.readMarkdown(relativePath: path).data, as: UTF8.self)
        let session = doorway.components(separatedBy: "\n").first(where: { $0.hasPrefix("capture_session_id:") })?.dropFirst("capture_session_id:".count).trimmingCharacters(in: .whitespaces) ?? "ready"
        let transcript = TranscriptDocument(schemaVersion: 1, captureSessionID: session, meetingRelativePath: path,
            language: .english, detectedLanguages: [], engine: "fixture", model: "fixture",
            generatedAt: Date(timeIntervalSince1970: 0), audioSources: [], segments: [], diagnostics: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try fixture.write(directory + "/transcript.json", String(decoding: encoder.encode(transcript), as: UTF8.self))
        if try fixture.vault.versionOfMarkdown(relativePath: directory + "/transcript.md") == nil { try fixture.write(directory + "/transcript.md", "# Transcript\n") }
        if try fixture.vault.versionOfMarkdown(relativePath: directory + "/summary.md") == nil { try fixture.write(directory + "/summary.md", "# Summary\n") }
        let extraction = MeetingSummaryExtraction(meeting: path, transcript: directory + "/transcript.json",
            decisions: [], myActionItems: [], otherActionItems: [], openQuestions: [])
        try fixture.write(directory + "/summary-extraction.json", String(decoding: encoder.encode(extraction), as: UTF8.self))
    }

    func testActionDraftSaveDoesNotAcceptOrCreateTodoAndSurvivesRequeue() throws {
        let fixture = try Fixture()
        let path = "Meetings/draft/meeting.md"
        try fixture.write(path, "---\ntitle: Draft\ncapture_session_id: draft\n---\n# Draft\n")
        let inbox = try TasksInbox(databaseURL: fixture.root.appendingPathComponent("Support/draft.sqlite"))
        let id = "meeting-action:draft:one"
        let source = "[[Meetings/draft/summary#My action items|ref]]"
        try inbox.queueProposal(id: id, title: "Generated task", sourceRef: source)
        var changedPaths: [[String]] = []
        let service = MeetingManagementService(vault: fixture.vault, inbox: inbox,
                                              onMeetingChanged: { changedPaths.append($0) })
        try service.saveActionDraft(id: id, title: "Edited task", comment: "Needs confirmation")
        XCTAssertEqual(try service.actionDraft(id: id)?.title, "Edited task")
        XCTAssertEqual(try service.actionDraft(id: id)?.comment, "Needs confirmation")
        XCTAssertEqual(try inbox.proposalReviewState(id: id), .pending)
        XCTAssertNil(try fixture.vault.versionOfMarkdown(relativePath: TodoItemIndex.mainTodoRelativePath))
        XCTAssertEqual(changedPaths, [["Meetings/draft/meeting.md"]])
        let detail = try service.detail(for: path)
        XCTAssertEqual(detail.actionDrafts[id], MeetingActionDraft(title: "Edited task", comment: "Needs confirmation"))
        try inbox.queueProposal(id: id, title: "Regenerated task", sourceRef: source)
        XCTAssertEqual(try inbox.pendingProposal(id: id)?.title, "Edited task")
        try service.reviewAction(id: id, accept: false)
        XCTAssertEqual(try inbox.proposalReviewState(id: id), .dismissed)
        XCTAssertEqual(changedPaths, [["Meetings/draft/meeting.md"], ["Meetings/draft/meeting.md"]])
        XCTAssertNil(try fixture.vault.versionOfMarkdown(relativePath: TodoItemIndex.mainTodoRelativePath))
    }

    func testBrowserPresentationAndQueuesUseActionReviewAndFailure() {
        let base = MeetingBrowserRow(id: "one", title: "Untitled Meeting at 2026-10-07 17:35",
            startedAt: nil, meetingRelativePath: "Meetings/one/meeting.md", captureState: .stopped,
            processingState: .ready, durationSeconds: 85, hasMyActions: true, hasOthersActions: true)
        XCTAssertEqual(base.displayTitle, "2026-10-07 17:35")
        XCTAssertEqual(base.durationSeconds, 85)
        XCTAssertTrue(base.hasMyActions && base.hasOthersActions)
        XCTAssertFalse(base.requiresAttention)
        let review = MeetingBrowserRow(id: "two", title: "Planning", startedAt: nil,
            meetingRelativePath: "Meetings/two/meeting.md", captureState: .stopped,
            processingState: .ready, needsActionReview: true)
        XCTAssertEqual(review.displayTitle, "Planning")
        XCTAssertTrue(review.requiresAttention)
        let failure = MeetingBrowserRow(id: "three", title: "Failed", startedAt: nil,
            meetingRelativePath: "Meetings/three/meeting.md", captureState: .stopped,
            processingState: .needsAttention,
            job: MeetingJobPresentation(jobID: "failed", title: "Transcribe", status: .failed, stage: nil, error: "Oops"))
        XCTAssertTrue(failure.requiresAttention)
    }

    func testExplicitMeetingMutationsPublishAffectedCanonicalPaths() throws {
        let fixture = try Fixture()
        let path = "Meetings/legacy/meeting.md"
        try fixture.write(path, "---\ntitle: Legacy meeting\ncapture_session_id: legacy\n---\n# Legacy meeting\n\n## Notes\n\nKeep this\n")
        try fixture.write("Meetings/legacy/summary.md", "## Summary\n\nOriginal summary.\n")
        var changes: [[String]] = []
        let service = MeetingManagementService(vault: fixture.vault, onMeetingChanged: { changes.append($0) })

        let initial = try service.detail(for: path)
        let edited = try service.saveHumanNotes("Updated notes", for: path,
                                                expectedVersion: try XCTUnwrap(initial.notesVersion))
        XCTAssertEqual(edited.humanNotes, "Updated notes")
        XCTAssertEqual(changes, [[path]])

        try seedArchiveReady(fixture, path: path)
        try service.archive(meetingID: path)
        XCTAssertEqual(changes, [[path], [path]])
        try Data("{\"archived\":false}".utf8).write(to: fixture.root.appendingPathComponent("Meetings/legacy/archive.json"))

        let renamed = try service.rename(meetingID: path, title: "Updated title",
                                         expectedVersion: try XCTUnwrap(edited.doorwayVersion))
        XCTAssertEqual(renamed.row.title, "Updated title")
        XCTAssertEqual(changes.last, [path, renamed.row.meetingRelativePath])
        try service.remove(meetingID: renamed.row.id)
        XCTAssertEqual(changes.last, [renamed.row.meetingRelativePath])
    }

    func testRemoveMovesOnlyMeetingFolderToTrash() throws {
        let fixture = try Fixture()
        try fixture.write("Meetings/disposable/meeting.md", "# Disposable\n")
        try fixture.write("Meetings/disposable/transcript.md", "Evidence\n")
        try fixture.write("Todos/todo.md", "# Todos\n")
        let service = MeetingManagementService(vault: fixture.vault)
        try service.remove(meetingID: "Meetings/disposable/meeting.md")
        XCTAssertTrue(try service.list().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("Meetings/disposable").path))
        XCTAssertEqual(try String(contentsOf: fixture.root.appendingPathComponent("Todos/todo.md")), "# Todos\n")
    }

    func testRemoveFailedWorkflowCleansJobsInboxAndSearchWithoutRemovingOtherMeetings() throws {
        let fixture = try Fixture()
        let path = "Meetings/failed/meeting.md"
        try fixture.write(path, "---\ntitle: DisposableEvidence\ncapture_session_id: failed\n---\n# DisposableEvidence\n")
        let databaseURL = fixture.root.appendingPathComponent("Support/operational.sqlite")
        let inbox = try TasksInbox(databaseURL: databaseURL)
        let store = try JobStore(databaseURL: databaseURL, inbox: inbox)
        let manifest = JobManifest(type: MeetingWorkflowJob.type, title: "Failed summary", executionClass: .heavy,
            stages: [.init(id: MeetingSummaryJob.stageID, title: "Summary")],
            sourceArtifacts: [.init(relativePath: path, role: "meeting-doorway")],
            metadata: ["capture_session_id": "failed"], maxAutomaticRetries: 0).owned(by: fixture.root)
        let scheduler = JobScheduler(store: store, executor: FailingMeetingExecutor())
        defer { scheduler.stop() }
        _ = try scheduler.enqueue(id: "failed-summary", manifest: manifest)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline && (try? store.job(id: "failed-summary"))?.status != .failed {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(try store.job(id: "failed-summary")?.status, .failed)
        let scoped = try inbox.scoped(to: fixture.root)
        try scoped.queueProposal(id: "proposal", title: "Pending", sourceRef: "[[Meetings/failed/summary#My action items|ref]]")
        try scoped.saveProposalDraft(id: "proposal", title: "Edited", comment: "Draft")
        try scoped.queueProposal(id: "dismissed", title: "Rejected", sourceRef: "[[Meetings/failed/summary|ref]]")
        try scoped.setProposalReviewState(id: "dismissed", state: .dismissed)
        XCTAssertTrue(try scoped.isProposalDismissed(suppressionKey: "dismissed"))
        try fixture.write("Meetings/other/meeting.md", "# Other\n")
        let unrelated = JobManifest(type: "other", title: "Other", executionClass: .heavy,
            stages: [.init(id: "other", title: "Other")],
            sourceArtifacts: [.init(relativePath: "Meetings/other/meeting.md", role: "meeting-doorway")])
        _ = try store.enqueue(id: "unrelated", manifest: unrelated)
        let otherWorkspace = fixture.root.appendingPathComponent("OtherWorkspace")
        _ = try store.enqueue(id: "other-workspace", manifest: manifest.owned(by: otherWorkspace))
        let index = try SearchIndex(databaseURL: fixture.root.appendingPathComponent("Support/search.sqlite"), workspaceRootURL: fixture.root)
        try index.rebuild()
        XCTAssertFalse(try index.search("DisposableEvidence").isEmpty)
        let service = MeetingManagementService(vault: fixture.vault, jobStore: store, inbox: scoped, searchIndex: index, enforceWorkspaceOwner: true)
        XCTAssertNotNil(try service.detail(for: "failed").doorwayVersion)
        try service.remove(meetingID: "failed")
        XCTAssertNil(try store.job(id: "failed-summary"))
        XCTAssertNotNil(try store.job(id: "unrelated"))
        XCTAssertNotNil(try store.job(id: "other-workspace"))
        XCTAssertTrue(try scoped.items().isEmpty)
        XCTAssertNil(try scoped.proposalDraft(id: "proposal"))
        XCTAssertNil(try scoped.proposalReviewState(id: "proposal"))
        XCTAssertFalse(try scoped.isProposalDismissed(suppressionKey: "dismissed"))
        XCTAssertTrue(try index.search("DisposableEvidence").isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("Meetings/failed").path))
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &connection), SQLITE_OK)
        defer { sqlite3_close(connection) }
        for table in ["jobs", "job_stages", "job_logs"] {
            var statement: OpaquePointer?
            let column = table == "jobs" ? "id" : "job_id"
            XCTAssertEqual(sqlite3_prepare_v2(connection, "SELECT COUNT(*) FROM \(table) WHERE \(column) = 'failed-summary'", -1, &statement, nil), SQLITE_OK)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
            XCTAssertEqual(sqlite3_column_int(statement, 0), 0)
            sqlite3_finalize(statement)
        }
    }

    func testRemoveRejectsActiveProcessingAndPreservesFilesAndJobs() throws {
        let fixture = try Fixture()
        let path = "Meetings/active/meeting.md"
        try fixture.write(path, "---\ncapture_session_id: active\n---\n# Active\n")
        let store = try JobStore(databaseURL: fixture.root.appendingPathComponent("Support/jobs.sqlite"))
        let manifest = JobManifest(type: MeetingWorkflowJob.type, title: "Active", executionClass: .heavy,
            stages: [.init(id: "summary", title: "Summary")], metadata: ["capture_session_id": "active"])
        _ = try store.enqueue(id: "active-job", manifest: manifest)
        let service = MeetingManagementService(vault: fixture.vault, jobStore: store)
        XCTAssertThrowsError(try service.remove(meetingID: "active"))
        XCTAssertNotNil(try fixture.vault.versionOfMarkdown(relativePath: path))
        XCTAssertEqual(try store.job(id: "active-job")?.status, .queued)
    }

    func testArchivePersistsWithoutTouchingMeetingArtifactsOrProcessing() throws {
        let fixture = try Fixture()
        let path = "Meetings/legacy/meeting.md"
        try fixture.write(path, "# Legacy meeting\n\n## Notes\n\nKeep this\n")
        try fixture.write("Meetings/legacy/transcript.md", "Transcript evidence")
        let link = "[[Meetings/legacy/meeting|source]]"
        try fixture.write("Tasks/linked.md", link)
        try seedArchiveReady(fixture, path: path)
        let service = MeetingManagementService(vault: fixture.vault)
        let before = try service.detail(for: path)
        let original = try Data(contentsOf: fixture.root.appendingPathComponent(path))
        try service.archive(meetingID: path)
        XCTAssertTrue(try service.list().isEmpty)
        let archived = try XCTUnwrap(service.list(filters: MeetingBrowserFilters(archived: true)).first)
        XCTAssertEqual(archived.id, before.row.id)
        XCTAssertEqual(archived.processingState, before.row.processingState)
        XCTAssertTrue(archived.isArchived)
        let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.root.appendingPathComponent("Meetings/legacy/archive.json"))) as? [String: Any]
        XCTAssertNotNil((marker?["archivedAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) })
        XCTAssertThrowsError(try service.archive(meetingID: path))
        XCTAssertEqual(try service.detail(for: path).humanNotes, "\nKeep this\n")
        XCTAssertEqual(try Data(contentsOf: fixture.root.appendingPathComponent(path)), original)
        XCTAssertEqual(try String(contentsOf: fixture.root.appendingPathComponent("Meetings/legacy/transcript.md")), "Transcript evidence")
        XCTAssertEqual(try String(contentsOf: fixture.root.appendingPathComponent("Tasks/linked.md")), link)
        let reopened = MeetingManagementService(vault: fixture.vault)
        XCTAssertEqual(try reopened.list(filters: MeetingBrowserFilters(archived: true)).map(\.id), [path])
        XCTAssertTrue(try reopened.list().isEmpty)
        try Data("# External archived notes\n".utf8).write(to: fixture.root.appendingPathComponent("Meetings/legacy/my-notes.md"))
        XCTAssertTrue(try reopened.detail(for: path).humanNotes.contains("External archived notes"))
        XCTAssertEqual(try reopened.detail(for: path).row.processingState, before.row.processingState)
    }

    func testArchiveCombinesWithSearchAndRejectsMissingOrMalformedMarker() throws {
        let fixture = try Fixture()
        try fixture.write("Meetings/a/meeting.md", "---\ntitle: Alpha\ncapture_session_id: alpha\n---\n# Alpha\n")
        try fixture.write("Meetings/b/meeting.md", "# Beta\n")
        let service = MeetingManagementService(vault: fixture.vault)
        XCTAssertEqual(try service.list().count, 2)
        try seedArchiveReady(fixture, path: "Meetings/a/meeting.md")
        try service.archive(meetingID: "alpha")
        XCTAssertEqual(try service.list(filters: MeetingBrowserFilters(query: "Alpha", archived: true)).map(\.id), ["alpha"])
        XCTAssertTrue(try service.list(filters: MeetingBrowserFilters(query: "Beta", archived: true)).isEmpty)
        XCTAssertThrowsError(try service.archive(meetingID: "missing"))
        try fixture.write("Meetings/b/archive.json", "not json")
        XCTAssertThrowsError(try service.list())
        XCTAssertThrowsError(try service.archive(meetingID: "Meetings/b/meeting.md"))
    }

    func testListsDoorwaysNewestFirstAndExposesDetail() throws {
        let fixture = try Fixture()
        try fixture.write("Meetings/older/meeting.md", """
        ---
        title: Earlier conversation
        started_at: 2026-09-16T09:00:00Z
        capture_session_id: old
        ---
        # Earlier conversation
        Notes
        """)
        try fixture.write("Meetings/newer/meeting.md", """
        ---
        title: Latest conversation
        started_at: 2026-09-16T10:00:00Z
        capture_session_id: new
        ---
        # Latest conversation
        """)
        let service = MeetingManagementService(vault: fixture.vault)
        let rows = try service.list()
        XCTAssertEqual(rows.map(\.title), ["Latest conversation", "Earlier conversation"])
        XCTAssertEqual(try service.detail(for: "new").doorwayText.contains("Latest conversation"), true)
    }

    func testListingMeetingsWithJobHistoryFitsRefreshInterval() throws {
        let fixture = try Fixture()
        let store = try JobStore(databaseURL: fixture.root.appendingPathComponent("Support/jobs.sqlite"))
        for number in 0..<100 {
            try fixture.write("Meetings/meeting-\(number)/meeting.md",
                "---\ntitle: Meeting \(number)\ncapture_session_id: session-\(number)\n---\n# Meeting \(number)\n")
        }
        for number in 0..<350 {
            let manifest = JobManifest(type: "meeting.test", title: "Job \(number)", executionClass: .lightweight,
                stages: [JobStageDefinition(id: "run", title: "Run")],
                sourceArtifacts: [JobArtifactReference(relativePath: "Meetings/meeting-\(number % 100)/meeting.md", role: "meeting")])
            _ = try store.enqueue(id: "job-\(number)", manifest: manifest)
        }
        let service = MeetingManagementService(vault: fixture.vault, jobStore: store)
        let start = Date()
        let result = try service.browserRows(filters: MeetingBrowserFilters(processing: .processing))
        XCTAssertEqual(result.available.count, 100)
        XCTAssertEqual(result.visible.count, 100)
        XCTAssertEqual(try service.detail(for: result.visible[0]).row.id, result.visible[0].id)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5, "A full browser refresh must fit the two-second update interval")
    }

    func testLegacyDoorwayRemainsVisibleWithFallbackTitleAndPathIdentity() throws {
        let fixture = try Fixture()
        try fixture.write("Meetings/2025/legacy-meeting/meeting.md", "# Legacy meeting\n")
        let row = try XCTUnwrap(MeetingManagementService(vault: fixture.vault).list().first)
        XCTAssertEqual(row.id, "Meetings/2025/legacy-meeting/meeting.md")
        XCTAssertEqual(row.title, "Legacy meeting")
        XCTAssertEqual(row.captureState, .stopped)
    }

    func testLiveSnapshotIsMergedWithDurableRows() throws {
        let fixture = try Fixture()
        try fixture.write("Meetings/live/meeting.md", "---\ntitle: Live\n---\n# Live\n")
        let snapshot = CaptureSnapshot(state: .recording, meetingTitle: "Live", meetingRelativePath: "Meetings/live/meeting.md", source: .teams, elapsedSeconds: 2, failureMessage: nil, processingStatus: [], preflightReport: nil, micRecording: nil, systemAudioRecording: nil, recordingBundle: nil, transcriptionAudio: nil)
        let row = try XCTUnwrap(MeetingManagementService(vault: fixture.vault, captureSnapshot: { snapshot }).list().first)
        XCTAssertEqual(row.captureState, .live)
    }

    func testLiveLegacyDoorwayDefersMigrationAndRetainsTheLatestRecorderNotes() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let path = "Meetings/live-legacy/meeting.md"
        let original = "---\ntitle: Live legacy\ncapture_session_id: live-legacy\n---\n# Live legacy\n\n## Live notes\n\nInitial recorder note.\n"
        try fixture.write(path, original)
        var snapshot: CaptureSnapshot? = CaptureSnapshot(state: .recording, meetingTitle: "Live legacy", meetingRelativePath: path, source: .teams,
            elapsedSeconds: 2, failureMessage: nil, processingStatus: [], preflightReport: nil, micRecording: nil,
            systemAudioRecording: nil, recordingBundle: nil, transcriptionAudio: nil)
        let service = MeetingManagementService(vault: fixture.vault, captureSnapshot: { snapshot })
        let live = try service.detail(for: path)
        XCTAssertEqual(live.row.captureState, .live)
        XCTAssertEqual(live.notesVersion, live.doorwayVersion)
        XCTAssertNil(live.summaryVersion)
        XCTAssertTrue(live.humanNotes.contains("Initial recorder note."))
        XCTAssertEqual(try fixture.vault.readMarkdown(relativePath: path).data, Data(original.utf8))
        XCTAssertNil(try fixture.vault.versionOfMarkdown(relativePath: "Meetings/live-legacy/meeting-artifacts.json"))
        let edited = try service.saveHumanNotes("Notes edited while capture continues.", for: path, expectedVersion: XCTUnwrap(live.notesVersion))
        XCTAssertTrue(edited.humanNotes.contains("Notes edited while capture continues."))
        XCTAssertNil(try fixture.vault.versionOfMarkdown(relativePath: "Meetings/live-legacy/my-notes.md"))
        let recorded = String(decoding: try fixture.vault.readMarkdown(relativePath: path).data, as: UTF8.self) + "A later recorder note.\n"
        try fixture.replace(path, recorded)
        XCTAssertThrowsError(try service.saveHumanNotes("Stale edit", for: path, expectedVersion: XCTUnwrap(edited.notesVersion)))
        XCTAssertEqual(try fixture.vault.readMarkdown(relativePath: path).data, Data(recorded.utf8))
        snapshot = nil
        let stopped = try service.detail(for: path)
        XCTAssertEqual(stopped.row.captureState, .stopped)
        XCTAssertTrue(stopped.humanNotes.contains("Notes edited while capture continues."))
        XCTAssertTrue(stopped.humanNotes.contains("A later recorder note."))
        let canonical = try fixture.vault.readMarkdown(relativePath: "Meetings/live-legacy/my-notes.md")
        XCTAssertEqual(stopped.notesVersion, canonical.version)
        XCTAssertNotEqual(stopped.notesVersion, stopped.doorwayVersion)
        XCTAssertNotNil(try fixture.vault.versionOfMarkdown(relativePath: "Meetings/live-legacy/meeting-artifacts.json"))
    }

    func testProcessingLegacyFilesStayWritableUntilTheCurrentProducerFinishes() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let path = "Meetings/processing-legacy/meeting.md"
        try fixture.write(path, "---\ntitle: Processing legacy\ncapture_session_id: processing-legacy\n---\n# Processing\n\n## Notes\n\nOld notes.\n")
        try fixture.write("Meetings/processing-legacy/summary.md", "## Summary\n\nOld producer output.\n")
        let store = try JobStore(databaseURL: fixture.root.appendingPathComponent("Support/processing.sqlite"))
        let manifest = JobManifest(type: "meeting.transcription", title: "Legacy producer", executionClass: .heavy,
            stages: [JobStageDefinition(id: "run", title: "Run")], metadata: ["capture_session_id": "processing-legacy"], maxAutomaticRetries: 0)
        _ = try store.enqueue(id: "legacy-producer", manifest: manifest)
        let service = MeetingManagementService(vault: fixture.vault, jobStore: store)
        let processing = try service.detail(for: path)
        XCTAssertEqual(processing.row.processingState, .processing)
        XCTAssertNil(try fixture.vault.versionOfMarkdown(relativePath: "Meetings/processing-legacy/meeting-artifacts.json"))
        var summary = try XCTUnwrap(processing.summary)
        summary.summary = "## Summary\n\nEdited prior output while queued.\n"
        let saved = try service.saveSummary(summary, for: path, expectedVersion: XCTUnwrap(processing.summaryVersion))
        XCTAssertTrue(saved.summary?.summary.contains("Edited prior output while queued.") == true)
        XCTAssertNil(try fixture.vault.versionOfMarkdown(relativePath: "Meetings/processing-legacy/meeting-artifacts.json"))
        let later = "---\ntitle: Processing legacy\ncapture_session_id: processing-legacy\n---\n# Processing\n\n## Notes\n\nLatest producer-context notes.\n"
        try fixture.replace(path, later)
        let scheduler = JobScheduler(store: store, executor: FailingMeetingExecutor())
        defer { scheduler.stop() }
        scheduler.start()
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline && (try? store.job(id: "legacy-producer"))?.status != .failed {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(try store.job(id: "legacy-producer")?.status, .failed)
        let completed = try service.detail(for: path)
        XCTAssertTrue(completed.humanNotes.contains("Latest producer-context notes."))
        XCTAssertTrue(completed.summary?.summary.contains("Edited prior output while queued.") == true)
        XCTAssertNotNil(try fixture.vault.versionOfMarkdown(relativePath: "Meetings/processing-legacy/meeting-artifacts.json"))
        // A later reprocess uses the already canonical files without moving notes back.
        scheduler.stop()
        _ = try store.enqueue(id: "next-producer", manifest: manifest)
        let reprocessing = try service.detail(for: path)
        XCTAssertEqual(reprocessing.row.processingState, .processing)
        XCTAssertEqual(reprocessing.humanNotes, completed.humanNotes)
        XCTAssertEqual(reprocessing.notesVersion, completed.notesVersion)
        XCTAssertFalse(String(decoding: try fixture.vault.readMarkdown(relativePath: path).data, as: UTF8.self).contains("Latest producer-context notes."))
    }

    func testSearchUsesIndexedSummaryContentAndKeepsSelectedMeetingPaths() throws {
        let fixture = try Fixture()
        try fixture.write("Meetings/alpha/meeting.md", "---\ntitle: Alpha\n---\n# Alpha\n")
        try fixture.write("Meetings/alpha/summary.md", "## Summary\n\nUnique indexed phrase\n")
        try fixture.write("Meetings/beta/meeting.md", "---\ntitle: Beta\n---\n# Beta\n")
        let index = try SearchIndex(
            databaseURL: fixture.root.appendingPathComponent("Support/search.sqlite"),
            workspaceRootURL: fixture.root
        )
        try index.startupScan()

        let rows = try MeetingManagementService(vault: fixture.vault, searchIndex: index).list(
            filters: MeetingBrowserFilters(query: "unique indexed phrase")
        )

        XCTAssertEqual(rows.map(\.meetingRelativePath), ["Meetings/alpha/meeting.md"])
    }

    func testFiltersCombineProjectAndInclusiveDateRange() throws {
        let fixture = try Fixture()
        try fixture.write("Meetings/one/meeting.md", "---\ntitle: One\nproject: Alpha\nstarted_at: 2026-09-15T18:00:00Z\n---\n# One\n")
        try fixture.write("Meetings/two/meeting.md", "---\ntitle: Two\nproject: Alpha\nstarted_at: 2026-09-16T18:00:00Z\n---\n# Two\n")
        try fixture.write("Meetings/three/meeting.md", "---\ntitle: Three\nproject: Beta\nstarted_at: 2026-09-16T09:00:00Z\n---\n# Three\n")
        let formatter = ISO8601DateFormatter()
        let rows = try MeetingManagementService(vault: fixture.vault).list(filters: MeetingBrowserFilters(
            startDate: try XCTUnwrap(formatter.date(from: "2026-09-16T00:00:00Z")),
            endDate: try XCTUnwrap(formatter.date(from: "2026-09-16T00:00:00Z")),
            project: "Alpha"
        ))

        XCTAssertEqual(rows.map(\.title), ["Two"])
        let browser = try MeetingManagementService(vault: fixture.vault).browserRows(filters: MeetingBrowserFilters(project: "Alpha"))
        XCTAssertEqual(Set(browser.available.map(\.title)), ["One", "Two", "Three"])
        XCTAssertEqual(Set(browser.visible.map(\.title)), ["One", "Two"])
    }

    func testActionItemsExposeInboxReviewStateAndKeepOtherItemsReferenceOnly() throws {
        let fixture = try Fixture()
        let meeting = "Meetings/outcomes/meeting.md"
        try fixture.write(meeting, "---\ntitle: Outcomes\ncapture_session_id: outcomes\n---\n# Outcomes\n")
        let extraction = MeetingSummaryExtraction(
            meeting: meeting,
            transcript: "Meetings/outcomes/transcript.json",
            decisions: [],
            myActionItems: [MeetingOutcome(id: "mine", text: "Send recap", citations: [MeetingOutcomeCitation(segmentID: "s1", startSeconds: 1, endSeconds: 2)])],
            otherActionItems: [MeetingOutcome(id: "other", text: "Review deck", citations: [])],
            openQuestions: []
        )
        try fixture.write(
            "Meetings/outcomes/summary-extraction.json",
            String(decoding: try JSONEncoder().encode(extraction), as: UTF8.self)
        )
        let inbox = try TasksInbox(databaseURL: fixture.root.appendingPathComponent("Support/inbox.sqlite"))
        try inbox.queueProposal(
            id: "meeting-action:outcomes:mine",
            title: "Send recap",
            sourceRef: "[[Meetings/outcomes/summary#My action items|ref]]"
        )
        try inbox.setProposalReviewState(id: "meeting-action:outcomes:mine", state: .accepted)

        let detail = try MeetingManagementService(vault: fixture.vault, inbox: inbox).detail(for: "outcomes")

        XCTAssertTrue(detail.myActionItems.isEmpty, "A missing accepted Todo must not be resurrected from old generated extraction")
        let history = try fixture.vault.readMarkdown(relativePath: "Meetings/outcomes/meeting-artifacts.json").data
        XCTAssertTrue(String(decoding: history, as: UTF8.self).contains("accepted"))
        XCTAssertTrue(String(decoding: history, as: UTF8.self).contains("meeting-action:outcomes:mine"))
        XCTAssertTrue(try XCTUnwrap(detail.otherActionItems.first).referenceOnly)
        XCTAssertEqual(try inbox.proposalReviewState(id: "meeting-action:outcomes:mine"), .accepted)
    }

    func testRegeneratedExtractionDistinguishesObsoletePendingProposalWithoutChangingReview() throws {
        let fixture = try Fixture()
        let meeting = "Meetings/outcomes/meeting.md"
        try fixture.write(meeting, "---\ntitle: Outcomes\ncapture_session_id: outcomes\n---\n# Outcomes\n")
        let inbox = try TasksInbox(databaseURL: fixture.root.appendingPathComponent("Support/inbox.sqlite"))
        let source = "[[Meetings/outcomes/summary#My action items|ref]]"
        try inbox.queueProposal(id: "meeting-action:outcomes:obsolete", title: "Old outcome", sourceRef: source)
        try inbox.queueProposal(id: "meeting-action:outcomes:current", title: "Current outcome", sourceRef: source)
        let extraction = MeetingSummaryExtraction(meeting: meeting, transcript: "Meetings/outcomes/transcript.json",
            decisions: [], myActionItems: [MeetingOutcome(id: "current", text: "Current outcome", citations: [])],
            otherActionItems: [], openQuestions: [])
        try fixture.write("Meetings/outcomes/summary-extraction.json", String(decoding: try JSONEncoder().encode(extraction), as: UTF8.self))
        let detail = try MeetingManagementService(vault: fixture.vault, inbox: inbox).detail(for: "outcomes")
        XCTAssertEqual(detail.staleProposals.map(\.id), ["meeting-action:outcomes:obsolete"])
        XCTAssertEqual(try inbox.proposalReviewState(id: "meeting-action:outcomes:obsolete"), .pending)
    }

    func testEvidenceTargetsRequireMatchingTranscriptCitationAndPlayableAudio() throws {
        let fixture = try Fixture()
        let bundle = try makePlaybackBundle(in: fixture, id: "evidence")
        let meeting = "Meetings/evidence/meeting.md"
        let transcriptPath = "Meetings/evidence/transcript.json"
        let service = MeetingManagementService(vault: fixture.vault)
        XCTAssertEqual(try service.list().map(\.id), ["evidence"])
        let segments = [
            TranscriptSegment(id: "later", startSeconds: 0.10, endSeconds: 0.20, text: "Later", language: .english, track: .systemAudio, speaker: "Guest"),
            TranscriptSegment(id: "first", startSeconds: 0.01, endSeconds: 0.09, text: "First", language: .english, track: .microphone, speaker: "Me"),
            TranscriptSegment(id: "outside", startSeconds: 0.3, endSeconds: 0.4, text: "Outside recording", language: .english, track: .microphone, speaker: "Me")
        ]
        func writeTranscript(_ segments: [TranscriptSegment], meetingPath: String = meeting, session: String = "evidence", schema: Int = 1) throws {
            let document = TranscriptDocument(schemaVersion: schema, captureSessionID: session, meetingRelativePath: meetingPath,
                language: .english, detectedLanguages: [.english], engine: "fixture", model: "fixture",
                generatedAt: Date(timeIntervalSince1970: 0), audioSources: [], segments: segments, diagnostics: [])
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            let data = String(decoding: try encoder.encode(document), as: UTF8.self)
            if (try? fixture.vault.readMarkdown(relativePath: transcriptPath)) != nil { try fixture.replace(transcriptPath, data) }
            else { try fixture.write(transcriptPath, data) }
        }
        try fixture.write(transcriptPath, "{broken json")
        XCTAssertThrowsError(try service.detail(for: "evidence"))
        try writeTranscript(segments, schema: 99)
        XCTAssertThrowsError(try service.detail(for: "evidence"))
        try writeTranscript(segments)
        let valid = MeetingOutcomeCitation(segmentID: "first", startSeconds: 0.01, endSeconds: 0.09)
        let unknown = MeetingOutcomeCitation(segmentID: "unknown", startSeconds: 0.01, endSeconds: 0.09)
        let wrongRange = MeetingOutcomeCitation(segmentID: "first", startSeconds: 0.02, endSeconds: 0.09)
        let invalid = MeetingOutcomeCitation(segmentID: "later", startSeconds: -1, endSeconds: 0.20)
        let extraction = MeetingSummaryExtraction(meeting: meeting, transcript: transcriptPath,
            decisions: [MeetingOutcome(id: "decision", text: "Decide", citations: [valid, unknown, wrongRange, invalid])],
            myActionItems: [MeetingOutcome(id: "mine", text: "Do", citations: [valid])],
            otherActionItems: [MeetingOutcome(id: "other", text: "Review", citations: [valid])],
            openQuestions: [MeetingOutcome(id: "question", text: "Why?", citations: [valid])])
        let extractionPath = "Meetings/evidence/summary-extraction.json"
        try fixture.write(extractionPath, String(decoding: try JSONEncoder().encode(extraction), as: UTF8.self))
        let detail = try service.detail(for: "evidence")
        XCTAssertEqual(detail.transcript.map(\.id), ["first", "later", "outside"])
        XCTAssertEqual(detail.transcript.first?.track, "Me")
        XCTAssertEqual(detail.transcript.first?.text, "First")
        XCTAssertEqual(detail.transcript.first?.seekSeconds, 0.01)
        XCTAssertNil(detail.transcript.last?.seekSeconds)
        XCTAssertEqual(detail.decisions.first?.citations.map(\.seekSeconds), [0.01, nil, nil, nil])
        XCTAssertEqual(detail.myActionItems.first?.citations.first?.seekSeconds, 0.01)
        XCTAssertEqual(detail.otherActionItems.first?.citations.first?.seekSeconds, 0.01)
        XCTAssertEqual(detail.openQuestions.first?.citations.first?.seekSeconds, 0.01)

        try writeTranscript(segments, meetingPath: "Meetings/other/meeting.md")
        XCTAssertThrowsError(try service.detail(for: "evidence"))
        try writeTranscript(segments, session: "other")
        XCTAssertThrowsError(try service.detail(for: "evidence"))
        try writeTranscript(segments)
        try fixture.replace(extractionPath, String(decoding: try JSONEncoder().encode(MeetingSummaryExtraction(
            meeting: "Meetings/other/meeting.md", transcript: transcriptPath, decisions: [], myActionItems: [], otherActionItems: [], openQuestions: [])), as: UTF8.self))
        XCTAssertEqual(try service.detail(for: "evidence").decisions.first?.text, "Decide", "Retired extraction JSON cannot overwrite canonical Markdown content")
        try Data("changed".utf8).write(to: bundle)
        let noAudio = try service.detail(for: "evidence")
        XCTAssertEqual(noAudio.transcript.map(\.text), ["First", "Later", "Outside recording"])
        XCTAssertTrue(noAudio.transcript.allSatisfy { $0.seekSeconds == nil })
    }

    func testEvidenceTargetsStayScopedToSelectedMeetingAcrossRepeatedReadsAndAudioLoss() throws {
        let fixture = try Fixture()
        let firstBundle = try makePlaybackBundle(in: fixture, id: "first")
        _ = try makePlaybackBundle(in: fixture, id: "second")
        let firstAudio = firstBundle.deletingLastPathComponent().appendingPathComponent("mic.caf")
        let originalAudio = try Data(contentsOf: firstAudio)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        for (id, start) in [("first", 0.02), ("second", 0.12)] {
            let path = "Meetings/\(id)/meeting.md"
            let transcriptPath = "Meetings/\(id)/transcript.json"
            let segment = TranscriptSegment(id: "shared-id", startSeconds: start, endSeconds: start + 0.05,
                                            text: "Speech in \(id)", language: .english, track: .microphone, speaker: "Me")
            let document = TranscriptDocument(schemaVersion: TranscriptDocument.currentSchemaVersion,
                captureSessionID: id, meetingRelativePath: path, language: .english,
                detectedLanguages: [.english], engine: "fixture", model: "fixture",
                generatedAt: Date(timeIntervalSince1970: 0), audioSources: [], segments: [segment], diagnostics: [])
            try fixture.write(transcriptPath, String(decoding: try encoder.encode(document), as: UTF8.self))
            let citation = MeetingOutcomeCitation(segmentID: "shared-id", startSeconds: start, endSeconds: start + 0.05)
            let extraction = MeetingSummaryExtraction(meeting: path, transcript: transcriptPath,
                decisions: [MeetingOutcome(id: "decision", text: "Decision in \(id)", citations: [citation])],
                myActionItems: [], otherActionItems: [], openQuestions: [])
            try fixture.write("Meetings/\(id)/summary-extraction.json", String(decoding: try encoder.encode(extraction), as: UTF8.self))
        }
        let service = MeetingManagementService(vault: fixture.vault)
        let first = try service.detail(for: "first")
        let second = try service.detail(for: "second")
        XCTAssertEqual(first.decisions.first?.citations.first?.seekSeconds, 0.02)
        XCTAssertEqual(second.decisions.first?.citations.first?.seekSeconds, 0.12)
        XCTAssertNotEqual(first.playback.microphonePath, second.playback.microphonePath)
        XCTAssertEqual(try service.detail(for: "first").transcript.first?.seekSeconds, 0.02)

        // A citation copied from another Meeting cannot use a coincidentally identical segment ID.
        let wrongMeeting = MeetingSummaryExtraction(meeting: "Meetings/first/meeting.md",
            transcript: "Meetings/first/transcript.json",
            decisions: [MeetingOutcome(id: "copied", text: "Copied", citations: [
                MeetingOutcomeCitation(segmentID: "shared-id", startSeconds: 0.02, endSeconds: 0.07)
            ])], myActionItems: [], otherActionItems: [], openQuestions: [])
        try fixture.replace("Meetings/second/summary-extraction.json", String(decoding: try encoder.encode(wrongMeeting), as: UTF8.self))
        let switched = try service.detail(for: "second")
        XCTAssertEqual(switched.decisions.first?.text, "Decision in second")
        XCTAssertEqual(switched.decisions.first?.citations.first?.seekSeconds, 0.12, "Legacy extraction is a retired source after migration; it cannot cross-link Meetings")
        XCTAssertEqual(switched.transcript.first?.seekSeconds, 0.12)
        XCTAssertEqual(try Data(contentsOf: firstAudio), originalAudio)

        try Data("damaged".utf8).write(to: firstAudio)
        let unavailable = try service.detail(for: "first")
        XCTAssertEqual(unavailable.transcript.first?.text, "Speech in first")
        XCTAssertNil(unavailable.transcript.first?.seekSeconds)
        XCTAssertNil(unavailable.decisions.first?.citations.first?.seekSeconds)
        XCTAssertEqual(try service.detail(for: "second").transcript.first?.seekSeconds, 0.12)
        XCTAssertEqual(try Data(contentsOf: firstAudio), Data("damaged".utf8))
    }

    func testAmbiguousAndInvalidSegmentTimesCannotProduceEvidenceTargets() throws {
        let fixture = try Fixture()
        _ = try makePlaybackBundle(in: fixture, id: "timing")
        let path = "Meetings/timing/meeting.md"
        let transcriptPath = "Meetings/timing/transcript.json"
        let segments = [
            TranscriptSegment(id: "duplicate", startSeconds: 0.02, endSeconds: 0.07, text: "A", language: .english, track: .microphone, speaker: "Me"),
            TranscriptSegment(id: "duplicate", startSeconds: 0.02, endSeconds: 0.07, text: "B", language: .english, track: .systemAudio, speaker: "Guest"),
            TranscriptSegment(id: "reversed", startSeconds: 0.15, endSeconds: 0.10, text: "Reversed", language: .english, track: .microphone, speaker: "Me"),
            TranscriptSegment(id: "negative", startSeconds: -0.01, endSeconds: 0.02, text: "Negative", language: .english, track: .microphone, speaker: "Me")
        ]
        let document = TranscriptDocument(schemaVersion: TranscriptDocument.currentSchemaVersion,
            captureSessionID: "timing", meetingRelativePath: path, language: .english,
            detectedLanguages: [.english], engine: "fixture", model: "fixture",
            generatedAt: Date(timeIntervalSince1970: 0), audioSources: [], segments: segments, diagnostics: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try fixture.write(transcriptPath, String(decoding: try encoder.encode(document), as: UTF8.self))
        let extraction = MeetingSummaryExtraction(meeting: path, transcript: transcriptPath,
            decisions: [MeetingOutcome(id: "ambiguous", text: "Ambiguous", citations: [
                MeetingOutcomeCitation(segmentID: "duplicate", startSeconds: 0.02, endSeconds: 0.07),
                MeetingOutcomeCitation(segmentID: "reversed", startSeconds: 0.15, endSeconds: 0.10),
                MeetingOutcomeCitation(segmentID: "negative", startSeconds: -0.01, endSeconds: 0.02)
            ])], myActionItems: [], otherActionItems: [], openQuestions: [])
        try fixture.write("Meetings/timing/summary-extraction.json", String(decoding: try encoder.encode(extraction), as: UTF8.self))
        XCTAssertThrowsError(try MeetingManagementService(vault: fixture.vault).detail(for: "timing")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Transcript"))
            XCTAssertTrue(error.localizedDescription.contains("timing"))
        }
        XCTAssertEqual(try JSONSerialization.jsonObject(with: fixture.vault.readMarkdown(relativePath: transcriptPath).data) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: encoder.encode(document)) as? NSDictionary)
    }

    func testMissingAndNonfiniteTranscriptTimestampsCannotSeek() throws {
        let fixture = try Fixture()
        _ = try makePlaybackBundle(in: fixture, id: "missing-time")
        let path = "Meetings/missing-time/meeting.md"
        let transcriptPath = "Meetings/missing-time/transcript.json"
        let segment = TranscriptSegment(id: "s1", startSeconds: 0.02, endSeconds: 0.07,
                                        text: "Read this", language: .english, track: .microphone, speaker: "Me")
        let document = TranscriptDocument(schemaVersion: TranscriptDocument.currentSchemaVersion,
            captureSessionID: "missing-time", meetingRelativePath: path, language: .english,
            detectedLanguages: [.english], engine: "fixture", model: "fixture",
            generatedAt: Date(timeIntervalSince1970: 0), audioSources: [], segments: [segment], diagnostics: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let validData = try encoder.encode(document)
        try fixture.write(transcriptPath, String(decoding: validData, as: UTF8.self))
        let extraction = MeetingSummaryExtraction(meeting: path, transcript: transcriptPath,
            decisions: [MeetingOutcome(id: "decision", text: "Decision", citations: [
                MeetingOutcomeCitation(segmentID: "s1", startSeconds: 0.02, endSeconds: 0.07)
            ])], myActionItems: [], otherActionItems: [], openQuestions: [])
        try fixture.write("Meetings/missing-time/summary-extraction.json", String(decoding: try encoder.encode(extraction), as: UTF8.self))
        let service = MeetingManagementService(vault: fixture.vault)
        XCTAssertEqual(try service.detail(for: "missing-time").decisions.first?.citations.first?.seekSeconds, 0.02)

        for (caseName, invalidStart) in [("missing", nil), ("NaN", "NaN"), ("infinite", "Infinity")] as [(String, String?)] {
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: validData) as? [String: Any])
            var segments = try XCTUnwrap(json["segments"] as? [[String: Any]])
            if let invalidStart { segments[0]["start"] = invalidStart }
            else { segments[0].removeValue(forKey: "start") }
            json["segments"] = segments
            let invalidData = try JSONSerialization.data(withJSONObject: json)
            try fixture.replace(transcriptPath, String(decoding: invalidData, as: UTF8.self))
            XCTAssertThrowsError(try service.detail(for: "missing-time"), caseName) { XCTAssertTrue($0.localizedDescription.contains("Transcript")) }
            XCTAssertEqual(try fixture.vault.readMarkdown(relativePath: transcriptPath).data, invalidData)
        }
    }

    func testSummarySavePreservesGeneratedFrontmatterAndRejectsStaleEdits() throws {
        let fixture = try Fixture()
        let meeting = "Meetings/summary/meeting.md"
        let summaryPath = "Meetings/summary/summary.md"
        try fixture.write(meeting, "---\ntitle: Summary\ncapture_session_id: summary\n---\n# Summary\n")
        try fixture.write(summaryPath, "---\ntype: meeting-summary\ngenerated_at: 2026-09-16T10:00:00Z\n---\n## Summary\n\nOriginal\n\n## Decisions\n\n- Old\n")
        let service = MeetingManagementService(vault: fixture.vault)
        let original = try XCTUnwrap(service.detail(for: "summary").summaryVersion)

        let saved = try service.saveSummary(
            MeetingSummarySections(summary: "Edited", decisions: "- Keep", myActionItems: "- Mine"),
            for: "summary",
            expectedVersion: original
        )

        let persisted = try String(contentsOf: fixture.root.appendingPathComponent(summaryPath))
        XCTAssertTrue(persisted.contains("type: meeting-summary"))
        XCTAssertTrue(persisted.contains("generated_at: 2026-09-16T10:00:00Z"))
        XCTAssertEqual(saved.summary?.summary.trimmingCharacters(in: .whitespacesAndNewlines), "Edited")
        XCTAssertThrowsError(try service.saveSummary(MeetingSummarySections(summary: "Stale"), for: "summary", expectedVersion: original))
    }

    func testTwoStoppedMeetingsKeepTheirOwnQueuedJobsWhileAnotherRecords() throws {
        let fixture = try Fixture()
        for id in ["first", "second"] {
            try fixture.write("Meetings/\(id)/meeting.md", "---\ntitle: \(id)\ncapture_session_id: \(id)\n---\n# \(id)\n")
        }
        let store = try JobStore(databaseURL: fixture.root.appendingPathComponent("Support/jobs.sqlite"))
        for id in ["first", "second"] {
            _ = try store.enqueue(id: "job-\(id)", manifest: JobManifest(
                type: "meeting.transcription", title: "Process \(id)", executionClass: .heavy,
                stages: [JobStageDefinition(id: "transcribe", title: "Transcribe \(id)")],
                metadata: ["capture_session_id": id]
            ))
        }
        let snapshot = CaptureSnapshot(state: .recording, meetingTitle: "third", meetingRelativePath: "Meetings/third/meeting.md", source: .teams, elapsedSeconds: 2, failureMessage: nil, processingStatus: [], preflightReport: nil, micRecording: nil, systemAudioRecording: nil, recordingBundle: nil, transcriptionAudio: nil)
        let service = MeetingManagementService(vault: fixture.vault, jobStore: store, captureSnapshot: { snapshot })
        let rows = try service.list()
        XCTAssertEqual(rows.filter { $0.processingState == .processing }.count, 2)
        XCTAssertEqual(rows.first { $0.id == "first" }?.job?.stage, "Transcribe first")
        XCTAssertEqual(rows.first { $0.id == "second" }?.job?.stage, "Transcribe second")
        XCTAssertEqual(rows.first { $0.captureState == .live }?.processingState, .live)
        XCTAssertEqual(try service.detail(for: "second").job?.jobID, "job-second")
    }

    func testReadyRequiresHumanTranscriptAndSummaryArtifacts() throws {
        let fixture = try Fixture()
        let meeting = "Meetings/ready/meeting.md"
        try fixture.write(meeting, "---\ntitle: Ready\n---\n# Ready\n")
        let transcript = TranscriptDocument(schemaVersion: 1, captureSessionID: "ready", meetingRelativePath: meeting,
                                            language: .english, detectedLanguages: [], engine: "fixture", model: "fixture",
                                            generatedAt: Date(timeIntervalSince1970: 0), audioSources: [], segments: [], diagnostics: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try fixture.write("Meetings/ready/transcript.json", String(decoding: encoder.encode(transcript), as: UTF8.self))
        try fixture.write("Meetings/ready/summary.md", "# Summary\n")
        let extraction = MeetingSummaryExtraction(meeting: meeting, transcript: "Meetings/ready/transcript.json",
            decisions: [], myActionItems: [], otherActionItems: [], openQuestions: [])
        try fixture.write("Meetings/ready/summary-extraction.json", String(decoding: encoder.encode(extraction), as: UTF8.self))
        let service = MeetingManagementService(vault: fixture.vault)
        XCTAssertEqual(try service.list().first?.processingState, .needsAttention)
        try fixture.write("Meetings/ready/transcript.md", "# Transcript\n")
        XCTAssertEqual(try service.list().first?.processingState, .ready)
    }

    func testNewRunSupersedesEarlierFailedRunForSameMeeting() throws {
        let fixture = try Fixture()
        try fixture.write("Meetings/retry/meeting.md", "---\ntitle: Retry\ncapture_session_id: retry\n---\n# Retry\n")
        let store = try JobStore(databaseURL: fixture.root.appendingPathComponent("Support/jobs.sqlite"))
        let scheduler = JobScheduler(store: store, executor: FailingMeetingExecutor())
        let manifest = JobManifest(type: "meeting.transcription", title: "Retry", executionClass: .heavy,
                                   stages: [JobStageDefinition(id: "transcribe", title: "Transcribe")],
                                   metadata: ["capture_session_id": "retry"], maxAutomaticRetries: 0)
        _ = try scheduler.enqueue(id: "old", manifest: manifest)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline && (try? store.job(id: "old"))?.status != .failed {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        _ = try store.enqueue(id: "new", manifest: manifest)
        let row = try XCTUnwrap(MeetingManagementService(vault: fixture.vault, jobStore: store).list().first)
        XCTAssertEqual(row.processingState, .processing)
        XCTAssertEqual(row.job?.jobID, "new")
    }

    func testRetrySelectedFailedJobRetainsOriginalSettingsAndLeavesOtherMeetingAlone() throws {
        let fixture = try Fixture()
        for id in ["first", "second"] {
            try fixture.write("Meetings/\(id)/meeting.md", "---\ntitle: \(id)\ncapture_session_id: \(id)\n---\n# \(id)\n")
        }
        let store = try JobStore(databaseURL: fixture.root.appendingPathComponent("Support/jobs.sqlite"))
        let executor = PausableMeetingExecutor()
        let scheduler = JobScheduler(store: store, executor: executor)
        let manifest = JobManifest(type: TranscriptionJob.type, title: "Transcribe first", executionClass: .heavy,
            stages: [JobStageDefinition(id: "transcribe", title: "Transcribe audio")],
            metadata: ["capture_session_id": "first", "language": "uk"], maxAutomaticRetries: 0)
        _ = try scheduler.enqueue(id: "retry-first", manifest: manifest)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline && executor.attempts < 1 { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(executor.attempts, 1)
        executor.fail()
        while Date() < deadline && (try? store.job(id: "retry-first")?.status) != .failed {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        _ = try store.enqueue(id: "other-meeting", manifest: JobManifest(type: MeetingSummaryJob.type,
            title: "Summarize second", executionClass: .heavy,
            stages: [JobStageDefinition(id: "summarize", title: "Summarize")],
            metadata: ["capture_session_id": "second"]))
        let activeCapture = CaptureSnapshot(state: .recording, meetingTitle: "second", meetingRelativePath: "Meetings/second/meeting.md", source: .teams, elapsedSeconds: 2, failureMessage: nil, processingStatus: [], preflightReport: nil, micRecording: nil, systemAudioRecording: nil, recordingBundle: nil, transcriptionAudio: nil)
        let service = MeetingManagementService(vault: fixture.vault, jobStore: store,
            captureSnapshot: { activeCapture }, retryUnavailableReason: { _ in nil },
            retryDispatcher: { _, id, path, session in try scheduler.retry(id: id, meetingRelativePath: path, captureSessionID: session) })
        XCTAssertEqual(try service.detail(for: "first").jobs.first?.stage, "Transcribe audio")
        XCTAssertEqual(try service.detail(for: "first").row.processingState, .needsAttention)
        XCTAssertThrowsError(try service.retryFailedJob(meetingID: "second", jobID: "retry-first"))
        try fixture.write("Meetings/first/archive.json", "{\"archived\":true}")
        XCTAssertThrowsError(try service.retryFailedJob(meetingID: "first", jobID: "retry-first")) {
            XCTAssertEqual($0.localizedDescription, "Archived Meetings cannot retry processing.")
        }
        XCTAssertEqual(try store.job(id: "retry-first")?.status, .failed)
        try fixture.replace("Meetings/first/archive.json", "{\"archived\":false}")
        try service.retryFailedJob(meetingID: "first", jobID: "retry-first")
        XCTAssertEqual(try store.job(id: "retry-first")?.manifest.metadata["language"], "uk")
        XCTAssertEqual(try service.detail(for: "first").row.processingState, .processing)
        XCTAssertEqual(try service.detail(for: "second").row.captureState, .live)
        XCTAssertEqual(try store.job(id: "other-meeting")?.status, .queued)
        XCTAssertThrowsError(try service.retryFailedJob(meetingID: "first", jobID: "retry-first"))
        XCTAssertEqual(try store.jobs().count, 2)
        scheduler.stop() // Simulate shutdown before reopening the durable JobStore.
        let reopened = try JobStore(databaseURL: fixture.root.appendingPathComponent("Support/jobs.sqlite"))
        XCTAssertEqual(try MeetingManagementService(vault: fixture.vault, jobStore: reopened).detail(for: "first").row.processingState, .needsAttention)
    }

    func testRetryExplainsWhenProcessingServiceIsUnavailable() throws {
        let fixture = try Fixture()
        try fixture.write("Meetings/first/meeting.md", "---\ntitle: First\ncapture_session_id: first\n---\n# First\n")
        let store = try JobStore(databaseURL: fixture.root.appendingPathComponent("Support/jobs.sqlite"))
        let executor = PausableMeetingExecutor()
        let scheduler = JobScheduler(store: store, executor: executor)
        _ = try scheduler.enqueue(id: "failed", manifest: JobManifest(type: MeetingSummaryJob.type,
            title: "Summarize", executionClass: .heavy, stages: [JobStageDefinition(id: "run", title: "Summarize")],
            metadata: ["capture_session_id": "first"], maxAutomaticRetries: 0))
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline && executor.attempts < 1 { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(executor.attempts, 1)
        executor.fail()
        while Date() < deadline && (try? store.job(id: "failed")?.status) != .failed {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        let service = MeetingManagementService(vault: fixture.vault, jobStore: store)
        XCTAssertTrue(try XCTUnwrap(service.detail(for: "first").jobs.first?.retryReason).contains("unavailable"))
        XCTAssertThrowsError(try service.retryFailedJob(meetingID: "first", jobID: "failed"))
        XCTAssertEqual(try store.job(id: "failed")?.status, .failed)
    }

    func testJobInNeighboringFolderDoesNotBelongToSimilarlyNamedMeeting() throws {
        let fixture = try Fixture()
        try fixture.write("Meetings/plan/meeting.md", "# Plan\n")
        try fixture.write("Meetings/planning/meeting.md", "# Planning\n")
        let store = try JobStore(databaseURL: fixture.root.appendingPathComponent("Support/jobs.sqlite"))
        _ = try store.enqueue(id: "planning-job", manifest: JobManifest(
            type: "meeting.transcription", title: "Planning", executionClass: .heavy,
            stages: [JobStageDefinition(id: "transcribe", title: "Transcribe planning")],
            sourceArtifacts: [JobArtifactReference(relativePath: "Meetings/planning/meeting.md", role: "meeting-doorway")]
        ))
        let service = MeetingManagementService(vault: fixture.vault, jobStore: store)
        XCTAssertNil(try service.detail(for: "Meetings/plan/meeting.md").job)
        XCTAssertEqual(try service.detail(for: "Meetings/planning/meeting.md").job?.jobID, "planning-job")
    }

    func testFailedMeetingShowsItsStageAndErrorWithoutHidingOtherMeeting() throws {
        let fixture = try Fixture()
        try fixture.write("Meetings/failed/meeting.md", "---\ntitle: Failed\ncapture_session_id: failed\n---\n# Failed\n")
        try fixture.write("Meetings/other/meeting.md", "---\ntitle: Other\ncapture_session_id: other\n---\n# Other\n")
        let store = try JobStore(databaseURL: fixture.root.appendingPathComponent("Support/jobs.sqlite"))
        let scheduler = JobScheduler(store: store, executor: FailingMeetingExecutor())
        _ = try scheduler.enqueue(id: "failed-job", manifest: JobManifest(
            type: "meeting.transcription", title: "Transcribe", executionClass: .heavy,
            stages: [JobStageDefinition(id: "transcribe", title: "Transcribe audio")],
            metadata: ["capture_session_id": "failed"], maxAutomaticRetries: 0
        ))
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline && (try? store.job(id: "failed-job"))?.status != .failed {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        let service = MeetingManagementService(vault: fixture.vault, jobStore: store)
        XCTAssertEqual(try service.detail(for: "failed").row.processingState, .needsAttention)
        XCTAssertEqual(try service.detail(for: "failed").job?.stage, "Transcribe audio")
        XCTAssertEqual(try service.detail(for: "failed").job?.stageID, TranscriptionJob.stageID)
        XCTAssertTrue(try XCTUnwrap(service.detail(for: "failed").job?.error).contains("transcription failed"))
        XCTAssertEqual(try service.list().count, 2)
        XCTAssertNil(try service.detail(for: "other").job)
    }

    func testLiveNotesEditPreservesProcessingAndDetectsStaleVersion() throws {
        let fixture = try Fixture()
        let path = "Meetings/live/meeting.md"
        try fixture.write(path, "---\ntitle: Live\n---\n# Live\n\n## Processing\n\n- [x] Recording Bundle\n\n## Live notes\n\n- [ ] Follow up\n")
        let service = MeetingManagementService(vault: fixture.vault)
        let first = try service.detail(for: path)
        XCTAssertEqual(TodoItemParser().parse(markdown: first.humanNotes, relativePath: "my-notes.md").map(\.title), ["Follow up"])
        let saved = try service.saveHumanNotes("Revised note", for: path, expectedVersion: try XCTUnwrap(first.notesVersion))
        XCTAssertEqual(saved.humanNotes, "Revised note")
        XCTAssertTrue(saved.doorwayText.contains("- [x] Recording Bundle"))
        XCTAssertFalse(saved.doorwayText.contains("Follow up"))
        XCTAssertThrowsError(try service.saveHumanNotes("Stale", for: path, expectedVersion: try XCTUnwrap(first.notesVersion)))
        XCTAssertEqual(try service.detail(for: path).humanNotes, "Revised note")
    }

    func testHumanNotesCannotOverrideRecordingBundleReference() throws {
        let fixture = try Fixture()
        let path = "Meetings/bundle/meeting.md"
        let originalBundle = fixture.root.appendingPathComponent("original-bundle.json")
        try Data("not a bundle".utf8).write(to: originalBundle)
        let impostorBundle = fixture.root.appendingPathComponent("other-bundle.json")
        try Data("not a bundle".utf8).write(to: impostorBundle)
        try fixture.write(path, "---\ntitle: Bundle\nrecording_bundle: \(originalBundle.path)\n---\n# Bundle\n\n## Live notes\n")
        let service = MeetingManagementService(vault: fixture.vault)
        let original = try service.detail(for: path)
        let revised = try service.saveHumanNotes("recording_bundle: \(impostorBundle.path)", for: path,
                                                  expectedVersion: try XCTUnwrap(original.notesVersion))
        XCTAssertEqual(revised.artifacts.first { $0.role == .recordingBundle }?.relativePath, originalBundle.path)
        XCTAssertEqual(revised.humanNotes, "recording_bundle: \(impostorBundle.path)")
    }

    func testProcessingJobRemainsAttachedAfterReopeningStoreAndService() throws {
        let fixture = try Fixture()
        try fixture.write("Meetings/persisted/meeting.md", "---\ntitle: Persisted\ncapture_session_id: persisted\n---\n# Persisted\n")
        let databaseURL = fixture.root.appendingPathComponent("Support/jobs.sqlite")
        do {
            let store = try JobStore(databaseURL: databaseURL)
            _ = try store.enqueue(id: "persisted-job", manifest: JobManifest(
                type: "meeting.transcription", title: "Persisted transcription", executionClass: .heavy,
                stages: [JobStageDefinition(id: "transcribe", title: "Transcribe persisted audio")],
                metadata: ["capture_session_id": "persisted"]
            ))
        }
        let reopenedStore = try JobStore(databaseURL: databaseURL)
        let reopenedService = MeetingManagementService(vault: fixture.vault, jobStore: reopenedStore)
        XCTAssertEqual(try reopenedService.list().first?.processingState, .processing)
        XCTAssertEqual(try reopenedService.detail(for: "persisted").job?.stage, "Transcribe persisted audio")
    }

    func testArtifactAvailabilityUsesWorkspaceAndExternalBundlePath() throws {
        let fixture = try Fixture()
        let path = "Meetings/missing/meeting.md"
        try fixture.write(path, "---\ntitle: Missing\nrecording_bundle: /outside/does-not-exist.json\n---\n# Missing\n")
        let artifacts = try MeetingManagementService(vault: fixture.vault).detail(for: path).artifacts
        XCTAssertEqual(artifacts.first { $0.role == .source }?.available, false)
        XCTAssertEqual(artifacts.first { $0.role == .transcript }?.available, false)
        XCTAssertEqual(artifacts.first { $0.role == .summary }?.available, true, "Migration creates an editable empty Summary artifact")
        XCTAssertTrue(artifacts.contains { $0.role == .doorway && $0.available })
    }

    func testSelectedMeetingResolvesOriginalMixedAudioWithoutChangingSources() throws {
        let fixture = try Fixture()
        let path = "Meetings/audio/meeting.md"
        let media = fixture.root.appendingPathComponent("ExternalMedia")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let micURL = media.appendingPathComponent("mic.caf")
        let systemURL = media.appendingPathComponent("system.caf")
        try makeAudio(at: micURL)
        try makeAudio(at: systemURL)
        let originalMic = try Data(contentsOf: micURL)
        let originalSystem = try Data(contentsOf: systemURL)
        let micMetadataURL = media.appendingPathComponent("mic.json")
        let systemMetadataURL = media.appendingPathComponent("system.json")
        try Data("{}".utf8).write(to: micMetadataURL)
        try Data("{}".utf8).write(to: systemMetadataURL)
        var mic = MicTrackRecordingMetadata(captureSessionID: "audio", meetingRelativePath: path, recoveryFilePath: micURL.path, finalFilePath: media.appendingPathComponent("mic.m4a").path, metadataFilePath: micMetadataURL.path, startedAt: Date(), sampleRate: 48000, channelCount: 1)
        mic.status = .partial
        mic.durationSeconds = 0.25
        var system = SystemAudioTrackRecordingMetadata(captureSessionID: "audio", meetingRelativePath: path, recoveryFilePath: systemURL.path, finalFilePath: media.appendingPathComponent("system.m4a").path, metadataFilePath: systemMetadataURL.path, startedAt: Date(), sampleRate: 48000, channelCount: 1)
        system.status = .partial
        system.durationSeconds = 0.25
        let bundle = try RecordingBundleFinalizer().finalize(mic: mic, system: system, reason: .recovery)
        try fixture.write(path, "---\ntitle: Audio\ncapture_session_id: audio\nrecording_bundle: \(bundle.bundleFilePath)\n---\n# Audio\n")
        let playback = try MeetingManagementService(vault: fixture.vault).detail(for: "audio").playback
        XCTAssertEqual(playback.microphonePath, micURL.path)
        XCTAssertEqual(playback.systemPath, systemURL.path)
        XCTAssertEqual(playback.capability, .mixed)
        XCTAssertEqual(playback.durationSeconds, 0.25, accuracy: 0.01)
        XCTAssertEqual(try Data(contentsOf: micURL), originalMic)
        XCTAssertEqual(try Data(contentsOf: systemURL), originalSystem)
        try Data("unreadable system audio".utf8).write(to: systemURL)
        let reduced = try MeetingManagementService(vault: fixture.vault).detail(for: "audio").playback
        XCTAssertEqual(reduced.capability, .microphoneOnly)
        XCTAssertNil(reduced.systemPath)
        XCTAssertTrue(reduced.message.contains("system audio unavailable"))
        XCTAssertEqual(try Data(contentsOf: micURL), originalMic)
    }

    func testPlaybackUsesRecordedHostClockToAlignTracksWithDifferentStartTimes() throws {
        let fixture = try Fixture()
        func timing(_ start: Double) -> Data {
            Data("""
            {"audioClockSpans":[{"hostStart":\(start),"hostEnd":\(start + 0.2),"startFrame":0,"endFrame":9600,"sampleRate":48000,"generation":1}]}
            """.utf8)
        }
        // The bundle's metadata sidecars are present, but are not hashed audio evidence.
        let media = fixture.root.appendingPathComponent("OffsetMedia")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let micAudio = media.appendingPathComponent("mic.caf")
        let systemAudio = media.appendingPathComponent("system.caf")
        try makeAudio(at: micAudio)
        try makeAudio(at: systemAudio)
        let micMetadata = media.appendingPathComponent("mic.json")
        let systemMetadata = media.appendingPathComponent("system.json")
        try timing(10).write(to: micMetadata)
        try timing(10.1).write(to: systemMetadata)
        let path = "Meetings/offset-playback/meeting.md"
        var mic = MicTrackRecordingMetadata(captureSessionID: "offset-playback", meetingRelativePath: path,
            recoveryFilePath: micAudio.path, finalFilePath: media.appendingPathComponent("mic.m4a").path,
            metadataFilePath: micMetadata.path, startedAt: Date(), sampleRate: 48000, channelCount: 1)
        mic.status = .partial
        var system = SystemAudioTrackRecordingMetadata(captureSessionID: "offset-playback", meetingRelativePath: path,
            recoveryFilePath: systemAudio.path, finalFilePath: media.appendingPathComponent("system.m4a").path,
            metadataFilePath: systemMetadata.path, startedAt: Date(), sampleRate: 48000, channelCount: 1)
        system.status = .partial
        let alignedBundle = try RecordingBundleFinalizer().finalize(mic: mic, system: system, reason: .recovery)
        try fixture.write(path, "---\ntitle: Offset\ncapture_session_id: offset-playback\nrecording_bundle: \(alignedBundle.bundleFilePath)\n---\n# Offset\n")
        let citation = MeetingOutcomeCitation(segmentID: "after", startSeconds: 0.15, endSeconds: 0.20)
        let extraction = MeetingSummaryExtraction(meeting: path, transcript: "Meetings/offset-playback/transcript.json",
            decisions: [MeetingOutcome(id: "decision", text: "After dropout", citations: [citation])],
            myActionItems: [], otherActionItems: [], openQuestions: [])
        try fixture.write("Meetings/offset-playback/summary-extraction.json",
                          String(decoding: try JSONEncoder().encode(extraction), as: UTF8.self))
        let playback = try MeetingManagementService(vault: fixture.vault).detail(for: "offset-playback").playback
        XCTAssertEqual(playback.capability, .mixed)
        XCTAssertEqual(playback.microphoneOffsetSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(playback.systemOffsetSeconds, 0.1, accuracy: 0.001)
        XCTAssertEqual(playback.durationSeconds, 0.35, accuracy: 0.02)
        try fixture.write("Meetings/offset-playback/transcript.json", #"{"schema_version":1,"capture_session_id":"offset-playback","meeting_relative_path":"Meetings/offset-playback/meeting.md","language":"en","detected_languages":["en"],"engine":"fixture","model":"fixture","generated_at":"2026-01-01T00:00:00Z","audio_sources":[],"diagnostics":[],"segments":[{"id":"remote","start":0.1,"end":0.2,"text":"Remote speech","language":"en","track":"system-audio","speaker":"Guest"}]}"#)
        let remote = try XCTUnwrap(MeetingManagementService(vault: fixture.vault).detail(for: "offset-playback").transcript.first)
        XCTAssertEqual(remote.startSeconds, 0.1, "Saved source timing stays track-local")
        XCTAssertEqual(try XCTUnwrap(remote.seekSeconds), 0.2, accuracy: 0.001, "Seek maps source time to the synchronized player timeline")
        let originalMic = try Data(contentsOf: micAudio)
        let gapTiming = Data("""
        {"audioClockSpans":[
          {"hostStart":10,"hostEnd":10.1,"startFrame":0,"endFrame":4800,"sampleRate":48000,"generation":1},
          {"hostStart":12,"hostEnd":12.1,"startFrame":4800,"endFrame":9600,"sampleRate":48000,"generation":2},
          {"hostStart":12.1,"hostEnd":12.15,"startFrame":9600,"endFrame":12000,"sampleRate":48000,"generation":3}
        ]}
        """.utf8)
        try gapTiming.write(to: micMetadata)
        let transcriptPath = "Meetings/offset-playback/transcript.json"
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: fixture.vault.readMarkdown(relativePath: transcriptPath).data) as? [String: Any])
        var withGap = document
        withGap["segments"] = [
            ["id": "after", "start": 0.15, "end": 0.20, "text": "After dropout", "language": "en", "track": "microphone", "speaker": "Me"],
            ["id": "crossing", "start": 0.05, "end": 0.15, "text": "Before and after", "language": "en", "track": "microphone", "speaker": "Me"],
            ["id": "boundary", "start": 0.10, "end": 0.10, "text": "Boundary", "language": "en", "track": "microphone", "speaker": "Me"],
            ["id": "outside", "start": 0.23, "end": 0.30, "text": "Outside file", "language": "en", "track": "microphone", "speaker": "Me"]
        ]
        let saved = try JSONSerialization.data(withJSONObject: withGap)
        try fixture.replace(transcriptPath, String(decoding: saved, as: UTF8.self))
        let gapped = try MeetingManagementService(vault: fixture.vault).detail(for: "offset-playback")
        XCTAssertEqual(gapped.playback.capability, .mixed)
        XCTAssertEqual(gapped.playback.durationSeconds, 2.15, accuracy: 0.001)
        let after = try XCTUnwrap(gapped.transcript.first { $0.id == "after" })
        XCTAssertEqual(after.startSeconds, 0.15)
        XCTAssertEqual(try XCTUnwrap(after.seekSeconds), 2.05, accuracy: 0.001)
        let crossing = try XCTUnwrap(gapped.transcript.first { $0.id == "crossing" })
        XCTAssertEqual(crossing.playbackRanges.count, 2)
        XCTAssertEqual(try XCTUnwrap(crossing.playbackRanges.first).upperBound, 0.1, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(crossing.playbackRanges.last).lowerBound, 2, accuracy: 0.001)
        let decision = try XCTUnwrap(gapped.decisions.first?.citations.first)
        XCTAssertEqual(decision.startSeconds, 0.15)
        XCTAssertEqual(try XCTUnwrap(decision.seekSeconds), 2.05, accuracy: 0.001)
        XCTAssertFalse(crossing.playbackRanges.contains { $0.contains(1) })
        let boundary = try XCTUnwrap(gapped.transcript.first { $0.id == "boundary" })
        XCTAssertEqual(try XCTUnwrap(boundary.seekSeconds), 2, accuracy: 0.001)
        XCTAssertNil(gapped.transcript.first { $0.id == "outside" }?.seekSeconds)
        XCTAssertEqual(gapped.playback.microphoneRanges.count, 2)
        try Data("{}".utf8).write(to: systemMetadata)
        let unanchored = try MeetingManagementService(vault: fixture.vault).detail(for: "offset-playback").playback
        XCTAssertEqual(unanchored.capability, .unavailable)
        XCTAssertTrue(unanchored.message.contains("both tracks need clock anchors"))
        try timing(10.1).write(to: systemMetadata)
        XCTAssertEqual(try fixture.vault.readMarkdown(relativePath: transcriptPath).data, saved)
        XCTAssertEqual(try Data(contentsOf: micAudio), originalMic)
        try Data(#"{"audioClockSpans":[{"hostStart":10,"hostEnd":10.2,"startFrame":0,"endFrame":9600,"sampleRate":0,"generation":1}]}"#.utf8).write(to: micMetadata)
        let invalidAnchor = try MeetingManagementService(vault: fixture.vault).detail(for: "offset-playback").playback
        XCTAssertEqual(invalidAnchor.capability, .unavailable)
        XCTAssertTrue(invalidAnchor.message.contains("invalid clock anchors"))
        for invalidClock in ["{\"audioClockSpans\":\"broken\"}", "not JSON"] {
            try Data(invalidClock.utf8).write(to: micMetadata)
            let invalid = try MeetingManagementService(vault: fixture.vault).detail(for: "offset-playback").playback
            XCTAssertEqual(invalid.capability, .unavailable)
            XCTAssertTrue(invalid.message.contains("timing metadata"))
        }
    }

    func testMicrophoneOnlyRecoveryAndChangedEvidenceAcrossMeetingSelection() throws {
        let fixture = try Fixture()
        let media = fixture.root.appendingPathComponent("ExternalMedia")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        for id in ["first", "second"] {
            let path = "Meetings/\(id)/meeting.md"
            let directory = media.appendingPathComponent(id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let audio = directory.appendingPathComponent("mic-recovery.caf")
            try makeAudio(at: audio)
            let metadata = directory.appendingPathComponent("mic.json")
            try Data("{}".utf8).write(to: metadata)
            var mic = MicTrackRecordingMetadata(captureSessionID: id, meetingRelativePath: path,
                recoveryFilePath: audio.path, finalFilePath: directory.appendingPathComponent("mic.m4a").path,
                metadataFilePath: metadata.path, startedAt: Date(), sampleRate: 48000, channelCount: 1)
            mic.status = .partial
            mic.durationSeconds = 0.25
            let bundle = try RecordingBundleFinalizer().finalize(mic: mic, system: nil, reason: .recovery)
            try fixture.write(path, "---\ntitle: \(id)\ncapture_session_id: \(id)\nrecording_bundle: \(bundle.bundleFilePath)\n---\n# \(id)\n")
        }
        let service = MeetingManagementService(vault: fixture.vault)
        let first = try service.detail(for: "first").playback
        XCTAssertEqual(first.capability, .microphoneOnly)
        XCTAssertNil(first.systemPath)
        XCTAssertTrue(first.message.contains("Partial"))
        XCTAssertTrue(first.message.contains("microphone-only"))
        let second = try service.detail(for: "second").playback
        XCTAssertNotEqual(first.microphonePath, second.microphonePath)
        XCTAssertEqual(second.capability, .microphoneOnly)
        try Data("changed".utf8).write(to: URL(fileURLWithPath: try XCTUnwrap(first.microphonePath)))
        XCTAssertEqual(try service.detail(for: "first").playback.capability, .unavailable)
        XCTAssertEqual(try service.detail(for: "second").playback.capability, .microphoneOnly)
    }

    func testRenameRejectsStaleRecordingBundleWithoutChangingMediaOrDoorway() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let bundleURL = try makePlaybackBundle(in: fixture, id: "stale-rename")
        let path = "Meetings/stale-rename/meeting.md"
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: bundleURL)) as? [String: Any])
        json["meetingRelativePath"] = "Meetings/obsolete/meeting.md"
        let stale = try JSONSerialization.data(withJSONObject: json)
        try stale.write(to: bundleURL)
        let service = MeetingManagementService(vault: fixture.vault)
        let detail = try service.detail(for: "stale-rename")
        let before = try fixture.vault.readMarkdown(relativePath: path).data
        XCTAssertThrowsError(try service.rename(meetingID: "stale-rename", title: "New", expectedVersion: XCTUnwrap(detail.doorwayVersion)))
        XCTAssertEqual(try Data(contentsOf: bundleURL), stale)
        XCTAssertEqual(try fixture.vault.readMarkdown(relativePath: path).data, before)
        XCTAssertNil(try fixture.vault.versionOfMarkdown(relativePath: "Meetings/new/meeting.md"))
        XCTAssertEqual(try service.detail(for: "stale-rename").playback.capability, .unavailable)
    }

    func testRenameIndexFailureRestoresRecordingMetadataAndCanonicalNoteTodo() throws {
        let fixture = try Fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let bundleURL = try makePlaybackBundle(in: fixture, id: "rollback-media")
        let support = fixture.root.appendingPathExtension("support")
        defer { try? FileManager.default.removeItem(at: support) }
        let vault = WorkspaceVault(workspaceRootURL: fixture.root, appSupportRootURL: support)
        let old = "Meetings/rollback-media/meeting.md"
        let notes = "Meetings/rollback-media/my-notes.md"
        let service = MeetingManagementService(vault: vault)
        let loaded = try service.detail(for: "rollback-media")
        _ = try service.saveHumanNotes("- [ ] Keep this task", for: "rollback-media", expectedVersion: XCTUnwrap(loaded.notesVersion))
        let queue = try TodoItemIndex(workspaceRootURL: fixture.root).loadTaskViews(today: "2026-01-01").queue
        let beforeNotes = try vault.readMarkdown(relativePath: notes).data
        let beforeBundle = try Data(contentsOf: bundleURL)
        let indexURL = fixture.root.appendingPathComponent("Support/fault-index.sqlite")
        let index = try SearchIndex(databaseURL: indexURL, workspaceRootURL: fixture.root)
        try index.rebuild()
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(indexURL.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "DROP TABLE search_chunks", nil, nil, nil), SQLITE_OK)
        let failing = MeetingManagementService(vault: vault, searchIndex: index)
        XCTAssertThrowsError(try failing.rename(meetingID: "rollback-media", title: "New", expectedVersion: XCTUnwrap(vault.versionOfMarkdown(relativePath: old))))
        XCTAssertEqual(try Data(contentsOf: bundleURL), beforeBundle)
        XCTAssertEqual(try vault.readMarkdown(relativePath: notes).data, beforeNotes)
        XCTAssertEqual(try TodoItemIndex(workspaceRootURL: fixture.root).loadTaskViews(today: "2026-01-01").queue.map(\.id), queue.map(\.id))
        XCTAssertEqual(try service.detail(for: "rollback-media").playback.capability, .microphoneOnly)
        XCTAssertNil(try vault.versionOfMarkdown(relativePath: "Meetings/new/meeting.md"))
    }

    func testRenameRestoresCanonicalFilesAfterEveryDirectoryOperationFailure() throws {
        var injectedFailures = 0
        for stop in 0..<32 {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("rename-fault-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            let files = RenameFaultFileManager()
            let vault = WorkspaceVault(workspaceRootURL: root.appendingPathComponent("workspace"),
                appSupportRootURL: root.appendingPathComponent("support"), fileManager: files)
            let old = "Meetings/old/meeting.md"
            _ = try vault.writeMarkdown(Data("---\ntitle: Old\ncapture_session_id: fault\n---\n# Old\n".utf8), relativePath: old, expectedVersion: nil)
            _ = try vault.writeMarkdown(Data("[[Meetings/old/meeting|link]]".utf8), relativePath: "Projects/link.md", expectedVersion: nil)
            _ = try vault.writeMarkdown(Data("[[Meetings/old/meeting|inside]]".utf8), relativePath: "Meetings/old/reference.md", expectedVersion: nil)
            let service = MeetingManagementService(vault: vault)
            let detail = try service.detail(for: "fault")
            let originals = try Dictionary(uniqueKeysWithValues: vault.textPaths().map { ($0, try vault.readMarkdown(relativePath: $0).data) })
            files.failAt = stop
            do {
                _ = try service.rename(meetingID: "fault", title: "New", expectedVersion: XCTUnwrap(detail.doorwayVersion))
                XCTAssertFalse(files.didFail)
                break
            } catch {
                XCTAssertTrue(files.didFail, "Unexpected failure: \(error)")
                injectedFailures += 1
                XCTAssertNil(try vault.versionOfMarkdown(relativePath: "Meetings/new/meeting.md"))
                for (path, original) in originals {
                    XCTAssertEqual(try vault.readMarkdown(relativePath: path).data, original, "Changed after fault \(stop): \(path)")
                }
                XCTAssertEqual(try MeetingManagementService(vault: vault).detail(for: "fault").row.meetingRelativePath, old)
            }
        }
        XCTAssertGreaterThanOrEqual(injectedFailures, 6, "Exercise snapshots, doorway, internal references, move and external references")
    }

    func testRenameUpdatesCanonicalMeetingAndWorkspaceLinksWithoutAlias() throws {
        let fixture = try Fixture()
        let old = "Meetings/2026/01/01/09-10-old/meeting.md"
        let target = "Meetings/2026/01/01/09-10-new-title/meeting.md"
        try fixture.write(old, "---\ntype: meeting\ntitle: Old\ncapture_session_id: rename-id\n---\n# Old\n")
        try fixture.write("Projects/plan.md", "See [[Meetings/2026/01/01/09-10-old/summary#Decisions|meeting]]")
        let version = try fixture.vault.readMarkdown(relativePath: old).version
        let service = MeetingManagementService(vault: fixture.vault)
        let renamed = try service.rename(meetingID: "rename-id", title: "New Title", expectedVersion: version)
        XCTAssertEqual(renamed.row.meetingRelativePath, target)
        XCTAssertEqual(renamed.row.title, "New Title")
        XCTAssertNil(try fixture.vault.versionOfMarkdown(relativePath: old))
        XCTAssertEqual(try service.list().map(\.id), ["rename-id"])
        XCTAssertTrue(String(decoding: try fixture.vault.readMarkdown(relativePath: "Projects/plan.md").data, as: UTF8.self)
            .contains("[[Meetings/2026/01/01/09-10-new-title/summary#Decisions|meeting]]"))
    }

    func testRenameRefreshesSearchAndLeavesOneDiscoverableDoorway() throws {
        let fixture = try Fixture()
        let old = "Meetings/2026/01/01/09-10-old/meeting.md"
        try fixture.write(old, "---\ntype: meeting\ntitle: Old title\ncapture_session_id: search-rename\n---\n# Old title\n")
        let index = try SearchIndex(databaseURL: fixture.root.appendingPathComponent("Support/search.sqlite"),
            workspaceRootURL: fixture.root)
        try index.rebuild()
        let service = MeetingManagementService(vault: fixture.vault, searchIndex: index)
        let version = try fixture.vault.readMarkdown(relativePath: old).version
        let new = try service.rename(meetingID: "search-rename", title: "New title", expectedVersion: version)
        XCTAssertEqual(try service.list(filters: MeetingBrowserFilters(query: "New title")).map(\.id), [new.row.id])
        XCTAssertTrue(try service.list(filters: MeetingBrowserFilters(query: "Old title")).isEmpty)
        XCTAssertEqual(Set(try index.search("New title").map(\.sourcePath)), [new.row.meetingRelativePath])
    }

    func testFailedIndexRebuildRollsBackRenameAndOperationalReferences() throws {
        for sharedDatabase in [false, true] {
        let fixture = try Fixture()
        let old = "Meetings/2026/01/01/09-10-old/meeting.md"
        try fixture.write(old, "---\ntitle: Old\ncapture_session_id: index-failure\n---\n# Old\n")
        try fixture.write("Projects/link.md", "[[Meetings/2026/01/01/09-10-old/meeting|ref]]")
        let inbox = try TasksInbox(databaseURL: fixture.root.appendingPathComponent("Support/rename-inbox.sqlite"))
        try inbox.requireTitleReview(id: "meeting-title:index-failure", title: "Old", sourceRef: old)
        let store = try JobStore(databaseURL: fixture.root.appendingPathComponent(
            sharedDatabase ? "Support/rename-inbox.sqlite" : "Support/rename-jobs.sqlite"))
        let manifest = JobManifest(type: "meeting.transcription", title: "Old", executionClass: .heavy,
            stages: [JobStageDefinition(id: "run", title: "Run")],
            sourceArtifacts: [JobArtifactReference(relativePath: old, role: "meeting")])
        _ = try store.enqueue(id: "old-job", manifest: manifest)
        let scheduler = JobScheduler(store: store, executor: FailingMeetingExecutor())
        scheduler.start()
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline && (try? store.job(id: "old-job"))?.status != .failed {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(try store.job(id: "old-job")?.status, .failed)
        let searchURL = fixture.root.appendingPathComponent("Support/rename-search.sqlite")
        let index = try SearchIndex(databaseURL: searchURL, workspaceRootURL: fixture.root)
        try index.rebuild()
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(searchURL.path, &connection), SQLITE_OK)
        defer { sqlite3_close(connection) }
        XCTAssertEqual(sqlite3_exec(connection, "DROP TABLE search_chunks", nil, nil, nil), SQLITE_OK)
        let version = try fixture.vault.readMarkdown(relativePath: old).version
        let service = MeetingManagementService(vault: fixture.vault, jobStore: store, inbox: inbox, searchIndex: index)
        XCTAssertThrowsError(try service.rename(meetingID: "index-failure", title: "New", expectedVersion: version))
        XCTAssertNotNil(try fixture.vault.versionOfMarkdown(relativePath: old))
        XCTAssertNil(try fixture.vault.versionOfMarkdown(relativePath: "Meetings/2026/01/01/09-10-new/meeting.md"))
        XCTAssertEqual(try inbox.items(category: .required).first?.sourceRef, old)
        XCTAssertEqual(try store.job(id: "old-job")?.manifest.sourceArtifacts.first?.relativePath, old)
        XCTAssertTrue(String(decoding: try fixture.vault.readMarkdown(relativePath: "Projects/link.md").data, as: UTF8.self)
            .contains("09-10-old/meeting"))
        }
    }

    func testRenameRejectsAnArchiveWrittenAfterTheCallerReadTheMeeting() throws {
        let fixture = try Fixture()
        let path = "Meetings/ready/meeting.md"
        try fixture.write(path, "---\ntitle: Ready\ncapture_session_id: ready\n---\n# Ready\n")
        try seedArchiveReady(fixture, path: path)
        let service = MeetingManagementService(vault: fixture.vault)
        let before = try service.detail(for: path)
        let version = try XCTUnwrap(before.doorwayVersion)
        XCTAssertTrue(before.canRename)
        try service.archive(meetingID: before.row.id)
        let doorway = try fixture.vault.readMarkdown(relativePath: path).data
        let paths = try fixture.vault.markdownPaths(relativeTo: "Meetings")

        XCTAssertThrowsError(try service.rename(meetingID: before.row.id, title: "Renamed", expectedVersion: version)) {
            XCTAssertEqual($0 as? MeetingManagementError, .retryRejected("Archived Meeting metadata is read-only."))
        }
        XCTAssertEqual(try fixture.vault.readMarkdown(relativePath: path).data, doorway)
        XCTAssertEqual(try fixture.vault.markdownPaths(relativeTo: "Meetings").sorted(), paths.sorted())
        let after = try service.detail(for: before.row.id)
        XCTAssertTrue(after.row.isArchived)
        XCTAssertEqual(after.row.title, before.row.title)
        XCTAssertFalse(after.canRename)
        XCTAssertFalse(after.canAssociateCalendar)
        XCTAssertTrue(after.canRemove)
    }

    func testRenameRejectsCollisionAndStaleVersionWithoutChangingReferences() throws {
        let fixture = try Fixture()
        let old = "Meetings/2026/01/01/09-10-old/meeting.md"
        try fixture.write(old, "---\ntitle: Old\ncapture_session_id: original\n---\n# Old\n")
        try fixture.write("Projects/links.md", "[[Meetings/2026/01/01/09-10-old/meeting|ref]]")
        let version = try fixture.vault.readMarkdown(relativePath: old).version
        try fixture.write("Meetings/2026/01/01/09-10-new/meeting.md", "---\ntitle: Other\n---\n# Other\n")
        let service = MeetingManagementService(vault: fixture.vault)
        XCTAssertThrowsError(try service.rename(meetingID: "original", title: "New", expectedVersion: version))
        XCTAssertTrue(String(decoding: try fixture.vault.readMarkdown(relativePath: "Projects/links.md").data, as: UTF8.self)
            .contains("09-10-old/meeting"))
        try fixture.replace(old, "---\ntitle: Changed\ncapture_session_id: original\n---\n# Changed\n")
        XCTAssertThrowsError(try service.rename(meetingID: "original", title: "Another", expectedVersion: version))
        XCTAssertEqual(try service.detail(for: "original").row.title, "Changed")
    }

    func testRenameMigratesRecordingAndPersistedReferencesAndRejectsActiveWork() throws {
        let fixture = try Fixture()
        let bundleURL = try makePlaybackBundle(in: fixture, id: "rename-source")
        let old = "Meetings/rename-source/meeting.md"
        let micMetadata = bundleURL.deletingLastPathComponent().appendingPathComponent("mic.json")
        try Data(#"{"meetingRelativePath":"Meetings/rename-source/meeting.md"}"#.utf8).write(to: micMetadata)
        let new = "Meetings/updated/meeting.md"
        // JSONEncoder escapes path separators; rename must rewrite decoded JSON values,
        // not merely substitute raw UTF-8 fragments.
        try fixture.write("Meetings/rename-source/summary-extraction.json",
            #"{"schema_version":1,"meeting":"Meetings/rename-source/meeting.md","transcript":"Meetings/rename-source/transcript.json","decisions":[],"my_action_items":[],"other_action_items":[],"open_questions":[]}"#)
        try fixture.write("Meetings/rename-source/transcript.json",
            #"{"schema_version":1,"capture_session_id":"rename-source","meeting_relative_path":"Meetings/rename-source/meeting.md","language":"en","detected_languages":["en"],"engine":"fixture","model":"fixture","generated_at":"2026-01-01T00:00:00Z","audio_sources":[],"segments":[],"diagnostics":[]}"#)
        let inbox = try TasksInbox(databaseURL: fixture.root.appendingPathComponent("Support/inbox.sqlite"))
        try inbox.queueProposal(id: "meeting-action:rename-source:one", title: "Follow up", sourceRef: "[[Meetings/rename-source/summary#My action items|ref]]")
        let store = try JobStore(databaseURL: fixture.root.appendingPathComponent("Support/jobs.sqlite"))
        let manifest = JobManifest(type: "meeting.transcription", title: "Transcribe", executionClass: .heavy,
            stages: [JobStageDefinition(id: "run", title: "Transcribe")],
            sourceArtifacts: [JobArtifactReference(relativePath: old, role: "meeting")],
            metadata: ["capture_session_id": "rename-source"], maxAutomaticRetries: 0)
        _ = try store.enqueue(id: "active", manifest: manifest)
        let service = MeetingManagementService(vault: fixture.vault, jobStore: store, inbox: inbox)
        var version = try fixture.vault.readMarkdown(relativePath: old).version
        XCTAssertThrowsError(try service.rename(meetingID: "rename-source", title: "Updated", expectedVersion: version))
        XCTAssertNotNil(try fixture.vault.versionOfMarkdown(relativePath: old))
        XCTAssertEqual(try inbox.items(category: .review).first?.sourceRef, "[[Meetings/rename-source/summary#My action items|ref]]")
        let scheduler = JobScheduler(store: store, executor: FailingMeetingExecutor())
        scheduler.start()
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline && (try? store.job(id: "active"))?.status != .failed {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertEqual(try store.job(id: "active")?.status, .failed)
        version = try fixture.vault.readMarkdown(relativePath: old).version
        XCTAssertEqual(try service.rename(meetingID: "rename-source", title: "Updated", expectedVersion: version).row.meetingRelativePath, new)
        XCTAssertNil(try fixture.vault.versionOfMarkdown(relativePath: old))
        let playback = try service.detail(for: "rename-source").playback
        XCTAssertEqual(playback.capability, .microphoneOnly, playback.message)
        XCTAssertNotNil(try service.detail(for: "rename-source").extraction)
        let transcriptData = try fixture.vault.readMarkdown(relativePath: "Meetings/updated/transcript.json").data
        let transcriptJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: transcriptData) as? [String: Any])
        XCTAssertEqual(transcriptJSON["meeting_relative_path"] as? String, new)
        XCTAssertEqual(try store.job(id: "active")?.manifest.sourceArtifacts.first?.relativePath, new)
        XCTAssertEqual(try inbox.items(category: .review).first?.sourceRef, "[[Meetings/updated/summary#My action items|ref]]")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(RecordingBundle.self, from: Data(contentsOf: bundleURL))
        XCTAssertEqual(decoded.meetingRelativePath, new)
        let micJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: micMetadata)) as? [String: String])
        XCTAssertEqual(micJSON["meetingRelativePath"], new)
        let reprocessed = try MeetingManagementService(vault: fixture.vault, jobStore: store,
            retryUnavailableReason: { _ in nil }).reprocess(meetingID: "rename-source", language: .ukrainian)
        XCTAssertEqual(reprocessed.manifest.metadata["language"], "uk")
    }

    func testReplaySelectedRecordingFromConfiguredWorkspace() throws {
        guard let root = ProcessInfo.processInfo.environment["STILLMATTER_REPLAY_WORKSPACE_ROOT"],
              let recordingID = ProcessInfo.processInfo.environment["STILLMATTER_REPLAY_RECORDING_ID"] else {
            throw XCTSkip("Set STILLMATTER_REPLAY_WORKSPACE_ROOT and STILLMATTER_REPLAY_RECORDING_ID for a local playback replay.")
        }
        let vault = WorkspaceVault(workspaceRootURL: URL(fileURLWithPath: root),
            appSupportRootURL: FileManager.default.temporaryDirectory.appendingPathComponent("StillmatterReplay-\(UUID().uuidString)"))
        let service = MeetingManagementService(vault: vault,
            recordingMediaURL: ProcessInfo.processInfo.environment["STILLMATTER_REPLAY_MEDIA_ROOT"].map { URL(fileURLWithPath: $0) })
        let matching = try service.list().filter { row in
            guard let text = try? String(data: vault.readMarkdown(relativePath: row.meetingRelativePath).data, encoding: .utf8) else { return false }
            return text.components(separatedBy: .newlines).contains { $0.hasPrefix("recording_bundle:") && $0.contains(recordingID) }
        }
        XCTAssertEqual(matching.count, 1, "Select exactly one Meeting with the supplied recording folder")
        guard let selected = matching.first else { return }
        let playback = try service.detail(for: selected.meetingRelativePath).playback
        XCTAssertNotEqual(playback.capability, .unavailable, playback.message)
        XCTAssertNotNil(playback.microphonePath)
    }

    func testPlaybackDoesNotTreatAnOldAliasAsAValidBundleReference() throws {
        let fixture = try Fixture()
        _ = try makePlaybackBundle(in: fixture, id: "legacy-alias")
        let oldDirectory = fixture.root.appendingPathComponent("Meetings/legacy-alias")
        let newDirectory = fixture.root.appendingPathComponent("Meetings/renamed-alias")
        try FileManager.default.moveItem(at: oldDirectory, to: newDirectory)
        try FileManager.default.createSymbolicLink(at: oldDirectory, withDestinationURL: newDirectory)
        let service = MeetingManagementService(vault: fixture.vault)
        XCTAssertEqual(try service.detail(for: "Meetings/renamed-alias/meeting.md").playback.capability, .unavailable,
            "A symlink must not allow a stale Recording Bundle path to authorize the renamed doorway")
    }

    func testRenamedMeetingPlaysItsOriginalBundleOnlyThroughItsCanonicalPath() throws {
        let fixture = try Fixture()
        let old = "Meetings/2026/01/01/original/meeting.md"
        let renamed = "Meetings/2026/01/01/renamed/meeting.md"
        let media = fixture.root.appendingPathComponent("ExternalMedia")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let audio = media.appendingPathComponent("mic.caf")
        try makeAudio(at: audio)
        let metadata = media.appendingPathComponent("mic.json")
        try Data("{}".utf8).write(to: metadata)
        var mic = MicTrackRecordingMetadata(captureSessionID: "original", meetingRelativePath: old,
            recoveryFilePath: audio.path, finalFilePath: media.appendingPathComponent("mic.m4a").path,
            metadataFilePath: metadata.path, startedAt: Date(), sampleRate: 48000, channelCount: 1)
        mic.status = .partial
        mic.durationSeconds = 0.25
        let bundle = try RecordingBundleFinalizer().finalize(mic: mic, system: nil, reason: .recovery)
        let doorway = "---\ntitle: Original\ncapture_session_id: original\nrecording_bundle: \(bundle.bundleFilePath)\n---\n# Original\n"
        try fixture.write(old, doorway)
        let version = try fixture.vault.readMarkdown(relativePath: old).version
        let service = MeetingManagementService(vault: fixture.vault)
        XCTAssertEqual(try service.rename(meetingID: "original", title: "Renamed", expectedVersion: version).row.meetingRelativePath, renamed)
        XCTAssertNil(try fixture.vault.versionOfMarkdown(relativePath: old))
        XCTAssertEqual(try service.detail(for: "original").row.meetingRelativePath, renamed)
        XCTAssertEqual(try service.detail(for: "original").playback.capability, .microphoneOnly)
        try fixture.write("Meetings/2026/01/01/other/meeting.md", doorway) // Even the same session ID cannot authorize an unrelated doorway.
        XCTAssertEqual(try service.detail(for: "Meetings/2026/01/01/other/meeting.md").playback.capability, .unavailable)
    }

    func testMalformedAndMismatchedBundlesDoNotExposeTransport() throws {
        let fixture = try Fixture()
        let path = "Meetings/invalid/meeting.md"
        let invalid = fixture.root.appendingPathComponent("invalid.json")
        try Data("not json".utf8).write(to: invalid)
        try fixture.write(path, "---\ntitle: Invalid\nrecording_bundle: \(invalid.path)\n---\n# Invalid\n")
        let service = MeetingManagementService(vault: fixture.vault)
        let playback = try service.detail(for: path).playback
        XCTAssertEqual(playback.capability, .unavailable)
        XCTAssertNil(playback.microphonePath)
        XCTAssertTrue(playback.message.contains("invalid"))
    }

    func testFinalizedMeetingPrefersOriginalCompressedMicrophoneAudio() throws {
        let fixture = try Fixture()
        let path = "Meetings/final/meeting.md"
        let media = fixture.root.appendingPathComponent("ExternalMedia/final")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let recovery = media.appendingPathComponent("mic.caf")
        let final = media.appendingPathComponent("mic.m4a")
        try makeAudio(at: recovery)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        try { () throws in
            let compressed = try AVAudioFile(forWriting: final, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1
            ])
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 12000))
            buffer.frameLength = 12000
            try compressed.write(from: buffer)
        }()
        let original = try Data(contentsOf: final)
        let metadata = media.appendingPathComponent("mic.json")
        try Data("{}".utf8).write(to: metadata)
        var mic = MicTrackRecordingMetadata(captureSessionID: "final", meetingRelativePath: path,
            recoveryFilePath: recovery.path, finalFilePath: final.path, metadataFilePath: metadata.path,
            startedAt: Date(), sampleRate: 48000, channelCount: 1)
        mic.status = .completed
        mic.durationSeconds = 0.25
        let bundle = try RecordingBundleFinalizer().finalize(mic: mic, system: nil, reason: .normalStop)
        try fixture.write(path, "---\ntitle: Final\ncapture_session_id: final\nrecording_bundle: \(bundle.bundleFilePath)\n---\n# Final\n")
        let playback = try MeetingManagementService(vault: fixture.vault).detail(for: "final").playback
        XCTAssertEqual(playback.capability, .microphoneOnly)
        XCTAssertEqual(playback.microphonePath, final.path)
        XCTAssertTrue(playback.durationSeconds > 0)
        XCTAssertEqual(try Data(contentsOf: final), original)
    }

    func testReprocessQueuesSelectedBundleWithLanguageWithoutReplacingEditsOrInbox() throws {
        let fixture = try Fixture()
        let bundle = try makePlaybackBundle(in: fixture, id: "first")
        _ = try makePlaybackBundle(in: fixture, id: "second")
        var summaryPath = "Meetings/first/summary.md"
        try fixture.write(summaryPath, "## Summary\nManually corrected\n")
        let inbox = try TasksInbox(databaseURL: fixture.root.appendingPathComponent("Support/inbox.sqlite"))
        try inbox.queueProposal(id: "meeting-action:first:old", title: "Previous proposal", sourceRef: "[[Meetings/first/summary#My action items|ref]]")
        try inbox.setProposalReviewState(id: "meeting-action:first:old", state: .accepted)
        let store = try JobStore(databaseURL: fixture.root.appendingPathComponent("Support/jobs.sqlite"))
        var starts = 0
        let service = MeetingManagementService(vault: fixture.vault, jobStore: store, inbox: inbox,
            retryUnavailableReason: { _ in nil }, onReprocessQueued: { starts += 1 })
        var titled = try service.detail(for: "first")
        let event = CalendarMeeting(title: "Exact calendar title", eventIdentifier: "calendar-event", calendarIdentifier: "work")
        titled = try service.associateCalendar(meetingID: "first", event: event, resetTitle: true, expectedVersion: titled.doorwayVersion!)
        titled = try service.rename(meetingID: "first", title: "Protected manual title", expectedVersion: titled.doorwayVersion!)
        titled = try service.associateCalendar(meetingID: "first", event: nil, expectedVersion: titled.doorwayVersion!)
        titled = try service.associateCalendar(meetingID: "first", event: event, expectedVersion: titled.doorwayVersion!)
        let actualStart = titled.row.startedAt
        summaryPath = (titled.row.meetingRelativePath as NSString).deletingLastPathComponent + "/summary.md"
        // Merely inspecting the Meeting or dismissing the UI warning never enqueues work.
        _ = try service.detail(for: "first")
        let canonicalSummaryBeforeReprocess = try fixture.vault.readMarkdown(relativePath: summaryPath).data
        XCTAssertTrue(try store.jobs().isEmpty)
        let job = try service.reprocess(meetingID: "first", language: .ukrainian)
        let afterReprocess = try service.detail(for: "first")
        XCTAssertEqual(afterReprocess.row.title, "Protected manual title")
        XCTAssertEqual(try MeetingCalendarContext.read(from: String(decoding: fixture.vault.readMarkdown(relativePath: afterReprocess.row.meetingRelativePath).data, as: UTF8.self))?.event, event)
        XCTAssertEqual(afterReprocess.row.startedAt, actualStart)
        XCTAssertEqual(job.manifest.metadata["language"], "uk")
        let recovery = MeetingReprocessingRecovery(vault: fixture.vault).location(jobID: job.id)
        let snapshot = try JSONDecoder().decode([String: Data].self, from: Data(contentsOf: recovery))
        XCTAssertEqual(snapshot[summaryPath], canonicalSummaryBeforeReprocess)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovery.path))
        XCTAssertEqual(job.manifest.metadata["recording_bundle_path"], bundle.path)
        XCTAssertEqual(job.manifest.metadata["transcription_audio_selection_path"], "")
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(try fixture.vault.readMarkdown(relativePath: summaryPath).data, canonicalSummaryBeforeReprocess)
        XCTAssertEqual(try inbox.proposalReviewState(id: "meeting-action:first:old"), .accepted)
        XCTAssertThrowsError(try service.reprocess(meetingID: "first", language: .english))
        XCTAssertEqual(try store.jobs().count, 1)
        // Unrelated Meetings remain independently eligible under the scheduler's limits.
        XCTAssertEqual(try service.reprocess(meetingID: "second", language: .english).manifest.metadata["language"], "en")
    }

    func testArchivedMeetingCannotReprocessOrChangeLanguage() throws {
        let fixture = try Fixture()
        _ = try makePlaybackBundle(in: fixture, id: "archived")
        let jobs = try JobStore(databaseURL: fixture.root.appendingPathComponent("Support/jobs.sqlite"))
        let service = MeetingManagementService(vault: fixture.vault, jobStore: jobs, retryUnavailableReason: { _ in nil })
        try seedArchiveReady(fixture, path: "Meetings/archived/meeting.md")
        let playbackBefore = try service.detail(for: "archived").playback
        try service.archive(meetingID: "archived")
        XCTAssertEqual(try service.detail(for: "archived").playback, playbackBefore)
        XCTAssertThrowsError(try service.reprocess(meetingID: "archived", language: .ukrainian)) {
            XCTAssertTrue($0.localizedDescription.contains("Archived"))
        }
        XCTAssertTrue(try jobs.jobs().isEmpty)
        XCTAssertTrue(try service.detail(for: "archived").row.isArchived)
    }

    func testReprocessRejectsMissingOrMismatchedBundleWithoutEnqueue() throws {
        let fixture = try Fixture()
        let bundle = try makePlaybackBundle(in: fixture, id: "source")
        let store = try JobStore(databaseURL: fixture.root.appendingPathComponent("Support/jobs.sqlite"))
        let service = MeetingManagementService(vault: fixture.vault, jobStore: store, retryUnavailableReason: { _ in nil })
        try fixture.write("Meetings/other/meeting.md", "---\ntitle: Other\ncapture_session_id: other\nrecording_bundle: \(bundle.path)\n---\n# Other\n")
        XCTAssertThrowsError(try service.reprocess(meetingID: "other", language: .english))
        try FileManager.default.removeItem(at: bundle)
        XCTAssertThrowsError(try service.reprocess(meetingID: "source", language: .english))
        XCTAssertTrue(try store.jobs().isEmpty)
    }

    func testReprocessRejectsModifiedRecordingEvidenceWithoutChangingSummaryOrJobs() throws {
        let fixture = try Fixture()
        let bundle = try makePlaybackBundle(in: fixture, id: "evidence")
        try fixture.write("Meetings/evidence/summary.md", "## Summary\nManual edit\n")
        let store = try JobStore(databaseURL: fixture.root.appendingPathComponent("Support/jobs.sqlite"))
        try Data("not the original audio".utf8).write(to: bundle.deletingLastPathComponent().appendingPathComponent("mic.caf"))
        let service = MeetingManagementService(vault: fixture.vault, jobStore: store, retryUnavailableReason: { _ in nil })
        _ = try service.detail(for: "evidence")
        let before = try fixture.vault.readMarkdown(relativePath: "Meetings/evidence/summary.md").data
        XCTAssertThrowsError(try service.reprocess(meetingID: "evidence", language: .ukrainian))
        XCTAssertTrue(try store.jobs().isEmpty)
        XCTAssertEqual(try fixture.vault.readMarkdown(relativePath: "Meetings/evidence/summary.md").data, before)
    }

    func testPlaybackRejectsBundleFromAnotherMeetingOrSessionAndUnsupportedVersion() throws {
        let fixture = try Fixture()
        let bundle = try makePlaybackBundle(in: fixture, id: "source")
        let service = MeetingManagementService(vault: fixture.vault)
        let source = try service.detail(for: "source").playback
        XCTAssertEqual(source.capability, .microphoneOnly)

        try fixture.write("Meetings/other/meeting.md", "---\ntitle: Other\ncapture_session_id: other\nrecording_bundle: \(bundle.path)\n---\n# Other\n")
        let other = try service.detail(for: "other").playback
        XCTAssertEqual(other.capability, .unavailable)
        XCTAssertNil(other.microphonePath)
        XCTAssertTrue(other.message.contains("does not match"))

        try fixture.replace("Meetings/source/meeting.md", "---\ntitle: Source\ncapture_session_id: impostor\nrecording_bundle: \(bundle.path)\n---\n# Source\n")
        XCTAssertEqual(try service.detail(for: "source").playback.capability, .unavailable)
        XCTAssertEqual(try service.detail(for: "source").row.id, "source", "Manifest identity survives explicit doorway metadata changes")

        try fixture.replace("Meetings/source/meeting.md", "---\ntitle: Source\ncapture_session_id: source\nrecording_bundle: \(bundle.path)\n---\n# Source\n")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: bundle)) as? [String: Any])
        json["schemaVersion"] = 999
        try JSONSerialization.data(withJSONObject: json).write(to: bundle)
        let unsupported = try service.detail(for: "source").playback
        XCTAssertEqual(unsupported.capability, .unavailable)
        XCTAssertNil(unsupported.microphonePath)
    }

    func testPlaybackFailsClosedWhenRequiredAudioIsMissingOrUndecodable() throws {
        let fixture = try Fixture()
        let bundle = try makePlaybackBundle(in: fixture, id: "source")
        let evidence = MeetingPlaybackEvidence(recordingMediaURL: nil)
        func resolve() throws -> MeetingPlaybackEvidence.Resolution {
            let path = "Meetings/source/meeting.md"
            let doorway = try fixture.vault.readMarkdown(relativePath: path).data
            return evidence.resolve(doorwayText: String(decoding: doorway, as: UTF8.self),
                                    meetingPath: path, transcript: nil)
        }
        let audio = bundle.deletingLastPathComponent().appendingPathComponent("mic.caf")
        try Data("not audio".utf8).write(to: audio)
        let corruptEvidence = try resolve()
        XCTAssertTrue(corruptEvidence.bundleArtifact.available, "Readable artifacts are distinct from valid playback")
        XCTAssertTrue(try XCTUnwrap(corruptEvidence.sourceArtifacts.first).available)
        let corrupt = corruptEvidence.playback
        XCTAssertEqual(corrupt.capability, .unavailable)
        XCTAssertNil(corrupt.microphonePath)
        XCTAssertTrue(corrupt.message.contains("Microphone"))
        try FileManager.default.removeItem(at: audio)
        XCTAssertEqual(try resolve().playback.capability, .unavailable)
        try FileManager.default.removeItem(at: bundle)
        let missing = try resolve().playback
        XCTAssertEqual(missing.capability, .unavailable)
        XCTAssertTrue(missing.message.contains("Recording Bundle unavailable"))
    }

    func testRelocatedConfiguredMediaRestoresVerifiedPlaybackWithoutChangingDoorway() throws {
        let fixture = try Fixture()
        let original = try makePlaybackBundle(in: fixture, id: "relocated")
        let doorway = try fixture.vault.readMarkdown(relativePath: "Meetings/relocated/meeting.md").data
        let media = fixture.root.appendingPathComponent("NewMedia/2026")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let moved = media.appendingPathComponent("relocated")
        try FileManager.default.moveItem(at: original.deletingLastPathComponent(), to: moved)
        let withoutRecovery = try MeetingManagementService(vault: fixture.vault).detail(for: "relocated").playback
        XCTAssertEqual(withoutRecovery.capability, .unavailable)
        let service = MeetingManagementService(vault: fixture.vault, recordingMediaURL: fixture.root.appendingPathComponent("NewMedia"))
        let recovered = try service.detail(for: "relocated").playback
        XCTAssertGreaterThan(try XCTUnwrap(service.list().first?.durationSeconds), 0)
        XCTAssertEqual(recovered.capability, .microphoneOnly, recovered.message)
        XCTAssertGreaterThan(recovered.durationSeconds, 0)
        XCTAssertEqual(recovered.microphonePath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
                       moved.appendingPathComponent("mic.caf").resolvingSymlinksInPath().path)
        XCTAssertEqual(try fixture.vault.readMarkdown(relativePath: "Meetings/relocated/meeting.md").data, doorway)
        try Data("tampered".utf8).write(to: moved.appendingPathComponent("mic.caf"))
        XCTAssertEqual(try service.detail(for: "relocated").playback.capability, .unavailable,
                       "A relocated track with different bytes must not be played")
    }

    func testRelocationRefusesAmbiguousOrForeignSidecars() throws {
        let fixture = try Fixture()
        let original = try makePlaybackBundle(in: fixture, id: "ambiguous")
        let media = fixture.root.appendingPathComponent("NewMedia")
        for year in ["2025", "2026"] {
            let parent = media.appendingPathComponent(year)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: original.deletingLastPathComponent(), to: parent.appendingPathComponent("ambiguous"))
        }
        try FileManager.default.removeItem(at: original.deletingLastPathComponent())
        let evidence = MeetingPlaybackEvidence(recordingMediaURL: media)
        func resolve() throws -> MeetingPlaybackEvidence.Resolution {
            let path = "Meetings/ambiguous/meeting.md"
            let doorway = try fixture.vault.readMarkdown(relativePath: path).data
            return evidence.resolve(doorwayText: String(decoding: doorway, as: UTF8.self),
                                    meetingPath: path, transcript: nil)
        }
        XCTAssertEqual(try resolve().playback.capability, .unavailable)
        try FileManager.default.removeItem(at: media.appendingPathComponent("2025/ambiguous"))
        XCTAssertEqual(try resolve().playback.capability, .microphoneOnly)
        let sidecar = media.appendingPathComponent("2026/ambiguous/recording-bundle.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as? [String: Any])
        json["meetingRelativePath"] = "Meetings/foreign/meeting.md"
        try JSONSerialization.data(withJSONObject: json).write(to: sidecar)
        XCTAssertEqual(try resolve().playback.capability, .unavailable)
    }

    private func makePlaybackBundle(in fixture: Fixture, id: String) throws -> URL {
        let path = "Meetings/\(id)/meeting.md"
        let media = fixture.root.appendingPathComponent("ExternalMedia/\(id)")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let audio = media.appendingPathComponent("mic.caf")
        try makeAudio(at: audio)
        let metadata = media.appendingPathComponent("mic.json")
        try Data("{}".utf8).write(to: metadata)
        var mic = MicTrackRecordingMetadata(captureSessionID: id, meetingRelativePath: path,
            recoveryFilePath: audio.path, finalFilePath: media.appendingPathComponent("mic.m4a").path,
            metadataFilePath: metadata.path, startedAt: Date(), sampleRate: 48000, channelCount: 1)
        mic.status = .partial
        mic.durationSeconds = 0.25
        let bundle = try RecordingBundleFinalizer().finalize(mic: mic, system: nil, reason: .recovery)
        try fixture.write(path, "---\ntitle: \(id)\ncapture_session_id: \(id)\nrecording_bundle: \(bundle.bundleFilePath)\n---\n# \(id)\n")
        return URL(fileURLWithPath: bundle.bundleFilePath)
    }

    private func makeAudio(at url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 12000))
        buffer.frameLength = 12000
        try file.write(from: buffer)
    }

    private final class PausableMeetingExecutor: JobExecuting {
        private let lock = NSLock()
        private var pending: ((Result<JobStageResult, Error>) -> Void)?
        private var count = 0
        var attempts: Int { lock.lock(); defer { lock.unlock() }; return count }
        func execute(job: JobRecord, stage: JobStageDefinition, completion: @escaping (Result<JobStageResult, Error>) -> Void) {
            lock.lock(); count += 1; pending = completion; lock.unlock()
        }
        func fail() {
            lock.lock(); let completion = pending; pending = nil; lock.unlock()
            completion?(.failure(NSError(domain: "fixture", code: 1)))
        }
    }

    private final class FailingMeetingExecutor: JobExecuting {
        func execute(job: JobRecord, stage: JobStageDefinition, completion: @escaping (Result<JobStageResult, Error>) -> Void) {
            completion(.failure(NSError(domain: "transcription failed", code: 1)))
        }
    }

    private struct Fixture {
        let root: URL
        let vault: WorkspaceVault
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            vault = WorkspaceVault(workspaceRootURL: root, appSupportRootURL: root.appendingPathComponent("Support"))
        }
        func write(_ path: String, _ text: String) throws {
            _ = try vault.writeMarkdown(Data(text.utf8), relativePath: path, expectedVersion: nil)
        }
        func replace(_ path: String, _ text: String) throws {
            let version = try vault.readMarkdown(relativePath: path).version
            _ = try vault.writeMarkdown(Data(text.utf8), relativePath: path, expectedVersion: version)
        }
    }
}

private final class RenameFaultFileManager: FileManager, @unchecked Sendable {
    var failAt: Int?
    private var operation = 0
    private(set) var didFail = false
    private func check() throws {
        guard let failAt else { return }
        defer { operation += 1 }
        if operation == failAt {
            self.failAt = nil
            didFail = true
            throw NSError(domain: "Injected rename filesystem failure", code: operation)
        }
    }
    override func createDirectory(at url: URL, withIntermediateDirectories createIntermediates: Bool,
                                  attributes: [FileAttributeKey: Any]? = nil) throws {
        try check()
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }
    override func moveItem(at srcURL: URL, to dstURL: URL) throws {
        try check()
        try super.moveItem(at: srcURL, to: dstURL)
    }
}
