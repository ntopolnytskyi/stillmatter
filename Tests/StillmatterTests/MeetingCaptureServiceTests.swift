import XCTest
@testable import StillmatterCore

final class MeetingCaptureServiceTests: XCTestCase {
    func testGrantedCapturePermissionNeverRaisesAnotherRequest() {
        var requestCount = 0
        let gate = CapturePermissionRequestGate(
            hasAccess: { true },
            requestAccess: {
                requestCount += 1
                return true
            }
        )

        XCTAssertEqual(gate.resolve(), .granted)
        XCTAssertEqual(gate.resolve(), .granted)
        XCTAssertEqual(requestCount, 0)
    }

    func testMissingCapturePermissionRequestsOnceThenWaitsForSettings() {
        var granted = false
        var requestCount = 0
        let gate = CapturePermissionRequestGate(
            hasAccess: { granted },
            requestAccess: {
                requestCount += 1
                return false
            }
        )

        XCTAssertEqual(gate.resolve(), .denied)
        XCTAssertEqual(gate.resolve(), .denied)
        XCTAssertEqual(requestCount, 1)

        granted = true
        XCTAssertEqual(gate.resolve(), .granted)
        XCTAssertEqual(requestCount, 1)
    }

    func testFallbackCaptureQueuesRequiredTitleReviewOnlyAfterStop() throws {
        let fixture = try CaptureFixture()
        let inbox = try TasksInbox(databaseURL: fixture.appSupportRoot.appendingPathComponent("inbox.sqlite"))
        var now = fixture.now
        let service = fixture.service(now: { now }, inbox: inbox)
        let session = try service.startManual()
        XCTAssertTrue(try inbox.items(category: .required).isEmpty)
        now = now.addingTimeInterval(10 * 60)
        _ = try service.stopManual()
        let reviews = try inbox.items(category: .required)
        XCTAssertEqual(reviews.map(\.kind), [.titleReview])
        XCTAssertEqual(reviews.first?.sourceRef, session.meetingRelativePath)
        XCTAssertEqual(reviews.first?.title, "Untitled meeting 09:30-09:40")
    }

    func testManualStartCreatesDoorwayNoteAndEntersRecordingImmediately() throws {
        let fixture = try CaptureFixture()
        let service = fixture.service()

        let session = try service.startManual()

        XCTAssertEqual(service.snapshot.state, .recording)
        XCTAssertEqual(session.meetingRelativePath, "Meetings/2026/09/16/09-30-untitled-meeting/meeting.md")
        let markdown = try String(contentsOf: fixture.workspaceRoot.appendingPathComponent(session.meetingRelativePath))
        XCTAssertTrue(markdown.contains("title: Untitled Meeting at 2026-09-16 09:30"))
        XCTAssertTrue(markdown.contains("## Live notes"))
        XCTAssertTrue(markdown.contains("## Processing"))
    }

    func testPreflightCheckerReportsPermissionDeviceMediaAndCapacityBlockers() {
        let checker = AudioCapturePreflightChecker(
            microphoneAuthorization: { .denied },
            microphoneDeviceName: { nil },
            systemAudioItem: {
                AudioCapturePreflightItem(
                    id: "system-audio",
                    title: "System audio",
                    status: .degraded,
                    detail: "Microphone-only mode."
                )
            },
            mediaOutputURL: { URL(fileURLWithPath: "/tmp/media") },
            minimumAvailableBytes: 1_000,
            availableCapacity: { _ in 500 },
            writeProbe: { _ in }
        )

        let report = checker.check()

        XCTAssertFalse(report.canStart)
        XCTAssertEqual(report.items.map(\.id), [
            "microphone-permission", "microphone-device", "system-audio", "media-capacity"
        ])
        XCTAssertEqual(report.items.map(\.status), [.blocked, .blocked, .degraded, .blocked])
        XCTAssertEqual(report.items.first?.settingsAction, .openMicrophonePrivacy)
        XCTAssertEqual(report.items.last?.settingsAction, .freeDiskSpace)
    }

