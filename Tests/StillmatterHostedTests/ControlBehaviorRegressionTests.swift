import AppKit
import XCTest
import StillmatterCore
@testable import StillmatterHostedTestHost

/// Runs unchanged against the pre-migration forms and their shared-control replacements.
final class ControlBehaviorRegressionTests: XCTestCase {
    func testMacRecorderReleaseAndExportEntryPointsWithoutActiveDevices() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stillmatter-recorder-entry-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let recovery = root.appendingPathComponent("missing-mic.caf")
        let microphone = MacMicTrackRecorder()
        let released = try microphone.stopWritingRecovery(to: recovery)
        XCTAssertEqual(released.codec, "linear PCM recovery")
        XCTAssertEqual(released.durationSeconds, 0)
        XCTAssertThrowsError(try microphone.finalizeRecovery(from: recovery, to: root.appendingPathComponent("missing-mic.m4a"), audioClockSpans: nil))
        XCTAssertThrowsError(try MacMicTrackRecorder().stopAndFinalize(
            recoveryURL: recovery,
            finalURL: root.appendingPathComponent("convenience-mic.m4a")
        ))
        XCTAssertThrowsError(try microphone.recover(
            recoveryURL: recovery,
            finalURL: root.appendingPathComponent("recovered-mic.m4a")
        ))
        let existingMicOutput = root.appendingPathComponent("existing-mic.m4a")
        XCTAssertTrue(FileManager.default.createFile(atPath: existingMicOutput.path, contents: Data()))
        XCTAssertThrowsError(try microphone.recover(recoveryURL: recovery, finalURL: existingMicOutput))

