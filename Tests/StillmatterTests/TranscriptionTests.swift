import Foundation
import Darwin
import XCTest
@testable import StillmatterCore

final class TranscriptionTests: XCTestCase {
    func testDiarizationTurnsRetainTrackTimingOverlapAndAnonymousClustersInTranscriptJSON() throws {
        let fixture = try TranscriptionFixture()
        let diarizer = StubSpeakerDiarizationEngine(turnsByTrack: [
            .microphone: [SpeakerDiarizationTurn(startSeconds: 1.0, endSeconds: 2.0, clusterID: 8)],
            .systemAudio: [
                SpeakerDiarizationTurn(startSeconds: 1.4, endSeconds: 2.2, clusterID: 3),
                SpeakerDiarizationTurn(startSeconds: 1.8, endSeconds: 2.5, clusterID: 1)
            ]
        ])
        let pipeline = TranscriptionPipeline(workspaceRootURL: fixture.workspaceRootURL,
            bundleValidator: AcceptingBundleValidator(),
            engine: StubTranscriptionEngine(textByTrack: [.microphone: "Mic", .systemAudio: "Remote"]),
            diarizationEngine: diarizer)

        let result = try pipeline.generate(from: fixture.makeBundle(system: fixture.bundle.system), selection: nil, language: .english)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let persisted = try decoder.decode(TranscriptDocument.self, from: result.json)
        let plainText = try MeetingTranscriptCodec.text(result.json)
        let roundTrip = try MeetingTranscriptCodec.json(plainText, path: "Meetings/fixture/transcript.txt")
        let roundTripDocument = try MeetingTranscriptCodec.document(roundTrip, path: "Meetings/fixture/transcript.json")

        XCTAssertEqual(diarizer.audioTracks, [.microphone, .systemAudio])
        XCTAssertEqual(persisted.speakerTurns?.map(\.track), [.microphone, .systemAudio, .systemAudio])
        XCTAssertEqual(persisted.speakerTurns?.map(\.clusterID), [8, 3, 1])
        XCTAssertEqual(persisted.speakerTurns?.map(\.startSeconds), [1.0, 1.4, 1.8])
        XCTAssertEqual(persisted.speakerTurns?.map(\.attributionMethod),
                       [.localAcousticDiarization, .localAcousticDiarization, .localAcousticDiarization])
        XCTAssertEqual(roundTripDocument.speakerTurns, persisted.speakerTurns)
        XCTAssertTrue((persisted.speakerTurns?[1].endSeconds ?? 0) > (persisted.speakerTurns?[2].startSeconds ?? .infinity),
                      "Overlapping acoustic turns must remain overlapping in the canonical Transcript")
        XCTAssertTrue(persisted.segments.allSatisfy { $0.speaker == $0.track.speakerLabel },
                      "Anonymous cluster ordinals must not be presented as known Person identities")
    }

    func testDiarizerLabelReorderingDoesNotChangeTranscriptIdentityLabels() throws {
        func transcript(clusterIDs: [Int]) throws -> TranscriptDocument {
            let fixture = try TranscriptionFixture()
            let diarizer = StubSpeakerDiarizationEngine(turnsByTrack: [
                .microphone: [SpeakerDiarizationTurn(startSeconds: 0.2, endSeconds: 0.8, clusterID: clusterIDs[0])],
                .systemAudio: [
                    SpeakerDiarizationTurn(startSeconds: 1.0, endSeconds: 1.7, clusterID: clusterIDs[1]),
                    SpeakerDiarizationTurn(startSeconds: 2.0, endSeconds: 2.8, clusterID: clusterIDs[2])
                ]
            ])
            let pipeline = TranscriptionPipeline(workspaceRootURL: fixture.workspaceRootURL,
                bundleValidator: AcceptingBundleValidator(),
                engine: StubTranscriptionEngine(textByTrack: [.microphone: "Me", .systemAudio: "One, then two"]),
                diarizationEngine: diarizer)
            return try pipeline.generate(from: fixture.makeBundle(system: fixture.bundle.system), selection: nil,
                language: .english).document
        }

        let first = try transcript(clusterIDs: [0, 0, 1])
        let reordered = try transcript(clusterIDs: [0, 1, 0])

        XCTAssertEqual(first.segments.map(\.speaker), reordered.segments.map(\.speaker))
        XCTAssertEqual(first.segments.map(\.speaker), ["Me", "Meeting audio"])
        XCTAssertEqual(first.speakerTurns?.map(\.clusterID), [0, 0, 1])
        XCTAssertEqual(reordered.speakerTurns?.map(\.clusterID), [0, 1, 0])
        XCTAssertFalse(first.segments.contains { $0.speaker.contains("0") || $0.speaker.contains("1") })
    }