    func testPreflightCheckerReportsInaccessibleMediaAsASettingsBlocker() {
        let checker = AudioCapturePreflightChecker(
            microphoneAuthorization: { .authorized },
            microphoneDeviceName: { "External Microphone" },
            systemAudioItem: {
                AudioCapturePreflightItem(
                    id: "system-audio",
                    title: "System audio",
                    status: .degraded,
                    detail: "Microphone-only mode."
                )
            },
            mediaOutputURL: { URL(fileURLWithPath: "/read-only/media") },
            availableCapacity: { _ in 10_000_000_000 },
            writeProbe: { _ in throw CocoaError(.fileWriteNoPermission) }
        )

        let media = checker.check().items.last

        XCTAssertEqual(media?.status, .blocked)
        XCTAssertEqual(media?.settingsAction, .chooseMediaFolder)
        XCTAssertTrue(media?.detail.contains("cannot write") == true)
    }

    func testBlockedPreflightPreventsStartAndCreatesNoMeeting() throws {
        let fixture = try CaptureFixture()
        let report = AudioCapturePreflightReport(items: [
            AudioCapturePreflightItem(
                id: "microphone-permission",
                title: "Microphone permission",
                status: .blocked,
                detail: "Enable Stillmatter in System Settings > Privacy & Security > Microphone.",
                settingsAction: .openMicrophonePrivacy
            )
        ])
        let service = fixture.service(preflight: { report })

        XCTAssertThrowsError(try service.startManual()) { error in
            XCTAssertEqual(error as? CaptureError, .preflightFailed(report))
        }

        XCTAssertEqual(service.snapshot.state, .failed)
        XCTAssertEqual(service.snapshot.preflightReport, report)
        XCTAssertTrue(service.snapshot.failureMessage?.contains("Microphone permission") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.workspaceRoot.appendingPathComponent("Meetings").path))
    }

    func testCaptureCanRetryAfterTheUserFixesABlockedPreflight() throws {
        let fixture = try CaptureFixture()
        var report = AudioCapturePreflightReport(items: [
            AudioCapturePreflightItem(
                id: "media-output",
                title: "Media output",
                status: .blocked,
                detail: "Choose a recording media location in Settings.",
                settingsAction: .chooseMediaFolder
            )
        ])
        let service = fixture.service(preflight: { report })
        XCTAssertThrowsError(try service.startManual())
        report = .readyForTesting

        _ = try service.startManual()

        XCTAssertEqual(service.snapshot.state, .recording)
        XCTAssertNil(service.snapshot.failureMessage)
    }

    func testKnownSystemAudioDegradedModeDoesNotBlockMicrophoneCapture() throws {
        let fixture = try CaptureFixture()
        let report = AudioCapturePreflightReport(items: [
            .ready(id: "microphone", title: "Microphone", detail: "MacBook Microphone is ready."),
            AudioCapturePreflightItem(
                id: "system-audio",
                title: "System audio",
                status: .degraded,
                detail: "System audio is unavailable; capture will continue microphone-only."
            ),
            .ready(id: "media-output", title: "Media output", detail: "Media folder is writable with 10 GB available.")
        ])
        let micRecorder = SpyMicRecorder()
        let systemRecorder = SpySystemAudioRecorder()
        let service = fixture.service(
            micRecorder: micRecorder,
            systemAudioRecorder: systemRecorder,
            preflight: { report }
        )

        _ = try service.startManual()

        XCTAssertEqual(service.snapshot.state, .recording)
        XCTAssertEqual(service.snapshot.preflightReport, report)
        XCTAssertTrue(service.snapshot.preflightReport?.summary.contains("microphone-only") == true)
        XCTAssertNotNil(micRecorder.activeMetadata)
        XCTAssertEqual(systemRecorder.startCalls, 0, "Degraded preflight must not invoke ScreenCaptureKit")
    }

    func testLiveNotesAndActionsAppendThroughTheDoorwayNote() throws {
        let fixture = try CaptureFixture()
        let service = fixture.service()
        let session = try service.startManual()

        try service.appendLiveNote("Customer needs the export by Friday")
        try service.appendActionItem("Send the revised export")

        let markdown = try String(contentsOf: fixture.workspaceRoot.appendingPathComponent(session.meetingRelativePath))
        XCTAssertTrue(markdown.contains("- Customer needs the export by Friday"))
        XCTAssertTrue(markdown.contains("- [ ] Send the revised export"))
    }

    func testStopCreatesPlaceholderProcessingJobAndPublishesStoppingAndFinalizingStates() throws {
        let fixture = try CaptureFixture()
        let service = fixture.service()
        _ = try service.startManual()
        var observedStates: [CaptureState] = []
        service.observe { observedStates.append($0.state) }

        let job = try service.stopManual()

        XCTAssertEqual(observedStates.suffix(3), [.stopping, .finalizing, .idle])
        XCTAssertEqual(service.snapshot.state, .idle)
        XCTAssertEqual(job?.manifest.type, "meeting-capture-placeholder")
        XCTAssertEqual(job?.manifest.stages.map(\.id), ["finalize-placeholder", "prepare-processing"])
        XCTAssertEqual(job?.manifest.sourceArtifacts.first?.relativePath, service.snapshot.meetingRelativePath)
        let markdown = try String(contentsOf: fixture.workspaceRoot.appendingPathComponent(service.snapshot.meetingRelativePath!))
        XCTAssertTrue(markdown.contains("- [x] Placeholder capture finalized"))
        XCTAssertTrue(markdown.contains("- [ ] Audio finalization (available in a later capture ticket)"))
    }

    func testAsyncStopKeepsStateReadableAndRejectsDuplicateStopWhileFinalizing() throws {
        let fixture = try CaptureFixture()
        let recorder = PausedMicRecorder()
        let service = fixture.service(micRecorder: recorder)
        _ = try service.startManual()
        let finished = expectation(description: "finalization finished")
        var observedStates: [CaptureState] = []
        service.observe { observedStates.append($0.state) }

        service.stopManualAsync { result in
            XCTAssertTrue(Thread.isMainThread)
            if case let .failure(error) = result { XCTFail("Stop failed: \(error)") }
            finished.fulfill()
        }
        XCTAssertEqual(service.snapshot.state, .stopping)
        service.stopManualAsync { result in
            if case .success = result { XCTFail("Duplicate stop succeeded") }
        }
        recorder.resume.signal()
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(observedStates.suffix(3), [.stopping, .finalizing, .idle])
        XCTAssertEqual(service.snapshot.state, .idle)
    }

    func testRealMicRecorderIsStartedStoppedAndLinkedFromMeetingDoorway() throws {
        let fixture = try CaptureFixture()
        let recorder = SpyMicRecorder()
        let service = fixture.service(micRecorder: recorder)

        let session = try service.startManual()
        XCTAssertEqual(recorder.startSessionID, session.id)
        XCTAssertEqual(service.snapshot.micRecording?.status, .recording)

        _ = try service.stopManual()

        XCTAssertEqual(recorder.stopCalls, 1)
        XCTAssertEqual(service.snapshot.micRecording?.status, .completed)
        let markdown = try String(contentsOf: fixture.workspaceRoot.appendingPathComponent(session.meetingRelativePath))
        XCTAssertTrue(markdown.contains("Microphone track finalized"))
        XCTAssertTrue(markdown.contains("mic-recovery.caf"))
        XCTAssertTrue(markdown.contains("mic-recording.json"))
    }

    func testSystemAudioFailureDegradesCaptureWhileMicrophoneStillStartsAndFinalizes() throws {
        let fixture = try CaptureFixture()
        let micRecorder = SpyMicRecorder()
        let systemRecorder = SpySystemAudioRecorder()
        systemRecorder.startError = CocoaError(.userCancelled)
        let service = fixture.service(micRecorder: micRecorder, systemAudioRecorder: systemRecorder)

        let session = try service.startManual()

        XCTAssertEqual(service.snapshot.state, .recording)
        XCTAssertEqual(service.snapshot.systemAudioRecording?.status, .failed)
        XCTAssertTrue(service.snapshot.processingStatus.contains { $0.contains("microphone-only") })
        XCTAssertEqual(micRecorder.startSessionID, session.id)

        _ = try service.stopManual()

        XCTAssertEqual(micRecorder.stopCalls, 1)
        XCTAssertEqual(service.snapshot.micRecording?.status, .completed)
        let markdown = try String(contentsOf: fixture.workspaceRoot.appendingPathComponent(session.meetingRelativePath))
        XCTAssertTrue(markdown.contains("System audio unavailable"))
        XCTAssertTrue(markdown.contains("system-recording.json"))
    }

    func testSystemAudioFinalizationFailureDoesNotPreventMicrophoneFinalization() throws {
        let fixture = try CaptureFixture()
        let micRecorder = SpyMicRecorder()
        let systemRecorder = SpySystemAudioRecorder()
        systemRecorder.stopError = CocoaError(.fileWriteUnknown)
        let service = fixture.service(micRecorder: micRecorder, systemAudioRecorder: systemRecorder)
        let session = try service.startManual()

        _ = try service.stopManual()

        XCTAssertEqual(service.snapshot.state, .idle)
        XCTAssertEqual(service.snapshot.micRecording?.status, .completed)
        XCTAssertEqual(service.snapshot.systemAudioRecording?.status, .failed)
        XCTAssertTrue(service.snapshot.processingStatus.contains { $0.contains("microphone track remains available") })
        let markdown = try String(contentsOf: fixture.workspaceRoot.appendingPathComponent(session.meetingRelativePath))
        XCTAssertTrue(markdown.contains("System audio unavailable"))
    }

    func testSeparateSystemAudioTrackStartsStopsAndIsLinkedFromMeeting() throws {
        let fixture = try CaptureFixture()
        let micRecorder = SpyMicRecorder()
        let systemRecorder = SpySystemAudioRecorder()
        let service = fixture.service(micRecorder: micRecorder, systemAudioRecorder: systemRecorder)

        let session = try service.startManual()
        XCTAssertEqual(service.snapshot.systemAudioRecording?.status, .recording)

        _ = try service.stopManual()

        XCTAssertEqual(systemRecorder.stopCalls, 1)
        XCTAssertEqual(service.snapshot.systemAudioRecording?.status, .completed)
        let markdown = try String(contentsOf: fixture.workspaceRoot.appendingPathComponent(session.meetingRelativePath))
        XCTAssertTrue(markdown.contains("System audio track finalized"))
        XCTAssertTrue(markdown.contains("system-recovery.caf"))
        XCTAssertTrue(markdown.contains("system-recording.json"))
    }

    func testStopPublishesCanonicalBundleAndQueuesItForProcessing() throws {
        let fixture = try CaptureFixture()
        let mediaRoot = fixture.root.appendingPathComponent("Media", isDirectory: true)
        let micRecorder = SpyMicRecorder(mediaRoot: mediaRoot)
        let systemRecorder = SpySystemAudioRecorder(mediaRoot: mediaRoot)
        let finalizer = RecordingBundleFinalizer(now: { fixture.now.addingTimeInterval(2) })
        let service = fixture.service(
            micRecorder: micRecorder,
            systemAudioRecorder: systemRecorder,
            bundleFinalizer: finalizer
        )
        service.setTranscriptionLanguage(.ukrainian)
        let session = try service.startManual(titleHint: "Bundle handoff")

        let job = try service.stopManual()

        let bundle = try XCTUnwrap(service.snapshot.recordingBundle)
        XCTAssertEqual(bundle.state, .ready)
        XCTAssertEqual(bundle.captureSessionID, session.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.bundleFilePath))
        XCTAssertEqual(job?.manifest.type, "meeting.transcription")
        XCTAssertEqual(job?.manifest.executionClass, .heavy)
        XCTAssertEqual(job?.manifest.stages.map(\.id), ["transcribe"])
        XCTAssertEqual(
            job?.manifest.sourceArtifacts.first(where: { $0.role == "recording-bundle" })?.relativePath,
            bundle.bundleFilePath
        )
        XCTAssertEqual(job?.manifest.sourceArtifacts.last?.role, "transcription-system-audio")
        XCTAssertEqual(job?.manifest.metadata["recording_bundle_path"], bundle.bundleFilePath)
        XCTAssertEqual(job?.manifest.metadata["language"], "uk")
        XCTAssertEqual(Set(job?.manifest.expectedOutputs.map(\.validatorID) ?? []), ["markdown", "json", "webvtt"])
        let regenerated = try service.regenerateTranscript(language: .english)
        XCTAssertEqual(regenerated.manifest.metadata["language"], "en")
        XCTAssertTrue(service.snapshot.processingStatus.last?.contains("regeneration queued in English") == true)
        let markdown = try String(contentsOf: fixture.workspaceRoot.appendingPathComponent(session.meetingRelativePath))
        XCTAssertTrue(markdown.contains("capture: finalized"))
        XCTAssertTrue(markdown.contains("Recording bundle (`ready`)"))
        XCTAssertTrue(markdown.contains(bundle.bundleFilePath))
    }

    func testStateMachineCoversDetectionFailureAndRecovery() throws {
        var machine = CaptureStateMachine()

        try machine.apply(.detectionStarted)
        XCTAssertEqual(machine.state, .detecting)
        try machine.apply(.startRequested)
        XCTAssertEqual(machine.state, .starting)
        try machine.apply(.captureStarted)
        XCTAssertEqual(machine.state, .recording)
        try machine.apply(.failed("Device disconnected"))
        XCTAssertEqual(machine.state, .failed)
        XCTAssertEqual(machine.failureMessage, "Device disconnected")
        try machine.apply(.recovered)
        XCTAssertEqual(machine.state, .recovered)
        try machine.apply(.reset)
        XCTAssertEqual(machine.state, .idle)
    }

    func testElapsedTimeStopsAdvancingWhenCaptureStops() throws {
        let fixture = try CaptureFixture()
        var now = fixture.now
        let service = fixture.service(now: { now })
        _ = try service.startManual()
        now = now.addingTimeInterval(125)

        XCTAssertEqual(service.snapshot.elapsedSeconds, 125)
        _ = try service.stopManual()
        now = now.addingTimeInterval(60)

        XCTAssertEqual(service.snapshot.elapsedSeconds, 125)
    }
}

