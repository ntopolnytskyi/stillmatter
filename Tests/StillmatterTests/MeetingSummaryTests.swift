import Foundation
import XCTest
@testable import StillmatterCore

final class MeetingSummaryTests: XCTestCase {
    func testManifestDeclaresBoundedPiWorkflowAndStableSummarySchema() throws {
        let fixture = try MeetingSummaryFixture()

        let manifest = try MeetingSummaryJob.manifest(
            transcript: fixture.transcript,
            transcriptJSONRelativePath: fixture.transcriptPath
        )

        XCTAssertEqual(manifest.type, "meeting.summary")
        XCTAssertEqual(manifest.executionClass, .heavy)
        XCTAssertEqual(manifest.stages.map(\.id), ["summarize-and-extract"])
        XCTAssertEqual(manifest.expectedOutputs.map(\.relativePath), [fixture.summaryPath, fixture.extractionPath])
        XCTAssertEqual(
            manifest.expectedOutputs.first?.requiredHeadings,
            ["Summary", "Decisions", "My action items", "Other action items", "Open questions"]
        )
        let contract = try XCTUnwrap(manifest.metadata[PiWorkflowManifest.metadataKey])
        let workflow = try JSONDecoder().decode(PiWorkflowManifest.self, from: Data(contract.utf8))
        XCTAssertEqual(workflow.primarySources.first?.relativePath, fixture.transcriptPath)
        XCTAssertTrue(workflow.task.contains("exact start/end seconds"))
        XCTAssertTrue(workflow.task.contains("only commitments assigned to the user/Me"))
        XCTAssertTrue(workflow.forbiddenMutations.contains("Todos/**"))
    }

    func testExecutorPublishesSummaryAndCitedExtractionAndQueuesOnlyMyActionItems() throws {
        let fixture = try MeetingSummaryFixture()
        let extraction = MeetingSummaryExtraction(
            meeting: fixture.transcript.meetingRelativePath,
            transcript: fixture.transcriptPath,
            decisions: [fixture.outcome(id: "decision-1", text: "Launch on Friday", segment: 1)],
            myActionItems: [fixture.outcome(id: "my-1", text: "Send the launch plan", segment: 0)],
            otherActionItems: [fixture.outcome(id: "other-1", text: "Alex checks capacity", segment: 1)],
            openQuestions: [fixture.outcome(id: "question-1", text: "Is legal approval ready?", segment: 1)]
        )
        let executor = try fixture.executor(extraction: extraction)
        let manifest = try MeetingSummaryJob.manifest(
            transcript: fixture.transcript,
            transcriptJSONRelativePath: fixture.transcriptPath
        )
        let result = try execute(executor, manifest: manifest)

        XCTAssertEqual(Set(result.artifacts.map(\.relativePath)), Set([fixture.summaryPath, fixture.extractionPath]))
        XCTAssertTrue(try fixture.contents(fixture.summaryPath).contains("## My action items"))
        let stored = try JSONDecoder().decode(
            MeetingSummaryExtraction.self,
            from: Data(contentsOf: fixture.workspaceURL.appendingPathComponent(fixture.extractionPath))
        )
        XCTAssertEqual(stored, extraction)

        let reviewItems = try fixture.inbox.items(category: .review)
        XCTAssertEqual(reviewItems.count, 1)
        XCTAssertEqual(reviewItems.first?.id, "meeting-action:capture-summary:my-1")
        XCTAssertEqual(reviewItems.first?.title, "Send the launch plan #ai-proposed")
        XCTAssertEqual(reviewItems.first?.sourceRef, "[[Meetings/2026/09/kickoff/summary#My action items|ref]]")
        XCTAssertFalse(reviewItems.contains { $0.title.contains("Alex") })
    }

    func testRegenerationKeepsManualSummaryUntilValidationSucceedsThenReplacesIt() throws {
        let fixture = try MeetingSummaryFixture()
        let original = "## Summary\n\nManually corrected.\n"
        try Data(original.utf8).write(to: fixture.workspaceURL.appendingPathComponent(fixture.summaryPath))
        let invalid = MeetingSummaryExtraction(meeting: fixture.transcript.meetingRelativePath,
            transcript: fixture.transcriptPath, decisions: [],
            myActionItems: [MeetingOutcome(id: "bad", text: "Uncited", citations: [])],
            otherActionItems: [], openQuestions: [])
        let manifest = try MeetingSummaryJob.manifest(transcript: fixture.transcript,
            transcriptJSONRelativePath: fixture.transcriptPath)
        XCTAssertThrowsError(try execute(fixture.executor(extraction: invalid), manifest: manifest))
        XCTAssertEqual(try fixture.contents(fixture.summaryPath), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.workspaceURL.appendingPathComponent(fixture.extractionPath).path))

