import XCTest
@testable import StillmatterCore

final class RecordingBundleTests: XCTestCase {
    func testNormalFinalizationPersistsValidatedDualTrackBundleWithHashesAndTechnicalMetadata() throws {
        let fixture = try RecordingBundleFixture()
        let mic = try fixture.micMetadata(status: .completed)
        let system = try fixture.systemMetadata(status: .completed)
        let finalizer = RecordingBundleFinalizer(now: { fixture.finalizedAt })

        let bundle = try finalizer.finalize(mic: mic, system: system, reason: .normalStop)

        XCTAssertEqual(bundle.state, .ready)
        XCTAssertEqual(bundle.reason, .normalStop)
        XCTAssertEqual(bundle.mic.preferredAudioFilePath, mic.finalFilePath)
        XCTAssertTrue(bundle.mic.finalFileExists)
        XCTAssertTrue(bundle.mic.recoveryFileExists)
        XCTAssertEqual(bundle.mic.codec, "AAC in M4A")
        XCTAssertEqual(bundle.mic.sampleRate, 48_000)
        XCTAssertEqual(bundle.mic.channelCount, 1)
        XCTAssertEqual(bundle.mic.durationSeconds, 12.5, accuracy: 0.001)
        XCTAssertEqual(bundle.mic.finalFileSHA256?.count, 64)
        XCTAssertEqual(bundle.system?.finalFileSHA256?.count, 64)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.bundleFilePath))
        XCTAssertNoThrow(try finalizer.validate(bundle))

        let stored = try fixture.decodeBundle(at: bundle.bundleFilePath)
        XCTAssertEqual(stored, bundle)
    }

    func testRecoveryFinalizationUsesRetainedAudioAndMarksPartialBundle() throws {
        let fixture = try RecordingBundleFixture()
        let mic = try fixture.micMetadata(status: .partial)
        try FileManager.default.removeItem(atPath: mic.finalFilePath)
        let system = try fixture.systemMetadata(status: .recovered)
        let finalizer = RecordingBundleFinalizer(now: { fixture.finalizedAt })

        let bundle = try finalizer.finalize(mic: mic, system: system, reason: .recovery)

        XCTAssertEqual(bundle.reason, .recovery)
        XCTAssertEqual(bundle.state, .partial)
        XCTAssertEqual(bundle.mic.preferredAudioFilePath, mic.recoveryFilePath)
        XCTAssertFalse(bundle.mic.finalFileExists)
        XCTAssertNotNil(bundle.mic.recoveryFileSHA256)
        XCTAssertEqual(bundle.system?.status, "recovered")
        XCTAssertNoThrow(try finalizer.validate(bundle))
    }

    func testValidationRejectsAudioChangedAfterBundleWasWritten() throws {
        let fixture = try RecordingBundleFixture()
        let mic = try fixture.micMetadata(status: .completed)
        let bundle = try RecordingBundleFinalizer().finalize(mic: mic, system: nil, reason: .normalStop)
        try Data("tampered".utf8).write(to: URL(fileURLWithPath: mic.finalFilePath))

        XCTAssertThrowsError(try RecordingBundleFinalizer().validate(bundle)) { error in
            XCTAssertEqual(error as? RecordingBundleError, .changedArtifact(mic.finalFilePath))
        }
    }

    func testFinalizationRejectsCompletedTrackWhoseAudioDoesNotExist() throws {
        let fixture = try RecordingBundleFixture()
        let mic = try fixture.micMetadata(status: .completed)
        try FileManager.default.removeItem(atPath: mic.finalFilePath)
        try FileManager.default.removeItem(atPath: mic.recoveryFilePath)

        XCTAssertThrowsError(
            try RecordingBundleFinalizer().finalize(mic: mic, system: nil, reason: .normalStop)
        ) { error in
            XCTAssertEqual(error as? RecordingBundleError, .missingMicrophoneAudio(mic.recoveryFilePath))
        }
    }
}

private final class RecordingBundleFixture {
    let root: URL
    let meetingPath = "Meetings/2026/09/18/09-30-sync/meeting.md"
    let startedAt = Date(timeIntervalSince1970: 1_789_724_800)
    let finalizedAt = Date(timeIntervalSince1970: 1_789_724_812)

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StillmatterRecordingBundleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func micMetadata(status: MicTrackRecordingStatus) throws -> MicTrackRecordingMetadata {
        let directory = try trackDirectory()
        let recovery = directory.appendingPathComponent("mic-recovery.caf")
        let final = directory.appendingPathComponent("mic.m4a")
        let metadata = directory.appendingPathComponent("mic-recording.json")
        try Data("mic recovery".utf8).write(to: recovery)
        try Data("mic final".utf8).write(to: final)
        try Data("{}".utf8).write(to: metadata)
        var value = MicTrackRecordingMetadata(
            captureSessionID: "capture-1",
            meetingRelativePath: meetingPath,
            recoveryFilePath: recovery.path,
            finalFilePath: final.path,
            metadataFilePath: metadata.path,
            startedAt: startedAt,
            sampleRate: 48_000,
            channelCount: 1,
            diagnostics: ["mic ok"]
        )
        value.status = status
        value.endedAt = finalizedAt
        value.durationSeconds = 12.5
        value.codec = "AAC in M4A"
        return value
    }

    func systemMetadata(status: SystemAudioTrackRecordingStatus) throws -> SystemAudioTrackRecordingMetadata {
        let directory = try trackDirectory()
        let recovery = directory.appendingPathComponent("system-recovery.caf")
        let final = directory.appendingPathComponent("system.m4a")
        let metadata = directory.appendingPathComponent("system-recording.json")
        try Data("system recovery".utf8).write(to: recovery)
        try Data("system final".utf8).write(to: final)
        try Data("{}".utf8).write(to: metadata)
        var value = SystemAudioTrackRecordingMetadata(
            captureSessionID: "capture-1",
            meetingRelativePath: meetingPath,
            recoveryFilePath: recovery.path,
            finalFilePath: final.path,
            metadataFilePath: metadata.path,
            startedAt: startedAt,
            sampleRate: 48_000,
            channelCount: 2,
            diagnostics: ["system ok"]
        )
        value.status = status
        value.endedAt = finalizedAt
        value.durationSeconds = 12.5
        value.codec = "AAC in M4A"
        return value
    }

    func decodeBundle(at path: String) throws -> RecordingBundle {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RecordingBundle.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    private func trackDirectory() throws -> URL {
        let directory = root.appendingPathComponent("Stillmatter Recordings/capture-1", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
