import Foundation

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

    public init(
        schemaVersion: Int = MeetingSummaryExtraction.currentSchemaVersion,
        meeting: String,
        transcript: String,
        decisions: [MeetingOutcome],
        myActionItems: [MeetingOutcome],
        otherActionItems: [MeetingOutcome],
        openQuestions: [MeetingOutcome]
    ) {
        self.schemaVersion = schemaVersion
        self.meeting = meeting
        self.transcript = transcript
        self.decisions = decisions
        self.myActionItems = myActionItems
        self.otherActionItems = otherActionItems
        self.openQuestions = openQuestions
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case meeting
        case transcript
        case decisions
        case myActionItems = "my_action_items"
        case otherActionItems = "other_action_items"
        case openQuestions = "open_questions"
    }
}

public enum MeetingSummaryError: Error, Equatable, CustomStringConvertible {
    case unsupportedJob(String)
    case missingMetadata(String)
    case missingArtifact(String)
    case invalidExtraction(String)

    public var description: String {
        switch self {
        case let .unsupportedJob(value): return "Unsupported meeting summary job: \(value)"
        case let .missingMetadata(key): return "Meeting summary job is missing metadata: \(key)"
        case let .missingArtifact(path): return "Meeting summary workflow did not return: \(path)"
        case let .invalidExtraction(reason): return "Invalid meeting summary extraction: \(reason)"
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
        let paths = artifactPaths(meetingRelativePath: transcript.meetingRelativePath)
        let workflow = PiWorkflowManifest(
            task: """
            Summarize this meeting transcript. Return an editable Markdown summary and a machine-readable extraction.
            The Markdown frontmatter must set type: meeting-summary, schema_version: 1, meeting and transcript to the exact source paths, and generated_at to an ISO-8601 timestamp.
            The Markdown must use exactly these headings: Summary, Decisions, My action items, Other action items, Open questions.
            Use '-' when a section has no supported outcome. Cite every extracted outcome with one or more transcript segment IDs and exact start/end seconds from transcript.json; do not invent evidence.
            The extraction JSON must have schema_version=1, meeting and transcript matching the manifest paths, and arrays named decisions, my_action_items, other_action_items, and open_questions. Every array item must contain a stable id, concise text, and citations with segment_id, start_seconds, and end_seconds.
            Classify only commitments assigned to the user/Me as my_action_items. Commitments assigned to anyone else belong in other_action_items.
            """,
            primarySources: [
                JobArtifactReference(relativePath: transcriptJSONRelativePath, role: "timestamped-transcript"),
                JobArtifactReference(relativePath: transcript.meetingRelativePath, role: "meeting-doorway")
            ],
            relatedContext: ["Projects/**", "People/**", "Activities/**"],
            expectedOutputs: [
                PiWorkflowOutput(
                    relativePath: paths.summary,
                    kind: .markdown,
                    requiredFrontmatterFields: ["type", "schema_version", "meeting", "transcript", "generated_at"],
                    requiredHeadings: ["Summary", "Decisions", "My action items", "Other action items", "Open questions"]
                ),
                PiWorkflowOutput(relativePath: paths.extraction, kind: .proposalJSON)
            ],
            forbiddenMutations: ["Todos/**", "Activities/**", "Projects/**", "People/**", "Meetings/**"],
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
                captureSessionMetadataKey: transcript.captureSessionID
            ],
            maxAutomaticRetries: 1
        )
    }
}

/// Validates pi/Codex output against the source Transcript before atomically publishing generated
/// artifacts and creating Review Inbox proposals for the user's Action Items only.
public final class MeetingSummaryJobExecutor: JobExecuting {
    private let worker: PiCodexWorker
    private let workspaceRootURL: URL
    private let vault: WorkspaceVault
    private let inbox: TasksInbox
    private let queue: DispatchQueue
    private let onApplied: () -> Void

    public init(
        worker: PiCodexWorker,
        workspaceRootURL: URL,
        vault: WorkspaceVault,
        inbox: TasksInbox,
        queue: DispatchQueue = DispatchQueue(label: "Stillmatter.MeetingSummary", qos: .utility),
        onApplied: @escaping () -> Void = {}
    ) {
        self.worker = worker
        self.workspaceRootURL = workspaceRootURL.standardizedFileURL
        self.vault = vault
        self.inbox = inbox
        self.queue = queue
        self.onApplied = onApplied
    }

