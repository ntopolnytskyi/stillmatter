import XCTest
@testable import StillmatterCore

final class SystemAudioTrackRecordingTests: XCTestCase {
    func testLegacySystemRecorderUsesDefaultReleasedFinalizationHandoff() throws {
        let recorder: SystemAudioTrackRecordingManaging = LegacySystemAudioTrackRecorder()
        let released = try recorder.releaseForFinalization(endedAt: Date(timeIntervalSince1970: 10))

        XCTAssertEqual(released.captureSessionID, "legacy-system")
        XCTAssertEqual(try recorder.finalizeReleased(released), released)
        XCTAssertEqual(try recorder.completeHandoff(released), released)
    }

    func testStopProducesSeparateFinalRecoveryAndMetadataArtifacts() throws {
        let fixture = try SystemAudioRecordingFixture()
        let backend = FakeSystemAudioBackend()
        let coordinator = SystemAudioTrackRecordingCoordinator(mediaRootURL: fixture.root, backend: backend)
        _ = try coordinator.start(
            sessionID: "capture-1",
            meetingRelativePath: "Meetings/2026/09/18/meeting.md",
            startedAt: fixture.startedAt
        )

        let metadata = try coordinator.stop(endedAt: fixture.startedAt.addingTimeInterval(15))

        XCTAssertEqual(metadata.status, .completed)
        XCTAssertEqual(metadata.durationSeconds, 15, accuracy: 0.001)
        XCTAssertEqual(metadata.codec, "AAC in M4A")
        XCTAssertEqual(metadata.sampleRate, 48_000)
        XCTAssertEqual(metadata.channelCount, 2)
        XCTAssertTrue(metadata.recoveryFilePath.hasSuffix("system-recovery.caf"))
        XCTAssertTrue(metadata.finalFilePath.hasSuffix("system.m4a"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadata.recoveryFilePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: metadata.finalFilePath))
        let stored = try fixture.decodeMetadata(at: metadata.metadataFilePath)
        XCTAssertEqual(stored.status, .completed)
        XCTAssertTrue(stored.diagnostics.contains { $0.contains("recovery/preview artifact retained") })
    }

    func testLegacySystemBackendFinishesAudioBeforeReleasingNextCapture() throws {
        let fixture = try SystemAudioRecordingFixture()
        let backend = FakeSystemAudioBackend()
        let coordinator = SystemAudioTrackRecordingCoordinator(mediaRootURL: fixture.root, backend: backend)
        _ = try coordinator.start(sessionID: "legacy-A", meetingRelativePath: "Meetings/A/meeting.md", startedAt: fixture.startedAt)

        let released = try coordinator.releaseForFinalization(endedAt: fixture.startedAt.addingTimeInterval(3))

        XCTAssertEqual(released.status, .completed)
        XCTAssertNil(coordinator.activeMetadata)
        XCTAssertTrue(FileManager.default.fileExists(atPath: released.finalFilePath))
        let next = try coordinator.start(sessionID: "legacy-B", meetingRelativePath: "Meetings/B/meeting.md",
            startedAt: fixture.startedAt.addingTimeInterval(4))
        XCTAssertEqual(next.captureSessionID, "legacy-B")
        XCTAssertEqual(coordinator.latestMetadata?.captureSessionID, "legacy-B")
    }

    func testInputReleaseAllowsNextCaptureBeforeSystemTrackEncodingCompletes() throws {
        let fixture = try SystemAudioRecordingFixture()
        let backend = SplitSystemAudioBackend()
        let coordinator = SystemAudioTrackRecordingCoordinator(mediaRootURL: fixture.root, backend: backend)
        _ = try coordinator.start(sessionID: "system-A", meetingRelativePath: "Meetings/A/meeting.md", startedAt: fixture.startedAt)

        let releasedA = try coordinator.releaseForFinalization(endedAt: fixture.startedAt.addingTimeInterval(3))
        XCTAssertNil(coordinator.activeMetadata)
        XCTAssertEqual(releasedA.status, .finalizing)
        XCTAssertEqual(backend.finalizeCalls, 0)

        _ = try coordinator.start(sessionID: "system-B", meetingRelativePath: "Meetings/B/meeting.md", startedAt: fixture.startedAt.addingTimeInterval(4))
        let releasedB = try coordinator.releaseForFinalization(endedAt: fixture.startedAt.addingTimeInterval(6))
        let completedA = try coordinator.finalizeReleased(releasedA)
        let completedB = try coordinator.finalizeReleased(releasedB)
        _ = try coordinator.completeHandoff(completedA)
        _ = try coordinator.completeHandoff(completedB)

        XCTAssertTrue(FileManager.default.fileExists(atPath: completedA.finalFilePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: completedB.finalFilePath))
        XCTAssertEqual(backend.finalizedRecoveryIDs, ["system-A", "system-B"])
        XCTAssertEqual(coordinator.latestMetadata?.captureSessionID, "system-B", "A's late handoff cannot replace B's recorder metadata")
    }

