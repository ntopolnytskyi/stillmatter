import Foundation

/// Dispatches a persisted job type to its registered handler. Registrations are
/// immutable for one scheduler lifetime, so reconfiguration cannot retarget a stage.
public final class JobHandlerRegistry: JobExecuting {
    public let jobTypes: Set<String>
    private let handlers: [String: JobExecuting]

    public init(handlers: [String: JobExecuting]) {
        self.handlers = handlers
        jobTypes = Set(handlers.keys)
    }

    public func execute(job: JobRecord, stage: JobStageDefinition,
                        completion: @escaping (Result<JobStageResult, Error>) -> Void) {
        guard let handler = handlers[job.manifest.type] else {
            completion(.failure(JobsError.invalidManifest("No registered handler for \(job.manifest.type)")))
            return
        }
        handler.execute(job: job, stage: stage, completion: completion)
    }
}

/// A missing capability fails durably through the same stage/attempt mechanism as
/// provider errors. It never changes providers or transfers workspace content.
public final class UnavailableJobHandler: JobExecuting {
    private let guidance: String
    public init(guidance: String) { self.guidance = guidance }
    public func execute(job: JobRecord, stage: JobStageDefinition,
                        completion: @escaping (Result<JobStageResult, Error>) -> Void) {
        completion(.failure(JobsError.invalidManifest(guidance)))
    }
}

/// References an already persisted checkpoint; migration never infers completion
/// from the mere presence of an artifact file.
public struct JobStageCheckpoint {
    public let jobID: String
    public let stageID: String
    public init(jobID: String, stageID: String) { self.jobID = jobID; self.stageID = stageID }
}