private final class CaptureFixture {
    let root: URL
    let workspaceRoot: URL
    let appSupportRoot: URL
    let now = Date(timeIntervalSince1970: 1_789_551_000) // 2026-09-16 09:30 UTC
    private let jobStore: JobStore

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("StillmatterCaptureTests-\(UUID().uuidString)", isDirectory: true)
        workspaceRoot = root.appendingPathComponent("Vault", isDirectory: true)
        appSupportRoot = root.appendingPathComponent("AppSupport", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appSupportRoot, withIntermediateDirectories: true)
        jobStore = try JobStore(databaseURL: appSupportRoot.appendingPathComponent("jobs.sqlite"), now: { "2026-09-16T09:30:00Z" })
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func service(
        now suppliedNow: (() -> Date)? = nil,
        micRecorder: MicTrackRecordingManaging? = nil,
        systemAudioRecorder: SystemAudioTrackRecordingManaging? = nil,
        bundleFinalizer: RecordingBundleFinalizing? = nil,
        inbox: TasksInbox? = nil,
        preflight: @escaping () -> AudioCapturePreflightReport = { .readyForTesting }
    ) -> MeetingCaptureService {
        MeetingCaptureService(
            vault: WorkspaceVault(workspaceRootURL: workspaceRoot, appSupportRootURL: appSupportRoot),
            jobStore: jobStore,
            inbox: inbox,
            micRecorder: micRecorder,
            systemAudioRecorder: systemAudioRecorder,
            bundleFinalizer: bundleFinalizer,
            preflight: preflight,
            now: suppliedNow ?? { self.now },
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
    }
}

private final class SpySystemAudioRecorder: SystemAudioTrackRecordingManaging {
    private let mediaRoot: URL?
    private(set) var activeMetadata: SystemAudioTrackRecordingMetadata?
    private(set) var latestMetadata: SystemAudioTrackRecordingMetadata?
    var startError: Error?
    var stopError: Error?
    private(set) var startCalls = 0
    private(set) var stopCalls = 0