    func testSystemInputReleaseFailurePersistsFailureAndKeepsRecoveryAudio() throws {
        let fixture = try SystemAudioRecordingFixture()
        let backend = SplitSystemAudioBackend()
        backend.stopWriteError = CocoaError(.fileWriteUnknown)
        let coordinator = SystemAudioTrackRecordingCoordinator(mediaRootURL: fixture.root, backend: backend)
        let started = try coordinator.start(sessionID: "system-release-failure", meetingRelativePath: "Meetings/failure/meeting.md", startedAt: fixture.startedAt)

        XCTAssertThrowsError(try coordinator.releaseForFinalization(endedAt: fixture.startedAt.addingTimeInterval(2)))

        XCTAssertNil(coordinator.activeMetadata)
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.recoveryFilePath))
        let persisted = try fixture.decodeMetadata(at: started.metadataFilePath)
        XCTAssertEqual(persisted.status, .failed)
        XCTAssertTrue(persisted.diagnostics.contains { $0.contains("System-audio input stop failed") })
    }

    func testSystemBackgroundEncodingFailurePersistsFailureAndKeepsRecoveryAudio() throws {
        let fixture = try SystemAudioRecordingFixture()
        let backend = SplitSystemAudioBackend()
        backend.finalizeError = CocoaError(.fileWriteUnknown)
        let coordinator = SystemAudioTrackRecordingCoordinator(mediaRootURL: fixture.root, backend: backend)
        let started = try coordinator.start(sessionID: "system-encode-failure", meetingRelativePath: "Meetings/failure/meeting.md", startedAt: fixture.startedAt)
        let released = try coordinator.releaseForFinalization(endedAt: fixture.startedAt.addingTimeInterval(2))

        XCTAssertThrowsError(try coordinator.finalizeReleased(released))

        XCTAssertTrue(FileManager.default.fileExists(atPath: started.recoveryFilePath))
        let persisted = try fixture.decodeMetadata(at: started.metadataFilePath)
        XCTAssertEqual(persisted.status, .failed)
        XCTAssertTrue(persisted.diagnostics.contains { $0.contains("System-audio finalization failed") })
    }

    func testFailedSystemFinalizationRemainsFailedAfterHandoff() throws {
        let fixture = try SystemAudioRecordingFixture()
        let backend = SplitSystemAudioBackend()
        backend.finalizeError = CocoaError(.fileWriteUnknown)
        let coordinator = SystemAudioTrackRecordingCoordinator(mediaRootURL: fixture.root, backend: backend)
        let started = try coordinator.start(sessionID: "system-handoff-failure", meetingRelativePath: "Meetings/failure/meeting.md", startedAt: fixture.startedAt)
        let released = try coordinator.releaseForFinalization(endedAt: fixture.startedAt.addingTimeInterval(2))
        XCTAssertThrowsError(try coordinator.finalizeReleased(released))
        let failed = try XCTUnwrap(coordinator.latestMetadata)

        let afterHandoff = try coordinator.completeHandoff(failed)

        XCTAssertEqual(afterHandoff.status, .failed)
        XCTAssertEqual(coordinator.latestMetadata?.status, .failed)
        XCTAssertEqual(try fixture.decodeMetadata(at: started.metadataFilePath).status, .failed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.recoveryFilePath))
    }

    func testPreviousSystemMetadataWithoutScopeStillDecodes() throws {
        let fixture = try SystemAudioRecordingFixture()
        let original = SystemAudioTrackRecordingMetadata(captureSessionID: "legacy", meetingRelativePath: "Meetings/legacy/meeting.md",
            recoveryFilePath: "media/legacy/system.caf", finalFilePath: "media/legacy/system.m4a",
            metadataFilePath: "media/legacy/system.json", startedAt: fixture.startedAt)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(original)) as? [String: Any])
        data.removeValue(forKey: "source")
        data.removeValue(forKey: "scope")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let legacy = try decoder.decode(SystemAudioTrackRecordingMetadata.self,
            from: JSONSerialization.data(withJSONObject: data))
        XCTAssertNil(legacy.source)
        XCTAssertNil(legacy.scope)
    }

    func testSelectedCaptureScopeIsPersistedAndPassedToBackend() throws {
        let fixture = try SystemAudioRecordingFixture()
        let backend = FakeSystemAudioBackend()
        let coordinator = SystemAudioTrackRecordingCoordinator(mediaRootURL: fixture.root, backend: backend)
        for source: CaptureAudioSource in [.teams, .zoom, .meet] {
            let metadata = try coordinator.start(sessionID: source.rawValue,
                meetingRelativePath: "Meetings/\(source.rawValue)/meeting.md", startedAt: fixture.startedAt,
                source: source)
            XCTAssertEqual(metadata.source, source)
            XCTAssertEqual(metadata.scope, source.scope)
            XCTAssertEqual(backend.lastScope, source.scope)
            XCTAssertEqual(try fixture.decodeMetadata(at: metadata.metadataFilePath).scope, source.scope)
            _ = try coordinator.stop(endedAt: fixture.startedAt.addingTimeInterval(2))
        }
    }

    func testStartFailureIsPersistedForDegradedModeWithoutAnActiveSystemTrack() throws {
        let fixture = try SystemAudioRecordingFixture()
        let backend = FakeSystemAudioBackend()
        backend.startError = CocoaError(.userCancelled)
        let coordinator = SystemAudioTrackRecordingCoordinator(mediaRootURL: fixture.root, backend: backend)

        XCTAssertThrowsError(try coordinator.start(
            sessionID: "capture-degraded",
            meetingRelativePath: "Meetings/degraded/meeting.md",
            startedAt: fixture.startedAt
        ))

        XCTAssertNil(coordinator.activeMetadata)
        XCTAssertEqual(coordinator.latestMetadata?.status, .failed)
        let stored = try fixture.decodeMetadata(at: coordinator.latestMetadata!.metadataFilePath)
        XCTAssertTrue(stored.diagnostics.contains { $0.contains("microphone capture may continue") })
    }

    func testFinalizationFailureRetainsRecoveryAndRecoveryCanFinalizeItLater() throws {
        let fixture = try SystemAudioRecordingFixture()
        let backend = FakeSystemAudioBackend()
        backend.stopError = CocoaError(.fileWriteUnknown)
        let interrupted = SystemAudioTrackRecordingCoordinator(mediaRootURL: fixture.root, backend: backend)
        let started = try interrupted.start(
            sessionID: "capture-recovery",
            meetingRelativePath: "Meetings/recovery/meeting.md",
            startedAt: fixture.startedAt
        )

        XCTAssertThrowsError(try interrupted.stop(endedAt: fixture.startedAt.addingTimeInterval(8)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.recoveryFilePath))

        let recoveringBackend = FakeSystemAudioBackend()
        let recovering = SystemAudioTrackRecordingCoordinator(mediaRootURL: fixture.root, backend: recoveringBackend)
        let reports = recovering.recoverUnfinished()

        XCTAssertEqual(reports.first?.status, .recovered)
        XCTAssertTrue(FileManager.default.fileExists(atPath: reports.first!.finalFilePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.recoveryFilePath))
    }
}

