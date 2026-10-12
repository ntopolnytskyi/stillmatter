import XCTest
@testable import StillmatterCore

/// Explicitly invoked only against disposable roots; never seeds a user's workspace.
final class MeetingAcceptanceFixtureTests: XCTestCase {
    func testSeedAndValidateOperationalFixtures() throws {
        let env = ProcessInfo.processInfo.environment
        guard let workspace = env["STILLMATTER_VALIDATION_WORKSPACE_ROOT"],
              let support = env["STILLMATTER_VALIDATION_APPLICATION_SUPPORT_ROOT"],
              let media = env["STILLMATTER_VALIDATION_RECORDING_MEDIA_ROOT"],
              env["STILLMATTER_VALIDATION_SEED_JOBS"] == "1" else {
            throw XCTSkip("Disposable operational fixture seeder requires three isolated roots and explicit opt-in")
        }
        let root = URL(fileURLWithPath: workspace, isDirectory: true)
        guard root.standardizedFileURL.resolvingSymlinksInPath().path.contains("/.build/workbench-redesign/02-03-acceptance/"),
              URL(fileURLWithPath: support).standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(root.deletingLastPathComponent().path + "/"),
              URL(fileURLWithPath: media).standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(root.deletingLastPathComponent().path + "/") else {
            throw NSError(domain: "DisposableFixtureRequired", code: 1)
        }
        let db = URL(fileURLWithPath: support).appendingPathComponent("operational.sqlite")
        let inbox = try TasksInbox(databaseURL: db)
        let store = try JobStore(databaseURL: db, inbox: inbox)
        let meeting = "Meetings/ready/meeting.md"
        let extraction = MeetingSummaryExtraction(meeting: meeting, transcript: "Meetings/ready/transcript.json",
            decisions: [], myActionItems: [MeetingOutcome(id: "send-recap", text: "Synthetic send recap",
                citations: [MeetingOutcomeCitation(segmentID: "s1", startSeconds: 4, endSeconds: 5)]),
                MeetingOutcome(id: "dismiss", text: "Synthetic dismiss duplicate", citations: [])],
            otherActionItems: [MeetingOutcome(id: "reference", text: "Synthetic colleague follow-up", citations: [])],
            openQuestions: [])
        let transcript = #"{"schema_version":1,"capture_session_id":"fixture-ready","meeting_relative_path":"Meetings/ready/meeting.md","language":"en","detected_languages":["en"],"engine":"fixture","model":"fixture","generated_at":"2026-01-01T00:00:00Z","audio_sources":[],"segments":[{"id":"s1","start":4,"end":5,"text":"Synthetic source moment","language":"en","track":"microphone","speaker":"Me"}],"diagnostics":[]}"#
        let directory = root.appendingPathComponent("Meetings/ready")
        try JSONEncoder().encode(extraction).write(to: directory.appendingPathComponent("summary-extraction.json"))
        try Data(transcript.utf8).write(to: directory.appendingPathComponent("transcript.json"))
        try Data("# Synthetic Transcript\n\nSynthetic source moment.\n".utf8)
            .write(to: directory.appendingPathComponent("transcript.md"))
        let proposalID = "meeting-action:fixture-ready:send-recap"
        try inbox.queueProposal(id: proposalID, title: "Synthetic send recap",
            sourceRef: "[[Meetings/ready/summary#My action items|source]]")
        try inbox.queueProposal(id: "meeting-action:fixture-ready:dismiss", title: "Synthetic dismiss duplicate",
            sourceRef: "[[Meetings/ready/summary#My action items|source]]")
        XCTAssertEqual(try inbox.proposalReviewState(id: proposalID), .pending)
        XCTAssertEqual(try inbox.proposalReviewState(id: "meeting-action:fixture-ready:dismiss"), .pending)
        let manifest = { (id: String, title: String) in
            JobManifest(type: "validation-held", title: title, executionClass: .lightweight,
                stages: [JobStageDefinition(id: "work", title: "Validate synthetic work")],
                sourceArtifacts: [JobArtifactReference(relativePath: "Meetings/\(id)/meeting.md", role: "source")],
                metadata: ["capture_session_id": "fixture-\(id)"], maxAutomaticRetries: 0)
        }
        let failure = JobScheduler(store: store, executor: ValidationJobExecutor(fail: true), eligibleJobTypes: ["validation-held"])
        _ = try failure.enqueue(id: "acceptance-failed", manifest: manifest("failed", "Synthetic failed processing"))
        let deadline = Date().addingTimeInterval(5)
        while (try store.job(id: "acceptance-failed")?.status) != .failed && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTAssertEqual(try store.job(id: "acceptance-failed")?.status, .failed)
        // Queued work is durable and shown as processing even after reopening the store.
        _ = try store.enqueue(id: "acceptance-queued", manifest: manifest("processing", "Synthetic processing"))
        XCTAssertEqual(try store.job(id: "acceptance-queued")?.status, .queued)
        let vault = WorkspaceVault(workspaceRootURL: root, appSupportRootURL: URL(fileURLWithPath: support))
        let service = MeetingManagementService(vault: vault, jobStore: store, inbox: inbox)
        XCTAssertEqual(try service.detail(for: "fixture-ready").myActionItems.first?.reviewState, .pending)
        XCTAssertEqual(try service.detail(for: "fixture-ready").row.processingState, .ready)
        XCTAssertEqual(try service.detail(for: "fixture-ready").otherActionItems.first?.referenceOnly, true)
        XCTAssertEqual(try service.detail(for: "fixture-failed").job?.status, .failed)
        XCTAssertEqual(try service.detail(for: "fixture-processing").job?.status, .queued)
    }
}

private final class ValidationJobExecutor: JobExecuting {
    let fail: Bool
    init(fail: Bool) { self.fail = fail }
    func execute(job: JobRecord, stage: JobStageDefinition,
                 completion: @escaping (Result<JobStageResult, Error>) -> Void) {
        if fail { completion(.failure(NSError(domain: "SyntheticValidation", code: 1))) }
    }
}
