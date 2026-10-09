import Foundation
import XCTest
@testable import StillmatterCore

final class TranscriptionTests: XCTestCase {
    func testPipelineConsumesSelectedSidecarAndSystemTrackAndWritesAllFormatsAndIndex() throws {
        let fixture = try TranscriptionFixture()
        let engine = StubTranscriptionEngine(textByTrack: [
            .microphone: "I will prepare the launch plan.",
            .systemAudio: "Please share it by Friday."
        ])
        let index = try SearchIndex(databaseURL: fixture.searchDatabaseURL, workspaceRootURL: fixture.workspaceRootURL)
        let pipeline = TranscriptionPipeline(
            workspaceRootURL: fixture.workspaceRootURL,
            bundleValidator: AcceptingBundleValidator(),
            engine: engine,
            searchIndex: index,
            now: { fixture.generatedAt }
        )

        let artifacts = try pipeline.generate(
            from: fixture.bundle,
            selection: fixture.selection,
            language: .english
        )

        XCTAssertEqual(engine.audioPaths, [fixture.echoSidecarURL.path, fixture.systemAudioURL.path])
        XCTAssertEqual(engine.languages, [.english, .english])
        XCTAssertEqual(artifacts.document.audioSources.map(\.selection), [
            TranscriptionAudioSelection.echoCancelledSidecar.rawValue,
            "original-system-audio"
        ])
        XCTAssertEqual(artifacts.document.segments.map(\.speaker), ["Me", "Meeting audio"])
        XCTAssertEqual(artifacts.document.segments.map(\.id), ["segment-00001", "segment-00002"])

        let markdown = try String(contentsOf: fixture.workspaceRootURL.appendingPathComponent(artifacts.markdownRelativePath))
        XCTAssertTrue(markdown.contains("language: en"))
        XCTAssertTrue(markdown.contains("**Me:** I will prepare the launch plan."))
        let vtt = try String(contentsOf: fixture.workspaceRootURL.appendingPathComponent(artifacts.vttRelativePath))
        XCTAssertTrue(vtt.hasPrefix("WEBVTT\n"))
        XCTAssertTrue(vtt.contains("00:00:01.000 --> 00:00:03.000"))

        let indexed = try index.search("Friday", filter: SearchFilter(kinds: [.transcript]))
        XCTAssertEqual(indexed.count, 1)
        XCTAssertEqual(indexed.first?.transcriptStartSeconds, 4)
        XCTAssertEqual(indexed.first?.transcriptEndSeconds, 6)
    }

