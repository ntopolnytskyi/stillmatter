import AppKit
import AVFoundation
import CoreMedia
import XCTest
import StillmatterCore
@testable import StillmatterHostedTestHost

/// Runs unchanged against the pre-migration forms and their shared-control replacements.
final class ControlBehaviorRegressionTests: XCTestCase {
    @MainActor
    func testLiveNotesRefreshesCleanEditorAndKeepsDraftAfterWriteFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stillmatter-live-notes-ui-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace")
        let vault = WorkspaceVault(workspaceRootURL: workspace, appSupportRootURL: root.appendingPathComponent("support"))
        let service = MeetingCaptureService(vault: vault, preflight: { .readyForTesting })
        let view = CaptureRecordingView(serviceProvider: { service }, rootURLProvider: { workspace },
            teamsDetectionProvider: { nil }, jobRecordsProvider: { [] }, onOpenSettings: {})
        _ = try service.startManual()
        view.refresh(isVisible: true)
        let path = try XCTUnwrap(service.snapshot.meetingRelativePath)
        let notePath = (path as NSString).deletingLastPathComponent + "/my-notes.md"
        _ = try vault.writeMarkdown(Data("External notes".utf8), relativePath: notePath, expectedVersion: nil)
        view.refresh(isVisible: true)
        XCTAssertEqual(view.noteTextView.string, "External notes")
        let status = try XCTUnwrap(findView("recording-my-notes-status", in: view) as? NSTextField)
        XCTAssertEqual(status.stringValue, "Updated from my-notes.md")

