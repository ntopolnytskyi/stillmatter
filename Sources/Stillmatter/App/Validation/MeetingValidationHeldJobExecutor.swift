#if DEBUG
import Foundation
#if SWIFT_PACKAGE
import StillmatterCore
#endif

/// Only the explicitly gated disposable acceptance fixture uses this executor.
/// It leaves the persisted stage running without touching recordings or AI services.
final class MeetingValidationHeldJobExecutor: JobExecuting {
    func execute(job: JobRecord, stage: JobStageDefinition,
                 completion: @escaping (Result<JobStageResult, Error>) -> Void) {
        // Deliberately held until the disposable process exits.
    }
}
#endif
