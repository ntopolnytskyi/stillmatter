import Foundation
import NaturalLanguage

public struct MeetingOutcomeCitation: Codable, Equatable {
    public let segmentID: String
    public let startSeconds: Double
    public let endSeconds: Double

    public init(segmentID: String, startSeconds: Double, endSeconds: Double) {
        self.segmentID = segmentID
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case segmentID = "segment_id"
        case startSeconds = "start_seconds"
        case endSeconds = "end_seconds"
    }
}

public struct MeetingOutcome: Codable, Equatable {
    public let id: String
    public let text: String
    public let citations: [MeetingOutcomeCitation]

    public init(id: String, text: String, citations: [MeetingOutcomeCitation]) {
        self.id = id
        self.text = text
        self.citations = citations
    }
}

public struct MeetingSummaryExtraction: Codable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let meeting: String
    public let transcript: String
    public let decisions: [MeetingOutcome]
    public let myActionItems: [MeetingOutcome]
    public let otherActionItems: [MeetingOutcome]
    public let openQuestions: [MeetingOutcome]
    public let tagAdditions: [AIItemTagAddition]?

    public init(
        schemaVersion: Int = MeetingSummaryExtraction.currentSchemaVersion,
        meeting: String,
        transcript: String,
        decisions: [MeetingOutcome],
        myActionItems: [MeetingOutcome],
        otherActionItems: [MeetingOutcome],
        openQuestions: [MeetingOutcome],
        tagAdditions: [AIItemTagAddition]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.meeting = meeting
        self.transcript = transcript
        self.decisions = decisions
        self.myActionItems = myActionItems
        self.otherActionItems = otherActionItems
        self.openQuestions = openQuestions
        self.tagAdditions = tagAdditions
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case meeting
        case transcript
        case decisions
        case myActionItems = "my_action_items"
        case otherActionItems = "other_action_items"
        case openQuestions = "open_questions"
        case tagAdditions = "tag_additions"
    }
}

public enum MeetingSummaryError: Error, Equatable, CustomStringConvertible {
    case unsupportedJob(String)
    case missingMetadata(String)
    case missingArtifact(String)
    case invalidExtraction(String)
    case invalidSummaryCitation(paragraph: Int, missing: Bool)

    public var description: String {
        switch self {
        case let .unsupportedJob(value): return "Unsupported meeting summary job: \(value)"
        case let .missingMetadata(key): return "Meeting summary job is missing metadata: \(key)"
        case let .missingArtifact(path): return "Meeting summary workflow did not return: \(path)"
        case let .invalidExtraction(reason): return "Invalid meeting summary extraction: \(reason)"
        case let .invalidSummaryCitation(paragraph, missing):
            return "Invalid meeting summary extraction: Every Summary paragraph must cite known Transcript segment IDs in brackets. Paragraph \(paragraph) \(missing ? "has no citation" : "contains an unrecognized citation")."
        }
    }
}

/// Builds the app-owned pi/Codex contract used to summarize one durable Transcript.
public enum MeetingSummaryJob {
    public static let type = "meeting.summary"
    public static let stageID = "summarize-and-extract"
    public static let transcriptJSONMetadataKey = "transcript_json_path"
    public static let captureSessionMetadataKey = "capture_session_id"

    public static func artifactPaths(meetingRelativePath: String) -> (summary: String, extraction: String) {
        let directory = (meetingRelativePath as NSString).deletingLastPathComponent
        let prefix = directory.isEmpty ? "" : directory + "/"
        return (prefix + "summary.md", prefix + "summary-extraction.json")
    }

    public static func manifest(transcript: TranscriptDocument, transcriptJSONRelativePath: String) throws -> JobManifest {
        try manifest(meetingRelativePath: transcript.meetingRelativePath, captureSessionID: transcript.captureSessionID,
                     transcriptJSONRelativePath: transcriptJSONRelativePath)
    }

