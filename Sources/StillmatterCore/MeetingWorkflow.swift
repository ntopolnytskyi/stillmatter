import Foundation

/// One durable processing turn. Acoustic stages are added only when a verified
/// engine exists; this contract does not claim diarization through a no-op stage.
public enum MeetingWorkflowJob {
    public static let type = "meeting.workflow"
    public static let supportedTypes: Set<String> = [type, TranscriptionJob.type, MeetingSummaryJob.type]

    public static func manifest(transcription: JobManifest, summary: JobManifest? = nil) throws -> JobManifest {
        guard transcription.type == TranscriptionJob.type,
              transcription.stages.map(\.id) == [TranscriptionJob.stageID],
              let session = transcription.metadata["capture_session_id"], !session.isEmpty,
              let meeting = transcription.sourceArtifacts.first(where: { $0.role == "meeting-doorway" })?.relativePath else {
            throw JobsError.invalidManifest("Legacy transcription does not identify a compatible Meeting workflow")
        }
        let analysis = try summary ?? MeetingSummaryJob.manifest(meetingRelativePath: meeting,
            captureSessionID: session, transcriptJSONRelativePath: TranscriptionPipeline.artifactPaths(meetingRelativePath: meeting).json)
        guard analysis.type == MeetingSummaryJob.type,
              analysis.stages.map(\.id) == [MeetingSummaryJob.stageID],
              analysis.metadata[MeetingSummaryJob.captureSessionMetadataKey] == session,
              analysis.maxAutomaticRetries == transcription.maxAutomaticRetries,
              analysis.sourceArtifacts.contains(where: { $0.role == "meeting-doorway" && $0.relativePath == meeting }) else {
            throw JobsError.invalidManifest("Legacy analysis does not belong to this Meeting workflow")
        }
        return JobManifest(type: type, title: transcription.title.replacingOccurrences(of: "Transcribe ", with: "Process "),
            executionClass: .heavy, stages: transcription.stages + analysis.stages,
            sourceArtifacts: transcription.sourceArtifacts + analysis.sourceArtifacts.filter { !transcription.sourceArtifacts.contains($0) },
            expectedOutputs: transcription.expectedOutputs + analysis.expectedOutputs,
            metadata: transcription.metadata.merging(analysis.metadata) { original, _ in original },
            maxAutomaticRetries: transcription.maxAutomaticRetries)
    }

    /// Runs before starting the single scheduler. Ownership-unknown legacy work is
    /// left quarantined; completed history remains readable without inventing runs.
    public static func migrate(store: JobStore, workspaceRootURL: URL) throws {
        let owner = workspaceRootURL.standardizedFileURL.resolvingSymlinksInPath().path
        let jobs = try store.jobs()
        for job in jobs where job.manifest.type == TranscriptionJob.type && job.manifest.workspaceOwner == owner && job.status != .dismissed {
            let continuation = jobs.first { $0.id == "meeting-summary:\(job.id)" && $0.manifest.workspaceOwner == owner && $0.status != .dismissed }
            if job.status == .succeeded && (continuation == nil || continuation?.status == .succeeded) { continue }
            var checkpoints = [TranscriptionJob.stageID: JobStageCheckpoint(jobID: job.id, stageID: TranscriptionJob.stageID)]
            if let continuation { checkpoints[MeetingSummaryJob.stageID] = JobStageCheckpoint(jobID: continuation.id, stageID: MeetingSummaryJob.stageID) }
            try store.adoptManifest(id: job.id, manifest: manifest(transcription: job.manifest, summary: continuation?.manifest),
                checkpoints: checkpoints, retiringJobIDs: continuation.map { [$0.id] } ?? [])
        }
    }
}

/// Owns Meeting-specific stage dispatch. Jobs only sees registered types and
/// persisted ordered stages, never transcription/analysis policy.
public final class MeetingWorkflowHandler: JobExecuting {
    private let transcription: JobExecuting
    private let analysis: JobExecuting
    public init(transcription: JobExecuting, analysis: JobExecuting) { self.transcription = transcription; self.analysis = analysis }

    public func execute(job: JobRecord, stage: JobStageDefinition,
                        completion: @escaping (Result<JobStageResult, Error>) -> Void) {
        let handler: JobExecuting
        switch stage.id {
        case TranscriptionJob.stageID: handler = transcription
        case MeetingSummaryJob.stageID: handler = analysis
        default:
            completion(.failure(JobsError.invalidManifest("Unsupported Meeting workflow stage \(stage.id)")))
            return
        }
        handler.execute(job: job, stage: stage, completion: completion)
    }
}