    func testEchoCancellationFallbackUsesOriginalMicrophoneAndKeepsClustersAnonymous() throws {
        let fixture = try TranscriptionFixture()
        let bundle = fixture.makeBundle(system: fixture.bundle.system)
        let rawMicrophone = try Data(contentsOf: fixture.microphoneURL)
        let sidecar = TranscriptionAudioSidecar(
            schemaVersion: TranscriptionAudioSidecar.currentSchemaVersion,
            captureSessionID: bundle.captureSessionID,
            recordingBundlePath: bundle.bundleFilePath,
            selection: .originalMicrophone,
            selectedAudioFilePath: fixture.microphoneURL.path,
            originalMicrophoneFilePath: fixture.microphoneURL.path,
            systemReferenceFilePath: fixture.systemAudioURL.path,
            echoCancelledFilePath: nil,
            metadataFilePath: fixture.selectionURL.path,
            generatedAt: fixture.generatedAt,
            quality: EchoCancellationQuality(confidence: 0.1, referenceCorrelation: 0.02,
                estimatedEchoReductionDB: 0.1, retainedSignalRatio: 0.9),
            diagnostics: ["Echo cancellation was uncertain; transcription will use the original microphone track."]
        )
        let transcription = StubTranscriptionEngine(textByTrack: [.microphone: "Me", .systemAudio: "Remote"])
        let diarizer = StubSpeakerDiarizationEngine(turnsByTrack: [
            .microphone: [SpeakerDiarizationTurn(startSeconds: 0.4, endSeconds: 1.1, clusterID: 7)],
            .systemAudio: [SpeakerDiarizationTurn(startSeconds: 0.5, endSeconds: 1.3, clusterID: 2)]
        ])
        let pipeline = TranscriptionPipeline(workspaceRootURL: fixture.workspaceRootURL,
            bundleValidator: AcceptingBundleValidator(), engine: transcription, diarizationEngine: diarizer)

        let document = try pipeline.generate(from: bundle, selection: sidecar, language: .english).document

        XCTAssertEqual(transcription.audioPaths, [fixture.microphoneURL.path, fixture.systemAudioURL.path])
        XCTAssertEqual(diarizer.audioPaths, [fixture.microphoneURL.path, fixture.systemAudioURL.path])
        XCTAssertEqual(document.audioSources[0].selection, TranscriptionAudioSelection.originalMicrophone.rawValue)
        XCTAssertTrue(document.diagnostics.contains { $0.contains("Echo cancellation was uncertain") })
        XCTAssertEqual(document.speakerTurns?.map(\.clusterID), [7, 2])
        XCTAssertEqual(document.segments.map(\.speaker), ["Me", "Meeting audio"])
        XCTAssertEqual(try Data(contentsOf: fixture.microphoneURL), rawMicrophone)
    }

    func testUncertainEchoCancelledSidecarKeepsMicrophoneLabelTimingAndUncertainty() throws {
        let fixture = try TranscriptionFixture()
        let bundle = fixture.makeBundle(system: fixture.bundle.system)
        let rawMicrophone = try Data(contentsOf: fixture.microphoneURL)
        let selection = TranscriptionAudioSidecar(
            schemaVersion: TranscriptionAudioSidecar.currentSchemaVersion,
            captureSessionID: bundle.captureSessionID,
            recordingBundlePath: bundle.bundleFilePath,
            selection: .echoCancelledSidecar,
            selectedAudioFilePath: fixture.echoSidecarURL.path,
            originalMicrophoneFilePath: fixture.microphoneURL.path,
            systemReferenceFilePath: fixture.systemAudioURL.path,
            echoCancelledFilePath: fixture.echoSidecarURL.path,
            metadataFilePath: fixture.selectionURL.path,
            generatedAt: fixture.generatedAt,
            quality: EchoCancellationQuality(confidence: 0.9, referenceCorrelation: 0.8,
                estimatedEchoReductionDB: 8, retainedSignalRatio: 0.9),
            diagnostics: ["Possible local speech or echo-path variation was detected; residual was retained without extra attenuation."]
        )
        let transcription = StubTranscriptionEngine(textByTrack: [
            .microphone: "Quiet reply retained", .systemAudio: "Remote speaker"
        ])
        let diarizer = StubSpeakerDiarizationEngine(turnsByTrack: [
            .microphone: [SpeakerDiarizationTurn(startSeconds: 5, endSeconds: 7, clusterID: 4)],
            .systemAudio: [SpeakerDiarizationTurn(startSeconds: 5, endSeconds: 7, clusterID: 9)]
        ])
        let pipeline = TranscriptionPipeline(workspaceRootURL: fixture.workspaceRootURL,
            bundleValidator: AcceptingBundleValidator(), engine: transcription, diarizationEngine: diarizer)

        let document = try pipeline.generate(from: bundle, selection: selection, language: .english).document

        XCTAssertEqual(transcription.audioPaths, [fixture.echoSidecarURL.path, fixture.systemAudioURL.path])
        XCTAssertEqual(diarizer.audioPaths, [fixture.echoSidecarURL.path, fixture.systemAudioURL.path])
        XCTAssertEqual(document.audioSources[0].track, .microphone)
        XCTAssertEqual(document.audioSources[0].selection, TranscriptionAudioSelection.echoCancelledSidecar.rawValue)
        XCTAssertEqual(document.segments.first?.track, .microphone)
        XCTAssertEqual(document.segments.first?.speaker, "Me")
        XCTAssertEqual(document.segments.first?.startSeconds, 1)
        XCTAssertEqual(document.segments.first?.endSeconds, 3)
        XCTAssertEqual(document.speakerTurns?.first?.startSeconds, 5)
        XCTAssertEqual(document.speakerTurns?.first?.track, .microphone)
        XCTAssertTrue(document.diagnostics.contains { $0.contains("Possible local speech or echo-path variation") })
        XCTAssertEqual(try Data(contentsOf: fixture.microphoneURL), rawMicrophone)
    }

