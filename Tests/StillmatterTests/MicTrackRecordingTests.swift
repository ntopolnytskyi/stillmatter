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