private final class LegacySystemAudioTrackRecorder: SystemAudioTrackRecordingManaging {
    var activeMetadata: SystemAudioTrackRecordingMetadata? { nil }
    var latestMetadata: SystemAudioTrackRecordingMetadata? { nil }

    func start(sessionID: String, meetingRelativePath: String, startedAt: Date,
               source: CaptureAudioSource) throws -> SystemAudioTrackRecordingMetadata {
        throw SystemAudioTrackRecordingError.alreadyRecording
    }

    func stop(endedAt: Date) throws -> SystemAudioTrackRecordingMetadata {
        var metadata = SystemAudioTrackRecordingMetadata(
            captureSessionID: "legacy-system",
            meetingRelativePath: "Meetings/legacy/meeting.md",
            recoveryFilePath: "media/legacy/system.caf",
            finalFilePath: "media/legacy/system.m4a",
            metadataFilePath: "media/legacy/system.json",
            startedAt: Date(timeIntervalSince1970: 0),
            status: .completed
        )
        metadata.endedAt = endedAt
        return metadata
    }
}

private final class SplitSystemAudioBackend: SystemAudioCaptureReleasingBackend {
    private var activeRecoveryURL: URL?
    private(set) var finalizeCalls = 0
    private(set) var finalizedRecoveryIDs: [String] = []
    var stopWriteError: Error?
    var finalizeError: Error?

