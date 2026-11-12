import CryptoKit
import Foundation

/// Bounds each provider request and each attempt without dropping late Meeting evidence.
public struct MeetingAnalysisBudget {
    public let chunkBytes: Int
    public let requestsPerAttempt: Int

    public init(chunkBytes: Int = 24 * 1024, requestsPerAttempt: Int = 8) {
        self.chunkBytes = max(1024, min(chunkBytes, 24 * 1024))
        self.requestsPerAttempt = max(1, min(requestsPerAttempt, 8))
    }
}

/// Checkpoints are internal proposals, scoped to the Job, contract, model, and exact approved input.
/// Every reused proposal is revalidated; only the executor publishes a complete result.
struct MeetingAnalysisProgress {
    let root: URL
    let budget: MeetingAnalysisBudget

    func run(jobID: String, workflow: PiWorkflowManifest, transcript: TranscriptDocument, transcriptPath: String, notes: String?,
             worker: PiCodexWorker, cancellation: JobExecutionCancellation,
             validate: (JobStageResult, TranscriptDocument) throws -> Void) throws -> JobStageResult {
        guard (notes?.utf8.count ?? 0) <= 24 * 1024 else {
            throw MeetingSummaryError.invalidExtraction("My Notes exceeds the 24 KiB analysis context budget. No text was sent.")
        }
        if transcript.segments.isEmpty {
            try worker.requireTransferApproval()
            let extraction = MeetingSummaryExtraction(meeting: transcript.meetingRelativePath, transcript: transcriptPath,
                decisions: [], myActionItems: [], otherActionItems: [], openQuestions: [])
            let paths = MeetingSummaryJob.artifactPaths(meetingRelativePath: transcript.meetingRelativePath)
            let result = JobStageResult(artifacts: [
                .init(relativePath: paths.summary, data: Data(MeetingSummaryEvidence.render(narrative: "No speech was detected.", extraction: extraction).utf8)),
                .init(relativePath: paths.extraction, data: try JSONEncoder().encode(extraction))])
            try validate(result, transcript)
            return result
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let chunks = try split(transcript, encoder: encoder)
        if chunks.count == 1 {
            let result = try worker.run(manifest: workflow, suppliedContext: MeetingAnalysisContext(
                transcript: String(decoding: try encoder.encode(chunks[0]), as: UTF8.self), myNotes: notes), cancellation: cancellation)
            try validate(result, chunks[0])
            return result
        }
        let context = MeetingAnalysisContext(transcript: String(decoding: try encoder.encode(transcript), as: UTF8.self), myNotes: notes)
        var identity = try encoder.encode(context)
        identity.append(try encoder.encode(workflow))
        identity.append(Data((jobID + PiIntegration.codexModel + "analysis-v2").utf8))
        let key = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
        let directory = root.appendingPathComponent(key, isDirectory: true)
        var results: [JobStageResult] = []
        var requests = 0
        for (index, chunk) in chunks.enumerated() {
            guard !cancellation.isCancelled else { throw JobsError.executionCancelled }
            try worker.requireTransferApproval()
            let file = directory.appendingPathComponent("\(index).json")
            if let data = try? Data(contentsOf: file),
               let saved = try? JSONDecoder().decode(Checkpoint.self, from: data),
               saved.index == index, saved.count == chunks.count {
                let result = saved.result
                if (try? validate(result, chunk)) != nil {
                    results.append(result)
                    continue
                }
            }
            guard requests < budget.requestsPerAttempt else {
                throw MeetingSummaryError.invalidExtraction("Analysis checkpointed \(results.count) of \(chunks.count) parts. Request budget reached; Retry resumes remaining parts.")
            }
            requests += 1
            let result = try worker.run(manifest: workflow, suppliedContext: MeetingAnalysisContext(
                transcript: String(decoding: try encoder.encode(chunk), as: UTF8.self), myNotes: notes), cancellation: cancellation)
            try validate(result, chunk)
            try cancellation.performIfActive {
                try worker.requireTransferApproval()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try encoder.encode(Checkpoint(index: index, count: chunks.count, artifacts: result.artifacts.map {
                    Checkpoint.Artifact(path: $0.relativePath, data: $0.data)
                })).write(to: file, options: .atomic)
            }
            results.append(result)
        }
        guard requests < budget.requestsPerAttempt else {
            throw MeetingSummaryError.invalidExtraction("Analysis checkpointed all \(chunks.count) parts. Retry to reconcile the complete Meeting.")
        }
        // Reconcile using original evidence only. Generated chunk text never becomes prompt context.
        var citedIDs: Set<String> = []
        let paths = MeetingSummaryJob.artifactPaths(meetingRelativePath: transcript.meetingRelativePath)
        for result in results {
            let summary = result.artifacts.first { $0.relativePath == paths.summary }!
            citedIDs.formUnion(try MeetingSummaryEvidence.citedSegmentIDs(in: String(decoding: summary.data, as: UTF8.self), transcript: transcript))
            let extraction = try JSONDecoder().decode(MeetingSummaryExtraction.self,
                from: result.artifacts.first { $0.relativePath == paths.extraction }!.data)
            for item in extraction.decisions + extraction.myActionItems + extraction.otherActionItems + extraction.openQuestions {
                citedIDs.formUnion(item.citations.map(\.segmentID))
            }
        }
        let evidence = document(transcript, segments: transcript.segments.filter { citedIDs.contains($0.id) })
        let result = try worker.run(manifest: workflow, suppliedContext: MeetingAnalysisContext(
            transcript: String(decoding: try encoder.encode(evidence), as: UTF8.self), myNotes: notes), cancellation: cancellation)
        try validate(result, evidence)
        return result
    }

    private func split(_ transcript: TranscriptDocument, encoder: JSONEncoder) throws -> [TranscriptDocument] {
        var groups: [[TranscriptSegment]] = []
        var current: [TranscriptSegment] = []
        var bytes = 0
        for segment in transcript.segments {
            let size = try encoder.encode(segment).count
            guard size <= budget.chunkBytes else {
                throw MeetingSummaryError.invalidExtraction("A Transcript segment exceeds the analysis request budget. No evidence was truncated.")
            }
            if bytes + size > budget.chunkBytes, !current.isEmpty {
                groups.append(current)
                current = []
                bytes = 0
            }
            current.append(segment)
            bytes += size
        }
        if !current.isEmpty || groups.isEmpty { groups.append(current) }
        guard groups.count <= 256 else {
            throw MeetingSummaryError.invalidExtraction("Meeting exceeds the 256-part analysis budget. No evidence was truncated.")
        }
        return groups.map { document(transcript, segments: $0) }
    }

    private func document(_ transcript: TranscriptDocument, segments: [TranscriptSegment]) -> TranscriptDocument {
        TranscriptDocument(schemaVersion: transcript.schemaVersion, captureSessionID: transcript.captureSessionID,
            meetingRelativePath: transcript.meetingRelativePath, language: transcript.language,
            detectedLanguages: transcript.detectedLanguages, engine: transcript.engine, model: transcript.model,
            generatedAt: transcript.generatedAt, audioSources: [], segments: segments, diagnostics: [])
    }

    private struct Checkpoint: Codable {
        struct Artifact: Codable { let path: String; let data: Data }
        let index: Int
        let count: Int
        let artifacts: [Artifact]
        var result: JobStageResult {
            JobStageResult(artifacts: artifacts.map { .init(relativePath: $0.path, data: $0.data) })
        }
    }
}
