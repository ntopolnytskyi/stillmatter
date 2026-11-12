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

    func run(jobID: String, workflow: PiWorkflowManifest, transcript: TranscriptDocument, notes: String?,
             worker: PiCodexWorker, cancellation: JobExecutionCancellation,
             validate: (JobStageResult, TranscriptDocument) throws -> Void) throws -> JobStageResult {
        guard (notes?.utf8.count ?? 0) <= 24 * 1024 else {
            throw MeetingSummaryError.invalidExtraction("My Notes exceeds the 24 KiB analysis context budget. No text was sent.")
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
        identity.append(Data((jobID + PiIntegration.codexModel + "analysis-v1").utf8))
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
        return try merge(results, transcript: transcript)
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
        return groups.map { segments in
            TranscriptDocument(schemaVersion: transcript.schemaVersion, captureSessionID: transcript.captureSessionID,
                meetingRelativePath: transcript.meetingRelativePath, language: transcript.language,
                detectedLanguages: transcript.detectedLanguages, engine: transcript.engine, model: transcript.model,
                generatedAt: transcript.generatedAt, audioSources: [], segments: segments, diagnostics: [])
        }
    }

    private func merge(_ results: [JobStageResult], transcript: TranscriptDocument) throws -> JobStageResult {
        let paths = MeetingSummaryJob.artifactPaths(meetingRelativePath: transcript.meetingRelativePath)
        var summaries: [String] = []
        var extractions: [MeetingSummaryExtraction] = []
        for result in results {
            let summary = String(decoding: result.artifacts.first { $0.relativePath == paths.summary }!.data, as: UTF8.self)
            // Preserve every chunk's narrative; outcome sections are rendered from validated extraction below.
            let lines = summary.components(separatedBy: .newlines)
            var collecting = false
            var body: [String] = []
            for line in lines {
                if line == "# Summary" || line == "## Summary" { collecting = true; continue }
                if collecting, line.hasPrefix("#") { break }
                if collecting { body.append(line) }
            }
            summaries.append(body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
            extractions.append(try JSONDecoder().decode(MeetingSummaryExtraction.self,
                from: result.artifacts.first { $0.relativePath == paths.extraction }!.data))
        }
        // Chunk-local model IDs must not collide across distinct evidence. Preserve explicit note UUID identity.
        var seenIDs: Set<String> = []
        func outcomes(_ select: (MeetingSummaryExtraction) -> [MeetingOutcome]) -> [MeetingOutcome] {
            extractions.enumerated().flatMap { index, extraction in select(extraction).compactMap { item in
                let id = UUID(uuidString: item.id) == nil ? "part-\(index)-\(item.id)" : item.id.lowercased()
                guard seenIDs.insert(id).inserted else { return nil }
                return MeetingOutcome(id: id, text: item.text, citations: item.citations)
            }}
        }
        let combined = MeetingSummaryExtraction(meeting: transcript.meetingRelativePath, transcript: extractions[0].transcript,
            decisions: outcomes { $0.decisions }, myActionItems: outcomes { $0.myActionItems },
            otherActionItems: outcomes { $0.otherActionItems }, openQuestions: outcomes { $0.openQuestions })
        func render(_ items: [MeetingOutcome]) -> String {
            items.isEmpty ? "-" : items.map { item in
                "- \(item.text) " + item.citations.map { "[\($0.segmentID) \($0.startSeconds)–\($0.endSeconds)]" }.joined(separator: " ")
            }.joined(separator: "\n")
        }
        let summary = """
        ---
        type: meeting-summary
        schema_version: 1
        meeting: \(transcript.meetingRelativePath)
        transcript: \(combined.transcript)
        generated_at: \(ISO8601DateFormatter().string(from: Date()))
        ---

        # Summary

        \(summaries.joined(separator: "\n\n"))

        ## Decisions

        \(render(combined.decisions))

        ## My action items

        \(render(combined.myActionItems))

        ## Other action items

        \(render(combined.otherActionItems))

        ## Open questions

        \(render(combined.openQuestions))
        """
        return JobStageResult(artifacts: [.init(relativePath: paths.summary, data: Data(summary.utf8)),
            .init(relativePath: paths.extraction, data: try JSONEncoder().encode(combined))],
            logMessages: ["Validated all \(results.count) analysis parts before publication."])
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