    public static func manifest(meetingRelativePath: String, captureSessionID: String, transcriptJSONRelativePath: String) throws -> JobManifest {
        let paths = artifactPaths(meetingRelativePath: meetingRelativePath)
        let meetingDirectory = (meetingRelativePath as NSString).deletingLastPathComponent
        let notesPath = meetingDirectory.isEmpty ? "my-notes.md" : meetingDirectory + "/my-notes.md"
        let workflow = PiWorkflowManifest(
            task: """
            Summarize this meeting transcript. Return an editable Markdown summary and a machine-readable extraction.
            The Markdown frontmatter must set type: meeting-summary, schema_version: 1, meeting and transcript to the exact source paths, and generated_at to an ISO-8601 timestamp.
            The Markdown must use exactly these headings: Summary, Decisions, My action items, Other action items, Open questions.
            Use '-' when a section has no supported outcome. Cite every extracted outcome with one or more transcript segment IDs and exact start/end seconds from transcript.json; do not invent evidence.
            Cite every Summary paragraph with bracketed segment IDs, e.g. [segment-00001]. For an empty Transcript the Summary narrative must be exactly: No speech was detected.
            Use # Summary followed by ## Decisions, ## My action items, ## Other action items, and ## Open questions. Each Summary paragraph or bullet must end with at least one citation. Put each exact ID in its own brackets, e.g. [segment-00001] [segment-00002]; do not add timestamps inside those brackets. Never use an uncited '-' placeholder inside Summary when speech was detected.
            Reconcile the entire supplied evidence chronologically: later explicit corrections supersede earlier decisions, and repeated commitments produce one outcome with combined citations.
            The extraction JSON must have schema_version=1, meeting and transcript matching the manifest paths, and arrays named decisions, my_action_items, other_action_items, and open_questions. Every array item must contain a stable id, concise text, and citations with segment_id, start_seconds, and end_seconds.
            For a silent/empty Transcript, return no invented outcomes and say no speech was detected. Unknown owners and due dates must remain unspecified in the text; never assign an unknown owner to Me.
            Classify only commitments assigned to the user/Me as my_action_items. Commitments assigned to anyone else belong in other_action_items.
            Optionally return tag_additions: an array of objects containing only item_id (an existing canonical sm-item UUID) and tags (ordinary tag names without #). These are additive patches, automatically applied without another approval. Never remove tags, use ai-gen/need-approve, or include text, owner, review or completion mutations. New generated Action Items may include ordinary inline tags in their text.
            Read My Notes at \(notesPath) as protected context. Never rewrite or delete its content. When a transcript commitment is already represented by one of its note-authored checkboxes, do not extract a second Action Item; reuse that checkbox's exact sm-item UUID as the outcome id so the app can enforce the identity match. Do not infer a match from title similarity alone.
            """,
            primarySources: [
                JobArtifactReference(relativePath: transcriptJSONRelativePath, role: "timestamped-transcript"),
                JobArtifactReference(relativePath: meetingRelativePath, role: "meeting-doorway")
            ],
            relatedContext: [notesPath],
            expectedOutputs: [
                PiWorkflowOutput(
                    relativePath: paths.summary,
                    kind: .markdown,
                    requiredFrontmatterFields: ["type", "schema_version", "meeting", "transcript", "generated_at"],
                    requiredHeadings: ["Summary", "Decisions", "My action items", "Other action items", "Open questions"]
                ),
                PiWorkflowOutput(relativePath: paths.extraction, kind: .proposalJSON)
            ],
            forbiddenMutations: ["Todos/**", "Projects/**", "People/**", "Meetings/**"],
            timeoutSeconds: 180
        )
        let encoded = try JSONEncoder().encode(workflow)
        guard let contract = String(data: encoded, encoding: .utf8) else {
            throw PiWorkerError.invalidManifest("Meeting summary workflow contract could not be encoded")
        }
        return JobManifest(
            type: type,
            title: "Summarize meeting",
            executionClass: .heavy,
            stages: [JobStageDefinition(id: stageID, title: "Summarize meeting and extract cited outcomes")],
            sourceArtifacts: workflow.primarySources,
            expectedOutputs: [
                GeneratedArtifactExpectation(
                    stageID: stageID,
                    relativePath: paths.summary,
                    validatorID: "markdown",
                    requiredFrontmatterFields: ["type", "schema_version", "meeting", "transcript", "generated_at"],
                    requiredHeadings: ["Summary", "Decisions", "My action items", "Other action items", "Open questions"]
                ),
                GeneratedArtifactExpectation(stageID: stageID, relativePath: paths.extraction, validatorID: "json")
            ],
            metadata: [
                PiWorkflowManifest.metadataKey: contract,
                transcriptJSONMetadataKey: transcriptJSONRelativePath,
                captureSessionMetadataKey: captureSessionID
            ],
            maxAutomaticRetries: 1
        )
    }
}

/// Runs and validates pi/Codex analysis against the source Transcript, then delegates
/// ordered, recoverable publication of generated artifacts and Action Item proposals.
public final class MeetingSummaryJobExecutor: CancellableJobExecuting {
    private let worker: PiCodexWorker
    private let workspaceRootURL: URL
    private let vault: WorkspaceVault
    private let inbox: TasksInbox
    private let queue: DispatchQueue
    private let onApplied: () -> Void
    private let analysisBudget: MeetingAnalysisBudget
    private let publicationCheckpoint: (Int) throws -> Void