        view.noteTextView.string = "Keep my draft"
        view.textDidChange(Notification(name: NSText.didChangeNotification, object: view.noteTextView))
        let noteURL = workspace.appendingPathComponent(notePath)
        try FileManager.default.removeItem(at: noteURL)
        try FileManager.default.createDirectory(at: noteURL, withIntermediateDirectories: true)
        let save = try XCTUnwrap(findView("recording-save-notes", in: view) as? NSButton)
        save.performClick(nil)
        XCTAssertTrue(status.stringValue.contains("Could not save My Notes"))
        XCTAssertEqual(view.noteTextView.string, "Keep my draft")
        try FileManager.default.removeItem(at: noteURL)
        _ = try vault.writeMarkdown(Data("External notes".utf8), relativePath: notePath, expectedVersion: nil)
        XCTAssertEqual(try XCTUnwrap(service.liveNotesDocument()).load().text, "Keep my draft")
    }

    @MainActor
    func testLiveNotesLoadRetryRestoresSessionDraftAfterTransientFileFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stillmatter-notes-retry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace")
        let vault = WorkspaceVault(workspaceRootURL: workspace, appSupportRootURL: root.appendingPathComponent("support"))
        let service = MeetingCaptureService(vault: vault, preflight: { .readyForTesting })
        _ = try service.startManual()
        let path = try XCTUnwrap(service.snapshot.meetingRelativePath)
        let notesURL = workspace.appendingPathComponent((path as NSString).deletingLastPathComponent)
            .appendingPathComponent("my-notes.md")
        try FileManager.default.createDirectory(at: notesURL, withIntermediateDirectories: true)
        let view = CaptureRecordingView(serviceProvider: { service }, rootURLProvider: { workspace },
            teamsDetectionProvider: { nil }, jobRecordsProvider: { [] }, onOpenSettings: {})
        view.refresh(isVisible: true)
        let status = try XCTUnwrap(findView("recording-my-notes-status", in: view) as? NSTextField)
        XCTAssertTrue(status.stringValue.contains("Could not load My Notes"))
        try FileManager.default.removeItem(at: notesURL)
        try XCTUnwrap(service.liveNotesDocument()).stage("Recovered draft", baseVersion: nil)
        view.refresh(isVisible: true)
        XCTAssertEqual(view.noteTextView.string, "Recovered draft")
        XCTAssertTrue(status.stringValue.contains("Recovered unsaved draft"))
    }

    @MainActor
    func testLiveNotesStageFailureDoesNotClaimDraftIsRetained() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stillmatter-notes-stage-fail-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace")
        let vault = WorkspaceVault(workspaceRootURL: workspace, appSupportRootURL: root.appendingPathComponent("support"))
        let service = MeetingCaptureService(vault: vault, preflight: { .readyForTesting })
        _ = try service.startManual()
        let view = CaptureRecordingView(serviceProvider: { service }, rootURLProvider: { workspace },
            teamsDetectionProvider: { nil }, jobRecordsProvider: { [] }, onOpenSettings: {})
        view.refresh(isVisible: true)
        let blocker = root.appendingPathComponent("support/MeetingArtifacts/LiveNotes")
        try FileManager.default.createDirectory(at: blocker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("blocked".utf8).write(to: blocker)
        view.noteTextView.string = "Keep this window open"
        view.textDidChange(Notification(name: NSText.didChangeNotification, object: view.noteTextView))
        let status = try XCTUnwrap(findView("recording-my-notes-status", in: view) as? NSTextField)
        XCTAssertTrue(status.stringValue.contains("Draft recovery failed"))
        let save = try XCTUnwrap(findView("recording-save-notes", in: view) as? NSButton)
        save.performClick(nil)
        XCTAssertTrue(status.stringValue.contains("draft recovery is unavailable"))
        XCTAssertFalse(status.stringValue.contains("Draft retained"))
        XCTAssertEqual(view.noteTextView.string, "Keep this window open")
        view.stopButton.performClick(nil)
        XCTAssertEqual(service.snapshot.state, .recording)
        XCTAssertTrue(view.noteTextView.isEditable)
    }

    private func findView(_ identifier: String, in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == identifier { return view }
        for child in view.subviews {
            if let found = findView(identifier, in: child) { return found }
        }
        return nil
    }

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

    func testOfflineMicCaptureKeepsConsecutiveSyntheticSessionsInTheirOwnFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stillmatter-offline-mic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = AVAudioEngine()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let signalLock = NSLock()
        var signal: Float = 0.125
        let source = AVAudioSourceNode(format: format) { _, _, frames, buffers in
            signalLock.lock()
            let sample = signal
            signalLock.unlock()
            for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
                buffer.mData?.initializeMemory(as: Float.self, repeating: sample, count: Int(frames))
            }
            return noErr
        }
        let mixer = AVAudioMixerNode()
        engine.attach(source)
        engine.attach(mixer)
        engine.connect(source, to: mixer, format: format)
        engine.connect(mixer, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
        let recorder = MacMicTrackRecorder(engine: engine, captureInput: { (mixer, mixer.outputFormat(forBus: 0)) })
        let rendered = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4_096))

        func capture(_ name: String, amplitude: Float) throws -> URL {
            signalLock.lock()
            signal = amplitude
            signalLock.unlock()
            let url = root.appendingPathComponent("\(name).caf")
            let started = try recorder.startWritingRecovery(to: url)
            XCTAssertEqual(started.sampleRate, 48_000)
            for _ in 0..<10 { _ = try engine.renderOffline(4_096, to: rendered) }
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
                if size > 4_096 { break }
                Thread.sleep(forTimeInterval: 0.01)
            }
            let released = try recorder.stopWritingRecovery(to: url)
            XCTAssertGreaterThan(released.durationSeconds, 0, "Offline audio must actually reach the recorder's tap")
            XCTAssertGreaterThan(try AVAudioFile(forReading: url).length, 0)
            return url
        }
        let first = try capture("A", amplitude: 0.125)
        let second = try capture("B", amplitude: 0.5)
        for (url, expected) in [(first, Float(0.125)), (second, Float(0.5))] {
            let file = try AVAudioFile(forReading: url)
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_096))
            try file.read(into: pcm)
            XCTAssertGreaterThan(pcm.frameLength, 0)
            let sample = try XCTUnwrap(pcm.floatChannelData?[0].pointee)
            XCTAssertEqual(sample, expected, accuracy: 0.01, "A's frames must never be written to B's recovery file")
        }
    }

    @available(macOS 13.0, *)
    func testSystemRecorderRejectsLateASamplesAndErrorsDuringB() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stillmatter-system-stream-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let factory = SyntheticSystemAudioStreamFactory()
        let recorder = MacSystemAudioTrackRecorder(streamFactory: factory)
        let first = root.appendingPathComponent("A.caf")
        let second = root.appendingPathComponent("B.caf")
        _ = try recorder.startWritingRecovery(to: first, scope: .teamsApplication)
        let streamA = try XCTUnwrap(factory.streams.last)
        streamA.deliver(try syntheticSystemSample(0.125))
        XCTAssertGreaterThan(try recorder.stopWritingRecovery(to: first).durationSeconds, 0)

        _ = try recorder.startWritingRecovery(to: second, scope: .allSystemAudio)
        let streamB = try XCTUnwrap(factory.streams.last)
        streamA.deliver(try syntheticSystemSample(0.875)) // Delayed A callback must never enter B.
        streamA.fail(CocoaError(.fileReadUnknown))
        streamB.deliver(try syntheticSystemSample(0.5))
        XCTAssertGreaterThan(try recorder.stopWritingRecovery(to: second).durationSeconds, 0)
        XCTAssertEqual(factory.scopes, [.teamsApplication, .allSystemAudio])
        for (url, expected) in [(first, Float(0.125)), (second, Float(0.5))] {
            let file = try AVAudioFile(forReading: url)
            XCTAssertEqual(file.length, 1_024, "A's delayed frames must not change B's retained sample count")
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1_024))
            try file.read(into: pcm)
            XCTAssertEqual(try XCTUnwrap(pcm.floatChannelData?[0].pointee), expected, accuracy: 0.01)
        }
    }

    @available(macOS 13.0, *)
    func testSystemRecorderRefusesBUntilFailedStopCanBeConfirmed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stillmatter-uncertain-stop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let factory = SyntheticSystemAudioStreamFactory()
        let recorder = MacSystemAudioTrackRecorder(streamFactory: factory)
        let first = root.appendingPathComponent("A.caf")
        _ = try recorder.startWritingRecovery(to: first, scope: .teamsApplication)
        let streamA = try XCTUnwrap(factory.streams.last)
        streamA.deliver(try syntheticSystemSample(0.125))
        streamA.stopError = CocoaError(.fileWriteUnknown)

        XCTAssertThrowsError(try recorder.stopWritingRecovery(to: first))
        XCTAssertThrowsError(try recorder.startWritingRecovery(to: root.appendingPathComponent("B.caf"), scope: .allSystemAudio))
        XCTAssertEqual(factory.scopes, [.teamsApplication], "B must not bypass an unconfirmed OS stop")
        streamA.stopError = nil
        XCTAssertGreaterThan(try recorder.stopWritingRecovery(to: first).durationSeconds, 0)
        _ = try recorder.startWritingRecovery(to: root.appendingPathComponent("B.caf"), scope: .allSystemAudio)
        XCTAssertEqual(factory.scopes, [.teamsApplication, .allSystemAudio])
        _ = try recorder.stopWritingRecovery(to: root.appendingPathComponent("B.caf"))
    }

    @available(macOS 13.0, *)
    func testUnavailableTeamsStreamNeverFallsBackAndFailedStartCanRetry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stillmatter-stream-start-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let factory = SyntheticSystemAudioStreamFactory()
        let recorder = MacSystemAudioTrackRecorder(streamFactory: factory)
        let teamsFile = root.appendingPathComponent("teams.caf")
        factory.makeError = CocoaError(.fileNoSuchFile)
        XCTAssertThrowsError(try recorder.startWritingRecovery(to: teamsFile, scope: .teamsApplication))
        XCTAssertEqual(factory.scopes, [.teamsApplication])
        XCTAssertFalse(FileManager.default.fileExists(atPath: teamsFile.path))

        factory.makeError = nil
        factory.nextStartError = CocoaError(.fileWriteUnknown)
        XCTAssertThrowsError(try recorder.startWritingRecovery(to: teamsFile, scope: .teamsApplication))
        factory.nextStartError = nil
        let manual = root.appendingPathComponent("manual.caf")
        _ = try recorder.startWritingRecovery(to: manual, scope: .allSystemAudio)
        XCTAssertEqual(factory.scopes, [.teamsApplication, .teamsApplication, .allSystemAudio])
        _ = try recorder.stopWritingRecovery(to: manual)
    }

    @available(macOS 13.0, *)
    func testFailedStartMustConfirmStopBeforeAnotherSession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stillmatter-uncertain-start-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let factory = SyntheticSystemAudioStreamFactory()
        let recorder = MacSystemAudioTrackRecorder(streamFactory: factory)
        factory.nextStartError = CocoaError(.fileWriteUnknown)
        _ = try? recorder.startWritingRecovery(to: root.appendingPathComponent("A.caf"), scope: .teamsApplication)
        let streamA = try XCTUnwrap(factory.streams.last)
        XCTAssertEqual(streamA.stopCount, 1, "A failed start must attempt to release the OS stream")

        factory.nextStartError = CocoaError(.fileWriteUnknown)
        factory.nextStopError = CocoaError(.fileReadUnknown)
        XCTAssertThrowsError(try recorder.startWritingRecovery(to: root.appendingPathComponent("uncertain.caf"), scope: .teamsApplication))
        let uncertainStream = try XCTUnwrap(factory.streams.last)
        XCTAssertEqual(uncertainStream.stopCount, 1)
        factory.nextStartError = nil
        factory.nextStopError = nil
        XCTAssertThrowsError(try recorder.startWritingRecovery(to: root.appendingPathComponent("B.caf"), scope: .allSystemAudio))
        XCTAssertEqual(factory.streams.count, 2, "B must not start while A's release is unconfirmed")
        uncertainStream.stopError = nil
        _ = try recorder.stopWritingRecovery(to: root.appendingPathComponent("uncertain.caf"))
        _ = try recorder.startWritingRecovery(to: root.appendingPathComponent("B.caf"), scope: .allSystemAudio)
        _ = try recorder.stopWritingRecovery(to: root.appendingPathComponent("B.caf"))
    }

    @available(macOS 13.0, *)
    func testCurrentStreamFailureIsReportedAfterSafeStopWithoutLosingRecoveryAudio() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stillmatter-stream-error-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let factory = SyntheticSystemAudioStreamFactory()
        let recorder = MacSystemAudioTrackRecorder(streamFactory: factory)
        let first = root.appendingPathComponent("failed.caf")
        var reportedFailure: String?
        let failureExpectation = expectation(description: "stream failure reaches the capture coordinator")
        recorder.setCaptureFailureHandler {
            reportedFailure = String(describing: $0)
            failureExpectation.fulfill()
        }
        _ = try recorder.startWritingRecovery(to: first, scope: .teamsApplication)
        let stream = try XCTUnwrap(factory.streams.last)
        stream.deliver(try syntheticSystemSample(0.25))
        stream.fail(CocoaError(.fileReadUnknown))
        wait(for: [failureExpectation], timeout: 2)
        XCTAssertNotNil(reportedFailure)
        XCTAssertGreaterThan(try recorder.stopWritingRecovery(to: first).durationSeconds, 0)
        XCTAssertEqual(try AVAudioFile(forReading: first).length, 1_024)
        XCTAssertEqual(stream.stopCount, 0, "The stream delegate already confirmed that the OS stopped this source")
        _ = try recorder.startWritingRecovery(to: root.appendingPathComponent("next.caf"), scope: .allSystemAudio)
        _ = try recorder.stopWritingRecovery(to: root.appendingPathComponent("next.caf"))
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
        view.noteTextView.string = "Synthetic live note through the real field"
        view.textDidChange(Notification(name: NSText.didChangeNotification, object: view.noteTextView))
        let saved = expectation(for: NSPredicate { _, _ in
            (try? String(contentsOf: workspace.appendingPathComponent(path).deletingLastPathComponent().appendingPathComponent("my-notes.md"))) == "Synthetic live note through the real field"
        }, evaluatedWith: view)
        await fulfillment(of: [saved], timeout: 10)
        XCTAssertEqual(view.noteTextView.string, "Synthetic live note through the real field")
        view.stopButton.performClick(nil)
        let stopped = expectation(for: NSPredicate { _, _ in service.snapshot.state == .idle }, evaluatedWith: service)
        await fulfillment(of: [stopped], timeout: 10)
        view.refresh(isVisible: true)
        XCTAssertTrue(view.startButton.isEnabled)
        XCTAssertFalse(view.stopButton.isEnabled)
        XCTAssertFalse(view.noteTextView.isEditable)
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
        XCTAssertEqual(view.statusLabel.stringValue, "Ready for the next capture")
        XCTAssertTrue(view.stateDetail(.idle, hasMeeting: true, isPreviousSessionFinalizationFailed: true)
            .contains("prior Meeting's audio finalization failed"))
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

