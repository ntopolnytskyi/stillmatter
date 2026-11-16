import AVFoundation
import XCTest
@testable import StillmatterCore

final class MeetingImportTests: XCTestCase {
    func testAudioImportPreservesOriginalAndEnqueuesOrdinaryWorkflow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("import-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Original.wav")
        try Self.audio(source)
        let bytes = try Data(contentsOf: source)
        let vault = WorkspaceVault(workspaceRootURL: root.appendingPathComponent("workspace"), appSupportRootURL: root.appendingPathComponent("support"))
        let jobs = try JobStore(databaseURL: root.appendingPathComponent("jobs.sqlite"))
        let service = MeetingImportService(vault: vault, mediaRootURL: root.appendingPathComponent("media"), jobStore: jobs)
        let result = try service.importFile(source)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(try jobs.jobs().count, 1)
        XCTAssertEqual(result.job.manifest.type, MeetingWorkflowJob.type)
        XCTAssertEqual(result.job.manifest.stages.map(\.id), [TranscriptionJob.stageID, MeetingSummaryJob.stageID])
        XCTAssertNotNil(try vault.versionOfMarkdown(relativePath: result.bundle.meetingRelativePath))
        try RecordingBundleFinalizer().validate(result.bundle)
        XCTAssertEqual(result.bundle.mic.role, "imported-audio")
    }

    static func audio(_ url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
        buffer.frameLength = 16_000
        for i in 0..<16_000 { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 0.17)) * 0.1 }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    func testInterruptedPhasesRecoverExactlyOneWorkflowAndKeepOriginalBytes() throws {
        for phase in [MeetingImportService.Phase.copying, .extracting, .prepared, .published, .enqueued] {
            let fixture = try Fixture()
            let bytes = try Data(contentsOf: fixture.source)
            XCTAssertThrowsError(try fixture.service.importFile(fixture.source, progress: {
                if $0 == phase { throw CocoaError(.userCancelled) }
            }))
            let reopened = MeetingImportService(vault: fixture.vault, mediaRootURL: fixture.media, jobStore: fixture.jobs)
            XCTAssertEqual(try reopened.recover(), [])
            XCTAssertEqual(try reopened.recover(), [])
            let prepared = [.prepared, .published, .enqueued].contains(phase)
            XCTAssertEqual(try fixture.jobs.jobs().count, prepared ? 1 : 0)
            let rows = try MeetingManagementService(vault: fixture.vault, jobStore: fixture.jobs).browserProjection()
            XCTAssertEqual(rows.count, prepared ? 1 : 0)
            XCTAssertEqual(try Data(contentsOf: fixture.source), bytes)
        }
    }

    func testInvalidFilesCancellationAndDeterministicOccurrenceLeaveOtherWorkUntouched() throws {
        let fixture = try Fixture()
        let unsupported = fixture.root.appendingPathComponent("document.txt")
        try Data("private text".utf8).write(to: unsupported)
        XCTAssertThrowsError(try fixture.service.importFile(unsupported)) { XCTAssertTrue($0.localizedDescription.contains("Unsupported")) }
        let corrupt = fixture.root.appendingPathComponent("broken.wav")
        try Data("not audio".utf8).write(to: corrupt)
        XCTAssertThrowsError(try fixture.service.importFile(corrupt)) { XCTAssertTrue($0.localizedDescription.contains("audio")) }
        XCTAssertThrowsError(try fixture.service.importFile(fixture.source, cancelled: { true }))
        XCTAssertEqual(try fixture.jobs.jobs().count, 0)
        let occurrence = Date(timeIntervalSince1970: 946_684_800)
        try FileManager.default.setAttributes([.modificationDate: occurrence], ofItemAtPath: fixture.source.path)
        let first = try fixture.service.importFile(fixture.source)
        let second = try fixture.service.importFile(fixture.source)
        XCTAssertNotEqual(first.bundle.captureSessionID, second.bundle.captureSessionID)
        let doorway = try fixture.vault.readMarkdown(relativePath: first.bundle.meetingRelativePath)
        let text = String(decoding: doorway.data, as: UTF8.self)
        XCTAssertTrue(text.contains("started_at: 2000-01-01T00:00:00Z"), text)
        XCTAssertTrue(text.contains("occurrence_source: file_"), text)
        XCTAssertFalse(text.contains("private text"))
        XCTAssertEqual(try fixture.service.recover(), [])
        XCTAssertEqual(try fixture.jobs.jobs().count, 2)
    }

    func testSharedMediaRecoveryCannotCleanAnotherWorkspacesPreparation() throws {
        let fixture = try Fixture()
        let otherVault = WorkspaceVault(workspaceRootURL: fixture.root.appendingPathComponent("other"), appSupportRootURL: fixture.root.appendingPathComponent("other-support"))
        let other = MeetingImportService(vault: otherVault, mediaRootURL: fixture.media, jobStore: fixture.jobs)
        let first = try fixture.service.importFile(fixture.source, progress: { phase in
            if phase == .extracting {
                XCTAssertEqual(try other.recover(), [])
                XCTAssertEqual(try fixture.service.recover(), [])
            }
        })
        let second = try other.importFile(fixture.source)
        XCTAssertNotEqual(first.bundle.captureSessionID, second.bundle.captureSessionID)
        XCTAssertNotEqual(first.job.manifest.workspaceOwner, second.job.manifest.workspaceOwner)
        XCTAssertEqual(try fixture.jobs.jobs().count, 2)
    }

    func testImportedTranscriptRemainsAnonymousSeekableAndOriginalSurvivesMeetingRemoval() throws {
        let fixture = try Fixture()
        let bytes = try Data(contentsOf: fixture.source)
        let imported = try fixture.service.importFile(fixture.source)
        let pipeline = TranscriptionPipeline(workspaceRootURL: fixture.vault.rootURL,
            bundleValidator: RecordingBundleFinalizer(), engine: ImportEngine())
        let artifacts = try pipeline.generate(from: imported.bundle, selection: nil, language: .english)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(TranscriptDocument.self, from: artifacts.json)
        XCTAssertEqual(document.segments.first?.track, .importedAudio)
        XCTAssertEqual(document.segments.first?.speaker, "Meeting audio")
        let meetings = MeetingManagementService(vault: fixture.vault, recordingMediaURL: fixture.media)
        let detail = try meetings.detail(for: imported.bundle.captureSessionID)
        XCTAssertEqual(detail.playback.message, "Imported audio")
        XCTAssertNotNil(detail.playback.microphonePath)
        XCTAssertEqual(detail.transcript.first?.seekSeconds, 0.1)
        try meetings.remove(meetingID: imported.bundle.captureSessionID)
        XCTAssertEqual(try Data(contentsOf: fixture.source), bytes)
    }

    func testVideoAudioExtractionPreservesVideoAndSeparatesImportContent() throws {
        let fixture = try Fixture()
        let video = fixture.root.appendingPathComponent("clip.mov")
        let silent = fixture.root.appendingPathComponent("silent.mov")
        let writer = try AVAssetWriter(outputURL: silent, fileType: .mov)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 32, AVVideoHeightKey: 32
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 32, kCVPixelBufferHeightKey as String: 32
        ])
        writer.add(videoInput)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 32, 32, kCVPixelFormatType_32ARGB, nil, &pixel), kCVReturnSuccess)
        let frame = try XCTUnwrap(pixel)
        CVPixelBufferLockBaseAddress(frame, [])
        memset(CVPixelBufferGetBaseAddress(frame), 0, CVPixelBufferGetDataSize(frame))
        CVPixelBufferUnlockBaseAddress(frame, [])
        let framesDone = expectation(description: "Generate video frames")
        videoInput.requestMediaDataWhenReady(on: DispatchQueue(label: "import-video-fixture")) {
            guard videoInput.isReadyForMoreMediaData else { return }
            XCTAssertTrue(adaptor.append(frame, withPresentationTime: .zero))
            videoInput.markAsFinished()
            writer.endSession(atSourceTime: CMTime(seconds: 1, preferredTimescale: 600))
            writer.finishWriting { framesDone.fulfill() }
        }
        wait(for: [framesDone], timeout: 15)
        XCTAssertEqual(writer.status, .completed)
        let composition = AVMutableComposition()
        let source = AVURLAsset(url: fixture.source)
        let audioTrack = try XCTUnwrap(source.tracks(withMediaType: .audio).first)
        let track = try XCTUnwrap(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        try track.insertTimeRange(CMTimeRange(start: .zero, duration: source.duration), of: audioTrack, at: .zero)
        let silentAsset = AVURLAsset(url: silent)
        let sourceVideo = try XCTUnwrap(silentAsset.tracks(withMediaType: .video).first)
        let videoTrack = try XCTUnwrap(composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid))
        try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 600)), of: sourceVideo, at: .zero)
        let export = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        export.outputURL = video
        export.outputFileType = .mov
        let complete = expectation(description: "Generate movie container")
        export.exportAsynchronously { complete.fulfill() }
        wait(for: [complete], timeout: 15)
        XCTAssertEqual(export.status, .completed, export.error?.localizedDescription ?? "")
        XCTAssertEqual(AVURLAsset(url: video).tracks(withMediaType: .video).count, 1)
        let bytes = try Data(contentsOf: video)
        let imported = try fixture.service.importFile(video)
        XCTAssertEqual(try Data(contentsOf: video), bytes)
        let audio = try AVAudioFile(forReading: URL(fileURLWithPath: imported.bundle.mic.preferredAudioFilePath))
        XCTAssertGreaterThan(audio.length, 0)
        let original = try fixture.service.importFile(fixture.source)
        XCTAssertNotEqual(imported.bundle.mic.preferredAudioFilePath, original.bundle.mic.preferredAudioFilePath)
        XCTAssertNotEqual(imported.job.id, original.job.id)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: imported.bundle.mic.recoveryFilePath)), bytes)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: original.bundle.mic.recoveryFilePath)), Data(contentsOf: fixture.source))
    }

    func testOneDamagedPreparedImportDoesNotPreventOtherRecovery() throws {
        let fixture = try Fixture()
        for _ in 0..<2 {
            XCTAssertThrowsError(try fixture.service.importFile(fixture.source, progress: {
                if $0 == .prepared { throw CocoaError(.userCancelled) }
            }))
        }
        let walker = FileManager.default.enumerator(at: fixture.media, includingPropertiesForKeys: nil)!
        let audio = try XCTUnwrap(walker.allObjects.compactMap { $0 as? URL }.first { $0.lastPathComponent == "audio.m4a" })
        try Data("changed".utf8).write(to: audio)
        XCTAssertEqual(try fixture.service.recover().count, 1)
        XCTAssertEqual(try fixture.jobs.jobs().count, 1)
    }

    private final class ImportEngine: TranscriptionEngine {
        let engineIdentifier = "controlled-import-test"
        let modelIdentifier = "fixture"
        func transcribe(audioURL: URL, language: TranscriptLanguage, track: TranscriptTrack) throws -> TranscriptionEngineResult {
            TranscriptionEngineResult(segments: [.init(id: "fixture", startSeconds: 0.1, endSeconds: 0.5,
                text: "Imported evidence", language: .english, track: track, speaker: track.speakerLabel)])
        }
    }

    private final class Fixture {
        let root: URL
        let source: URL
        let media: URL
        let vault: WorkspaceVault
        let jobs: JobStore
        let service: MeetingImportService
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("import-fixture-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            source = root.appendingPathComponent("Original.wav")
            try MeetingImportTests.audio(source)
            media = root.appendingPathComponent("media")
            vault = WorkspaceVault(workspaceRootURL: root.appendingPathComponent("workspace"), appSupportRootURL: root.appendingPathComponent("support"))
            jobs = try JobStore(databaseURL: root.appendingPathComponent("jobs.sqlite"))
            service = MeetingImportService(vault: vault, mediaRootURL: media, jobStore: jobs)
        }
        deinit { try? FileManager.default.removeItem(at: root) }
    }
}
