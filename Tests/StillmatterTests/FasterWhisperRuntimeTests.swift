import Foundation
import XCTest
@testable import StillmatterCore
@testable import StillmatterTranscriptionRuntime

final class FasterWhisperRuntimeTests: XCTestCase {
    func testEngineUsesDetectedLanguageForAutomaticTranscription() throws {
        let root = try makeComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let argumentsURL = root.appendingPathComponent("arguments.txt")
        let executableURL = root.appendingPathComponent("runtime/bin/python3")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > "\(argumentsURL.path)"
        cat > "$5" <<'JSON'
        {"language":"uk","segments":[{"start":0.25,"end":1.5,"text":" Привіт "}]}
        JSON
        """
        try script.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        let result = try FasterWhisperTranscriptionEngine(componentURL: root, modelIdentifier: "fixture")
            .transcribe(audioURL: URL(fileURLWithPath: "/fixture/audio.wav"), language: .automatic, track: .microphone)

        XCTAssertEqual(result.detectedLanguage, .ukrainian)
        XCTAssertEqual(result.segments.first?.language, .ukrainian)
        XCTAssertTrue(try String(contentsOf: argumentsURL, encoding: .utf8).contains("\nauto\n"))
    }

    func testAutomaticTranscriptionRejectsUnknownDetectedLanguage() throws {
        let root = try makeComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let executableURL = root.appendingPathComponent("runtime/bin/python3")
        let script = """
        #!/bin/sh
        cat > "$5" <<'JSON'
        {"language":"fr","segments":[{"start":0.25,"end":1.5,"text":" Bonjour "}]}
        JSON
        """
        try script.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        XCTAssertThrowsError(try FasterWhisperTranscriptionEngine(componentURL: root, modelIdentifier: "fixture")
            .transcribe(audioURL: URL(fileURLWithPath: "/fixture/audio.wav"), language: .automatic, track: .microphone)) { error in
                guard case TranscriptionError.invalidEngineOutput = error else {
                    return XCTFail("Expected an unsupported detected language failure, got \(error)")
                }
            }
    }

    func testAutomaticEngineUsesSelectedWindowLanguageAndReportsRussianOverride() throws {
        let root = try makeComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let executableURL = root.appendingPathComponent("runtime/bin/python3")
        let script = """
        #!/bin/sh
        cat > "$5" <<'JSON'
        {"language":"uk","window_language_selection":true,
         "language_windows":[{"start":0,"end":60,"detected_language":"ru","language_probability":0.8,
          "selected_language":"uk","russian_mapped_to_ukrainian":true}],
         "tail_language":"uk","tail_start":900,
         "segments":[{"start":0,"end":1,"text":"Привіт","language":"uk"},
          {"start":60,"end":61,"text":"Hello","language":"en"}]}
        JSON
        """
        try script.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        let result = try FasterWhisperTranscriptionEngine(componentURL: root, modelIdentifier: "fixture")
            .transcribe(audioURL: URL(fileURLWithPath: "/fixture/audio.wav"), language: .automatic,
                track: .microphone)

        XCTAssertEqual(result.detectedLanguage, .ukrainian)
        XCTAssertEqual(result.segments.map(\.language), [.ukrainian, .english])
        XCTAssertTrue(result.diagnostics.contains { $0.contains("Russian mapped to Ukrainian") })
        XCTAssertTrue(result.diagnostics.contains { $0.contains("last sampled language uk after 900s") })
    }

    func testEngineRunsManagedRuntimeAndNormalizesSegments() throws {
        let root = try makeComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let argumentsURL = root.appendingPathComponent("arguments.txt")
        let executableURL = root.appendingPathComponent("runtime/bin/python3")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > "\(argumentsURL.path)"
        cat > "$5" <<'JSON'
        {"language":"uk","segments":[{"start":1.25,"end":3.5,"text":" Привіт "},{"start":4,"end":5,"text":"   "}]}
        JSON
        """
        try script.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        let engine = FasterWhisperTranscriptionEngine(componentURL: root, modelIdentifier: "fixture")
        let result = try engine.transcribe(
            audioURL: URL(fileURLWithPath: "/fixture/audio.wav"),
            language: .ukrainian,
            track: .microphone
        )

        XCTAssertEqual(result.detectedLanguage, .ukrainian)
        XCTAssertEqual(result.segments.count, 1)
        XCTAssertEqual(result.segments.first?.id, "faster-whisper-1")
        XCTAssertEqual(result.segments.first?.startSeconds, 1.25)
        XCTAssertEqual(result.segments.first?.endSeconds, 3.5)
        XCTAssertEqual(result.segments.first?.text, "Привіт")
        XCTAssertEqual(result.segments.first?.speaker, "Me")
        let arguments = try String(contentsOf: argumentsURL, encoding: .utf8)
        XCTAssertTrue(arguments.contains("Stillmatter-transcribe-"))
        XCTAssertTrue(arguments.contains("/fixture/audio.wav"))
        XCTAssertTrue(arguments.contains("\nuk\n"))
    }

