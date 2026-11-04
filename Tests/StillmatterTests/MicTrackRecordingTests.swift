import XCTest
@testable import StillmatterCore

final class MicTrackRecordingTests: XCTestCase {
    func testStopProducesFinalRecoveryAndDurableTechnicalMetadata() throws {
        let fixture = try MicRecordingFixture()
        let backend = FakeMicBackend()
        let coordinator = MicTrackRecordingCoordinator(mediaRootURL: fixture.root, backend: backend)
        _ = try coordinator.start(
            sessionID: "capture-1",
            meetingRelativePath: "Meetings/2026/09/18/meeting.md",
            startedAt: fixture.startedAt
        )

        let metadata = try coordinator.stop(endedAt: fixture.startedAt.addingTimeInterval(12.5))

        XCTAssertEqual(metadata.status, .completed)
        XCTAssertEqual(metadata.durationSeconds, 12.5, accuracy: 0.001)
        XCTAssertEqual(metadata.codec, "AAC in M4A")
        XCTAssertEqual(metadata.sampleRate, 48_000)
        XCTAssertEqual(metadata.channelCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadata.recoveryFilePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadata.finalFilePath))
        let stored = try fixture.decodeMetadata(at: metadata.metadataFilePath)
        XCTAssertEqual(stored.captureSessionID, metadata.captureSessionID)
        XCTAssertEqual(stored.status, .completed)
        XCTAssertEqual(stored.durationSeconds, metadata.durationSeconds)
        XCTAssertEqual(stored.finalFilePath, metadata.finalFilePath)
        XCTAssertTrue(stored.diagnostics.contains { $0.contains("recovery/preview artifact retained") })
    }

    func testFinalizationFailureNeverDeletesRecoveryArtifactAndRecordsDiagnostic() throws {
        let fixture = try MicRecordingFixture()
        let backend = FakeMicBackend()
        backend.stopError = CocoaError(.fileWriteUnknown)
        let coordinator = MicTrackRecordingCoordinator(mediaRootURL: fixture.root, backend: backend)
        let started = try coordinator.start(
            sessionID: "capture-failure",
            meetingRelativePath: "Meetings/failure/meeting.md",
            startedAt: fixture.startedAt
        )

        XCTAssertThrowsError(try coordinator.stop(endedAt: fixture.startedAt.addingTimeInterval(3)))

        XCTAssertTrue(FileManager.default.fileExists(atPath: started.recoveryFilePath))
        let stored = try fixture.decodeMetadata(at: started.metadataFilePath)
        XCTAssertEqual(stored.status, .failed)
        XCTAssertTrue(stored.diagnostics.contains { $0.contains("source artifacts retained") })
    }

    func testInputReleaseAllowsNextCaptureBeforePreviousTrackEncodingCompletes() throws {
        let fixture = try MicRecordingFixture()
        let backend = SplitMicBackend()
        let coordinator = MicTrackRecordingCoordinator(mediaRootURL: fixture.root, backend: backend)
        _ = try coordinator.start(sessionID: "capture-A", meetingRelativePath: "Meetings/A/meeting.md", startedAt: fixture.startedAt)

        let releasedA = try coordinator.releaseForFinalization(endedAt: fixture.startedAt.addingTimeInterval(3))
        XCTAssertNil(coordinator.activeMetadata)
        XCTAssertEqual(releasedA.status, .finalizing)
        XCTAssertEqual(backend.finalizeCalls, 0, "Input release must not wait for AAC export")

        _ = try coordinator.start(sessionID: "capture-B", meetingRelativePath: "Meetings/B/meeting.md", startedAt: fixture.startedAt.addingTimeInterval(4))
        let releasedB = try coordinator.releaseForFinalization(endedAt: fixture.startedAt.addingTimeInterval(6))
        let completedA = try coordinator.completeHandoff(coordinator.finalizeReleased(releasedA))
        let completedB = try coordinator.completeHandoff(coordinator.finalizeReleased(releasedB))

        XCTAssertEqual(completedA.status, .completed)
        XCTAssertEqual(completedB.status, .completed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: completedA.finalFilePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: completedB.finalFilePath))
        XCTAssertEqual(backend.finalizedRecoveryIDs, ["capture-A", "capture-B"])
        XCTAssertEqual(try fixture.decodeMetadata(at: completedA.metadataFilePath).status, .completed)
        XCTAssertEqual(try fixture.decodeMetadata(at: completedB.metadataFilePath).status, .completed)
    }

    func testInputReleaseFailurePersistsFailureAndKeepsRecoveryAudio() throws {
        let fixture = try MicRecordingFixture()
        let backend = SplitMicBackend()
        backend.stopWriteError = CocoaError(.fileWriteUnknown)
        let coordinator = MicTrackRecordingCoordinator(mediaRootURL: fixture.root, backend: backend)
        let started = try coordinator.start(sessionID: "capture-release-failure", meetingRelativePath: "Meetings/failure/meeting.md", startedAt: fixture.startedAt)

        XCTAssertThrowsError(try coordinator.releaseForFinalization(endedAt: fixture.startedAt.addingTimeInterval(2)))

        XCTAssertNil(coordinator.activeMetadata)
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.recoveryFilePath))
        let persisted = try fixture.decodeMetadata(at: started.metadataFilePath)
        XCTAssertEqual(persisted.status, .failed)
        XCTAssertTrue(persisted.diagnostics.contains { $0.contains("Microphone input stop failed") })
    }

    func testBackgroundEncodingFailurePersistsFailureAndKeepsRecoveryAudio() throws {
        let fixture = try MicRecordingFixture()
        let backend = SplitMicBackend()
        backend.finalizeError = CocoaError(.fileWriteUnknown)
        let coordinator = MicTrackRecordingCoordinator(mediaRootURL: fixture.root, backend: backend)
        let started = try coordinator.start(sessionID: "capture-encode-failure", meetingRelativePath: "Meetings/failure/meeting.md", startedAt: fixture.startedAt)
        let released = try coordinator.releaseForFinalization(endedAt: fixture.startedAt.addingTimeInterval(2))

        XCTAssertThrowsError(try coordinator.finalizeReleased(released))

        XCTAssertTrue(FileManager.default.fileExists(atPath: started.recoveryFilePath))
        let persisted = try fixture.decodeMetadata(at: started.metadataFilePath)
        XCTAssertEqual(persisted.status, .failed)
        XCTAssertTrue(persisted.diagnostics.contains { $0.contains("Microphone finalization failed") })
    }

    func testStartupRecoveryFinalizesUnfinishedRecordingFromRecoveryAudio() throws {
        let fixture = try MicRecordingFixture()
        let firstBackend = FakeMicBackend()
        let interrupted = MicTrackRecordingCoordinator(mediaRootURL: fixture.root, backend: firstBackend)
        let started = try interrupted.start(
            sessionID: "capture-crash",
            meetingRelativePath: "Meetings/crash/meeting.md",
            startedAt: fixture.startedAt
        )
        let recoveryBackend = FakeMicBackend()
        let recovering = MicTrackRecordingCoordinator(mediaRootURL: fixture.root, backend: recoveryBackend)

        let reports = recovering.recoverUnfinished()

        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports[0].status, .recovered)
        XCTAssertEqual(reports[0].codec, "AAC in M4A")
        XCTAssertTrue(FileManager.default.fileExists(atPath: reports[0].finalFilePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.recoveryFilePath))
        XCTAssertEqual(recoveryBackend.recoveryCalls, 1)
    }

    func testRestartRecoversSourceReleasedBeforeBackgroundEncoding() throws {
        let fixture = try MicRecordingFixture()
        let firstCoordinator = MicTrackRecordingCoordinator(mediaRootURL: fixture.root, backend: SplitMicBackend())
        let started = try firstCoordinator.start(sessionID: "capture-release-restart", meetingRelativePath: "Meetings/restart/meeting.md", startedAt: fixture.startedAt)
        let released = try firstCoordinator.releaseForFinalization(endedAt: fixture.startedAt.addingTimeInterval(4))
        XCTAssertEqual(released.status, .finalizing)
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.recoveryFilePath))

        let restarted = MicTrackRecordingCoordinator(mediaRootURL: fixture.root, backend: FakeMicBackend())
        let reports = restarted.recoverUnfinished()

        XCTAssertEqual(reports.map(\.captureSessionID), ["capture-release-restart"])
        XCTAssertEqual(reports.first?.status, .recovered)
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.recoveryFilePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.finalFilePath))
    }

    func testStartupRecoveryReportsMissingSourceAsPartial() throws {
        let fixture = try MicRecordingFixture()
        let interrupted = MicTrackRecordingCoordinator(mediaRootURL: fixture.root, backend: FakeMicBackend())
        let started = try interrupted.start(
            sessionID: "capture-missing",
            meetingRelativePath: "Meetings/missing/meeting.md",
            startedAt: fixture.startedAt
        )
        try FileManager.default.removeItem(atPath: started.recoveryFilePath)
        let recovering = MicTrackRecordingCoordinator(mediaRootURL: fixture.root, backend: FakeMicBackend())

        let reports = recovering.recoverUnfinished()

        XCTAssertEqual(reports.first?.status, .partial)
        XCTAssertTrue(reports.first?.diagnostics.contains { $0.contains("recovery artifact is missing") } == true)
    }
}