        if #available(macOS 13.0, *) {
            let system = MacSystemAudioTrackRecorder()
            XCTAssertThrowsError(try system.stopWritingRecovery(to: root.appendingPathComponent("missing-system.caf")))
            XCTAssertThrowsError(try system.finalizeRecovery(from: root.appendingPathComponent("missing-system.caf"), to: root.appendingPathComponent("missing-system.m4a"), audioClockSpans: nil))
            XCTAssertThrowsError(try system.stopAndFinalize(
                recoveryURL: root.appendingPathComponent("missing-system.caf"),
                finalURL: root.appendingPathComponent("convenience-system.m4a")
            ))
            XCTAssertThrowsError(try system.recover(
                recoveryURL: root.appendingPathComponent("missing-system.caf"),
                finalURL: root.appendingPathComponent("recovered-system.m4a")
            ))
            let existingSystemOutput = root.appendingPathComponent("existing-system.m4a")
            XCTAssertTrue(FileManager.default.createFile(atPath: existingSystemOutput.path, contents: Data()))
            XCTAssertThrowsError(try system.recover(
                recoveryURL: root.appendingPathComponent("missing-system.caf"),
                finalURL: existingSystemOutput
            ))
        }
    }

    @MainActor
    func testRecordingControlsStartStopAndPersistLiveNoteWithoutDevices() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stillmatter-controls-baseline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace")
        let support = root.appendingPathComponent("support")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let service = MeetingCaptureService(
            vault: WorkspaceVault(workspaceRootURL: workspace, appSupportRootURL: support),
            preflight: { .readyForTesting })
        let view = CaptureRecordingView(serviceProvider: { service }, rootURLProvider: { workspace },
            teamsDetectionProvider: { nil }, jobRecordsProvider: { [] }, onOpenSettings: {})
        view.refresh(isVisible: true)
        XCTAssertTrue(view.startButton.isEnabled)
        XCTAssertEqual(view.startButton.keyEquivalent, "\r")
        view.startButton.performClick(nil)
        XCTAssertEqual(service.snapshot.state, .recording)
        XCTAssertFalse(view.startButton.isEnabled)
        XCTAssertTrue(view.stopButton.isEnabled)
        let path = try XCTUnwrap(service.snapshot.meetingRelativePath)
        view.noteField.stringValue = "Synthetic live note through the real field"
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(view.noteField.action), to: view.noteField.target, from: view.noteField))
        XCTAssertTrue(try String(contentsOf: workspace.appendingPathComponent(path)).contains("Synthetic live note through the real field"))
        XCTAssertEqual(view.noteField.stringValue, "")
        view.stopButton.performClick(nil)
        let stopped = expectation(for: NSPredicate { _, _ in service.snapshot.state == .idle }, evaluatedWith: service)
        await fulfillment(of: [stopped], timeout: 10)
        view.refresh(isVisible: true)
        XCTAssertTrue(view.startButton.isEnabled)
        XCTAssertFalse(view.stopButton.isEnabled)
        XCTAssertFalse(view.noteField.isEnabled)
    }

    @MainActor
    func testRecordControlCanStartBWhileStoppedSessionAStillFinalizes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stillmatter-capture-overlap-\(UUID().uuidString)")
        let workspace = root.appendingPathComponent("workspace")
        let support = root.appendingPathComponent("support")
        let media = root.appendingPathComponent("media")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let jobStore = try JobStore(databaseURL: support.appendingPathComponent("jobs.sqlite"))
        let finalizer = PausedControlBundleFinalizer()
        let recorder = ControlMicRecorder(mediaRoot: media)
        let service = MeetingCaptureService(
            vault: WorkspaceVault(workspaceRootURL: workspace, appSupportRootURL: support),
            jobStore: jobStore,
            micRecorder: recorder,
            bundleFinalizer: finalizer,
            preflight: { .readyForTesting }
        )
        let view = CaptureRecordingView(serviceProvider: { service }, rootURLProvider: { workspace },
            teamsDetectionProvider: { nil }, jobRecordsProvider: { [] }, onOpenSettings: {})
        view.refresh(isVisible: true)

        view.startButton.performClick(nil)
        let firstPath = try XCTUnwrap(service.snapshot.meetingRelativePath)
        view.stopButton.performClick(nil)
        XCTAssertTrue(view.startButton.isEnabled)
        XCTAssertEqual(view.statusLabel.stringValue, "Ready for the next capture")
        await fulfillment(of: [finalizer.firstFinalizationStarted], timeout: 5)
        XCTAssertTrue(view.renderedArtifactTitles.contains("Prior Meeting — Finalizing audio"))

        view.startButton.performClick(nil)
        XCTAssertEqual(service.snapshot.state, .recording)
        let secondPath = try XCTUnwrap(service.snapshot.meetingRelativePath)
        XCTAssertNotEqual(firstPath, secondPath)
        XCTAssertTrue(view.stopButton.isEnabled)
        XCTAssertTrue(view.renderedArtifactTitles.contains("Prior Meeting — Finalizing audio"))
        XCTAssertTrue(view.stateDetail(.recording, hasMeeting: true, isPreviousSessionFinalizing: true).contains("prior Meeting's audio is finalizing separately"))

        finalizer.resumeFirst.signal()
        await fulfillment(of: [finalizer.firstFinalizationFinished], timeout: 5)
        XCTAssertEqual(service.snapshot.state, .recording)
        XCTAssertEqual(service.snapshot.meetingRelativePath, secondPath)
        XCTAssertTrue(view.stopButton.isEnabled, "A's completion must not replace B's active Record controls")

        try? FileManager.default.removeItem(at: root)
    }

    @MainActor
    func testPriorFinalizationFailureIsVisibleWithoutDisablingNextCapture() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stillmatter-controls-failed-finalization-\(UUID().uuidString)")
        let workspace = root.appendingPathComponent("workspace")
        let media = root.appendingPathComponent("media")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = ControlMicRecorder(mediaRoot: media)
        let service = MeetingCaptureService(
            vault: WorkspaceVault(workspaceRootURL: workspace, appSupportRootURL: root.appendingPathComponent("support")),
            micRecorder: recorder,
            bundleFinalizer: FailedControlBundleFinalizer(),
            preflight: { .readyForTesting }
        )
        _ = try service.startManual()
        XCTAssertThrowsError(try service.stopManual())
        let view = CaptureRecordingView(serviceProvider: { service }, rootURLProvider: { workspace },
            teamsDetectionProvider: { nil }, jobRecordsProvider: { [] }, onOpenSettings: {})

        view.refresh(isVisible: true)

        XCTAssertTrue(view.startButton.isEnabled)
        XCTAssertTrue(view.renderedArtifactTitles.contains("Prior Meeting — Finalization failed"))
        XCTAssertFalse(view.renderedArtifactTitles.contains("Meeting capture failed"))
    }

    @MainActor
    func testSettingsFieldAndTogglePersistThroughAReopenedStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stillmatter-settings-baseline-\(UUID().uuidString)")
        let suite = "works.stillmatter.controls.baseline.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let store = SettingsStore(userDefaults: defaults)
        let installer = TranscriptionComponentInstaller(paths: TranscriptionComponentPaths(applicationSupportURL: root), acquirer: NoModelAcquirer())
        let view = SettingsFormView(settingsStore: store, transcriptionComponentInstaller: installer)
        let controls = descendants(of: view)
        let field = try XCTUnwrap(controls.compactMap { $0 as? NSTextField }.first { $0.placeholderString == "Private/**, Archive/Old/**" })
        field.stringValue = "Private/**, Synthetic/**"
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(field.action), to: field.target, from: field))
        let toggle = try XCTUnwrap(controls.compactMap { $0 as? NSButton }.first { $0.title == "Launch Stillmatter at login" })
        let prior = store.settings.launchAtLoginEnabled
        toggle.performClick(nil)
        XCTAssertEqual(store.settings.launchAtLoginEnabled, !prior)
        let reopened = SettingsStore(userDefaults: defaults)
        XCTAssertEqual(reopened.settings.searchExcludedPatterns, ["Private/**", "Synthetic/**"])
        XCTAssertEqual(reopened.settings.launchAtLoginEnabled, !prior)
    }

    @MainActor
    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}