@available(macOS 13.0, *)
private final class SyntheticSystemAudioStreamFactory: SystemAudioStreamCreating {
    private(set) var scopes: [CaptureAudioScope] = []
    private(set) var streams: [SyntheticSystemAudioStream] = []
    var makeError: Error?
    var nextStartError: Error?
    var nextStopError: Error?

    func make(scope: CaptureAudioScope, sampleQueue: DispatchQueue,
              onSample: @escaping (CMSampleBuffer) -> Void,
              onError: @escaping (Error) -> Void) throws -> SystemAudioInputStream {
        scopes.append(scope)
        if let makeError { throw makeError }
        let stream = SyntheticSystemAudioStream(queue: sampleQueue, onSample: onSample, onError: onError)
        stream.startError = nextStartError
        stream.stopError = nextStopError
        streams.append(stream)
        return stream
    }
}

@available(macOS 13.0, *)
private final class SyntheticSystemAudioStream: SystemAudioInputStream {
    private let queue: DispatchQueue
    private let onSample: (CMSampleBuffer) -> Void
    private let onError: (Error) -> Void
    var startError: Error?
    var stopError: Error?
    private(set) var stopCount = 0

    init(queue: DispatchQueue, onSample: @escaping (CMSampleBuffer) -> Void, onError: @escaping (Error) -> Void) {
        self.queue = queue
        self.onSample = onSample
        self.onError = onError
    }

