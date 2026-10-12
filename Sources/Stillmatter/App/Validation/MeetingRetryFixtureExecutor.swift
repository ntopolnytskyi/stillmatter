import Foundation
import StillmatterCore

#if DEBUG
/// Fails the first attempt, then holds the retry so the native Retry control can be inspected.
final class MeetingRetryFixtureExecutor: JobExecuting {
    private var attempts = 0
    private var pending: ((Result<JobStageResult, Error>) -> Void)?

    func execute(job: JobRecord, stage: JobStageDefinition, completion: @escaping (Result<JobStageResult, Error>) -> Void) {
        attempts += 1
        if attempts == 1 { completion(.failure(NSError(domain: "fixture", code: 1))) }
        else { pending = completion }
    }
}
#endif