    init(mediaRoot: URL? = nil) {
        self.mediaRoot = mediaRoot
    }

    func start(sessionID: String, meetingRelativePath: String, startedAt: Date) throws -> SystemAudioTrackRecordingMetadata {
        startCalls += 1
        let directory = mediaRoot?.appendingPathComponent("Stillmatter Recordings/\(sessionID)", isDirectory: true)
        if let directory = directory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("system recovery".utf8).write(to: directory.appendingPathComponent("system-recovery.caf"))
            try Data("{}".utf8).write(to: directory.appendingPathComponent("system-recording.json"))
        }
        var metadata = SystemAudioTrackRecordingMetadata(
            captureSessionID: sessionID,
            meetingRelativePath: meetingRelativePath,
            recoveryFilePath: directory?.appendingPathComponent("system-recovery.caf").path ?? "/media/\(sessionID)/system-recovery.caf",
            finalFilePath: directory?.appendingPathComponent("system.m4a").path ?? "/media/\(sessionID)/system.m4a",
            metadataFilePath: directory?.appendingPathComponent("system-recording.json").path ?? "/media/\(sessionID)/system-recording.json",
            startedAt: startedAt,
            sampleRate: 48_000,
            channelCount: 2
        )
        if let startError = startError {
            metadata.status = .failed
            metadata.diagnostics = ["System capture unavailable: \(startError)"]
            latestMetadata = metadata
            throw startError
        }
        activeMetadata = metadata
        latestMetadata = metadata
        return metadata
    }

