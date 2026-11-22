import Foundation

/// Owns the source snapshot and ordered publication of already validated Meeting analysis.
/// File publication and Inbox reconciliation remain restartable steps, not one atomic write.
final class MeetingGeneratedPublication {
    let transcript: TranscriptDocument
    let transcriptPath: String
    let notes: String?

    private let jobID: String
    private let workspaceRootURL: URL
    private let vault: WorkspaceVault
    private let inbox: TasksInbox
    private let captureSessionID: String
    private let transcriptData: Data
    private let artifacts: MeetingArtifactStore
    private let canonicalID: String?
    private let canonicalBase: MeetingArtifactStore.Loaded?
    private let expectedVersions: [String: WorkspaceFileVersion?]
    private let notesPath: String
    private let notesVersion: WorkspaceFileVersion?

    /// Recover before capturing versions; these versions must precede AI generation.
    init(job: JobRecord, workflow: PiWorkflowManifest, workspaceRootURL: URL,
         vault: WorkspaceVault, inbox: TasksInbox) throws {
        guard let transcriptPath = job.manifest.metadata[MeetingSummaryJob.transcriptJSONMetadataKey] else {
            throw MeetingSummaryError.missingMetadata(MeetingSummaryJob.transcriptJSONMetadataKey)
        }
        guard let captureSessionID = job.manifest.metadata[MeetingSummaryJob.captureSessionMetadataKey] else {
            throw MeetingSummaryError.missingMetadata(MeetingSummaryJob.captureSessionMetadataKey)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let transcriptData = try Data(contentsOf: workspaceRootURL.appendingPathComponent(transcriptPath))
        let transcript = try decoder.decode(TranscriptDocument.self, from: transcriptData)
        try MeetingArtifactTransaction(vault: vault, identity: captureSessionID).recover()
        let artifacts = MeetingArtifactStore(vault: vault, inbox: inbox)
        let canonicalID = try artifacts.identity(at: transcript.meetingRelativePath)
        let canonicalBase = try canonicalID.map { try artifacts.load(meetingPath: transcript.meetingRelativePath, meetingID: $0) }
        let expectedVersions = try Dictionary(uniqueKeysWithValues: workflow.expectedOutputs.map {
            ($0.relativePath, try vault.versionOfMarkdown(relativePath: $0.relativePath))
        })
        let notesPath = canonicalBase?.paths["notes"] ?? Self.notesPath(for: transcript.meetingRelativePath)
        let notesVersion = try vault.versionOfMarkdown(relativePath: notesPath)
        let notesText = try canonicalBase?.notes ?? (notesVersion == nil ? nil :
            String(contentsOf: workspaceRootURL.appendingPathComponent(notesPath), encoding: .utf8))
        self.jobID = job.id
        self.workspaceRootURL = workspaceRootURL
        self.vault = vault
        self.inbox = inbox
        self.transcriptPath = transcriptPath
        self.captureSessionID = captureSessionID
        self.transcriptData = transcriptData
        self.transcript = transcript
        self.artifacts = artifacts
        self.canonicalID = canonicalID
        self.canonicalBase = canonicalBase
        self.expectedVersions = expectedVersions
        self.notesPath = notesPath
        self.notesVersion = notesVersion
        self.notes = notesText.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The executor validates evidence and schema before crossing this seam. Keep the
    /// cancellation fence around permission rechecking and every publication side effect.
    func publishValidated(_ result: JobStageResult, summary: GeneratedArtifact,
                          extraction validatedExtraction: MeetingSummaryExtraction,
                          cancellation: JobExecutionCancellation,
                          requireTransferApproval: () throws -> Void,
                          publicationCheckpoint: (Int) throws -> Void = { _ in },
                          onApplied: () -> Void = {}) throws -> JobStageResult {
        var extraction = validatedExtraction
        let paths = MeetingSummaryJob.artifactPaths(meetingRelativePath: transcript.meetingRelativePath)

        let noteItemIDs = try noteAuthoredItemIDs(at: notesPath)
        let extractedActionItemIDs = extraction.myActionItems + extraction.otherActionItems
        let duplicateNoteIDs = noteItemIDs.intersection(Set(extractedActionItemIDs.map { $0.id.lowercased() }))
        if !duplicateNoteIDs.isEmpty {
            extraction = MeetingSummaryExtraction(
                schemaVersion: extraction.schemaVersion,
                meeting: extraction.meeting,
                transcript: extraction.transcript,
                decisions: extraction.decisions,
                myActionItems: extraction.myActionItems.filter { !duplicateNoteIDs.contains($0.id.lowercased()) },
                otherActionItems: extraction.otherActionItems.filter { !duplicateNoteIDs.contains($0.id.lowercased()) },
                openQuestions: extraction.openQuestions,
                tagAdditions: extraction.tagAdditions
            )
        }
        if let canonicalBase { extraction = try artifacts.reconcileGeneratedActions(extraction, base: canonicalBase) }
        let sanitizedExtractionData = try JSONEncoder().encode(extraction)
        let renderedSummary = GeneratedArtifact(relativePath: paths.summary, data: Data(MeetingSummaryEvidence.readableText(MeetingSummaryEvidence.render(
            narrative: MeetingSummaryEvidence.narrative(in: String(decoding: summary.data, as: UTF8.self)), extraction: extraction)).utf8))
        var publishedArtifacts = result.artifacts.map { $0.relativePath == paths.summary ? renderedSummary : $0 }
        if let extractionIndex = publishedArtifacts.firstIndex(where: { $0.relativePath == paths.extraction }) {
            publishedArtifacts[extractionIndex] = GeneratedArtifact(relativePath: paths.extraction, data: sanitizedExtractionData)
        }

        let sourceRef = Self.summarySourceRef(meetingRelativePath: transcript.meetingRelativePath)
        var queued = 0
        try cancellation.performIfActive {
            try requireTransferApproval()
            guard try Data(contentsOf: workspaceRootURL.appendingPathComponent(transcriptPath)) == transcriptData,
                  (try vault.versionOfMarkdown(relativePath: notesPath) == notesVersion || !(extraction.tagAdditions ?? []).isEmpty) else {
                throw MeetingSummaryError.invalidExtraction("Transcript or My Notes changed during analysis. Retry with current sources.")
            }
            if let canonicalBase, let canonicalID {
                try artifacts.publishGenerated(summary: renderedSummary.data, extraction: extraction, extractionData: sanitizedExtractionData,
                    base: canonicalBase, meetingPath: transcript.meetingRelativePath, meetingID: canonicalID,
                    expectedExtraction: expectedVersions[paths.extraction] ?? nil)
            } else {
                let tagChanges = try ItemTagStore(vault: vault).prepareAIAdditions(extraction.tagAdditions ?? [], allowedPaths: [notesPath])
                let generated = publishedArtifacts.map {
                    WorkspaceMarkdownReplacement(relativePath: $0.relativePath, data: $0.data,
                        expectedVersion: expectedVersions[$0.relativePath] ?? nil)
                }
                try MeetingArtifactTransaction(vault: vault, identity: captureSessionID).publish(generated + tagChanges)
            }
            try publicationCheckpoint(0)
            for noteID in noteItemIDs {
                let duplicateProposalID = "meeting-action:\(captureSessionID):\(noteID)"
                if try inbox.proposalReviewState(id: duplicateProposalID) == .pending {
                    try inbox.setProposalReviewState(id: duplicateProposalID, state: .referenceOnly)
                }
            }
            for (index, item) in extraction.myActionItems.enumerated() {
                let proposalID = "meeting-action:\(captureSessionID):\(item.id)"
                if try inbox.queueProposal(
                    id: proposalID,
                    title: "\(item.text) #ai-proposed",
                    sourceRef: sourceRef,
                    suppressionKey: proposalID
                ) {
                    queued += 1
                }
                try publicationCheckpoint(index + 1)
            }
            try inbox.reconcileMeetingProposals(sessionID: captureSessionID, sourceRef: sourceRef,
                currentIDs: Set(extraction.myActionItems.map { "meeting-action:\(captureSessionID):\($0.id)" }))
            try publicationCheckpoint(extraction.myActionItems.count + 1)
            MeetingReprocessingRecovery(vault: vault).discard(jobID: jobID)
            onApplied()
        }
        return JobStageResult(
            artifacts: publishedArtifacts,
            logMessages: result.logMessages + [
                "Published editable meeting summary and cited structured extraction",
                "Queued \(queued) My Action Item proposal(s); suppressed \(duplicateNoteIDs.count) note-identity duplicate(s); kept \(extraction.otherActionItems.count) Other Action Item(s) reference-only"
            ]
        )
    }

    private static func summarySourceRef(meetingRelativePath: String) -> String {
        let directory = (meetingRelativePath as NSString).deletingLastPathComponent
        return "[[\(directory)/summary#My action items|ref]]"
    }

    private static func notesPath(for meetingRelativePath: String) -> String {
        let directory = (meetingRelativePath as NSString).deletingLastPathComponent
        return directory.isEmpty ? "my-notes.md" : directory + "/my-notes.md"
    }

    private func noteAuthoredItemIDs(at relativePath: String) throws -> Set<String> {
        guard try vault.versionOfMarkdown(relativePath: relativePath) != nil else { return [] }
        let source = try vault.readMarkdown(relativePath: relativePath)
        let text = String(decoding: source.data, as: UTF8.self)
        return Set(TodoItemParser().parse(markdown: text, relativePath: relativePath).compactMap { item in
            guard let metadata = TodoItemParser.metadata(in: item.rawText),
                  metadata.origin == "note", UUID(uuidString: metadata.id) != nil else { return nil }
            return metadata.id.lowercased()
        })
    }
}
