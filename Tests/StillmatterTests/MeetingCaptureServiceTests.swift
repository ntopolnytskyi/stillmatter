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
        var idlePublishedAfterReview = false
        service.observe { snapshot in
            if snapshot.state == .idle && snapshot.meetingRelativePath != nil {
                idlePublishedAfterReview = (try? inbox.items(category: .required).contains { $0.kind == .titleReview }) == true
            }
        }
        let session = try service.startManual()
        XCTAssertTrue(try inbox.items(category: .required).isEmpty)
        now = now.addingTimeInterval(10 * 60)
        _ = try service.stopManual()
        let reviews = try inbox.items(category: .required)
        XCTAssertEqual(reviews.map(\.kind), [.titleReview])
        XCTAssertEqual(reviews.first?.sourceRef, session.meetingRelativePath)
        XCTAssertEqual(reviews.first?.title, "Untitled meeting 09:30-09:40")
        XCTAssertTrue(idlePublishedAfterReview, "Idle must not expose a workspace switch before title review is persisted")
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

    func testSystemSourceFailureDuringCapturePublishesDegradedSnapshotAndRetainsMicrophone() throws {
        let fixture = try CaptureFixture()
        let mic = SpyMicRecorder()
        let system = SpySystemAudioRecorder()
        let service = fixture.service(micRecorder: mic, systemAudioRecorder: system)
        var snapshots: [CaptureSnapshot] = []
        let degradedExpectation = expectation(description: "degraded capture snapshot")
        service.observe {
            snapshots.append($0)
            if $0.systemAudioRecording?.status == .failed { degradedExpectation.fulfill() }
        }

        let session = try service.startManual(source: .zoom)
        system.reportFailure("source device disconnected")
        wait(for: [degradedExpectation], timeout: 2)

        let degraded = try XCTUnwrap(snapshots.last)
        XCTAssertEqual(degraded.state, .recording)
        XCTAssertEqual(degraded.source, .zoom)
        XCTAssertEqual(degraded.micRecording?.captureSessionID, session.id)
        XCTAssertEqual(degraded.systemAudioRecording?.status, .failed)
        XCTAssertTrue(degraded.systemAudioRecording?.diagnostics.contains(where: { $0.contains("source device disconnected") }) == true)
        XCTAssertTrue(degraded.processingStatus.contains(where: { $0.contains("microphone-only") }))
    }

    func testLiveNotesRejectMalformedMeetingMarkdown() throws {
        let fixture = try CaptureFixture()
        let service = fixture.service()
        let session = try service.startManual()
        let meetingURL = fixture.workspaceRoot.appendingPathComponent(session.meetingRelativePath)
        try Data([0xFF, 0xFE]).write(to: meetingURL)

        XCTAssertThrowsError(try service.appendLiveNote("note"))
        XCTAssertThrowsError(try service.appendActionItem("action"))
    }

    func testCorruptDoorwayOnStopRetainsOriginalBytesAndReleasedAudioForRecovery() throws {
        let fixture = try CaptureFixture()
        let recorder = SpyMicRecorder(mediaRoot: fixture.root.appendingPathComponent("Media"))
        let service = fixture.service(micRecorder: recorder)
        let first = try service.startManual(titleHint: "Session A")
        let doorway = fixture.workspaceRoot.appendingPathComponent(first.meetingRelativePath)
        let invalidMarkdown = Data([0xFF, 0xFE])
        try invalidMarkdown.write(to: doorway)

        XCTAssertThrowsError(try service.stopManual())

        XCTAssertEqual(try Data(contentsOf: doorway), invalidMarkdown)
        XCTAssertEqual(service.snapshot.state, .idle, "The source stopped even though the doorway cannot be updated")
        XCTAssertEqual(service.snapshot.priorCaptureFinalizations.map(\.sessionID), [first.id])
        guard case .failed = service.snapshot.priorCaptureFinalizations[0].state else {
            return XCTFail("The first Meeting's finalization failure must remain visible")
        }
        let recovery = fixture.root.appendingPathComponent("Media/Stillmatter Recordings/\(first.id)/mic-recovery.caf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovery.path))
        let second = try service.startManual(titleHint: "Session B")
        XCTAssertNotEqual(second.meetingRelativePath, first.meetingRelativePath)
    }

    func testMicrophoneInputReleaseFailureLeavesCaptureRecoverableAndOutOfStopping() throws {
        let fixture = try CaptureFixture()
        let recorder = SpyMicRecorder(mediaRoot: fixture.appSupportRoot)
        recorder.stopError = CocoaError(.fileWriteUnknown)
        let service = fixture.service(micRecorder: recorder)
        let session = try service.startManual()

        XCTAssertThrowsError(try service.stopManual())

        XCTAssertEqual(service.snapshot.state, .failed)
        XCTAssertEqual(service.snapshot.meetingRelativePath, session.meetingRelativePath)
        XCTAssertEqual(service.snapshot.micRecording?.status, .failed)
        XCTAssertEqual(service.snapshot.priorCaptureFinalizations.map(\.sessionID), [session.id])
        guard case .failed = service.snapshot.priorCaptureFinalizations[0].state else {
            return XCTFail("Failed source release must remain visible for the original session")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: service.snapshot.micRecording!.recoveryFilePath))
    }

    func testStopCreatesPlaceholderProcessingJobAndPublishesStoppingAndFinalizingStates() throws {
        let fixture = try CaptureFixture()
        let service = fixture.service()
        _ = try service.startManual()
        var observedStates: [CaptureState] = []
        service.observe { observedStates.append($0.state) }

        let job = try service.stopManual()

        XCTAssertEqual(observedStates.suffix(3), [.stopping, .idle, .idle])
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
        XCTAssertEqual(service.snapshot.state, .idle)
        service.stopManualAsync { result in
            if case .success = result { XCTFail("Duplicate stop succeeded") }
        }
        recorder.resume.signal()
        wait(for: [finished], timeout: 5)
        XCTAssertTrue(observedStates.contains(.stopping))
        XCTAssertEqual(observedStates.last, .idle)
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

    func testManualMeetSelectionPersistsAllSystemScopeWithoutChangingMicrophone() throws {
        let fixture = try CaptureFixture()
        let mic = SpyMicRecorder()
        let system = SpySystemAudioRecorder()
        let service = fixture.service(micRecorder: mic, systemAudioRecorder: system)
        let session = try service.startManual(titleHint: "Meet", source: .meet)
        XCTAssertEqual(service.snapshot.source, .meet)
        XCTAssertEqual(mic.startSessionID, session.id)
        XCTAssertEqual(service.snapshot.systemAudioRecording?.scope, .allSystemAudio)
        let markdown = try String(contentsOf: fixture.workspaceRoot.appendingPathComponent(session.meetingRelativePath))
        XCTAssertTrue(markdown.contains("meeting_source: meet"))
        XCTAssertTrue(markdown.contains("audio_scope: allSystemAudio"))
        _ = try service.stopManual()
    }

    func testSelectedMicrophoneAndSystemTracksShareSessionIdentityAndTiming() throws {
        let fixture = try CaptureFixture()
        let service = fixture.service(micRecorder: SpyMicRecorder(), systemAudioRecorder: SpySystemAudioRecorder())
        let session = try service.startManual(source: .teams)
        let activeMic = try XCTUnwrap(service.snapshot.micRecording)
        let activeSystem = try XCTUnwrap(service.snapshot.systemAudioRecording)

        XCTAssertEqual(activeMic.captureSessionID, session.id)
        XCTAssertEqual(activeSystem.captureSessionID, session.id)
        XCTAssertEqual(activeMic.meetingRelativePath, session.meetingRelativePath)
        XCTAssertEqual(activeSystem.meetingRelativePath, session.meetingRelativePath)
        XCTAssertEqual(activeMic.startedAt, activeSystem.startedAt)
        XCTAssertEqual(activeSystem.source, .teams)
        XCTAssertEqual(activeSystem.scope, .teamsApplication)

        _ = try service.stopManual()
        XCTAssertEqual(service.snapshot.micRecording?.endedAt, service.snapshot.systemAudioRecording?.endedAt)
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

    func testUnconfirmedSystemStopPreventsAnotherCaptureAndRetainsFailureEvidence() throws {
        let fixture = try CaptureFixture()
        let micRecorder = SpyMicRecorder()
        let systemRecorder = SpySystemAudioRecorder()
        systemRecorder.stopError = CocoaError(.fileWriteUnknown)
        let service = fixture.service(micRecorder: micRecorder, systemAudioRecorder: systemRecorder)
        let session = try service.startManual()

        XCTAssertThrowsError(try service.stopManual())
        XCTAssertEqual(micRecorder.stopCalls, 1)
        XCTAssertEqual(service.snapshot.state, .failed)
        XCTAssertEqual(service.snapshot.systemAudioRecording?.status, .failed)
        XCTAssertThrowsError(try service.startManual()) { error in
            XCTAssertEqual(error as? CaptureError, .sourceStopUnconfirmed)
            XCTAssertTrue(String(describing: error).contains("previous audio source has not been confirmed stopped"))
        }
        let markdown = try String(contentsOf: fixture.workspaceRoot.appendingPathComponent(session.meetingRelativePath))
        XCTAssertTrue(markdown.contains("Capture input could not be confirmed stopped"))
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

    func testBackgroundSystemAudioFinalizationFailureIsReportedWithoutLosingMicrophone() throws {
        let fixture = try CaptureFixture()
        let micRecorder = SpyMicRecorder()
        let systemRecorder = SpySystemAudioRecorder()
        systemRecorder.splitFinalization = true
        systemRecorder.finalizeError = CocoaError(.fileWriteUnknown)
        let service = fixture.service(micRecorder: micRecorder, systemAudioRecorder: systemRecorder)
        _ = try service.startManual()

        _ = try service.stopManual()

        XCTAssertEqual(service.snapshot.micRecording?.status, .completed)
        XCTAssertEqual(service.snapshot.systemAudioRecording?.status, .failed)
        XCTAssertTrue(service.snapshot.processingStatus.contains { $0.contains("microphone track remains available") })
    }

    func testBackgroundSystemAudioSuccessPublishesFinalizedTrackStatus() throws {
        let fixture = try CaptureFixture()
        let systemRecorder = SpySystemAudioRecorder()
        systemRecorder.splitFinalization = true
        let service = fixture.service(micRecorder: SpyMicRecorder(), systemAudioRecorder: systemRecorder)
        _ = try service.startManual()

        _ = try service.stopManual()

        XCTAssertEqual(service.snapshot.systemAudioRecording?.status, .completed)
        XCTAssertTrue(service.snapshot.processingStatus.contains("Separate system audio finalized (AAC)"))
        XCTAssertTrue(service.snapshot.processingStatus.contains("System-audio recovery/preview retained"))
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
        XCTAssertEqual(job?.manifest.type, MeetingWorkflowJob.type)
        XCTAssertEqual(job?.manifest.executionClass, .heavy)
        XCTAssertEqual(job?.manifest.stages.map(\.id), ["transcribe", MeetingSummaryJob.stageID])
        XCTAssertEqual(
            job?.manifest.sourceArtifacts.first(where: { $0.role == "recording-bundle" })?.relativePath,
            bundle.bundleFilePath
        )
        XCTAssertTrue(job?.manifest.sourceArtifacts.contains(where: { $0.role == "transcription-system-audio" }) == true)
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

        let recovery = RecordingRecoveryService(
            vault: WorkspaceVault(workspaceRootURL: fixture.workspaceRoot, appSupportRootURL: fixture.appSupportRoot),
            jobStore: fixture.jobStoreForTests,
            bundleFinalizer: finalizer
        )
        let mic = try XCTUnwrap(service.snapshot.micRecording)
        let recoveredOnce = try recovery.finalizeRecovered(mic: mic, system: nil)
        let recoveredAgain = try recovery.finalizeRecovered(mic: mic, system: nil)
        XCTAssertEqual(recoveredOnce.job?.id, recoveredAgain.job?.id)
        XCTAssertEqual(try fixture.jobStoreForTests.jobs().filter { $0.id == recoveredOnce.job?.id }.count, 1,
                       "Restart recovery reuses the normal capture handoff's durable Job intent")
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

    func testLateTitleReviewForPriorMeetingCannotRenameCurrentCapture() throws {
        let fixture = try CaptureFixture()
        let service = fixture.service()
        let first = try service.startManual(titleHint: "Session A")
        _ = try service.stopManual()
        let second = try service.startManual(titleHint: "Session B")

        service.titleReviewAccepted(meetingRelativePath: first.meetingRelativePath,
            title: "Renamed A", newPath: "Meetings/2026/09/16/renamed-a/meeting.md")
        try service.appendLiveNote("B note after A's late title review")

        XCTAssertEqual(service.snapshot.meetingRelativePath, second.meetingRelativePath)
        XCTAssertEqual(service.snapshot.meetingTitle, second.title)
        let secondMarkdown = try String(contentsOf: fixture.workspaceRoot.appendingPathComponent(second.meetingRelativePath))
        XCTAssertTrue(secondMarkdown.contains("B note after A's late title review"))
        let firstMarkdown = try String(contentsOf: fixture.workspaceRoot.appendingPathComponent(first.meetingRelativePath))
        XCTAssertFalse(firstMarkdown.contains("B note after A's late title review"))
    }

    func testAcceptedTitleReviewFollowsRenamedActiveMeetingForSubsequentNotes() throws {
        let fixture = try CaptureFixture()
        let service = fixture.service()
        let session = try service.startManual(titleHint: "Original")
        let renamedPath = session.meetingRelativePath.replacingOccurrences(of: "original/meeting.md", with: "renamed/meeting.md")
        let oldFolder = fixture.workspaceRoot.appendingPathComponent(session.meetingRelativePath).deletingLastPathComponent()
        let newFolder = fixture.workspaceRoot.appendingPathComponent(renamedPath).deletingLastPathComponent()
        try FileManager.default.moveItem(at: oldFolder, to: newFolder)

        service.titleReviewAccepted(meetingRelativePath: session.meetingRelativePath,
            title: "Renamed", newPath: renamedPath)
        try service.appendLiveNote("Note after accepted rename")

        XCTAssertEqual(service.snapshot.meetingTitle, "Renamed")
        XCTAssertEqual(service.snapshot.meetingRelativePath, renamedPath)
        XCTAssertTrue(try String(contentsOf: fixture.workspaceRoot.appendingPathComponent(renamedPath))
            .contains("Note after accepted rename"))
    }

    func testNextCaptureStartsWhilePriorBundleFinalizationIsHeldAndLateCallbacksStayOwned() throws {
        let fixture = try CaptureFixture()
        let micRecorder = SpyMicRecorder(mediaRoot: fixture.root.appendingPathComponent("Media"))
        let bundleFinalizer = BlockingBundleFinalizer(blockFirstCall: true)
        let service = fixture.service(micRecorder: micRecorder, bundleFinalizer: bundleFinalizer)
        let first = try service.startManual(titleHint: "Session A")
        try service.appendLiveNote("A note")
        let firstStopped = DispatchSemaphore(value: 0)
        service.stopManualAsync { _ in firstStopped.signal() }

        XCTAssertEqual(service.snapshot.state, .idle, "Capture controls become available as soon as the source has stopped")
        XCTAssertEqual(bundleFinalizer.entered.wait(timeout: .now() + 5), .success)
        let second = try service.startManual(titleHint: "Session B")
        try service.appendLiveNote("B note")
        let secondStopped = DispatchSemaphore(value: 0)
        var secondStopSucceeded = false
        service.stopManualAsync { result in
            if case .success = result { secondStopSucceeded = true }
            secondStopped.signal()
        }

        XCTAssertTrue(waitForMainCallback(secondStopped))
        XCTAssertTrue(secondStopSucceeded)
        XCTAssertEqual(service.snapshot.state, .idle)
        XCTAssertEqual(service.snapshot.meetingRelativePath, second.meetingRelativePath)
        XCTAssertEqual(service.snapshot.micRecording?.captureSessionID, second.id)

        bundleFinalizer.resume.signal()
        XCTAssertTrue(waitForMainCallback(firstStopped))

        let firstText = try String(contentsOf: fixture.workspaceRoot.appendingPathComponent(first.meetingRelativePath))
        let secondText = try String(contentsOf: fixture.workspaceRoot.appendingPathComponent(second.meetingRelativePath))
        XCTAssertTrue(firstText.contains("A note"))
        XCTAssertFalse(firstText.contains("B note"))
        XCTAssertTrue(secondText.contains("B note"))
        XCTAssertFalse(secondText.contains("A note"))
        XCTAssertEqual(try fixture.jobStoreForTests.jobs().filter { $0.manifest.metadata["capture_session_id"] == first.id }.count, 1)
        XCTAssertEqual(try fixture.jobStoreForTests.jobs().filter { $0.manifest.metadata["capture_session_id"] == second.id }.count, 1)
        XCTAssertEqual(service.snapshot.meetingRelativePath, second.meetingRelativePath, "A late A callback cannot replace B's current session")
    }

    func testLateFinalizationFailureIsRecordedForAWithoutFailingActiveB() throws {
        let fixture = try CaptureFixture()
        let mediaRoot = fixture.root.appendingPathComponent("Media")
        let micRecorder = SpyMicRecorder(mediaRoot: mediaRoot)
        let bundleFinalizer = BlockingBundleFinalizer(blockFirstCall: true, failFirstCall: true)
        let service = fixture.service(micRecorder: micRecorder, bundleFinalizer: bundleFinalizer)
        let first = try service.startManual(titleHint: "Session A")
        try service.appendLiveNote("A note survives")
        let firstCompletion = DispatchSemaphore(value: 0)
        var firstFailed = false
        service.stopManualAsync { result in
            if case .failure = result { firstFailed = true }
            firstCompletion.signal()
        }
        XCTAssertEqual(bundleFinalizer.entered.wait(timeout: .now() + 5), .success)

        let second = try service.startManual(titleHint: "Session B")
        XCTAssertEqual(service.snapshot.state, .recording)
        try service.appendLiveNote("B remains active")
        bundleFinalizer.resume.signal()

        XCTAssertTrue(waitForMainCallback(firstCompletion))
        XCTAssertTrue(firstFailed)
        XCTAssertEqual(service.snapshot.state, .recording)
        XCTAssertNil(service.snapshot.failureMessage, "A's late failure must not become B's failure")
        XCTAssertEqual(service.snapshot.meetingRelativePath, second.meetingRelativePath)

        let firstText = try String(contentsOf: fixture.workspaceRoot.appendingPathComponent(first.meetingRelativePath))
        XCTAssertTrue(firstText.contains("A note survives"))
        XCTAssertTrue(firstText.contains("audio evidence retained"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: mediaRoot.appendingPathComponent("Stillmatter Recordings/\(first.id)/mic-recovery.caf").path))
        XCTAssertTrue(try String(contentsOf: fixture.workspaceRoot.appendingPathComponent(second.meetingRelativePath)).contains("B remains active"))
    }

    private func waitForMainCallback(_ semaphore: DispatchSemaphore, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if semaphore.wait(timeout: .now()) == .success { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return semaphore.wait(timeout: .now()) == .success
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

private final class BlockingBundleFinalizer: RecordingBundleFinalizing {
    private let delegate = RecordingBundleFinalizer()
    private let lock = NSLock()
    private var shouldBlockFirstCall: Bool
    private var shouldFailFirstCall: Bool
    let entered = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)

    init(blockFirstCall: Bool, failFirstCall: Bool = false) {
        shouldBlockFirstCall = blockFirstCall
        shouldFailFirstCall = failFirstCall
    }

    func finalize(
        mic: MicTrackRecordingMetadata,
        system: SystemAudioTrackRecordingMetadata?,
        reason: RecordingBundleFinalizationReason
    ) throws -> RecordingBundle {
        lock.lock()
        let shouldBlock = shouldBlockFirstCall
        let shouldFail = shouldFailFirstCall
        shouldBlockFirstCall = false
        shouldFailFirstCall = false
        lock.unlock()
        if shouldBlock {
            entered.signal()
            resume.wait()
        }
        if shouldFail { throw CocoaError(.fileWriteUnknown) }
        return try delegate.finalize(mic: mic, system: system, reason: reason)
    }

    func validate(_ bundle: RecordingBundle) throws {
        try delegate.validate(bundle)
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

    var jobStoreForTests: JobStore { jobStore }

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
    var splitFinalization = false
    var finalizeError: Error?
    private(set) var startCalls = 0
    private(set) var stopCalls = 0
    private var failureHandler: ((SystemAudioTrackRecordingMetadata) -> Void)?

    func setCaptureFailureHandler(_ handler: ((SystemAudioTrackRecordingMetadata) -> Void)?) {
        failureHandler = handler
    }

    func reportFailure(_ message: String) {
        guard var metadata = activeMetadata else { return }
        metadata.status = .failed
        metadata.diagnostics.append(message)
        latestMetadata = metadata
        failureHandler?(metadata)
    }

    init(mediaRoot: URL? = nil) {
        self.mediaRoot = mediaRoot
    }

    func start(sessionID: String, meetingRelativePath: String, startedAt: Date,
               source: CaptureAudioSource) throws -> SystemAudioTrackRecordingMetadata {
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
            source: source, scope: source.scope,
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

    func releaseForFinalization(endedAt: Date) throws -> SystemAudioTrackRecordingMetadata {
        guard splitFinalization else { return try stop(endedAt: endedAt) }
        stopCalls += 1
        var metadata = activeMetadata!
        metadata.endedAt = endedAt
        metadata.status = .finalizing
        activeMetadata = nil
        latestMetadata = metadata
        return metadata
    }

    func finalizeReleased(_ released: SystemAudioTrackRecordingMetadata) throws -> SystemAudioTrackRecordingMetadata {
        if let finalizeError = finalizeError { throw finalizeError }
        var metadata = released
        metadata.status = .completed
        metadata.durationSeconds = 2
        metadata.codec = "AAC in M4A"
        if mediaRoot != nil {
            try Data("system final".utf8).write(to: URL(fileURLWithPath: metadata.finalFilePath))
        }
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
        return try underlying.stop(endedAt: endedAt)
    }

    func releaseForFinalization(endedAt: Date) throws -> MicTrackRecordingMetadata {
        try underlying.stop(endedAt: endedAt)
    }

    func finalizeReleased(_ metadata: MicTrackRecordingMetadata) throws -> MicTrackRecordingMetadata {
        resume.wait()
        return metadata
    }
}

private final class SpyMicRecorder: MicTrackRecordingManaging {
    private let mediaRoot: URL?
    private(set) var activeMetadata: MicTrackRecordingMetadata?
    private(set) var startSessionID: String?
    private(set) var stopCalls = 0
    var stopError: Error?

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
        if let stopError = stopError {
            metadata.status = .failed
            metadata.diagnostics.append("Synthetic microphone input stop failure: \(stopError)")
            activeMetadata = nil
            throw stopError
        }
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