    func stop(endedAt: Date) throws -> SystemAudioTrackRecordingMetadata {
        stopCalls += 1
        var metadata = activeMetadata!
        metadata.endedAt = endedAt
        if let stopError = stopError {
            metadata.status = .failed
            metadata.diagnostics.append("System finalization failed: \(stopError)")
            activeMetadata = nil
            latestMetadata = metadata
            throw stopError
        }
        metadata.status = .completed
        metadata.durationSeconds = 2
        metadata.codec = "AAC in M4A"
        if mediaRoot != nil {
            try Data("system final".utf8).write(to: URL(fileURLWithPath: metadata.finalFilePath))
        }
        activeMetadata = nil
        latestMetadata = metadata
        return metadata
    }
}

private final class PausedMicRecorder: MicTrackRecordingManaging {
    private let underlying = SpyMicRecorder()
    let resume = DispatchSemaphore(value: 0)
    var activeMetadata: MicTrackRecordingMetadata? { underlying.activeMetadata }
    var latestMetadata: MicTrackRecordingMetadata? { underlying.activeMetadata }

    func start(sessionID: String, meetingRelativePath: String, startedAt: Date) throws -> MicTrackRecordingMetadata {
        try underlying.start(sessionID: sessionID, meetingRelativePath: meetingRelativePath, startedAt: startedAt)
    }

