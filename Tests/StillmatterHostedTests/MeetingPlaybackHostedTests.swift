import AVFoundation
import XCTest
import StillmatterCore
import StillmatterPresentation
@testable import StillmatterHostedTestHost

final class MeetingPlaybackHostedTests: XCTestCase {
    @MainActor
    func testDiscontinuousCAFAndAACTracksPlayOnTheCommonTimeline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let preparationRoot = root.appendingPathComponent("playback")
        try FileManager.default.createDirectory(at: preparationRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let microphone = try audio(root.appendingPathComponent("mic.caf"), amplitude: 0.2, secondAmplitude: 0.6)
        let system = try audio(root.appendingPathComponent("other.m4a"), amplitude: 0.1, secondAmplitude: 0.4)
        let originalMicrophone = try Data(contentsOf: microphone)
        let originalSystem = try Data(contentsOf: system)
        let microphoneRanges = [MeetingPlaybackRange(fileStart: 0, fileEnd: 1, timelineStart: 0),
                                MeetingPlaybackRange(fileStart: 1, fileEnd: 2, timelineStart: 2)]
        let systemRanges = [MeetingPlaybackRange(fileStart: 0, fileEnd: 1, timelineStart: 0.5),
                            MeetingPlaybackRange(fileStart: 1, fileEnd: 2, timelineStart: 2.5)]
        let source = MeetingPlayback(capability: .mixed, microphonePath: microphone.path, systemPath: system.path,
            durationSeconds: 3.5, microphoneRanges: microphoneRanges, systemRanges: systemRanges, message: "Retained")
        let controller = MeetingAudioPlaybackController(temporaryDirectory: preparationRoot)
        defer { controller.stop() }
        controller.load(source)
        XCTAssertFalse(controller.state.isAvailable, "Preparation runs off the main actor")
        controller.seek(to: 0.25)
        controller.seek(to: 2.2)
        controller.load(source)
        let ready = expectation(for: NSPredicate { _, _ in controller.state.isAvailable && !controller.state.waveform.isEmpty }, evaluatedWith: nil)
        await fulfillment(of: [ready], timeout: 5)
        XCTAssertEqual(controller.state.position, 2.2, accuracy: 0.001, "The latest source-link seek survives preparation and a same-Meeting refresh")
        XCTAssertFalse(controller.state.isPlaying, "A source-link seek does not start playback")
        XCTAssertEqual(controller.state.duration, 3.5, accuracy: 0.001)
        controller.selectTrack(.mine)
        let microphoneWave = controller.state.waveform
        XCTAssertEqual(microphoneWave.count, 96)
        XCTAssertGreaterThan(microphoneWave[12], 0.5)
        XCTAssertEqual(microphoneWave[47], 0, accuracy: 0.001)
        XCTAssertGreaterThan(microphoneWave[69], microphoneWave[12])
        controller.selectTrack(.other)
        let systemWave = controller.state.waveform
        XCTAssertEqual(systemWave[5], 0, accuracy: 0.001)
        XCTAssertGreaterThan(systemWave[25], 0.05)
        XCTAssertEqual(systemWave[52], 0, accuracy: 0.001)
        XCTAssertGreaterThan(systemWave[80], systemWave[25])
        controller.seek(to: 0.8)
        controller.setSpeed(2)
        controller.play()
        let gap = try await observePosition(1.7, controller: controller)
        XCTAssertTrue(controller.state.isPlaying)
        XCTAssertEqual(gap.tracks[0], gap.position, accuracy: 0.12)
        XCTAssertEqual(gap.tracks[1], gap.position - 0.5, accuracy: 0.12)
        let resumed = try await observePosition(2.6, controller: controller)
        XCTAssertEqual(resumed.tracks[0], resumed.position, accuracy: 0.12)
        XCTAssertEqual(resumed.tracks[1], resumed.position - 0.5, accuracy: 0.12)
        XCTAssertEqual(try Data(contentsOf: microphone), originalMicrophone)
        XCTAssertEqual(try Data(contentsOf: system), originalSystem)
        let stoppedPlayer = try XCTUnwrap(controller.activePlayer)
        try FileManager.default.removeItem(at: microphone)
        let unavailable = expectation(for: NSPredicate { _, _ in
            !controller.state.isAvailable && controller.state.errorMessage?.contains("no longer retained") == true
        }, evaluatedWith: nil)
        await fulfillment(of: [unavailable], timeout: 5)
        XCTAssertNil(controller.activePlayer)
        let cleaned = expectation(for: NSPredicate { _, _ in
            (try? FileManager.default.contentsOfDirectory(atPath: preparationRoot.path).isEmpty) == true
        }, evaluatedWith: nil)
        await fulfillment(of: [cleaned], timeout: 5)
        XCTAssertFalse(stoppedPlayer.isPlaying)
    }

