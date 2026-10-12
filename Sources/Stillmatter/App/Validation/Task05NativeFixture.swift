#if DEBUG
import Foundation
#if SWIFT_PACKAGE
import StillmatterPresentation
import StillmatterCore
#endif

/// Only instantiated by the three-root, explicitly requested native lifecycle probe.
/// Does not open an audio device or write media.
final class Task05FakeMicrophone: MicTrackRecordingManaging {
    private let lock = NSLock()
    private var metadata: MicTrackRecordingMetadata?
    private var stopGate: DispatchSemaphore?
    var failNextStop = false

    var activeMetadata: MicTrackRecordingMetadata? {
        lock.lock(); defer { lock.unlock() }
        return metadata
    }

    func holdNextStop() { lock.lock(); stopGate = DispatchSemaphore(value: 0); lock.unlock() }
    func releaseStop() { lock.lock(); let gate = stopGate; lock.unlock(); gate?.signal() }

    func start(sessionID: String, meetingRelativePath: String, startedAt: Date) throws -> MicTrackRecordingMetadata {
        let record = MicTrackRecordingMetadata(captureSessionID: sessionID, meetingRelativePath: meetingRelativePath,
            recoveryFilePath: "fixture/recovery.caf", finalFilePath: "fixture/final.m4a",
            metadataFilePath: "fixture/metadata.json", startedAt: startedAt)
        lock.lock(); metadata = record; lock.unlock()
        return record
    }

    func stop(endedAt: Date) throws -> MicTrackRecordingMetadata {
        lock.lock(); let gate = stopGate; lock.unlock()
        if let gate, gate.wait(timeout: .now() + 10) != .success {
            throw NSError(domain: "Stillmatter.Task05Fixture", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Fake finalization timed out"])
        }
        lock.lock(); defer { lock.unlock() }
        stopGate = nil
        guard var record = metadata else { throw MicTrackRecordingError.noActiveRecording }
        metadata = nil
        if failNextStop {
            failNextStop = false
            throw NSError(domain: "Stillmatter.Task05Fixture", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Injected fake finalization failure"])
        }
        record.status = .completed
        record.endedAt = endedAt
        return record
    }
}

/// Only the main-queue delivery of the real serialized mutation is gated; the vault,
/// read model, Settings callback, and AppKit delegate remain production objects.
final class Task05MeetingMutationGate: MeetingMutationExecuting {
    let underlying: MeetingMutationExecuting
    var holdCompletion = false
    var failNext = false
    private(set) var pending: (() -> Void)?

    init(underlying: MeetingMutationExecuting) { self.underlying = underlying }

    func execute(_ mutation: MeetingMutation, completion: @escaping (Result<MeetingMutationOutput, Error>) -> Void) {
        precondition(Thread.isMainThread)
        if failNext {
            failNext = false
            let failure = { completion(.failure(NSError(domain: "Stillmatter.Task05Fixture", code: 7,
                userInfo: [NSLocalizedDescriptionKey: "Injected save failure"]))) }
            if holdCompletion { pending = failure } else { failure() }
            return
        }
        underlying.execute(mutation) { [weak self] result in
            guard let self else { return }
            let delivery = { completion(result) }
            if self.holdCompletion { self.pending = delivery } else { delivery() }
        }
    }

    func release() {
        let delivery = pending
        pending = nil
        holdCompletion = false
        delivery?()
    }
}

final class Task05FakeWorker: JobExecuting {
    private let lock = NSLock()
    private var completions: [String: (Result<JobStageResult, Error>) -> Void] = [:]
    func execute(job: JobRecord, stage: JobStageDefinition,
                 completion: @escaping (Result<JobStageResult, Error>) -> Void) {
        lock.lock(); completions[job.id] = completion; lock.unlock()
    }
    func hasStarted(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return completions[id] != nil
    }
    func finish(_ id: String) {
        lock.lock(); let completion = completions.removeValue(forKey: id); lock.unlock()
        completion?(.success(JobStageResult()))
    }
}
#endif