    public init(
        worker: PiCodexWorker,
        workspaceRootURL: URL,
        vault: WorkspaceVault,
        inbox: TasksInbox,
        queue: DispatchQueue = DispatchQueue(label: "Stillmatter.MeetingSummary", qos: .utility),
        onApplied: @escaping () -> Void = {},
        analysisBudget: MeetingAnalysisBudget = MeetingAnalysisBudget(),
        publicationCheckpoint: @escaping (Int) throws -> Void = { _ in }
    ) {
        self.worker = worker
        self.workspaceRootURL = workspaceRootURL.standardizedFileURL
        self.vault = vault
        self.inbox = inbox
        self.queue = queue
        self.onApplied = onApplied
        self.analysisBudget = analysisBudget
        self.publicationCheckpoint = publicationCheckpoint
    }

    public func execute(
        job: JobRecord,
        stage: JobStageDefinition,
        completion: @escaping (Result<JobStageResult, Error>) -> Void
    ) {
        execute(job: job, stage: stage, cancellation: JobExecutionCancellation(), completion: completion)
    }

    public func execute(job: JobRecord, stage: JobStageDefinition, cancellation: JobExecutionCancellation,
                        completion: @escaping (Result<JobStageResult, Error>) -> Void) {
        let workerFinished = DispatchGroup()
        workerFinished.enter()
        cancellation.installCancelAndWait {
            workerFinished.wait()
            return true
        }
        queue.async { [self] in
            defer { workerFinished.leave() }
            completion(Result { try run(job: job, stage: stage, cancellation: cancellation) })
        }
    }

    private func run(job: JobRecord, stage: JobStageDefinition,
                     cancellation: JobExecutionCancellation) throws -> JobStageResult {
        guard !cancellation.isCancelled else { throw JobsError.executionCancelled }
        guard (job.manifest.type == MeetingSummaryJob.type || job.manifest.type == MeetingWorkflowJob.type), stage.id == MeetingSummaryJob.stageID else {
            throw MeetingSummaryError.unsupportedJob("\(job.manifest.type)/\(stage.id)")
        }
        let workflow = try decodeWorkflow(from: job)
        let publication = try MeetingGeneratedPublication(job: job, workflow: workflow,
            workspaceRootURL: workspaceRootURL, vault: vault, inbox: inbox)
        let transcript = publication.transcript
        let transcriptPath = publication.transcriptPath
        let result = try MeetingAnalysisProgress(root: vault.meetingArtifactStateURL.appendingPathComponent("Analysis"),
            budget: analysisBudget).run(jobID: job.id, workflow: workflow, transcript: transcript, transcriptPath: transcriptPath,
                notes: publication.notes, worker: worker, cancellation: cancellation) { result, chunk in
                    _ = try self.validateResult(result, transcript: chunk, transcriptPath: transcriptPath, manifest: job.manifest)
                }
        guard !cancellation.isCancelled else { throw JobsError.executionCancelled }
        let (summary, validatedExtraction) = try validateResult(result, transcript: transcript,
            transcriptPath: transcriptPath, manifest: job.manifest)
        return try publication.publishValidated(result, summary: summary, extraction: validatedExtraction,
            cancellation: cancellation, requireTransferApproval: { try worker.requireTransferApproval() },
            publicationCheckpoint: publicationCheckpoint, onApplied: onApplied)
    }