    func testLanguageOverrideRegeneratesArtifactsAndReplacesIndexedChunks() throws {
        let fixture = try TranscriptionFixture()
        let engine = StubTranscriptionEngine(textByTrack: [.microphone: "Original compass phrase."])
        let index = try SearchIndex(databaseURL: fixture.searchDatabaseURL, workspaceRootURL: fixture.workspaceRootURL)
        let pipeline = TranscriptionPipeline(
            workspaceRootURL: fixture.workspaceRootURL,
            bundleValidator: AcceptingBundleValidator(),
            engine: engine,
            searchIndex: index,
            now: { fixture.generatedAt }
        )
        var microphoneOnly = fixture.bundle
        microphoneOnly = fixture.makeBundle(system: nil)
        let original = try pipeline.generate(from: microphoneOnly, selection: fixture.selection, language: .english)
        let transcriptURL = fixture.workspaceRootURL.appendingPathComponent(original.markdownRelativePath)
        let jsonURL = fixture.workspaceRootURL.appendingPathComponent(original.jsonRelativePath)
        let vttURL = fixture.workspaceRootURL.appendingPathComponent(original.vttRelativePath)
        let originalMarkdown = try Data(contentsOf: transcriptURL)
        let originalJSON = try Data(contentsOf: jsonURL)
        let originalVTT = try Data(contentsOf: vttURL)
        let wrongSession = TranscriptionAudioSidecar(schemaVersion: fixture.selection.schemaVersion,
            captureSessionID: "wrong-session", recordingBundlePath: fixture.bundleURL.path,
            selection: .echoCancelledSidecar, selectedAudioFilePath: fixture.echoSidecarURL.path,
            originalMicrophoneFilePath: fixture.microphoneURL.path, systemReferenceFilePath: fixture.systemAudioURL.path,
            echoCancelledFilePath: fixture.echoSidecarURL.path, metadataFilePath: fixture.selectionURL.path,
            generatedAt: fixture.generatedAt, quality: nil, diagnostics: [])
        XCTAssertThrowsError(try pipeline.generate(from: microphoneOnly, selection: wrongSession, language: .ukrainian))
        XCTAssertEqual(try Data(contentsOf: transcriptURL), originalMarkdown)
        XCTAssertEqual(try Data(contentsOf: jsonURL), originalJSON)
        XCTAssertEqual(try Data(contentsOf: vttURL), originalVTT)
        engine.textByTrack = [.microphone: "Оновлений план запуску."]

        let regenerated = try pipeline.generate(from: microphoneOnly, selection: fixture.selection, language: .ukrainian)
        XCTAssertTrue(try String(contentsOf: transcriptURL).contains("Оновлений план запуску."))
        XCTAssertFalse(try String(contentsOf: transcriptURL).contains("Original compass phrase."))
        XCTAssertNotEqual(try Data(contentsOf: jsonURL), originalJSON)
        XCTAssertNotEqual(try Data(contentsOf: vttURL), originalVTT)

        XCTAssertEqual(regenerated.document.language, .ukrainian)
        XCTAssertEqual(engine.languages, [.english, .ukrainian])
        XCTAssertTrue(try index.search("compass").isEmpty)
        XCTAssertEqual(try index.search("Оновлений").count, 1)
        let decoded = try JSONDecoder.iso8601.decode(TranscriptDocument.self, from: regenerated.json)
        XCTAssertEqual(decoded.language, .ukrainian)
    }

    func testFailedSummaryHandoffRestoresAllTranscriptFilesAndSearchResults() throws {
        let fixture = try TranscriptionFixture()
        let engine = StubTranscriptionEngine(textByTrack: [.microphone: "Original compass phrase."])
        let index = try SearchIndex(databaseURL: fixture.searchDatabaseURL, workspaceRootURL: fixture.workspaceRootURL)
        let pipeline = TranscriptionPipeline(workspaceRootURL: fixture.workspaceRootURL,
            bundleValidator: AcceptingBundleValidator(), engine: engine, searchIndex: index)
        let bundle = fixture.makeBundle(system: nil)
        let original = try pipeline.generate(from: bundle, selection: fixture.selection, language: .english)
        let paths = [original.markdownRelativePath, original.jsonRelativePath, original.vttRelativePath]
        let before = try paths.map { try Data(contentsOf: fixture.workspaceRootURL.appendingPathComponent($0)) }
        engine.textByTrack = [.microphone: "A completely new phrase."]
        enum HandoffFailure: Error { case injected }
        XCTAssertThrowsError(try pipeline.generate(from: bundle, selection: fixture.selection, language: .ukrainian) { _ in
            throw HandoffFailure.injected
        })
        XCTAssertEqual(try paths.map { try Data(contentsOf: fixture.workspaceRootURL.appendingPathComponent($0)) }, before)
        XCTAssertEqual(try index.search("compass").count, 1)
        XCTAssertTrue(try index.search("completely").isEmpty)
    }