    @MainActor
    func testInvalidGapRangesFailAndReplacingPreparationDiscardsTemporaryMedia() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let preparationRoot = root.appendingPathComponent("playback")
        try FileManager.default.createDirectory(at: preparationRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let microphone = try audio(root.appendingPathComponent("mic.caf"), amplitude: 0.2)
        let controller = MeetingAudioPlaybackController(temporaryDirectory: preparationRoot)
        defer { controller.stop() }
        let invalid = MeetingPlayback(capability: .microphoneOnly, microphonePath: microphone.path, durationSeconds: 4,
            microphoneRanges: [MeetingPlaybackRange(fileStart: 0, fileEnd: 4, timelineStart: 0)], message: "Invalid")
        controller.load(invalid)
        controller.seek(to: 2.5)
        let failed = expectation(for: NSPredicate { _, _ in controller.state.errorMessage != nil }, evaluatedWith: nil)
        await fulfillment(of: [failed], timeout: 5)
        XCTAssertFalse(controller.state.isAvailable)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: preparationRoot.path), [])
        let giantGap = 1_000_000_000_000.0
        controller.load(MeetingPlayback(capability: .microphoneOnly, microphonePath: microphone.path,
            durationSeconds: giantGap + 1,
            microphoneRanges: [MeetingPlaybackRange(fileStart: 0, fileEnd: 1, timelineStart: 0),
                               MeetingPlaybackRange(fileStart: 1, fileEnd: 2, timelineStart: giantGap)], message: "Giant gap"))
        let space = expectation(for: NSPredicate { _, _ in
            controller.state.errorMessage?.contains("temporary disk space") == true
        }, evaluatedWith: nil)
        await fulfillment(of: [space], timeout: 5)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: preparationRoot.path), [])
        let gap = MeetingPlayback(capability: .microphoneOnly, microphonePath: microphone.path, durationSeconds: 3,
            microphoneRanges: [MeetingPlaybackRange(fileStart: 0, fileEnd: 1, timelineStart: 0),
                               MeetingPlaybackRange(fileStart: 1, fileEnd: 2, timelineStart: 2)], message: "Superseded")
        controller.load(gap)
        controller.seek(to: 1.75)
        let replacement = MeetingPlayback(capability: .microphoneOnly, microphonePath: microphone.path, message: "Replacement")
        controller.load(replacement)
        let ready = expectation(for: NSPredicate { _, _ in !controller.state.waveform.isEmpty }, evaluatedWith: nil)
        await fulfillment(of: [ready], timeout: 5)
        XCTAssertEqual(controller.state.source, replacement)
        XCTAssertEqual(controller.state.duration, 2, accuracy: 0.001)
        XCTAssertEqual(controller.state.position, 0, "Another Meeting cannot inherit a pending source-link seek")
        let cleaned = expectation(for: NSPredicate { _, _ in
            (try? FileManager.default.contentsOfDirectory(atPath: preparationRoot.path).isEmpty) == true
        }, evaluatedWith: nil)
        await fulfillment(of: [cleaned], timeout: 5)
    }

    @MainActor
    func testWaveformCombinesCollocatedAnnotations() {
        let view = MeetingManagementView(readModelProvider: { nil }, mutationExecutorProvider: { nil },
            playbackTransportProvider: { nil }, openRecording: {}, openWorkspaceFile: { _ in })
        view.waveform.maxValue = 100
        view.waveform.markerLabels = [(10, "S"), (10, "D"), (10, "A"), (10, "Q"), (99, "Q")]
        XCTAssertEqual(view.waveform.renderedMarkerLabels.map(\.symbols), ["SDAQ", "Q"], "Collocated outcomes remain visible alongside speech")
        view.waveform.maxValue = 200
        XCTAssertEqual(view.waveform.renderedMarkerLabels.map(\.symbols), ["SDAQ", "Q"])
    }

    @MainActor
    func testTimelineAnnotationsValidateSourcesAndWaveformSeeks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace")
        let folder = workspace.appendingPathComponent("Meetings/markers")
        let media = root.appendingPathComponent("media")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let mic = try audio(media.appendingPathComponent("mic.caf"), amplitude: 0.1)
        let metadata = media.appendingPathComponent("mic.json")
        try Data("{}".utf8).write(to: metadata)
        let meeting = "Meetings/markers/meeting.md"
        let bundle = try RecordingBundleFinalizer().finalize(mic: MicTrackRecordingMetadata(
            captureSessionID: "markers", meetingRelativePath: meeting, recoveryFilePath: mic.path,
            finalFilePath: media.appendingPathComponent("missing.m4a").path, metadataFilePath: metadata.path,
            startedAt: Date(), status: .partial, durationSeconds: 2, codec: "caf", sampleRate: 8_000, channelCount: 1),
            system: nil, reason: .recovery)
        try Data("---\ntitle: Markers\ncapture_session_id: markers\nrecording_bundle: \(bundle.bundleFilePath)\n---\n# Markers\n".utf8)
            .write(to: folder.appendingPathComponent("meeting.md"))
        let segments = (0..<205).map { index in
            TranscriptSegment(id: "prefix-\(index)", startSeconds: Double(index) / 250, endSeconds: Double(index) / 250 + 0.001,
                text: "Earlier phrase \(index)", language: .english, track: .microphone, speaker: "Me")
        } + [TranscriptSegment(id: "one", startSeconds: 0.25, endSeconds: 0.5, text: "First", language: .english, track: .microphone, speaker: "Me"),
                        TranscriptSegment(id: "two", startSeconds: 1.25, endSeconds: 1.5, text: "Second", language: .english, track: .microphone, speaker: "Me"),
                        TranscriptSegment(id: "outside", startSeconds: 50, endSeconds: 51, text: "Unavailable", language: .english, track: .microphone, speaker: "Me")]
        let transcript = TranscriptDocument(schemaVersion: 1, captureSessionID: "markers", meetingRelativePath: meeting,
            language: .english, detectedLanguages: [.english], engine: "fixture", model: "fixture", generatedAt: Date(),
            audioSources: [], segments: segments, diagnostics: [])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(transcript).write(to: folder.appendingPathComponent("transcript.json"))
        let valid = MeetingOutcomeCitation(segmentID: "one", startSeconds: 0.25, endSeconds: 0.5)
        let invalid = MeetingOutcomeCitation(segmentID: "unknown", startSeconds: 0.25, endSeconds: 0.5)
        let outcome = MeetingOutcome(id: "decision", text: "Decide", citations: [.init(segmentID: "two", startSeconds: 1.25, endSeconds: 1.5), invalid])
        let extraction = MeetingSummaryExtraction(meeting: meeting, transcript: "Meetings/markers/transcript.json",
            decisions: [outcome], myActionItems: [MeetingOutcome(id: "mine", text: "Do", citations: [valid])],
            otherActionItems: [MeetingOutcome(id: "other", text: "Review", citations: [valid])],
            openQuestions: [MeetingOutcome(id: "question", text: "Why?", citations: [valid])])
        try encoder.encode(extraction).write(to: folder.appendingPathComponent("summary-extraction.json"))
        let vault = WorkspaceVault(workspaceRootURL: workspace, appSupportRootURL: root.appendingPathComponent("support"))
        let service = MeetingManagementService(vault: vault)
        let canonical = try service.detail(for: "markers")
        XCTAssertEqual(canonical.transcript.count, 208)
        XCTAssertEqual(canonical.playback.capability, .microphoneOnly, canonical.playback.message)
        let readModel = MeetingReadModel(workspaceID: UUID().uuidString) { MeetingManagementReadSource(serviceProvider: { service }) }
        let controller = MeetingAudioPlaybackController()
        defer { controller.stop() }
        let view = MeetingManagementView(readModelProvider: { readModel }, mutationExecutorProvider: { nil },
            playbackTransportProvider: { controller }, openRecording: {}, openWorkspaceFile: { _ in })
        view.refresh(isVisible: true)
        let rows = expectation(for: NSPredicate { _, _ in !view.meetingsModel.visibleRows.isEmpty }, evaluatedWith: nil)
        await fulfillment(of: [rows], timeout: 5)
        let row = try XCTUnwrap(view.meetingsModel.visibleRows.first)
        _ = view.meetingsModel.select(meetingID: row.id, selectedIDs: [row.id])
        let loaded = expectation(for: NSPredicate { _, _ in view.waveform.isEnabled }, evaluatedWith: nil)
        await fulfillment(of: [loaded], timeout: 5)
        XCTAssertEqual(controller.state.track, .both, "Playback includes every available track without a selection control")
        XCTAssertTrue(view.playbackSpeed.isEnabled)
        XCTAssertEqual(Set(view.waveform.markerLabels.map(\.symbol)), ["S", "D", "A", "Q"])
        XCTAssertEqual(view.waveform.markerLabels.count, 211, "Invalid citations and outside-recording speech do not become markers")
        view.openTimeline()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.timelinePage.frame.minX, view.pinnedAudio.frame.minX, accuracy: 1)
        XCTAssertEqual(view.timelinePage.frame.maxX, view.pinnedAudio.frame.maxX, accuracy: 1)
        view.waveform.doubleValue = 0.25
        view.waveform.sendAction(view.waveform.action, to: view.waveform.target)
        XCTAssertEqual(controller.state.position, 0.25)
        XCTAssertTrue(view.markerPicker.isEnabled)
        let markers = try XCTUnwrap(view.markerPicker.menu).items.dropFirst()
        XCTAssertEqual(markers.count, 211)
        for item in markers.filter({ $0.title.hasSuffix("one") || $0.title.hasSuffix("two") }) {
            view.selectPlaybackMarker(item)
            XCTAssertEqual(view.timelineNavigation.jump?.segmentID, item.title.hasSuffix("two") ? "two" : "one")
            XCTAssertEqual(controller.state.position, item.title.hasSuffix("two") ? 1.25 : 0.25, accuracy: 0.001)
            XCTAssertFalse(controller.state.isPlaying)
        }
        controller.play()
        view.selectPlaybackMarker(try XCTUnwrap(markers.first))
        XCTAssertTrue(controller.state.isPlaying)
        controller.pause()
        func find<T: NSView>(_ id: String, in parent: NSView) throws -> T {
            if parent.accessibilityIdentifier() == id, let result = parent as? T { return result }
            for child in parent.subviews { if let result: T = try? find(id, in: child) { return result } }
            throw NSError(domain: "Missing marker control", code: 1)
        }
        let decisionID = try XCTUnwrap(MeetingOutcomeDocument.entries(in: canonical.summary!.decisions, defaultKind: .decision).first?.id)
        let source: NSButton = try find("meeting-outcome-source-" + decisionID + "-0", in: view)
        source.performClick(nil)
        XCTAssertEqual(view.selectedID, "markers")
        XCTAssertEqual(view.meetingsModel.detail.page, .transcript)
        XCTAssertEqual(view.timelineNavigation.jump?.segmentID, "two")
        XCTAssertEqual(controller.state.position, 1.25, accuracy: 0.001)
        XCTAssertFalse(controller.state.isPlaying)
        let selected: NSTextField = try find("transcript-text-two", in: view)
        XCTAssertTrue(selected.accessibilityHelp()?.contains("Selected source phrase") == true)
        XCTAssertEqual(selected.stringValue, "Second")
        controller.play(); source.performClick(nil)
        XCTAssertEqual(controller.state.position, 1.25, accuracy: 0.001)
        XCTAssertTrue(controller.state.isPlaying)
        controller.pause()
        window.displayIfNeeded()

    }
    @MainActor
    func testTrackAndSpeedChangesPreserveSourcePositionAndOriginalFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mic = try audio(root.appendingPathComponent("mic.caf"), amplitude: 0.1)
        let other = try audio(root.appendingPathComponent("other.caf"), amplitude: 0.7)
        let original = try Data(contentsOf: mic)
        let controller = MeetingAudioPlaybackController()
        defer { controller.stop() }
        controller.load(MeetingPlayback(capability: .mixed, microphonePath: mic.path, systemPath: other.path,
            durationSeconds: 5, microphoneOffsetSeconds: 1, systemOffsetSeconds: 3, message: "Retained"))
        XCTAssertTrue(controller.state.isAvailable)
        XCTAssertEqual(controller.state.duration, 5, accuracy: 0.01)
        controller.seek(to: 2)
        controller.selectTrack(.other)
        controller.setSpeed(2)
        XCTAssertEqual(controller.state.position, 2, accuracy: 0.01)
        XCTAssertEqual(controller.state.track, .other)
        XCTAssertEqual(controller.state.speed, 2)
        XCTAssertFalse(controller.state.isPlaying)
        XCTAssertEqual(controller.activePlayer?.trackVolumes, [0, 1])
        controller.selectTrack(.mine)
        XCTAssertEqual(controller.activePlayer?.trackVolumes, [1, 0])
        controller.selectTrack(.both)
        XCTAssertEqual(controller.activePlayer?.trackVolumes, [1, 1])
        XCTAssertEqual(try Data(contentsOf: mic), original)
    }

    @MainActor
    func testDoubleSpeedAdvancesRealTrackFramesAndHonorsDelayedStart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mic = try audio(root.appendingPathComponent("mic.caf"), amplitude: 0.1)
        let other = try audio(root.appendingPathComponent("other.caf"), amplitude: 0.7)
        let controller = MeetingAudioPlaybackController()
        defer { controller.stop() }
        controller.load(MeetingPlayback(capability: .mixed, microphonePath: mic.path, systemPath: other.path,
            microphoneOffsetSeconds: 1, systemOffsetSeconds: 3, message: "Retained"))
        controller.seek(to: 1)
        controller.setSpeed(2)
        let advanced = expectation(description: "One source second at double speed")
        let started = Date()
        var elapsed: TimeInterval?
        var position: Double?
        var tracks: [Double]?
        controller.onChange = { [weak controller] state in
            guard state.position >= 2, elapsed == nil else { return }
            elapsed = Date().timeIntervalSince(started)
            position = state.position
            tracks = controller?.activePlayer?.trackPositions
            advanced.fulfill()
        }
        controller.play()
        await fulfillment(of: [advanced], timeout: 2)
        controller.pause()
        controller.onChange = nil
        let wall = try XCTUnwrap(elapsed)
        XCTAssertGreaterThan(wall, 0.35)
        XCTAssertLessThan(wall, 0.85, "One source second at 2× should take about half a wall-clock second")
        let actual = try XCTUnwrap(tracks)
        XCTAssertEqual(actual[0], try XCTUnwrap(position) - 1, accuracy: 0.12, "Real microphone frames follow the source cursor at 2×")
        XCTAssertEqual(actual[1], 0, accuracy: 0.01, "The later Other track must not start before its original offset")
        controller.seek(to: 3.2)
        let otherStarted = expectation(description: "Other track advances at its original timeline position")
        var otherPosition: Double?
        var otherFrames: Double?
        controller.onChange = { [weak controller] state in
            guard state.position >= 3.5, otherPosition == nil else { return }
            otherPosition = state.position
            otherFrames = controller?.activePlayer?.trackPositions[1]
            otherStarted.fulfill()
        }
        controller.play()
        await fulfillment(of: [otherStarted], timeout: 2)
        controller.pause()
        controller.onChange = nil
        XCTAssertEqual(try XCTUnwrap(otherFrames), try XCTUnwrap(otherPosition) - 3, accuracy: 0.12)
    }

    @MainActor
    func testEverySupportedRatePreservesDelayedStartsAndCancelsOldScheduledStartsOnSeek() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mic = try audio(root.appendingPathComponent("mic.caf"), amplitude: 0.1)
        let other = try audio(root.appendingPathComponent("other.caf"), amplitude: 0.7)
        let source = MeetingPlayback(capability: .mixed, microphonePath: mic.path, systemPath: other.path,
            microphoneOffsetSeconds: 1, systemOffsetSeconds: 3, message: "Retained")
        let controller = MeetingAudioPlaybackController()
        defer { controller.stop() }
        for rate in [0.5, 1, 1.5, 2] {
            controller.stop()
            controller.load(source)
            controller.setSpeed(rate)
            controller.seek(to: 1)
            controller.play()
            let delayed = try await observePosition(2.5, controller: controller)
            controller.pause()
            XCTAssertEqual(delayed.tracks[0], delayed.position - 1, accuracy: 0.12, "Microphone follows the source timeline at \(rate)×")
            XCTAssertEqual(delayed.tracks[1], 0, accuracy: 0.01, "Other cannot start before source position 3 at \(rate)×")
            controller.seek(to: 3.2)
            controller.play()
            let resumed = try await observePosition(3.5, controller: controller)
            controller.pause()
            XCTAssertEqual(resumed.tracks[1], resumed.position - 3, accuracy: 0.12, "Old queued starts cannot move the resumed Other position at \(rate)×")
        }
    }

    @MainActor
    private func observePosition(_ target: Double, controller: MeetingAudioPlaybackController) async throws -> (position: Double, tracks: [Double]) {
        let reached = expectation(description: "Source position reaches \(target)")
        var observed: (Double, [Double])?
        controller.onChange = { [weak controller] state in
            guard state.position >= target, observed == nil, let tracks = controller?.activePlayer?.trackPositions else { return }
            observed = (state.position, tracks)
            reached.fulfill()
        }
        await fulfillment(of: [reached], timeout: 5)
        controller.onChange = nil
        return try XCTUnwrap(observed)
    }

    @MainActor
    func testWaveformOffsetsSilenceAndSelectedMixAndRefresh() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mic = try audio(root.appendingPathComponent("mic.caf"), amplitude: 0.1)
        let other = try audio(root.appendingPathComponent("other.caf"), amplitude: 0.7)
        let source = MeetingPlayback(capability: .mixed, microphonePath: mic.path, systemPath: other.path,
            durationSeconds: 5, microphoneOffsetSeconds: 1, systemOffsetSeconds: 3, message: "Retained")
        let controller = MeetingAudioPlaybackController()
        defer { controller.stop() }
        controller.load(source)
        expectation(for: NSPredicate { _, _ in controller.state.waveform.count == 96 }, evaluatedWith: nil)
        waitForExpectations(timeout: 5)
        let player = controller.activePlayer
        XCTAssertEqual(controller.state.waveform[0], 0)
        XCTAssertGreaterThan(controller.state.waveform[24], 0.4)
        XCTAssertEqual(controller.state.waveform[45], 0)
        XCTAssertGreaterThan(controller.state.waveform[64], 0.9)
        controller.selectTrack(.other)
        XCTAssertEqual(controller.state.waveform[24], 0)
        XCTAssertGreaterThan(controller.state.waveform[64], 0.9)
        controller.selectTrack(.mine)
        XCTAssertGreaterThan(controller.state.waveform[24], 0.4)
        XCTAssertEqual(controller.state.waveform[64], 0)
        controller.seek(to: 2.5)
        controller.setSpeed(1.5)
        controller.load(source)
        XCTAssertTrue(controller.activePlayer === player, "Unrelated refresh keeps the loaded player")
        XCTAssertEqual(controller.state.position, 2.5)
        XCTAssertEqual(controller.state.speed, 1.5)
        XCTAssertEqual(controller.state.track, .mine)
    }

    @MainActor
    func testPlayingSeekSpeedEOFAndStaleMeetingCallbacks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mic = try audio(root.appendingPathComponent("mic.caf"), amplitude: 0.1)
        let other = try audio(root.appendingPathComponent("other.caf"), amplitude: 0.7)
        let controller = MeetingAudioPlaybackController()
        defer { controller.stop() }
        controller.load(MeetingPlayback(capability: .mixed, microphonePath: mic.path, systemPath: other.path,
            microphoneOffsetSeconds: 1, systemOffsetSeconds: 3, message: "First"))
        let oldPlayer = try XCTUnwrap(controller.activePlayer)
        let oldCallback = oldPlayer.onTimeChange
        controller.play()
        XCTAssertTrue(controller.state.isPlaying)
        controller.seek(to: 2)
        XCTAssertTrue(controller.state.isPlaying)
        XCTAssertEqual(controller.state.position, 2, accuracy: 0.02)
        controller.setSpeed(2)
        XCTAssertTrue(controller.state.isPlaying)
        XCTAssertEqual(controller.state.position, 2, accuracy: 0.02)
        controller.selectTrack(.other)
        XCTAssertTrue(controller.state.isPlaying)
        controller.seek(to: 4.8)
        expectation(for: NSPredicate { _, _ in !controller.state.isPlaying && controller.state.position == 5 }, evaluatedWith: nil)
        waitForExpectations(timeout: 3)
        controller.play()
        XCTAssertTrue(controller.state.isPlaying)
        XCTAssertLessThan(controller.state.position, 0.1, "Play at EOF restarts from the beginning")
        controller.pause()
        XCTAssertFalse(controller.state.isPlaying)
        controller.seek(to: -.infinity)
        XCTAssertEqual(controller.state.position, 0)
        controller.seek(to: -10)
        XCTAssertEqual(controller.state.position, 0)
        controller.seek(to: 50)
        XCTAssertEqual(controller.state.position, 5)
        controller.load(MeetingPlayback(capability: .microphoneOnly, microphonePath: mic.path, message: "Second"))
        oldCallback?(4, true)
        XCTAssertFalse(oldPlayer.isPlaying)
        XCTAssertEqual(controller.state.source?.message, "Second")
        XCTAssertEqual(controller.state.position, 0)
        XCTAssertFalse(controller.state.isPlaying)
        XCTAssertEqual(controller.state.speed, 1)
        XCTAssertEqual(controller.state.track, .both)
        controller.selectTrack(.other)
        XCTAssertEqual(controller.state.track, .both, "Missing Other track cannot masquerade as available")
        controller.setSpeed(.nan)
        XCTAssertEqual(controller.state.speed, 1)
    }

    @MainActor
    func testMissingPurgedCorruptAndUnavailableEvidenceDisablesPlayback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mic = try audio(root.appendingPathComponent("mic.caf"), amplitude: 0.1)
        let source = MeetingPlayback(capability: .microphoneOnly, microphonePath: mic.path, message: "Partial microphone only")
        let controller = MeetingAudioPlaybackController()
        controller.load(source)
        XCTAssertTrue(controller.state.isAvailable)
        try FileManager.default.removeItem(at: mic)
        controller.play()
        XCTAssertFalse(controller.state.isAvailable)
        XCTAssertTrue(controller.state.errorMessage?.contains("no longer retained") == true)
        XCTAssertNil(controller.activePlayer)
        controller.seek(to: 1)
        controller.selectTrack(.other)
        controller.setSpeed(2)
        XCTAssertFalse(controller.state.isPlaying)
        let corrupt = Data("not audio".utf8)
        try corrupt.write(to: mic)
        controller.load(source)
        XCTAssertFalse(controller.state.isAvailable)
        XCTAssertNotNil(controller.state.errorMessage)
        XCTAssertEqual(try Data(contentsOf: mic), corrupt)
        controller.load(MeetingPlayback(capability: .unavailable, message: "Source no longer retained"))
        XCTAssertFalse(controller.state.isAvailable)
        XCTAssertNil(controller.activePlayer)
        controller.stop()
        controller.stop()
        XCTAssertNil(controller.state.source)
        controller.play()
        controller.pause()
    }

    private func audio(_ url: URL, amplitude: Float, secondAmplitude: Float = 0) throws -> URL {
        let compressed = url.pathExtension == "m4a"
        let rate = compressed ? 48_000 : 8_000
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 1))
        var settings = format.settings
        if compressed { settings[AVFormatIDKey] = kAudioFormatMPEG4AAC }
        let writer = try AVAudioFile(forWriting: url, settings: settings)
        let frames = AVAudioFrameCount(rate * 2)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for i in 0..<Int(frames) { buffer.floatChannelData?[0][i] = i < rate ? amplitude : secondAmplitude }
        try writer.write(from: buffer)
        return url
    }
}