    private func validateResult(_ result: JobStageResult, transcript: TranscriptDocument,
                                transcriptPath: String, manifest: JobManifest) throws -> (GeneratedArtifact, MeetingSummaryExtraction) {
        let paths = MeetingSummaryJob.artifactPaths(meetingRelativePath: transcript.meetingRelativePath)
        guard result.artifacts.count == 2, Set(result.artifacts.map(\.relativePath)) == Set([paths.summary, paths.extraction]),
              let summary = result.artifacts.first(where: { $0.relativePath == paths.summary }),
              let data = result.artifacts.first(where: { $0.relativePath == paths.extraction })?.data else {
            throw MeetingSummaryError.invalidExtraction("Analysis must return exactly the declared Summary and extraction.")
        }
        guard result.artifacts.allSatisfy({ $0.data.count <= 128 * 1024 }) else {
            throw MeetingSummaryError.invalidExtraction("Analysis artifact exceeds the 128 KiB output budget.")
        }
        let expectation = try requiredExpectation(path: summary.relativePath, manifest: manifest)
        try MarkdownGeneratedArtifactValidator().validate(summary, expectation: expectation)
        try validateSummaryMetadata(summary, meetingPath: transcript.meetingRelativePath, transcriptPath: transcriptPath)
        let extraction: MeetingSummaryExtraction
        do { extraction = try JSONDecoder().decode(MeetingSummaryExtraction.self, from: data) }
        catch { throw MeetingSummaryError.invalidExtraction("JSON does not match the extraction schema.") }
        try validate(extraction, transcript: transcript, transcriptPath: transcriptPath)
        let markdown = String(decoding: summary.data, as: UTF8.self)
        _ = try MeetingSummaryEvidence.citedSegmentIDs(in: markdown, transcript: transcript)
        let body = MeetingSummaryEvidence.narrative(in: markdown)
        // Fixed English headings and metadata cannot mask non-English generated narrative.
        for heading in body.components(separatedBy: .newlines) where heading.hasPrefix("#") {
            try validateEnglish(heading.replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression))
        }
        let narrative = body.components(separatedBy: .newlines).filter { !$0.hasPrefix("#") }.joined(separator: "\n")
        for paragraph in narrative.components(separatedBy: "\n\n") {
            try validateEnglish(paragraph)
        }
        for outcome in extraction.decisions + extraction.myActionItems + extraction.otherActionItems + extraction.openQuestions {
            try validateEnglish(outcome.text)
        }
        return (summary, extraction)
    }

    private func validateEnglish(_ text: String) throws {
        let text = text.replacingOccurrences(of: #"\[[^\]]+\]|[\"“][^\"”]+[\"”]"#, with: "", options: .regularExpression)
        guard text.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else { return }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard recognizer.dominantLanguage == .english else {
            throw MeetingSummaryError.invalidExtraction("Generated narrative must be in English. Retry analysis.")
        }
    }

    private func decodeWorkflow(from job: JobRecord) throws -> PiWorkflowManifest {
        guard let encoded = job.manifest.metadata[PiWorkflowManifest.metadataKey],
              let data = encoded.data(using: .utf8) else {
            throw MeetingSummaryError.missingMetadata(PiWorkflowManifest.metadataKey)
        }
        return try JSONDecoder().decode(PiWorkflowManifest.self, from: data)
    }

    private func requiredExpectation(path: String, manifest: JobManifest) throws -> GeneratedArtifactExpectation {
        guard let expectation = manifest.expectedOutputs.first(where: { $0.relativePath == path }) else {
            throw MeetingSummaryError.missingArtifact(path)
        }
        return expectation
    }

    private func validateSummaryMetadata(
        _ artifact: GeneratedArtifact,
        meetingPath: String,
        transcriptPath: String
    ) throws {
        guard let markdown = String(data: artifact.data, encoding: .utf8) else {
            throw MeetingSummaryError.invalidExtraction("summary is not UTF-8")
        }
        for line in [
            "type: meeting-summary",
            "schema_version: 1",
            "meeting: \(meetingPath)",
            "transcript: \(transcriptPath)"
        ] where !markdown.components(separatedBy: .newlines).contains(line) {
            throw MeetingSummaryError.invalidExtraction("summary frontmatter must contain '\(line)'")
        }
    }

    private func validate(
        _ extraction: MeetingSummaryExtraction,
        transcript: TranscriptDocument,
        transcriptPath: String
    ) throws {
        guard extraction.schemaVersion == MeetingSummaryExtraction.currentSchemaVersion else {
            throw MeetingSummaryError.invalidExtraction("unsupported schema_version \(extraction.schemaVersion)")
        }
        guard extraction.meeting == transcript.meetingRelativePath else {
            throw MeetingSummaryError.invalidExtraction("meeting does not match the Transcript")
        }
        guard extraction.transcript == transcriptPath else {
            throw MeetingSummaryError.invalidExtraction("transcript path does not match the primary source")
        }
        let segments = Dictionary(uniqueKeysWithValues: transcript.segments.map { ($0.id, $0) })
        var outcomeIDs: Set<String> = []
        let groups = extraction.decisions + extraction.myActionItems + extraction.otherActionItems + extraction.openQuestions
        for outcome in groups {
            guard !outcome.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  outcomeIDs.insert(outcome.id).inserted else {
                throw MeetingSummaryError.invalidExtraction("outcome IDs must be non-empty and unique")
            }
            guard !outcome.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MeetingSummaryError.invalidExtraction("outcome \(outcome.id) has empty text")
            }
            guard !outcome.citations.isEmpty else {
                throw MeetingSummaryError.invalidExtraction("outcome \(outcome.id) has no transcript citation")
            }
            try MeetingSummaryEvidence.validateQuotes(in: outcome.text, sources: outcome.citations.compactMap { segments[$0.segmentID]?.text })
            for citation in outcome.citations {
                guard let segment = segments[citation.segmentID] else {
                    throw MeetingSummaryError.invalidExtraction("outcome \(outcome.id) cites unknown segment \(citation.segmentID)")
                }
                guard abs(segment.startSeconds - citation.startSeconds) < 0.001,
                      abs(segment.endSeconds - citation.endSeconds) < 0.001 else {
                    throw MeetingSummaryError.invalidExtraction("outcome \(outcome.id) citation range does not match \(citation.segmentID)")
                }
            }
        }
    }

}