    func testFailedFirstPublishDoesNotLeavePartialTranscript() throws {
        let fixture = try TranscriptionFixture()
        let pipeline = TranscriptionPipeline(workspaceRootURL: fixture.workspaceRootURL,
            bundleValidator: AcceptingBundleValidator(),
            engine: StubTranscriptionEngine(textByTrack: [.microphone: "A new phrase."]))
        let paths = TranscriptionPipeline.artifactPaths(meetingRelativePath: fixture.bundle.meetingRelativePath)
        enum HandoffFailure: Error { case injected }
        XCTAssertThrowsError(try pipeline.generate(from: fixture.makeBundle(system: nil), selection: fixture.selection,
            language: .english) { _ in throw HandoffFailure.injected })
        for path in [paths.markdown, paths.json, paths.vtt] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.workspaceRootURL.appendingPathComponent(path).path))
        }
    }

    func testPipelineRejectsSidecarFromAnotherCaptureSession() throws {
        let fixture = try TranscriptionFixture()
        let pipeline = TranscriptionPipeline(
            workspaceRootURL: fixture.workspaceRootURL,
            bundleValidator: AcceptingBundleValidator(),
            engine: StubTranscriptionEngine(textByTrack: [:])
        )
        let invalid = TranscriptionAudioSidecar(
            schemaVersion: 1,
            captureSessionID: "different-session",
            recordingBundlePath: fixture.bundleURL.path,
            selection: .echoCancelledSidecar,
            selectedAudioFilePath: fixture.echoSidecarURL.path,
            originalMicrophoneFilePath: fixture.microphoneURL.path,
            systemReferenceFilePath: fixture.systemAudioURL.path,
            echoCancelledFilePath: fixture.echoSidecarURL.path,
            metadataFilePath: fixture.selectionURL.path,
            generatedAt: fixture.generatedAt,
            quality: nil,
            diagnostics: []
        )

        XCTAssertThrowsError(try pipeline.generate(from: fixture.bundle, selection: invalid, language: .english)) { error in
            XCTAssertEqual(
                error as? TranscriptionError,
                .invalidSidecar("capture session does not match the Recording Bundle")
            )
        }
    }

    func testManifestDeclaresSerialHeavyJobFormatsLanguageAndRegenerationStage() throws {
        let fixture = try TranscriptionFixture()

        let manifest = TranscriptionJob.manifest(
            title: "Roadmap",
            bundle: fixture.bundle,
            selection: fixture.selection,
            language: .ukrainian
        )

        XCTAssertEqual(manifest.type, "meeting.transcription")
        XCTAssertEqual(manifest.executionClass, .heavy)
        XCTAssertEqual(manifest.stages.map(\.id), ["transcribe"])
        XCTAssertEqual(manifest.metadata["language"], "uk")
        XCTAssertEqual(Set(manifest.expectedOutputs.map(\.validatorID)), ["markdown", "json", "webvtt"])
        XCTAssertEqual(manifest.maxAutomaticRetries, 1)
    }

    func testSuccessfulTranscriptionHandsDurableTranscriptToSummaryWorkflowHook() throws {
        let fixture = try TranscriptionFixture()
        let pipeline = TranscriptionPipeline(
            workspaceRootURL: fixture.workspaceRootURL,
            bundleValidator: AcceptingBundleValidator(),
            engine: StubTranscriptionEngine(textByTrack: [.microphone: "I will send the plan."])
        )
        let handedOff = expectation(description: "summary handoff")
        var handedOffPath: String?
        let executor = TranscriptionJobExecutor(
            pipeline: pipeline,
            onTranscriptGenerated: { _, artifacts in
                handedOffPath = artifacts.jsonRelativePath
                XCTAssertTrue(FileManager.default.fileExists(
                    atPath: fixture.workspaceRootURL.appendingPathComponent(artifacts.jsonRelativePath).path
                ))
                handedOff.fulfill()
            }
        )
        let manifest = TranscriptionJob.manifest(
            title: "Roadmap",
            bundle: fixture.bundle,
            selection: fixture.selection,
            language: .english
        )
        let job = JobRecord(
            id: "transcription-handoff",
            manifest: manifest,
            status: .running,
            stages: [],
            createdAt: "2027-01-15T10:00:00Z",
            updatedAt: "2027-01-15T10:00:00Z",
            failureDetails: nil
        )
        let completed = expectation(description: "transcription completed")
        executor.execute(job: job, stage: manifest.stages[0]) { result in
            if case let .failure(error) = result { XCTFail("Unexpected error: \(error)") }
            completed.fulfill()
        }

        wait(for: [handedOff, completed], timeout: 2)
        XCTAssertEqual(handedOffPath, "Meetings/2027/01/15/10-00-roadmap/transcript.json")
    }

    func testWhisperCLIAdapterPassesLanguageAndNormalizesCurrentJSONFormat() throws {
        let fixture = try TranscriptionFixture()
        let executable = fixture.rootURL.appendingPathComponent("fake-whisper.sh")
        let argumentsFile = fixture.rootURL.appendingPathComponent("arguments.txt")
        let script = """
        #!/usr/bin/env bash
        set -euo pipefail
        printf '%s\\n' "$@" > "\(argumentsFile.path)"
        prefix=""
        while (($#)); do
          if [[ "$1" == "-of" ]]; then prefix="$2"; shift 2; else shift; fi
        done
        cat > "${prefix}.json" <<'JSON'
        {"result":{"language":"uk"},"transcription":[{"offsets":{"from":1250,"to":3500},"text":" Привіт "}]}
        JSON
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let model = fixture.rootURL.appendingPathComponent("model.bin")
        try Data("model".utf8).write(to: model)
        let engine = WhisperCLITranscriptionEngine(executableURL: executable, modelURL: model)

        let result = try engine.transcribe(audioURL: fixture.echoSidecarURL, language: .ukrainian, track: .microphone)

        XCTAssertEqual(result.detectedLanguage, .ukrainian)
        XCTAssertEqual(result.segments.first?.startSeconds, 1.25)
        XCTAssertEqual(result.segments.first?.endSeconds, 3.5)
        XCTAssertEqual(result.segments.first?.speaker, "Me")
        let arguments = try String(contentsOf: argumentsFile)
        XCTAssertTrue(arguments.contains("-l\nuk\n"))
        XCTAssertTrue(arguments.contains("-oj\n"))
    }
}

private final class StubTranscriptionEngine: TranscriptionEngine {
    let engineIdentifier = "test-whisper"
    let modelIdentifier = "test-model"
    var textByTrack: [TranscriptTrack: String]
    private(set) var audioPaths: [String] = []
    private(set) var languages: [TranscriptLanguage] = []

    init(textByTrack: [TranscriptTrack: String]) {
        self.textByTrack = textByTrack
    }

    func transcribe(audioURL: URL, language: TranscriptLanguage, track: TranscriptTrack) throws -> TranscriptionEngineResult {
        audioPaths.append(audioURL.path)
        languages.append(language)
        guard let text = textByTrack[track] else { return TranscriptionEngineResult(segments: []) }
        let start = track == .microphone ? 1.0 : 4.0
        return TranscriptionEngineResult(
            segments: [TranscriptSegment(
                id: "engine-id",
                startSeconds: start,
                endSeconds: start + 2,
                text: text,
                language: language,
                track: track,
                speaker: track.speakerLabel
            )],
            detectedLanguage: language,
            diagnostics: ["fixture transcript"]
        )
    }
}

private final class AcceptingBundleValidator: RecordingBundleFinalizing {
    func finalize(
        mic: MicTrackRecordingMetadata,
        system: SystemAudioTrackRecordingMetadata?,
        reason: RecordingBundleFinalizationReason
    ) throws -> RecordingBundle {
        fatalError("Not used by transcription tests")
    }

    func validate(_ bundle: RecordingBundle) throws {}
}

private final class TranscriptionFixture {
    let rootURL: URL
    let workspaceRootURL: URL
    let mediaRootURL: URL
    let searchDatabaseURL: URL
    let microphoneURL: URL
    let systemAudioURL: URL
    let echoSidecarURL: URL
    let bundleURL: URL
    let selectionURL: URL
    let generatedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let bundle: RecordingBundle
    let selection: TranscriptionAudioSidecar

    init() throws {
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent("StillmatterTranscriptionTests-\(UUID().uuidString)")
        workspaceRootURL = rootURL.appendingPathComponent("Workspace")
        mediaRootURL = rootURL.appendingPathComponent("Media/session-1")
        searchDatabaseURL = rootURL.appendingPathComponent("AppSupport/search.sqlite")
        microphoneURL = mediaRootURL.appendingPathComponent("mic.m4a")
        systemAudioURL = mediaRootURL.appendingPathComponent("system.m4a")
        echoSidecarURL = mediaRootURL.appendingPathComponent("mic-transcription-echo-cancelled.wav")
        bundleURL = mediaRootURL.appendingPathComponent("recording-bundle.json")
        selectionURL = mediaRootURL.appendingPathComponent("transcription-audio-selection.json")
        try FileManager.default.createDirectory(at: workspaceRootURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mediaRootURL, withIntermediateDirectories: true)
        for url in [microphoneURL, systemAudioURL, echoSidecarURL] {
            try Data("audio".utf8).write(to: url)
        }
        let mic = Self.track(role: "microphone", audioURL: microphoneURL, mediaRootURL: mediaRootURL)
        let system = Self.track(role: "system-audio", audioURL: systemAudioURL, mediaRootURL: mediaRootURL)
        bundle = RecordingBundle(
            schemaVersion: 1,
            captureSessionID: "session-1",
            meetingRelativePath: "Meetings/2027/01/15/10-00-roadmap/meeting.md",
            bundleFilePath: bundleURL.path,
            finalizedAt: generatedAt,
            reason: .normalStop,
            state: .ready,
            mic: mic,
            system: system,
            diagnostics: []
        )
        selection = TranscriptionAudioSidecar(
            schemaVersion: 1,
            captureSessionID: "session-1",
            recordingBundlePath: bundleURL.path,
            selection: .echoCancelledSidecar,
            selectedAudioFilePath: echoSidecarURL.path,
            originalMicrophoneFilePath: microphoneURL.path,
            systemReferenceFilePath: systemAudioURL.path,
            echoCancelledFilePath: echoSidecarURL.path,
            metadataFilePath: selectionURL.path,
            generatedAt: generatedAt,
            quality: nil,
            diagnostics: ["sidecar selected"]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(bundle).write(to: bundleURL)
        try encoder.encode(selection).write(to: selectionURL)
    }

    deinit { try? FileManager.default.removeItem(at: rootURL) }

    func makeBundle(system: RecordingBundleTrack?) -> RecordingBundle {
        RecordingBundle(
            schemaVersion: bundle.schemaVersion,
            captureSessionID: bundle.captureSessionID,
            meetingRelativePath: bundle.meetingRelativePath,
            bundleFilePath: bundle.bundleFilePath,
            finalizedAt: bundle.finalizedAt,
            reason: bundle.reason,
            state: system == nil ? .degraded : .ready,
            mic: bundle.mic,
            system: system,
            diagnostics: bundle.diagnostics
        )
    }

    private static func track(role: String, audioURL: URL, mediaRootURL: URL) -> RecordingBundleTrack {
        RecordingBundleTrack(
            role: role,
            status: "completed",
            preferredAudioFilePath: audioURL.path,
            recoveryFilePath: mediaRootURL.appendingPathComponent("\(role)-recovery.caf").path,
            finalFilePath: audioURL.path,
            metadataFilePath: mediaRootURL.appendingPathComponent("\(role).json").path,
            recoveryFileExists: false,
            finalFileExists: true,
            metadataFileExists: false,
            recoveryFileSHA256: nil,
            finalFileSHA256: nil,
            durationSeconds: 10,
            codec: "aac",
            sampleRate: 48_000,
            channelCount: 1,
            diagnostics: []
        )
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
