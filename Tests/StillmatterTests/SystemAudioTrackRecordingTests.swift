import XCTest
@testable import StillmatterCore

final class SystemAudioTrackRecordingTests: XCTestCase {
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

private final class FakeSystemAudioBackend: SystemAudioTrackRecordingBackend {
    var startError: Error?
    var stopError: Error?

    func startWritingRecovery(to recoveryURL: URL) throws -> SystemAudioTrackTechnicalInfo {
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
