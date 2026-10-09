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

    func testModelChoicesUsePinnedFasterWhisperRepositoriesAndRuntime() {
        XCTAssertEqual(FasterWhisperModelAcquirer.packageVersion, "1.2.1")
        XCTAssertEqual(TranscriptionComponentPaths.runtimeVersion, "faster-whisper-1.2.1")
        XCTAssertEqual(TranscriptionModelChoice.recommended.repository, "dropbox-dash/faster-whisper-large-v3-turbo")
        XCTAssertEqual(TranscriptionModelChoice.full.repository, "Systran/faster-whisper-large-v3")
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