    func startWritingRecovery(to recoveryURL: URL, scope: CaptureAudioScope) throws -> SystemAudioTrackTechnicalInfo {
        activeRecoveryURL = recoveryURL
        try Data("durable system PCM frames".utf8).write(to: recoveryURL)
        return SystemAudioTrackTechnicalInfo(durationSeconds: 0, codec: "linear PCM recovery", sampleRate: 48_000, channelCount: 2)
    }

    func stopWritingRecovery(to recoveryURL: URL) throws -> SystemAudioTrackTechnicalInfo {
        guard activeRecoveryURL == recoveryURL else { throw SystemAudioTrackRecordingError.noActiveRecording }
        if let stopWriteError = stopWriteError { throw stopWriteError }
        activeRecoveryURL = nil
        return SystemAudioTrackTechnicalInfo(durationSeconds: 3, codec: "linear PCM recovery", sampleRate: 48_000, channelCount: 2)
    }

    func finalizeRecovery(from recoveryURL: URL, to finalURL: URL, audioClockSpans: [AudioClockSpan]?) throws -> SystemAudioTrackTechnicalInfo {
        finalizeCalls += 1
        finalizedRecoveryIDs.append(recoveryURL.deletingLastPathComponent().lastPathComponent)
        if let finalizeError = finalizeError { throw finalizeError }
        try Data("compact system AAC frames".utf8).write(to: finalURL)
        return SystemAudioTrackTechnicalInfo(durationSeconds: 3, codec: "AAC in M4A", sampleRate: 48_000, channelCount: 2,
                                             audioClockSpans: audioClockSpans)
    }

    func stopAndFinalize(recoveryURL: URL, finalURL: URL) throws -> SystemAudioTrackTechnicalInfo {
        let stopped = try stopWritingRecovery(to: recoveryURL)
        return try finalizeRecovery(from: recoveryURL, to: finalURL, audioClockSpans: stopped.audioClockSpans)
    }

    func recover(recoveryURL: URL, finalURL: URL) throws -> SystemAudioTrackTechnicalInfo {
        try Data("recovered system AAC frames".utf8).write(to: finalURL)
        return SystemAudioTrackTechnicalInfo(durationSeconds: 3, codec: "AAC in M4A", sampleRate: 48_000, channelCount: 2)
    }
}

private final class FakeSystemAudioBackend: SystemAudioTrackRecordingBackend {
    var startError: Error?
    var stopError: Error?
    var lastScope: CaptureAudioScope?

    func startWritingRecovery(to recoveryURL: URL, scope: CaptureAudioScope) throws -> SystemAudioTrackTechnicalInfo {
        lastScope = scope
        if let startError = startError { throw startError }
        try Data("durable system PCM frames".utf8).write(to: recoveryURL)
        return SystemAudioTrackTechnicalInfo(durationSeconds: 0, codec: "linear PCM recovery", sampleRate: 48_000, channelCount: 2)
    }

    func stopAndFinalize(recoveryURL: URL, finalURL: URL) throws -> SystemAudioTrackTechnicalInfo {
        if let stopError = stopError { throw stopError }
        try Data("compact system AAC frames".utf8).write(to: finalURL)
        return SystemAudioTrackTechnicalInfo(durationSeconds: 15, codec: "AAC in M4A", sampleRate: 48_000, channelCount: 2)
    }

    func recover(recoveryURL: URL, finalURL: URL) throws -> SystemAudioTrackTechnicalInfo {
        try Data("recovered system AAC frames".utf8).write(to: finalURL)
        return SystemAudioTrackTechnicalInfo(durationSeconds: 15, codec: "AAC in M4A", sampleRate: 48_000, channelCount: 2)
    }
}

private final class SystemAudioRecordingFixture {
    let root: URL
    let startedAt = Date(timeIntervalSince1970: 1_789_724_800)

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("StillmatterSystemAudioTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func decodeMetadata(at path: String) throws -> SystemAudioTrackRecordingMetadata {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SystemAudioTrackRecordingMetadata.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }
}