    func start() throws { if let startError { throw startError } }
    func stop() throws {
        stopCount += 1
        if let stopError { throw stopError }
    }
    func deliver(_ buffer: CMSampleBuffer) { queue.sync { onSample(buffer) } }
    func fail(_ error: Error) { onError(error) }
}

@available(macOS 13.0, *)
private func syntheticSystemSample(_ value: Float) throws -> CMSampleBuffer {
    let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
        channels: 1, interleaved: true))
    var asbd = format.streamDescription.pointee
    var description: CMAudioFormatDescription?
    XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
        layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
        formatDescriptionOut: &description), noErr)
    let frames = [Float](repeating: value, count: 1_024)
    var block: CMBlockBuffer?
    XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
        blockLength: frames.count * MemoryLayout<Float>.size, blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil, offsetToData: 0, dataLength: frames.count * MemoryLayout<Float>.size,
        flags: 0, blockBufferOut: &block), noErr)
    let bytesStatus = frames.withUnsafeBytes { bytes in
        CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block!,
            offsetIntoDestination: 0, dataLength: bytes.count)
    }
    XCTAssertEqual(bytesStatus, noErr)
    var buffer: CMSampleBuffer?
    XCTAssertEqual(CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault,
        dataBuffer: try XCTUnwrap(block), formatDescription: try XCTUnwrap(description), sampleCount: frames.count,
        presentationTimeStamp: CMTime(value: 0, timescale: 48_000), packetDescriptions: nil,
        sampleBufferOut: &buffer), noErr)
    return try XCTUnwrap(buffer)
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