    func testEngineComparesRequestedLanguageSamplesInOneModelProcess() throws {
        let root = try makeComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let argumentsURL = root.appendingPathComponent("arguments.txt")
        let executableURL = root.appendingPathComponent("runtime/bin/python3")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > "\(argumentsURL.path)"
        cat > "$5" <<'JSON'
        {"samples":[
          {"start":0,"language":"en","average_log_probability":-0.42,"speech_duration_seconds":30},
          {"start":0,"language":"uk","average_log_probability":-0.15,"speech_duration_seconds":29},
          {"start":600,"language":"en","average_log_probability":0,"speech_duration_seconds":0},
          {"start":600,"language":"uk","average_log_probability":0,"speech_duration_seconds":0}
        ]}
        JSON
        """
        try script.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        let results = try FasterWhisperTranscriptionEngine(componentURL: root, modelIdentifier: "fixture")
            .sampleLanguages(audioURL: URL(fileURLWithPath: "/fixture/audio.wav"), starts: [0, 600],
                durationSeconds: 120, languages: [.english, .ukrainian], track: .microphone)

        XCTAssertEqual(results.map(\.startSeconds), [0, 0, 600, 600])
        XCTAssertEqual(results.map(\.language), [.english, .ukrainian, .english, .ukrainian])
        XCTAssertEqual(results[1].averageLogProbability, -0.15)
        let arguments = try String(contentsOf: argumentsURL, encoding: .utf8)
        XCTAssertTrue(arguments.contains("--samples"))
        XCTAssertTrue(arguments.contains("\n600.0\n"))
        XCTAssertTrue(arguments.contains("\n120.0\n"))
    }

    func testSampleEngineRejectsInvalidRequestsBeforeStartingRuntime() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StillmatterFasterWhisperTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = FasterWhisperTranscriptionEngine(componentURL: root, modelIdentifier: "fixture")

        XCTAssertThrowsError(try engine.sampleLanguages(audioURL: URL(fileURLWithPath: "/fixture/audio.wav"),
            starts: [], durationSeconds: 120, languages: [.english, .ukrainian], track: .microphone)) { error in
                guard case TranscriptionError.invalidEngineOutput = error else {
                    return XCTFail("Expected an invalid sample request error, got \(error)")
                }
            }
    }

    func testSampleEngineRejectsIncompleteManagedRuntime() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StillmatterFasterWhisperTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = FasterWhisperTranscriptionEngine(componentURL: root, modelIdentifier: "fixture")

        XCTAssertThrowsError(try engine.sampleLanguages(audioURL: URL(fileURLWithPath: "/fixture/audio.wav"),
            starts: [0], durationSeconds: 120, languages: [.english, .ukrainian], track: .microphone)) { error in
                guard case TranscriptionError.missingConfiguration = error else {
                    return XCTFail("Expected missing runtime configuration, got \(error)")
                }
            }
    }

    func testSampleEngineRejectsMissingQualityResults() throws {
        let root = try makeComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let executableURL = root.appendingPathComponent("runtime/bin/python3")
        let script = """
        #!/bin/sh
        cat > "$5" <<'JSON'
        {"samples":[]}
        JSON
        """
        try script.write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        XCTAssertThrowsError(try FasterWhisperTranscriptionEngine(componentURL: root, modelIdentifier: "fixture")
            .sampleLanguages(audioURL: URL(fileURLWithPath: "/fixture/audio.wav"), starts: [0],
                durationSeconds: 120, languages: [.english, .ukrainian], track: .microphone)) { error in
                    guard case TranscriptionError.invalidEngineOutput = error else {
                        return XCTFail("Expected malformed sample output error, got \(error)")
                    }
                }
    }

    func testEngineRejectsIncompleteManagedRuntime() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StillmatterFasterWhisperTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let engine = FasterWhisperTranscriptionEngine(componentURL: root, modelIdentifier: "fixture")

        XCTAssertThrowsError(try engine.transcribe(
            audioURL: URL(fileURLWithPath: "/fixture/audio.wav"),
            language: .english,
            track: .systemAudio
        )) { error in
            guard case TranscriptionError.missingConfiguration = error else {
                return XCTFail("Expected missing configuration, got \(error)")
            }
        }
    }

    func testEngineStopsManagedProcessWhenJobExecutionIsCancelled() throws {
        let root = try makeComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let executableURL = root.appendingPathComponent("runtime/bin/python3")
        let startedURL = root.appendingPathComponent("started")
        try "#!/bin/sh\ntrap '' TERM\nprintf started > '\(startedURL.path)'\nexec /bin/sleep 30\n".write(
            to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        let engine = FasterWhisperTranscriptionEngine(componentURL: root, modelIdentifier: "fixture")
        let cancellation = JobExecutionCancellation()
        let stopped = expectation(description: "managed process stopped")
        let resultLock = NSLock()
        var result: Result<TranscriptionEngineResult, Error>?
        DispatchQueue.global().async {
            let value = Result { try engine.transcribe(audioURL: URL(fileURLWithPath: "/fixture/audio.wav"),
                language: .english, track: .microphone, cancellation: cancellation) }
            resultLock.lock(); result = value; resultLock.unlock()
            stopped.fulfill()
        }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline && !FileManager.default.fileExists(atPath: startedURL.path) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: startedURL.path))
        _ = cancellation.cancelAndWait()
        wait(for: [stopped], timeout: 3)
        resultLock.lock(); let finalResult = result; resultLock.unlock()
        guard case .failure(let error)? = finalResult else { return XCTFail("Cancelled process unexpectedly succeeded") }
        XCTAssertEqual(error as? JobsError, .executionCancelled)
    }

    func testManagedProcessRunnerStopsInstallerProcessOnCancellation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StillmatterProcessRunnerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("blocking-installer.sh")
        let started = root.appendingPathComponent("installer-started")
        try "#!/bin/sh\ntrap '' TERM\nprintf started > '\(started.path)'\nwhile :; do /bin/sleep 1; done\n".write(
            to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let cancellation = TranscriptionInstallCancellation()
        let stopped = expectation(description: "installer process stopped")
        let resultLock = NSLock()
        var failure: Error?
        DispatchQueue.global().async {
            do { _ = try ProcessRunner().run(executable: executable, arguments: [], cancellation: cancellation) }
            catch { resultLock.lock(); failure = error; resultLock.unlock() }
            stopped.fulfill()
        }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline && !FileManager.default.fileExists(atPath: started.path) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: started.path))
        cancellation.cancel()
        wait(for: [stopped], timeout: 4)
        resultLock.lock(); let finalFailure = failure; resultLock.unlock()
        XCTAssertEqual(finalFailure as? TranscriptionComponentInstallError, .cancelled)
    }

    func testModelChoicesUsePinnedFasterWhisperRepositoriesAndRuntime() {
        XCTAssertEqual(FasterWhisperModelAcquirer.packageVersion, "1.2.1")
        XCTAssertEqual(TranscriptionComponentPaths.runtimeVersion, "faster-whisper-1.2.1+sherpa-onnx-2.0.1")
        XCTAssertEqual(SpeakerDiarizationModelManifest.runtimeVersion, "sherpa-onnx-2.0.1")
        XCTAssertEqual(SpeakerDiarizationModelManifest.downloadBytes, 47_215_727)
        XCTAssertEqual(SpeakerDiarizationModelManifest.segmentationArchiveSHA256,
                       "24615ee884c897d9d2ba09bb4d30da6bb1b15e685065962db5b02e76e4996488")
        XCTAssertEqual(SpeakerDiarizationModelManifest.embeddingModelSHA256,
                       "ad4a1802485d8b34c722d2a9d04249662f2ece5d28a7a039063ca22f515a789e")
        XCTAssertEqual(TranscriptionModelChoice.recommended.repository, "dropbox-dash/faster-whisper-large-v3-turbo")
        XCTAssertEqual(TranscriptionModelChoice.full.repository, "Systran/faster-whisper-large-v3")
    }

    func testAcquirerInstallsPinnedSpeakerPackagesAndBothHashCheckedModelAssets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StillmatterSpeakerAcquirer-\(UUID().uuidString)")
        let python = root.appendingPathComponent("fake-python3")
        let stage = root.appendingPathComponent("stage")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fakeRuntime = #"""
        #!/bin/sh
        if [ "$1" = "-c" ]; then printf '3.12'; exit 0; fi
        if [ "$1" = "-m" ] && [ "$2" = "venv" ]; then
          mkdir -p "$3/bin"
          cp "$0" "$3/bin/python3"
          chmod +x "$3/bin/python3"
          exit 0
        fi
        case "$1" in
          */setup_speakers.py)
            mkdir -p "$6" "$7"
            printf 'segmentation' > "$6/model.onnx"
            printf 'license' > "$6/LICENSE"
            printf 'embedding' > "$7/titanet-small.onnx"
            ;;
          */setup.py)
            mkdir -p "$4"
            printf '{}' > "$4/config.json"
            printf 'weights' > "$4/model.bin"
            printf 'tokens' > "$4/tokenizer.json"
            ;;
        esac
        exit 0
        """#
        try fakeRuntime.write(to: python, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
        let acquiring = FasterWhisperModelAcquirer(
            fileManager: .default,
            environment: ["STILLMATTER_PYTHON": python.path]
        )
        var updates: [TranscriptionInstallProgress] = []

        let component = try acquiring.acquireModel(.recommended, in: stage,
            cancellation: TranscriptionInstallCancellation(), progress: { updates.append($0) })

        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: component.appendingPathComponent("runtime/bin/python3").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: component.appendingPathComponent("speaker-segmentation/model.onnx").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: component.appendingPathComponent("speaker-segmentation/LICENSE").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: component.appendingPathComponent("speaker-embedding/titanet-small.onnx").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: component.appendingPathComponent("diarize.py").path))
        XCTAssertTrue(updates.contains { $0.phase.contains("speaker models") })
        XCTAssertEqual(updates.last?.completedBytes, TranscriptionModelChoice.recommended.downloadBytes)
    }

    func testInstallerConstrainsPyAVAndChecksAudioDecodeBeforePromotingModel() {
        XCTAssertEqual(FasterWhisperModelAcquirer.pythonPackageRequirements,
                       ["faster-whisper==1.2.1", "av>=11,<19", "sherpa-onnx==2.0.1", "sherpa-onnx-bin==2.0.1"])
        XCTAssertTrue(FasterWhisperModelAcquirer.speakerModelSetupScript.contains("hashlib.sha256"))
        XCTAssertTrue(FasterWhisperModelAcquirer.speakerModelSetupScript.contains("getmember(name)"))
        XCTAssertTrue(FasterWhisperModelAcquirer.diarizationScript.contains("OfflineSpeakerDiarizationConfig"))
        XCTAssertTrue(FasterWhisperModelAcquirer.diarizationScript.contains("provider=\"cpu\""))
        XCTAssertTrue(FasterWhisperModelAcquirer.diarizationScript.contains("np.asarray(wave, dtype=np.float32)"))
        let check = FasterWhisperModelAcquirer.transcriptionScript
        XCTAssertTrue(check.contains("decode_audio(sample.name)"),
                      "A model-only check accepts runtimes that cannot decode recordings")
        XCTAssertTrue(check.contains("decoded_audio[begin:end]"),
                      "Auto samples must use the audio decoder API supported by the pinned runtime")
        XCTAssertTrue(check.contains("window_samples = 60 * 16000"),
                      "Auto samples language in one-minute windows")
        XCTAssertTrue(check.contains("sampling_end = min(len(decoded_audio), 15 * window_samples)"),
                      "Language sampling must stop after the first 15 minutes")
        XCTAssertTrue(check.contains("tail_language = language_windows[-1][\"selected_language\"]"),
                      "Audio after the sampling period must use the last sampled language")
        XCTAssertTrue(check.contains("decoded_audio[sampling_end:], language=tail_language"),
                      "The unsampled remainder must be transcribed as one fixed-language tail")
        XCTAssertTrue(check.contains("selected_language = \"en\" if detected_language == \"en\" else \"uk\""),
                      "Russian and other unsupported detections must be transcribed as Ukrainian")
        XCTAssertTrue(check.contains("russian_mapped_to_ukrainian = detected_language == \"ru\""),
                      "Russian language detection must be recorded as an explicit Ukrainian override")
        XCTAssertTrue(check.contains("window_language_selection"),
                      "The output must identify window-based Auto results")
        XCTAssertTrue(check.contains("\"language\": segments[0][\"language\"] if segments else None"),
                      "Silence must not claim a detected transcript language")
        XCTAssertFalse(check.contains("decode_audio(audio_path, duration="),
                       "The pinned faster-whisper decoder does not accept offset/duration arguments")
        if let decode = check.range(of: "decode_audio(sample.name)"),
           let model = check.range(of: "WhisperModel(sys.argv[2]") {
            XCTAssertLessThan(decode.lowerBound, model.lowerBound)
        }
    }

    func testPythonSelectionSkipsVersionWithoutONNXRuntimeWheels() {
        let python314 = URL(fileURLWithPath: "/python3.14")
        let python313 = URL(fileURLWithPath: "/python3.13")
        let versions = [python314: (3, 14), python313: (3, 13)]

        let selected = FasterWhisperPythonSelector.select(
            candidates: [python314, python313],
            isExecutable: { _ in true },
            version: { versions[$0] }
        )

        XCTAssertEqual(selected, python313)
        XCTAssertFalse(FasterWhisperPythonSelector.isSupported(major: 3, minor: 14))
        XCTAssertTrue(FasterWhisperPythonSelector.isSupported(major: 3, minor: 9))
        XCTAssertTrue(FasterWhisperPythonSelector.isSupported(major: 3, minor: 13))
    }

    private func makeComponent() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StillmatterFasterWhisperTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("runtime/bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("model"), withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: root.appendingPathComponent("model/model.bin"))
        try Data("fixture".utf8).write(to: root.appendingPathComponent("transcribe.py"))
        return root
    }
}
