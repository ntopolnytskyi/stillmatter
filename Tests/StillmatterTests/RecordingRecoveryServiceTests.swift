import XCTest
@testable import StillmatterCore

final class RecordingRecoveryServiceTests: XCTestCase {
    func testRecoveryUpdatesMeetingAndQueuesValidatedBundle() throws {
        let fixture = try RecordingRecoveryFixture()
        let service = RecordingRecoveryService(
            vault: fixture.vault,
            jobStore: fixture.jobStore,
            bundleFinalizer: RecordingBundleFinalizer(now: { fixture.recoveredAt })
        )

        let result = try service.finalizeRecovered(mic: fixture.mic, system: fixture.system)

        XCTAssertEqual(result.bundle.reason, .recovery)
        XCTAssertEqual(result.bundle.state, .ready)
        XCTAssertEqual(result.job?.manifest.type, "meeting.transcription")
        XCTAssertEqual(result.job?.manifest.stages.map(\.id), ["transcribe"])
        XCTAssertEqual(
            result.job?.manifest.sourceArtifacts.first(where: { $0.role == "recording-bundle" })?.relativePath,
            result.bundle.bundleFilePath
        )
        XCTAssertEqual(result.job?.manifest.metadata["language"], "en")
        let meeting = try String(contentsOf: fixture.workspaceRoot.appendingPathComponent(fixture.meetingPath))
        XCTAssertTrue(meeting.contains("capture: recovered"))
        XCTAssertTrue(meeting.contains("Recovered recording bundle (`ready`)"))
        XCTAssertTrue(meeting.contains(result.bundle.bundleFilePath))
    }
}

private final class RecordingRecoveryFixture {
    let root: URL
    let workspaceRoot: URL
    let appSupportRoot: URL
    let meetingPath = "Meetings/2026/09/18/recovered/meeting.md"
    let recoveredAt = Date(timeIntervalSince1970: 1_789_724_900)
    let vault: WorkspaceVault
    let jobStore: JobStore
    let mic: MicTrackRecordingMetadata
    let system: SystemAudioTrackRecordingMetadata

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StillmatterRecordingRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        workspaceRoot = root.appendingPathComponent("Vault", isDirectory: true)
        appSupportRoot = root.appendingPathComponent("AppSupport", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appSupportRoot, withIntermediateDirectories: true)
        vault = WorkspaceVault(workspaceRootURL: workspaceRoot, appSupportRootURL: appSupportRoot)
        jobStore = try JobStore(databaseURL: appSupportRoot.appendingPathComponent("jobs.sqlite"))
        try vault.createDirectory(relativePath: "Meetings/2026/09/18/recovered")
        _ = try vault.writeMarkdown(Data("""
        ---
        schema_version: 1
        type: meeting
        title: Recovered meeting
        capture: placeholder
        ---
        # Recovered meeting

        ## Processing

        - [ ] Placeholder capture active

        ## Live notes

        - note retained
        """.utf8), relativePath: meetingPath, expectedVersion: nil)

        let media = root.appendingPathComponent("Media/Stillmatter Recordings/recovery-1", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let micRecovery = media.appendingPathComponent("mic-recovery.caf")
        let micFinal = media.appendingPathComponent("mic.m4a")
        let micMetadata = media.appendingPathComponent("mic-recording.json")
        let systemRecovery = media.appendingPathComponent("system-recovery.caf")
        let systemFinal = media.appendingPathComponent("system.m4a")
        let systemMetadata = media.appendingPathComponent("system-recording.json")
        try Data("mic recovery".utf8).write(to: micRecovery)
        try Data("mic recovered final".utf8).write(to: micFinal)
        try Data("{}".utf8).write(to: micMetadata)
        try Data("system recovery".utf8).write(to: systemRecovery)
        try Data("system recovered final".utf8).write(to: systemFinal)
        try Data("{}".utf8).write(to: systemMetadata)

        var mic = MicTrackRecordingMetadata(
            captureSessionID: "recovery-1",
            meetingRelativePath: meetingPath,
            recoveryFilePath: micRecovery.path,
            finalFilePath: micFinal.path,
            metadataFilePath: micMetadata.path,
            startedAt: recoveredAt.addingTimeInterval(-30),
            sampleRate: 48_000,
            channelCount: 1,
            diagnostics: ["Recovered mic"]
        )
        mic.status = .recovered
        mic.endedAt = recoveredAt
        mic.durationSeconds = 30
        mic.codec = "AAC in M4A"
        self.mic = mic

        var system = SystemAudioTrackRecordingMetadata(
            captureSessionID: "recovery-1",
            meetingRelativePath: meetingPath,
            recoveryFilePath: systemRecovery.path,
            finalFilePath: systemFinal.path,
            metadataFilePath: systemMetadata.path,
            startedAt: recoveredAt.addingTimeInterval(-30),
            sampleRate: 48_000,
            channelCount: 2,
            diagnostics: ["Recovered system audio"]
        )
        system.status = .recovered
        system.endedAt = recoveredAt
        system.durationSeconds = 30
        system.codec = "AAC in M4A"
        self.system = system
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}
