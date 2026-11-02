import Foundation
import XCTest
@testable import StillmatterCore
@testable import StillmatterTranscriptionRuntime

final class FasterWhisperRuntimeTests: XCTestCase {
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
        XCTAssertTrue(arguments.contains("transcribe.py"))
        XCTAssertTrue(arguments.contains("/fixture/audio.wav"))
        XCTAssertTrue(arguments.contains("\nuk\n"))
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
        XCTAssertEqual(TranscriptionComponentPaths.runtimeVersion, "faster-whisper-1.2.1")
        XCTAssertEqual(TranscriptionModelChoice.recommended.repository, "dropbox-dash/faster-whisper-large-v3-turbo")
        XCTAssertEqual(TranscriptionModelChoice.full.repository, "Systran/faster-whisper-large-v3")
    }

    func testInstallerConstrainsPyAVAndChecksAudioDecodeBeforePromotingModel() {
        XCTAssertEqual(FasterWhisperModelAcquirer.pythonPackageRequirements,
                       ["faster-whisper==1.2.1", "av>=11,<19"])
        let check = FasterWhisperModelAcquirer.transcriptionScript
        XCTAssertTrue(check.contains("decode_audio(sample.name)"),
                      "A model-only check accepts runtimes that cannot decode recordings")
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