    func stop(endedAt: Date) throws -> MicTrackRecordingMetadata {
        resume.wait()
        return try underlying.stop(endedAt: endedAt)
    }
}

private final class SpyMicRecorder: MicTrackRecordingManaging {
    private let mediaRoot: URL?
    private(set) var activeMetadata: MicTrackRecordingMetadata?
    private(set) var startSessionID: String?
    private(set) var stopCalls = 0

    init(mediaRoot: URL? = nil) {
        self.mediaRoot = mediaRoot
    }

    func start(sessionID: String, meetingRelativePath: String, startedAt: Date) throws -> MicTrackRecordingMetadata {
        startSessionID = sessionID
        let directory = mediaRoot?.appendingPathComponent("Stillmatter Recordings/\(sessionID)", isDirectory: true)
        if let directory = directory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("mic recovery".utf8).write(to: directory.appendingPathComponent("mic-recovery.caf"))
            try Data("{}".utf8).write(to: directory.appendingPathComponent("mic-recording.json"))
        }
        let metadata = MicTrackRecordingMetadata(
            captureSessionID: sessionID,
            meetingRelativePath: meetingRelativePath,
            recoveryFilePath: directory?.appendingPathComponent("mic-recovery.caf").path ?? "/media/\(sessionID)/mic-recovery.caf",
            finalFilePath: directory?.appendingPathComponent("mic.m4a").path ?? "/media/\(sessionID)/mic.m4a",
            metadataFilePath: directory?.appendingPathComponent("mic-recording.json").path ?? "/media/\(sessionID)/mic-recording.json",
            startedAt: startedAt,
            sampleRate: 48_000,
            channelCount: 1
        )
        activeMetadata = metadata
        return metadata
    }

    func stop(endedAt: Date) throws -> MicTrackRecordingMetadata {
        stopCalls += 1
        var metadata = activeMetadata!
        metadata.endedAt = endedAt
        metadata.status = .completed
        metadata.durationSeconds = 2
        metadata.codec = "AAC in M4A"
        if mediaRoot != nil {
            try Data("mic final".utf8).write(to: URL(fileURLWithPath: metadata.finalFilePath))
        }
        activeMetadata = nil
        return metadata
    }
}