    func testSpeakerCorrectionEvidenceSurvivesCanonicalTranscriptRoundTrip() throws {
        let fixture = try TranscriptionFixture()
        let diarizer = StubSpeakerDiarizationEngine(turnsByTrack: [.microphone: [
            SpeakerDiarizationTurn(startSeconds: 0.25, endSeconds: 1.1, clusterID: 4)
        ]])
        let pipeline = TranscriptionPipeline(workspaceRootURL: fixture.workspaceRootURL,
            bundleValidator: AcceptingBundleValidator(),
            engine: StubTranscriptionEngine(textByTrack: [.microphone: "Me"]), diarizationEngine: diarizer)
        let generated = try pipeline.generate(from: fixture.makeBundle(system: nil), selection: nil,
            language: .english).json
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: generated) as? [String: Any])
        var segments = try XCTUnwrap(document["segments"] as? [[String: Any]])
        segments[0]["person_id"] = "person-42"
        segments[0]["attribution_evidence"] = ["method": "user-corrected", "source": "transcript-review"]
        document["segments"] = segments
        let correctedJSON = try MeetingTranscriptCodec.encodeJSON(document)

        let text = try MeetingTranscriptCodec.text(correctedJSON)
        let roundTripJSON = try MeetingTranscriptCodec.json(text, path: "Meetings/fixture/transcript.txt")
        let roundTrip = try XCTUnwrap(JSONSerialization.jsonObject(with: roundTripJSON) as? [String: Any])
        let roundTripSegments = try XCTUnwrap(roundTrip["segments"] as? [[String: Any]])
        let evidence = try XCTUnwrap(roundTripSegments.first)
        let expectedTurns = try MeetingTranscriptCodec.encodeJSON(try XCTUnwrap(document["speaker_turns"]))
        let actualTurns = try MeetingTranscriptCodec.encodeJSON(try XCTUnwrap(roundTrip["speaker_turns"]))

        XCTAssertEqual(evidence["person_id"] as? String, "person-42")
        XCTAssertEqual(evidence["attribution_evidence"] as? [String: String], [
            "method": "user-corrected", "source": "transcript-review"
        ])
        XCTAssertEqual(actualTurns, expectedTurns)
    }

    func testSpeakerTurnsRecordAttributionMethodAndReadEarlierTurnJSON() throws {
        let encoded = try JSONEncoder().encode(TranscriptSpeakerTurn(
            startSeconds: 0.2, endSeconds: 1.0, track: .systemAudio, clusterID: 6))
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(value["attribution_method"] as? String, "local-acoustic-diarization")
        XCTAssertEqual(value["cluster_id"] as? Int, 6)
        XCTAssertEqual(value["start"] as? Double, 0.2)

        let earlier = Data(#"{"startSeconds":0.2,"endSeconds":1.0,"track":"system-audio","clusterID":6}"#.utf8)
        let decoded = try JSONDecoder().decode(TranscriptSpeakerTurn.self, from: earlier)
        XCTAssertEqual(decoded.attributionMethod, .localAcousticDiarization)
        XCTAssertEqual(decoded.clusterID, 6)
    }

    func testDiarizationFailureKeepsAudioAndReusesCompletedTrackCheckpointOnRetry() throws {
        let fixture = try TranscriptionFixture()
        let bundle = fixture.makeBundle(system: fixture.bundle.system)
        let meetingFolder = fixture.workspaceRootURL.appendingPathComponent(bundle.meetingRelativePath).deletingLastPathComponent()
        let transcriptURL = meetingFolder.appendingPathComponent("transcript.json")
        let failingDiarizer = StubSpeakerDiarizationEngine(turnsByTrack: [.microphone: [
            SpeakerDiarizationTurn(startSeconds: 0.1, endSeconds: 0.8, clusterID: 0)
        ]], failingTracks: [.systemAudio])
        let transcriber = StubTranscriptionEngine(textByTrack: [.microphone: "Mic", .systemAudio: "Remote"])
        let firstAttempt = TranscriptionPipeline(workspaceRootURL: fixture.workspaceRootURL,
            bundleValidator: AcceptingBundleValidator(), engine: transcriber, diarizationEngine: failingDiarizer)

        XCTAssertThrowsError(try firstAttempt.generate(from: bundle, selection: nil, language: .english))
        XCTAssertFalse(FileManager.default.fileExists(atPath: transcriptURL.path),
                       "A partial attribution run must not publish a completed Transcript")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.microphoneURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.systemAudioURL.path))

        let retryDiarizer = StubSpeakerDiarizationEngine(turnsByTrack: [.systemAudio: [
            SpeakerDiarizationTurn(startSeconds: 0.3, endSeconds: 1.0, clusterID: 2)
        ]])
        let retry = TranscriptionPipeline(workspaceRootURL: fixture.workspaceRootURL,
            bundleValidator: AcceptingBundleValidator(), engine: transcriber, diarizationEngine: retryDiarizer)
        let result = try retry.generate(from: bundle, selection: nil, language: .english)

        XCTAssertEqual(retryDiarizer.audioTracks, [.systemAudio], "The successful microphone attribution checkpoint should be reused")
        XCTAssertEqual(result.document.speakerTurns?.map(\.track), [.microphone, .systemAudio])
        XCTAssertTrue(FileManager.default.fileExists(atPath: transcriptURL.path))
    }

    func testAutomaticLanguageIsPersistedAsAJobSetting() throws {
        XCTAssertEqual(TranscriptLanguage.automatic.rawValue, "auto")
        XCTAssertEqual(TranscriptLanguage.automatic.displayName, "Auto")

        let fixture = try TranscriptionFixture()
        let manifest = TranscriptionJob.manifest(
            title: "Automatic",
            bundle: fixture.bundle,
            selection: fixture.selection,
            language: .automatic
        )

        XCTAssertEqual(manifest.metadata["language"], "auto")
    }

    func testWindowedAutomaticEngineSkipsGlobalLanguageSampling() throws {
        let fixture = try TranscriptionFixture()
        let engine = WindowedAutoStubTranscriptionEngine()
        let pipeline = TranscriptionPipeline(workspaceRootURL: fixture.workspaceRootURL,
            bundleValidator: AcceptingBundleValidator(), engine: engine)

        let result = try pipeline.generate(from: fixture.makeBundle(system: nil), selection: nil,
            language: .automatic)

        XCTAssertEqual(engine.languages, [.automatic])
        XCTAssertEqual(result.document.language, .automatic)
        XCTAssertEqual(result.document.detectedLanguages, [.ukrainian, .english])
        XCTAssertEqual(result.document.segments.map(\.language), [.ukrainian, .english])
        XCTAssertTrue(result.document.diagnostics.contains {
            $0.contains("one-minute windows for the first 15 minutes")
                && $0.contains("keeps the last sampled language")
        })
    }

    func testAutomaticLanguageComparesStartAndMinuteTenInBothLanguagesBeforeWholeTrackDecode() throws {
        let fixture = try TranscriptionFixture()
        let engine = SamplingStubTranscriptionEngine()
        let pipeline = TranscriptionPipeline(
            workspaceRootURL: fixture.workspaceRootURL,
            bundleValidator: AcceptingBundleValidator(),
            engine: engine
        )

        let result = try pipeline.generate(from: fixture.makeBundle(system: nil), selection: nil, language: .automatic,
            cancellation: JobExecutionCancellation())

        XCTAssertEqual(engine.samples.map(\.startSeconds), [0, 0, 600, 600])
        XCTAssertEqual(engine.samples.map(\.language), [.english, .ukrainian, .english, .ukrainian])
        XCTAssertEqual(engine.transcriptions, [.ukrainian], "Only the selected language should decode the full track")
        XCTAssertEqual(result.document.language, .ukrainian)
        XCTAssertEqual(result.document.segments.map(\.language), [.ukrainian])
        XCTAssertTrue(result.document.diagnostics.contains { $0.contains("Auto selected uk") })
    }

    func testAutomaticLanguageChoosesEnglishWhenItsSampleScoresAreHigher() throws {
        let fixture = try TranscriptionFixture()
        let engine = SamplingStubTranscriptionEngine(scores: [.english: -0.1, .ukrainian: -0.4])
        let pipeline = TranscriptionPipeline(workspaceRootURL: fixture.workspaceRootURL,
            bundleValidator: AcceptingBundleValidator(), engine: engine)

        let result = try pipeline.generate(from: fixture.makeBundle(system: nil), selection: nil, language: .automatic)

        XCTAssertEqual(engine.transcriptions, [.english])
        XCTAssertEqual(result.document.language, .english)
        XCTAssertTrue(result.document.diagnostics.contains { $0.contains("Auto selected en") })
    }

    func testAutomaticLanguageUsesRecognizerAutoWhenCandidateScoresTie() throws {
        let fixture = try TranscriptionFixture()
        let engine = SamplingStubTranscriptionEngine(scores: [.english: -0.2, .ukrainian: -0.2])
        let pipeline = TranscriptionPipeline(workspaceRootURL: fixture.workspaceRootURL,
            bundleValidator: AcceptingBundleValidator(), engine: engine)

        let result = try pipeline.generate(from: fixture.makeBundle(system: nil), selection: nil, language: .automatic)

        XCTAssertEqual(engine.transcriptions, [.automatic])
        XCTAssertEqual(result.document.language, .automatic)
        XCTAssertTrue(result.document.diagnostics.contains { $0.contains("scores tied") })
    }

    func testAutomaticLanguageLeavesSilentRecordingOnRecognizerAutoWhenSamplesHaveNoSpeech() throws {
        let fixture = try TranscriptionFixture()
        let engine = SamplingStubTranscriptionEngine(sampleHasSpeech: false)
        let pipeline = TranscriptionPipeline(
            workspaceRootURL: fixture.workspaceRootURL,
            bundleValidator: AcceptingBundleValidator(),
            engine: engine
        )

        let result = try pipeline.generate(from: fixture.makeBundle(system: nil), selection: nil, language: .automatic)

        XCTAssertEqual(engine.transcriptions, [.automatic])
        XCTAssertEqual(result.document.language, .automatic)
        XCTAssertTrue(result.document.diagnostics.contains { $0.contains("no speech") })
    }

    func testAutomaticLanguageReportsUnsupportedEngineBeforeDecodingAudio() throws {
        let fixture = try TranscriptionFixture()
        let engine = StubTranscriptionEngine(textByTrack: [.microphone: "Should not run"])
        let pipeline = TranscriptionPipeline(workspaceRootURL: fixture.workspaceRootURL,
            bundleValidator: AcceptingBundleValidator(), engine: engine)

        XCTAssertThrowsError(try pipeline.generate(from: fixture.makeBundle(system: nil), selection: nil, language: .automatic)) { error in
            guard case TranscriptionError.missingConfiguration = error else {
                return XCTFail("Expected Auto capability guidance, got \(error)")
            }
        }
        XCTAssertTrue(engine.audioPaths.isEmpty)
    }

    func testSuccessfulTrackCheckpointIsReusedAfterAnotherTrackFails() throws {
        let fixture = try TranscriptionFixture()
        let firstEngine = StubTranscriptionEngine(
            textByTrack: [.microphone: "Mic words", .systemAudio: "Other words"],
            failingTracks: [.systemAudio]
        )
        let firstPipeline = TranscriptionPipeline(
            workspaceRootURL: fixture.workspaceRootURL,
            bundleValidator: AcceptingBundleValidator(),
            engine: firstEngine
        )

        XCTAssertThrowsError(try firstPipeline.generate(from: fixture.bundle, selection: fixture.selection, language: .english))
        XCTAssertEqual(firstEngine.languages, [.english, .english])
        XCTAssertEqual(try Data(contentsOf: fixture.microphoneURL), Data("audio".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.workspaceRootURL
            .appendingPathComponent("Meetings/2027/01/15/10-00-roadmap/.transcription-checkpoints.json").path))

        let retryEngine = StubTranscriptionEngine(textByTrack: [.microphone: "Mic words", .systemAudio: "Other words"])
        let retryPipeline = TranscriptionPipeline(
            workspaceRootURL: fixture.workspaceRootURL,
            bundleValidator: AcceptingBundleValidator(),
            engine: retryEngine
        )
        let artifacts = try retryPipeline.generate(from: fixture.bundle, selection: fixture.selection, language: .english)

        XCTAssertEqual(retryEngine.audioPaths, [fixture.systemAudioURL.path], "The completed microphone track should be reused")
        XCTAssertEqual(artifacts.document.segments.map(\.text), ["Mic words", "Other words"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.workspaceRootURL
            .appendingPathComponent("Meetings/2027/01/15/10-00-roadmap/.transcription-checkpoints.json").path))
    }

    func testAutomaticWhisperTranscriptionFailsWhenDetectedLanguageIsUnsupported() throws {
        let fixture = try TranscriptionFixture()
        let executable = fixture.rootURL.appendingPathComponent("unknown-language-whisper.sh")
        let script = """
        #!/bin/sh
        prefix=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "-of" ]; then prefix="$2"; shift 2; else shift; fi
        done
        cat > "${prefix}.json" <<'JSON'
        {"result":{"language":"fr"},"transcription":[{"offsets":{"from":250,"to":1500},"text":" Bonjour "}]}
        JSON
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let model = fixture.rootURL.appendingPathComponent("model.bin")
        try Data("model".utf8).write(to: model)
        let engine = WhisperCLITranscriptionEngine(executableURL: executable, modelURL: model)

        XCTAssertThrowsError(try engine.transcribe(audioURL: fixture.echoSidecarURL, language: .automatic, track: .microphone)) { error in
            guard case TranscriptionError.invalidEngineOutput = error else {
                return XCTFail("Expected an unsupported detected language failure, got \(error)")
            }
        }
    }

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

    func testObsoleteTranscriptionCannotOverwriteFilesEditedDuringInference() throws {
        let fixture = try TranscriptionFixture()
        let paths = TranscriptionPipeline.artifactPaths(meetingRelativePath: fixture.bundle.meetingRelativePath)
        let json = fixture.workspaceRootURL.appendingPathComponent(paths.json)
        try FileManager.default.createDirectory(at: json.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("Original saved transcript".utf8).write(to: json)
        let engine = StubTranscriptionEngine(textByTrack: [.microphone: "Obsolete generated phrase"])
        engine.onTranscribe = { try Data("Newer authoritative transcript".utf8).write(to: json, options: .atomic) }
        let pipeline = TranscriptionPipeline(workspaceRootURL: fixture.workspaceRootURL,
            bundleValidator: AcceptingBundleValidator(), engine: engine)
        XCTAssertThrowsError(try pipeline.generate(from: fixture.makeBundle(system: nil), selection: nil, language: .english))
        XCTAssertEqual(try String(contentsOf: json), "Newer authoritative transcript")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.workspaceRootURL.appendingPathComponent(paths.vtt).path))
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
        XCTAssertTrue(manifest.stages[0].title.localizedCaseInsensitiveContains("speaker turns"))
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
        let manifest = try MeetingWorkflowJob.manifest(transcription: TranscriptionJob.manifest(
            title: "Roadmap",
            bundle: fixture.bundle,
            selection: fixture.selection,
            language: .english
        ))

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

    func testJobExecutorSurfacesDiarizationFailureWithoutPublishingTranscript() throws {
        let fixture = try TranscriptionFixture()
        let pipeline = TranscriptionPipeline(workspaceRootURL: fixture.workspaceRootURL,
            bundleValidator: AcceptingBundleValidator(),
            engine: StubTranscriptionEngine(textByTrack: [.microphone: "Me", .systemAudio: "Remote"]),
            diarizationEngine: StubSpeakerDiarizationEngine(turnsByTrack: [.microphone: [
                SpeakerDiarizationTurn(startSeconds: 0.2, endSeconds: 0.8, clusterID: 0)
            ]], failingTracks: [.systemAudio]))
        let executor = TranscriptionJobExecutor(pipeline: pipeline, onTranscriptGenerated: { _, _ in
            XCTFail("A failed speaker-attribution stage must not publish a complete Transcript")
        })
        let manifest = try MeetingWorkflowJob.manifest(transcription: TranscriptionJob.manifest(
            title: "Roadmap", bundle: fixture.bundle, selection: fixture.selection, language: .english))
        let job = JobRecord(id: "diarization-failure", manifest: manifest, status: .running, stages: [],
            createdAt: "2027-01-15T10:00:00Z", updatedAt: "2027-01-15T10:00:00Z", failureDetails: nil)
        let completed = expectation(description: "attribution stage failed")
        executor.execute(job: job, stage: manifest.stages[0]) { result in
            guard case let .failure(error) = result else {
                XCTFail("A partial diarization run must return a failed Job stage")
                completed.fulfill()
                return
            }
            XCTAssertTrue(error.localizedDescription.contains("fixture failure for system-audio"))
            XCTAssertEqual(manifest.stages[0].id, TranscriptionJob.stageID)
            XCTAssertTrue(manifest.stages[0].title.localizedCaseInsensitiveContains("speaker turns"))
            completed.fulfill()
        }

        wait(for: [completed], timeout: 2)
        let paths = TranscriptionPipeline.artifactPaths(meetingRelativePath: fixture.bundle.meetingRelativePath)
        for path in [paths.markdown, paths.json, paths.vtt] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.workspaceRootURL.appendingPathComponent(path).path))
        }
    }

    func testProductionTranscriptionExecutorQuiescesCancellationBeforePublishing() throws {
        let fixture = try TranscriptionFixture()
        let started = expectation(description: "transcription engine started")
        let engine = BlockingCancellableTranscriptionEngine(started: started)
        let pipeline = TranscriptionPipeline(workspaceRootURL: fixture.workspaceRootURL,
            bundleValidator: AcceptingBundleValidator(), engine: engine)
        let publicationLock = NSLock()
        var published = false
        let executor = TranscriptionJobExecutor(pipeline: pipeline, onTranscriptGenerated: { _, _ in
            publicationLock.lock(); published = true; publicationLock.unlock()
        })
        let transcription = TranscriptionJob.manifest(title: "Roadmap", bundle: fixture.makeBundle(system: nil),
            selection: fixture.selection, language: .english)
        let manifest = try MeetingWorkflowJob.manifest(transcription: transcription)
        let job = JobRecord(id: "cancel-transcription", manifest: manifest, status: .running, stages: [],
            createdAt: "2027-01-15T10:00:00Z", updatedAt: "2027-01-15T10:00:00Z", failureDetails: nil)
        let cancellation = JobExecutionCancellation()
        let completed = expectation(description: "cancelled transcription completed")
        executor.execute(job: job, stage: manifest.stages[0], cancellation: cancellation) { result in
            guard case .failure = result else { XCTFail("Cancelled stage unexpectedly succeeded"); completed.fulfill(); return }
            completed.fulfill()
        }

        wait(for: [started], timeout: 2)
        XCTAssertTrue(cancellation.cancelAndWait(), "Executor must wait for its worker to stop")
        wait(for: [completed], timeout: 2)
        let paths = TranscriptionPipeline.artifactPaths(meetingRelativePath: fixture.bundle.meetingRelativePath)
        publicationLock.lock(); let wasPublished = published; publicationLock.unlock()
        XCTAssertFalse(wasPublished)
        for path in [paths.markdown, paths.json, paths.vtt] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.workspaceRootURL.appendingPathComponent(path).path))
        }
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

    func testWhisperCLIProcessStopsWhenTranscriptionIsCancelled() throws {
        let fixture = try TranscriptionFixture()
        let executable = fixture.rootURL.appendingPathComponent("hanging-whisper.sh")
        let started = fixture.rootURL.appendingPathComponent("whisper-started")
        try Data("#!/bin/sh\ntrap '' TERM\nprintf started > '\(started.path)'\nexec /bin/sleep 30\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let model = fixture.rootURL.appendingPathComponent("model.bin")
        try Data("model".utf8).write(to: model)
        let engine = WhisperCLITranscriptionEngine(executableURL: executable, modelURL: model)
        let cancellation = JobExecutionCancellation()
        let stopped = expectation(description: "whisper process stopped")
        let resultLock = NSLock()
        var result: Result<TranscriptionEngineResult, Error>?
        DispatchQueue.global().async {
            let value = Result { try engine.transcribe(audioURL: fixture.echoSidecarURL, language: .english,
                track: .microphone, cancellation: cancellation) }
            resultLock.lock(); result = value; resultLock.unlock()
            stopped.fulfill()
        }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline && !FileManager.default.fileExists(atPath: started.path) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.path), "Fake transcription process did not start")
        _ = cancellation.cancelAndWait()
        wait(for: [stopped], timeout: 3)
        resultLock.lock(); let finalResult = result; resultLock.unlock()
        guard case .failure(let error)? = finalResult else { return XCTFail("Cancelled process unexpectedly succeeded") }
        XCTAssertEqual(error as? JobsError, .executionCancelled)
        XCTAssertEqual(TranscriptionError.cancelled.description, "Transcription was cancelled.")
    }

    func testWhisperAudioConversionStopsWhenTranscriptionIsCancelled() throws {
        let fixture = try TranscriptionFixture()
        let converter = fixture.rootURL.appendingPathComponent("hanging-afconvert.sh")
        let started = fixture.rootURL.appendingPathComponent("converter-started")
        try "#!/bin/sh\nprintf started > '\(started.path)'\nexec /bin/sleep 30\n".write(
            to: converter, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: converter.path)
        let model = fixture.rootURL.appendingPathComponent("model.bin")
        try Data("model".utf8).write(to: model)
        let engine = WhisperCLITranscriptionEngine(executableURL: URL(fileURLWithPath: "/bin/sh"),
            modelURL: model, audioConverterURL: converter)
        let cancellation = JobExecutionCancellation()
        let stopped = expectation(description: "audio converter stopped")
        let resultLock = NSLock()
        var result: Result<TranscriptionEngineResult, Error>?
        DispatchQueue.global().async {
            let value = Result { try engine.transcribe(audioURL: fixture.microphoneURL, language: .english,
                track: .microphone, cancellation: cancellation) }
            resultLock.lock(); result = value; resultLock.unlock()
            stopped.fulfill()
        }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline && !FileManager.default.fileExists(atPath: started.path) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        if !FileManager.default.fileExists(atPath: started.path) {
            wait(for: [stopped], timeout: 1)
            resultLock.lock(); let earlyResult = result; resultLock.unlock()
            return XCTFail("Converter did not start: \(String(describing: earlyResult))")
        }
        _ = cancellation.cancelAndWait()
        wait(for: [stopped], timeout: 3)
        resultLock.lock(); let finalResult = result; resultLock.unlock()
        guard case .failure(let error)? = finalResult else { return XCTFail("Cancelled converter unexpectedly succeeded") }
        XCTAssertEqual(error as? JobsError, .executionCancelled)
    }
}

private final class StubTranscriptionEngine: TranscriptionEngine {
    let engineIdentifier = "test-whisper"
    let modelIdentifier = "test-model"
    var textByTrack: [TranscriptTrack: String]
    var onTranscribe: (() throws -> Void)?
    let failingTracks: Set<TranscriptTrack>
    private(set) var audioPaths: [String] = []
    private(set) var languages: [TranscriptLanguage] = []

    init(textByTrack: [TranscriptTrack: String], failingTracks: Set<TranscriptTrack> = []) {
        self.textByTrack = textByTrack
        self.failingTracks = failingTracks
    }

    func transcribe(audioURL: URL, language: TranscriptLanguage, track: TranscriptTrack) throws -> TranscriptionEngineResult {
        try onTranscribe?()
        audioPaths.append(audioURL.path)
        languages.append(language)
        if failingTracks.contains(track) { throw TranscriptionError.engineFailed("fixture failure for \(track.rawValue)") }
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

private final class StubSpeakerDiarizationEngine: SpeakerDiarizationEngine {
    let engineIdentifier = "test-sherpa-onnx"
    let modelIdentifier = "test-pyannote+titanet"
    let turnsByTrack: [TranscriptTrack: [SpeakerDiarizationTurn]]
    let failingTracks: Set<TranscriptTrack>
    private(set) var audioTracks: [TranscriptTrack] = []
    private(set) var audioPaths: [String] = []

    init(turnsByTrack: [TranscriptTrack: [SpeakerDiarizationTurn]], failingTracks: Set<TranscriptTrack> = []) {
        self.turnsByTrack = turnsByTrack
        self.failingTracks = failingTracks
    }

    func diarize(audioURL: URL) throws -> [SpeakerDiarizationTurn] {
        let track: TranscriptTrack
        switch audioURL.lastPathComponent {
        case "system.m4a":
            track = .systemAudio
        case "mic.m4a", "mic-transcription-echo-cancelled.wav":
            track = .microphone
        default:
            XCTFail("Unexpected diarization audio path: \(audioURL.path)")
            return []
        }
        audioTracks.append(track)
        audioPaths.append(audioURL.path)
        if failingTracks.contains(track) { throw SpeakerDiarizationError.invalidOutput("fixture failure for \(track.rawValue)") }
        return turnsByTrack[track] ?? []
    }
}

private final class SamplingStubTranscriptionEngine: CancellableTranscriptLanguageSamplingEngine {
    let engineIdentifier = "sampling-test-whisper"
    let modelIdentifier = "sampling-test-model"
    let sampleHasSpeech: Bool
    let scores: [TranscriptLanguage: Double]
    private(set) var samples: [TranscriptLanguageSample] = []
    private(set) var transcriptions: [TranscriptLanguage] = []

    init(sampleHasSpeech: Bool = true, scores: [TranscriptLanguage: Double] = [.english: -0.48, .ukrainian: -0.12]) {
        self.sampleHasSpeech = sampleHasSpeech
        self.scores = scores
    }

    func sampleLanguages(audioURL: URL, starts: [Double], durationSeconds: Double,
                         languages: [TranscriptLanguage], track: TranscriptTrack) throws -> [TranscriptLanguageSample] {
        starts.flatMap { start in languages.map { language in
            let hasSpeech = sampleHasSpeech && start == 0
            let sample = TranscriptLanguageSample(startSeconds: start, language: language,
                averageLogProbability: scores[language] ?? -0.48,
                speechDurationSeconds: hasSpeech ? 30 : 0)
            samples.append(sample)
            return sample
        } }
    }

    func sampleLanguages(audioURL: URL, starts: [Double], durationSeconds: Double,
                         languages: [TranscriptLanguage], track: TranscriptTrack,
                         cancellation: JobExecutionCancellation) throws -> [TranscriptLanguageSample] {
        try sampleLanguages(audioURL: audioURL, starts: starts, durationSeconds: durationSeconds,
            languages: languages, track: track)
    }

    func transcribe(audioURL: URL, language: TranscriptLanguage, track: TranscriptTrack) throws -> TranscriptionEngineResult {
        transcriptions.append(language)
        let segmentLanguage = language == .automatic ? .english : language
        return TranscriptionEngineResult(segments: [TranscriptSegment(id: "full-track", startSeconds: 1,
            endSeconds: 2, text: "Full track transcript", language: segmentLanguage,
            track: track, speaker: track.speakerLabel)], detectedLanguage: segmentLanguage)
    }
}

private final class WindowedAutoStubTranscriptionEngine: TranscriptionEngine,
    WindowedAutomaticTranscriptLanguageEngine {
    let engineIdentifier = "windowed-test-whisper"
    let modelIdentifier = "windowed-test-model"
    private(set) var languages: [TranscriptLanguage] = []

    func transcribe(audioURL: URL, language: TranscriptLanguage, track: TranscriptTrack) throws
        -> TranscriptionEngineResult {
        languages.append(language)
        return TranscriptionEngineResult(segments: [
            TranscriptSegment(id: "ukrainian-window", startSeconds: 1, endSeconds: 2,
                text: "Українські слова", language: .ukrainian, track: track, speaker: track.speakerLabel),
            TranscriptSegment(id: "english-window", startSeconds: 61, endSeconds: 62,
                text: "English words", language: .english, track: track, speaker: track.speakerLabel),
        ], detectedLanguage: .ukrainian)
    }
}

private final class BlockingCancellableTranscriptionEngine: CancellableTranscriptionEngine {
    let engineIdentifier = "blocking-test-engine"
    let modelIdentifier = "blocking-test-model"
    private let started: XCTestExpectation

    init(started: XCTestExpectation) { self.started = started }

    func transcribe(audioURL: URL, language: TranscriptLanguage, track: TranscriptTrack) throws -> TranscriptionEngineResult {
        XCTFail("Cancellable pipeline should call the cancellation-aware engine method")
        return TranscriptionEngineResult(segments: [])
    }

    func transcribe(audioURL: URL, language: TranscriptLanguage, track: TranscriptTrack,
                    cancellation: JobExecutionCancellation) throws -> TranscriptionEngineResult {
        started.fulfill()
        while !cancellation.isCancelled { Thread.sleep(forTimeInterval: 0.005) }
        throw JobsError.executionCancelled
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