private final class PausedControlBundleFinalizer: RecordingBundleFinalizing {
    private let delegate = RecordingBundleFinalizer()
    private let lock = NSLock()
    private var didPause = false
    let resumeFirst = DispatchSemaphore(value: 0)
    let firstFinalizationStarted = XCTestExpectation(description: "Session A bundle finalization started")
    let firstFinalizationFinished = XCTestExpectation(description: "Session A bundle finalization finished")

    func finalize(mic: MicTrackRecordingMetadata, system: SystemAudioTrackRecordingMetadata?,
                  reason: RecordingBundleFinalizationReason) throws -> RecordingBundle {
        lock.lock()
        let shouldPause = !didPause
        didPause = true
        lock.unlock()
        if shouldPause {
            firstFinalizationStarted.fulfill()
            resumeFirst.wait()
        }
        let bundle = try delegate.finalize(mic: mic, system: system, reason: reason)
        if shouldPause { firstFinalizationFinished.fulfill() }
        return bundle
    }

    func validate(_ bundle: RecordingBundle) throws { try delegate.validate(bundle) }
}

private final class ControlMicRecorder: MicTrackRecordingManaging {
    private let mediaRoot: URL
    private(set) var activeMetadata: MicTrackRecordingMetadata?

    init(mediaRoot: URL) { self.mediaRoot = mediaRoot }

    func start(sessionID: String, meetingRelativePath: String, startedAt: Date) throws -> MicTrackRecordingMetadata {
        let directory = mediaRoot.appendingPathComponent("Stillmatter Recordings", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let metadata = MicTrackRecordingMetadata(
            captureSessionID: sessionID,
            meetingRelativePath: meetingRelativePath,
            recoveryFilePath: directory.appendingPathComponent("mic-recovery.caf").path,
            finalFilePath: directory.appendingPathComponent("mic.m4a").path,
            metadataFilePath: directory.appendingPathComponent("mic-recording.json").path,
            startedAt: startedAt,
            sampleRate: 48_000,
            channelCount: 1
        )
        try Data("synthetic recovery audio".utf8).write(to: URL(fileURLWithPath: metadata.recoveryFilePath))
        try Data("{}".utf8).write(to: URL(fileURLWithPath: metadata.metadataFilePath))
        activeMetadata = metadata
        return metadata
    }

    func stop(endedAt: Date) throws -> MicTrackRecordingMetadata {
        var metadata = try XCTUnwrap(activeMetadata)
        metadata.endedAt = endedAt
        metadata.status = .completed
        metadata.durationSeconds = 1
        metadata.codec = "AAC in M4A"
        try Data("synthetic finalized audio".utf8).write(to: URL(fileURLWithPath: metadata.finalFilePath))
        activeMetadata = nil
        return metadata
    }
}

private final class FailedControlBundleFinalizer: RecordingBundleFinalizing {
    func finalize(mic: MicTrackRecordingMetadata, system: SystemAudioTrackRecordingMetadata?,
                  reason: RecordingBundleFinalizationReason) throws -> RecordingBundle {
        throw CocoaError(.fileWriteUnknown)
    }

    func validate(_ bundle: RecordingBundle) throws {}
}

private struct NoModelAcquirer: TranscriptionModelAcquiring {
    func acquireModel(_ model: TranscriptionModelChoice, in stagingURL: URL, cancellation: TranscriptionInstallCancellation,
                      progress: @escaping (TranscriptionInstallProgress) -> Void) throws -> URL {
        throw CocoaError(.featureUnsupported)
    }
}