        let valid = MeetingSummaryExtraction(meeting: fixture.transcript.meetingRelativePath,
            transcript: fixture.transcriptPath, decisions: [], myActionItems: [], otherActionItems: [], openQuestions: [])
        _ = try execute(fixture.executor(extraction: valid), manifest: manifest)
        XCTAssertTrue(try fixture.contents(fixture.summaryPath).contains("Launch planning."))
        XCTAssertFalse(try fixture.contents(fixture.summaryPath).contains("Manually corrected."))
        XCTAssertEqual(try fixture.inbox.items(category: .review).count, 0)
    }

    func testRegenerationPreservesReviewedOutcomesAndMarksUnsupportedPendingProposals() throws {
        let fixture = try MeetingSummaryFixture()
        let source = "[[Meetings/2026/09/kickoff/summary#My action items|ref]]"
        let todo = fixture.workspaceURL.appendingPathComponent("Todos/todo.md")
        try FileManager.default.createDirectory(at: todo.deletingLastPathComponent(), withIntermediateDirectories: true)
        let acceptedTodo = "## Queue\n- [ ] Approved follow-up \(source)\n"
        try Data(acceptedTodo.utf8).write(to: todo)
        for id in ["kept", "old", "approved"] {
            try fixture.inbox.queueProposal(id: "meeting-action:capture-summary:\(id)", title: id, sourceRef: source)
        }
        try fixture.inbox.setProposalReviewState(id: "meeting-action:capture-summary:approved", state: .accepted)
        let extraction = MeetingSummaryExtraction(meeting: fixture.transcript.meetingRelativePath,
            transcript: fixture.transcriptPath, decisions: [],
            myActionItems: [fixture.outcome(id: "kept", text: "Send the launch plan", segment: 0),
                            fixture.outcome(id: "approved", text: "Send the launch plan", segment: 0),
                            fixture.outcome(id: "new", text: "Send the launch plan", segment: 0)],
            otherActionItems: [], openQuestions: [])
        _ = try execute(fixture.executor(extraction: extraction), manifest: MeetingSummaryJob.manifest(
            transcript: fixture.transcript, transcriptJSONRelativePath: fixture.transcriptPath))
        XCTAssertEqual(try fixture.inbox.proposalReviewState(id: "meeting-action:capture-summary:approved"), .accepted)
        XCTAssertNil(try fixture.inbox.pendingProposal(id: "meeting-action:capture-summary:approved"))
        XCTAssertEqual(Set(try fixture.inbox.items(category: .review).map(\.id)),
                       Set(["meeting-action:capture-summary:kept", "meeting-action:capture-summary:old", "meeting-action:capture-summary:new"]))
        XCTAssertEqual(try fixture.inbox.items(category: .review).first { $0.id == "meeting-action:capture-summary:old" }?.details,
                       "Not supported by the current Summary")
        let reopened = try TasksInbox(databaseURL: fixture.rootURL.appendingPathComponent("operational.sqlite"))
        XCTAssertEqual(try reopened.items(category: .review).first { $0.id == "meeting-action:capture-summary:old" }?.details,
                       "Not supported by the current Summary")
        XCTAssertEqual(try reopened.pendingProposal(id: "meeting-action:capture-summary:old")?.isObsolete, true)
        XCTAssertEqual(try reopened.pendingProposal(id: "meeting-action:capture-summary:kept")?.isObsolete, false)
        XCTAssertEqual(try String(contentsOf: todo, encoding: .utf8), acceptedTodo)
    }

    func testInvalidCitationPublishesNothingAndCreatesNoProposals() throws {
        let fixture = try MeetingSummaryFixture()
        let invalid = MeetingOutcome(
            id: "my-1",
            text: "Send the launch plan",
            citations: [MeetingOutcomeCitation(segmentID: "missing-segment", startSeconds: 1, endSeconds: 3)]
        )
        let extraction = MeetingSummaryExtraction(
            meeting: fixture.transcript.meetingRelativePath,
            transcript: fixture.transcriptPath,
            decisions: [],
            myActionItems: [invalid],
            otherActionItems: [],
            openQuestions: []
        )
        let executor = try fixture.executor(extraction: extraction)
        let manifest = try MeetingSummaryJob.manifest(
            transcript: fixture.transcript,
            transcriptJSONRelativePath: fixture.transcriptPath
        )

        XCTAssertThrowsError(try execute(executor, manifest: manifest)) { error in
            XCTAssertEqual(
                error as? MeetingSummaryError,
                .invalidExtraction("outcome my-1 cites unknown segment missing-segment")
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.workspaceURL.appendingPathComponent(fixture.summaryPath).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.workspaceURL.appendingPathComponent(fixture.extractionPath).path))
        XCTAssertTrue(try fixture.inbox.items(category: .review).isEmpty)
    }

    private func execute(_ executor: MeetingSummaryJobExecutor, manifest: JobManifest) throws -> JobStageResult {
        let job = JobRecord(
            id: "summary-job",
            manifest: manifest,
            status: .running,
            stages: [],
            createdAt: "2026-09-21T09:00:00Z",
            updatedAt: "2026-09-21T09:00:00Z",
            failureDetails: nil
        )
        let completed = expectation(description: "summary completed")
        var captured: Result<JobStageResult, Error>?
        executor.execute(job: job, stage: manifest.stages[0]) {
            captured = $0
            completed.fulfill()
        }
        wait(for: [completed], timeout: 2)
        return try XCTUnwrap(captured).get()
    }
}