private final class SplitMicBackend: MicTrackCaptureReleasingBackend {
    private var activeRecoveryURL: URL?
    private(set) var finalizeCalls = 0
    private(set) var finalizedRecoveryIDs: [String] = []
    var stopWriteError: Error?
    var finalizeError: Error?

    func startWritingRecovery(to recoveryURL: URL) throws -> MicTrackTechnicalInfo {
        activeRecoveryURL = recoveryURL
        try Data("durable PCM frames".utf8).write(to: recoveryURL)
        return MicTrackTechnicalInfo(durationSeconds: 0, codec: "linear PCM recovery", sampleRate: 48_000, channelCount: 1)
    }

    func stopWritingRecovery(to recoveryURL: URL) throws -> MicTrackTechnicalInfo {
        guard activeRecoveryURL == recoveryURL else { throw MicTrackRecordingError.noActiveRecording }
        if let stopWriteError = stopWriteError { throw stopWriteError }
        activeRecoveryURL = nil
        return MicTrackTechnicalInfo(durationSeconds: 3, codec: "linear PCM recovery", sampleRate: 48_000, channelCount: 1)
    }

    func finalizeRecovery(from recoveryURL: URL, to finalURL: URL, audioClockSpans: [AudioClockSpan]?) throws -> MicTrackTechnicalInfo {
        finalizeCalls += 1
        finalizedRecoveryIDs.append(recoveryURL.deletingLastPathComponent().lastPathComponent)
        if let finalizeError = finalizeError { throw finalizeError }
        try Data("compact AAC frames".utf8).write(to: finalURL)
        return MicTrackTechnicalInfo(durationSeconds: 3, codec: "AAC in M4A", sampleRate: 48_000, channelCount: 1,
                                    audioClockSpans: audioClockSpans)
    }