    public func execute(
        job: JobRecord,
        stage: JobStageDefinition,
        completion: @escaping (Result<JobStageResult, Error>) -> Void
    ) {
        queue.async { [self] in
            completion(Result { try run(job: job, stage: stage) })
        }
    }

    private func run(job: JobRecord, stage: JobStageDefinition) throws -> JobStageResult {
        guard job.manifest.type == MeetingSummaryJob.type, stage.id == MeetingSummaryJob.stageID else {
            throw MeetingSummaryError.unsupportedJob("\(job.manifest.type)/\(stage.id)")
        }
        let workflow = try decodeWorkflow(from: job)
        guard let transcriptPath = job.manifest.metadata[MeetingSummaryJob.transcriptJSONMetadataKey] else {
            throw MeetingSummaryError.missingMetadata(MeetingSummaryJob.transcriptJSONMetadataKey)
        }
        guard let captureSessionID = job.manifest.metadata[MeetingSummaryJob.captureSessionMetadataKey] else {
            throw MeetingSummaryError.missingMetadata(MeetingSummaryJob.captureSessionMetadataKey)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let transcript = try decoder.decode(
            TranscriptDocument.self,
            from: Data(contentsOf: workspaceRootURL.appendingPathComponent(transcriptPath))
        )
        let expectedVersions = try Dictionary(uniqueKeysWithValues: workflow.expectedOutputs.map {
            ($0.relativePath, try vault.versionOfMarkdown(relativePath: $0.relativePath))
        })
        let result = try worker.run(manifest: workflow)
        let artifactsByPath = Dictionary(uniqueKeysWithValues: result.artifacts.map { ($0.relativePath, $0) })
        let paths = MeetingSummaryJob.artifactPaths(meetingRelativePath: transcript.meetingRelativePath)
        guard let summary = artifactsByPath[paths.summary] else {
            throw MeetingSummaryError.missingArtifact(paths.summary)
        }
        guard let extractionArtifact = artifactsByPath[paths.extraction] else {
            throw MeetingSummaryError.missingArtifact(paths.extraction)
        }

        let summaryExpectation = try requiredExpectation(path: paths.summary, manifest: job.manifest)
        try MarkdownGeneratedArtifactValidator().validate(summary, expectation: summaryExpectation)
        try validateSummaryMetadata(
            summary,
            meetingPath: transcript.meetingRelativePath,
            transcriptPath: transcriptPath
        )
        let extraction: MeetingSummaryExtraction
        do {
            extraction = try JSONDecoder().decode(MeetingSummaryExtraction.self, from: extractionArtifact.data)
        } catch {
            throw MeetingSummaryError.invalidExtraction("JSON does not match schema: \(error.localizedDescription)")
        }
        try validate(extraction, transcript: transcript, transcriptPath: transcriptPath)

        try vault.replaceMarkdownTransaction(result.artifacts.map {
            WorkspaceMarkdownReplacement(
                relativePath: $0.relativePath,
                data: $0.data,
                expectedVersion: expectedVersions[$0.relativePath] ?? nil
            )
        })
        let sourceRef = Self.summarySourceRef(meetingRelativePath: transcript.meetingRelativePath)
        var queued = 0
        for item in extraction.myActionItems {
            let proposalID = "meeting-action:\(captureSessionID):\(item.id)"
            if try inbox.queueProposal(
                id: proposalID,
                title: "\(item.text) #ai-proposed",
                sourceRef: sourceRef,
                suppressionKey: proposalID
            ) {
                queued += 1
            }
        }
        try inbox.reconcileMeetingProposals(sessionID: captureSessionID, sourceRef: sourceRef,
            currentIDs: Set(extraction.myActionItems.map { "meeting-action:\(captureSessionID):\($0.id)" }))
        onApplied()
        return JobStageResult(
            artifacts: result.artifacts,
            logMessages: result.logMessages + [
                "Published editable meeting summary and cited structured extraction",
                "Queued \(queued) My Action Item proposal(s); kept \(extraction.otherActionItems.count) Other Action Item(s) reference-only"
            ]
        )
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

    private static func summarySourceRef(meetingRelativePath: String) -> String {
        let directory = (meetingRelativePath as NSString).deletingLastPathComponent
        return "[[\(directory)/summary#My action items|ref]]"
    }
}