private final class MeetingSummaryFixture {
    let rootURL: URL
    let workspaceURL: URL
    let transcriptPath = "Meetings/2026/09/kickoff/transcript.json"
    let summaryPath = "Meetings/2026/09/kickoff/summary.md"
    let extractionPath = "Meetings/2026/09/kickoff/summary-extraction.json"
    let transcript: TranscriptDocument
    let inbox: TasksInbox

    init() throws {
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        workspaceURL = rootURL.appendingPathComponent("Vault", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspaceURL.appendingPathComponent("Meetings/2026/09/kickoff", isDirectory: true),
            withIntermediateDirectories: true
        )
        transcript = TranscriptDocument(
            schemaVersion: 1,
            captureSessionID: "capture-summary",
            meetingRelativePath: "Meetings/2026/09/kickoff/meeting.md",
            language: .english,
            detectedLanguages: [.english],
            engine: "fixture",
            model: "fixture-model",
            generatedAt: Date(timeIntervalSince1970: 1_790_000_000),
            audioSources: [],
            segments: [
                TranscriptSegment(
                    id: "segment-00001",
                    startSeconds: 1,
                    endSeconds: 3,
                    text: "I will send the launch plan.",
                    language: .english,
                    track: .microphone,
                    speaker: "Me"
                ),
                TranscriptSegment(
                    id: "segment-00002",
                    startSeconds: 4,
                    endSeconds: 7,
                    text: "Launch Friday. Alex will check capacity.",
                    language: .english,
                    track: .systemAudio,
                    speaker: "Meeting audio"
                )
            ],
            diagnostics: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(transcript).write(to: workspaceURL.appendingPathComponent(transcriptPath))
        try Data("# Meeting\n".utf8).write(to: workspaceURL.appendingPathComponent("Meetings/2026/09/kickoff/meeting.md"))
        inbox = try TasksInbox(databaseURL: rootURL.appendingPathComponent("operational.sqlite"))
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func outcome(id: String, text: String, segment index: Int) -> MeetingOutcome {
        let segment = transcript.segments[index]
        return MeetingOutcome(
            id: id,
            text: text,
            citations: [MeetingOutcomeCitation(
                segmentID: segment.id,
                startSeconds: segment.startSeconds,
                endSeconds: segment.endSeconds
            )]
        )
    }

    func executor(extraction: MeetingSummaryExtraction) throws -> MeetingSummaryJobExecutor {
        let summary = """
        ---
        type: meeting-summary
        schema_version: 1
        meeting: \(transcript.meetingRelativePath)
        transcript: \(transcriptPath)
        generated_at: 2026-09-21T09:00:00Z
        ---

        # Summary

        Launch planning.

        ## Decisions

        - Launch on Friday [segment-00002 00:00:04–00:00:07]

        ## My action items

        - Send the launch plan [segment-00001 00:00:01–00:00:03]

        ## Other action items

        - Alex checks capacity [segment-00002 00:00:04–00:00:07]

        ## Open questions

        - Is legal approval ready? [segment-00002 00:00:04–00:00:07]
        """ + "\n"
        let extractionData = try JSONEncoder().encode(extraction)
        let responseObject: [String: Any] = [
            "schema_version": 1,
            "artifacts": [
                ["relative_path": summaryPath, "content": summary],
                ["relative_path": extractionPath, "content": String(decoding: extractionData, as: UTF8.self)]
            ]
        ]
        let response = String(
            decoding: try JSONSerialization.data(withJSONObject: responseObject, options: [.sortedKeys]),
            as: UTF8.self
        )
        let worker = PiCodexWorker(
            executableURL: URL(fileURLWithPath: "/usr/local/bin/pi"),
            vaultRootURL: workspaceURL,
            commandRunner: MeetingSummaryPiRunner(response: response)
        )
        return MeetingSummaryJobExecutor(
            worker: worker,
            workspaceRootURL: workspaceURL,
            vault: WorkspaceVault(
                workspaceRootURL: workspaceURL,
                appSupportRootURL: rootURL.appendingPathComponent("Application Support", isDirectory: true)
            ),
            inbox: inbox
        )
    }

    func contents(_ relativePath: String) throws -> String {
        try String(contentsOf: workspaceURL.appendingPathComponent(relativePath), encoding: .utf8)
    }
}

private final class MeetingSummaryPiRunner: PiCommandRunning {
    let response: String

    init(response: String) {
        self.response = response
    }

    func run(_ command: PiCommand) throws -> PiCommandResult {
        PiCommandResult(exitCode: 0, standardOutput: response, standardError: "")
    }
}