    func stopAndFinalize(recoveryURL: URL, finalURL: URL) throws -> MicTrackTechnicalInfo {
        let stopped = try stopWritingRecovery(to: recoveryURL)
        return try finalizeRecovery(from: recoveryURL, to: finalURL, audioClockSpans: stopped.audioClockSpans)
    }

    func recover(recoveryURL: URL, finalURL: URL) throws -> MicTrackTechnicalInfo {
        try Data("recovered AAC frames".utf8).write(to: finalURL)
        return MicTrackTechnicalInfo(durationSeconds: 3, codec: "AAC in M4A", sampleRate: 48_000, channelCount: 1)
    }
}

private final class FakeMicBackend: MicTrackRecordingBackend {
    var stopError: Error?
    var recoveryCalls = 0

    func startWritingRecovery(to recoveryURL: URL) throws -> MicTrackTechnicalInfo {
        try Data("durable PCM frames".utf8).write(to: recoveryURL)
        return MicTrackTechnicalInfo(durationSeconds: 0, codec: "linear PCM recovery", sampleRate: 48_000, channelCount: 1)
    }

    func stopAndFinalize(recoveryURL: URL, finalURL: URL) throws -> MicTrackTechnicalInfo {
        if let stopError = stopError { throw stopError }
        try Data("compact AAC frames".utf8).write(to: finalURL)
        return completedInfo()
    }

    func recover(recoveryURL: URL, finalURL: URL) throws -> MicTrackTechnicalInfo {
        recoveryCalls += 1
        try Data("recovered AAC frames".utf8).write(to: finalURL)
        return completedInfo()
    }

    private func completedInfo() -> MicTrackTechnicalInfo {
        MicTrackTechnicalInfo(durationSeconds: 12.5, codec: "AAC in M4A", sampleRate: 48_000, channelCount: 1)
    }
}

private final class MicRecordingFixture {
    let root: URL
    let startedAt = Date(timeIntervalSince1970: 1_789_724_800)

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("StillmatterMicRecordingTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func decodeMetadata(at path: String) throws -> MicTrackRecordingMetadata {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MicTrackRecordingMetadata.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }
}
