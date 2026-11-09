import Foundation
import XCTest
@testable import StillmatterCore
@testable import StillmatterTranscriptionRuntime

final class SherpaOnnxSpeakerDiarizationTests: XCTestCase {
    func testEngineRunsOfflineModelsAndReturnsAnonymousTimedTurns() throws {
        let root = try makeComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let argumentsURL = root.appendingPathComponent("arguments.txt")
        let python = root.appendingPathComponent("runtime/bin/python3")
        try """
        #!/bin/sh
        printf '%s\\n' "$@" > "\(argumentsURL.path)"
        printf '%s\\n' "$OMP_NUM_THREADS" >> "\(argumentsURL.path)"
        cat > "$5" <<'JSON'
        {"duration_seconds":2.0,"segments":[
          {"start":0.1,"end":0.8,"speaker":4},
          {"start":0.65,"end":1.2,"speaker":2}
        ]}
        JSON
        """.write(to: python, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)

        let turns = try SherpaOnnxSpeakerDiarizationEngine(componentURL: root)
            .diarize(audioURL: URL(fileURLWithPath: "/fixture/system.wav"))

        XCTAssertEqual(turns, [
            SpeakerDiarizationTurn(startSeconds: 0.1, endSeconds: 0.8, clusterID: 4),
            SpeakerDiarizationTurn(startSeconds: 0.65, endSeconds: 1.2, clusterID: 2)
        ])
        let arguments = try String(contentsOf: argumentsURL, encoding: .utf8)
        XCTAssertTrue(arguments.contains("speaker-segmentation/model.onnx"))
        XCTAssertTrue(arguments.contains("speaker-embedding/titanet-small.onnx"))
        XCTAssertTrue(arguments.contains("/fixture/system.wav"))
        XCTAssertTrue(arguments.contains("2"))
    }

    func testEngineRejectsInvalidTurnWithoutInventingAnIdentity() throws {
        let root = try makeComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let python = root.appendingPathComponent("runtime/bin/python3")
        try """
        #!/bin/sh
        cat > "$5" <<'JSON'
        {"duration_seconds":1.0,"segments":[{"start":0.7,"end":0.2,"speaker":-1}]}
        JSON
        """.write(to: python, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)

        XCTAssertThrowsError(try SherpaOnnxSpeakerDiarizationEngine(componentURL: root)
            .diarize(audioURL: URL(fileURLWithPath: "/fixture/mic.wav"))) { error in
                guard case SpeakerDiarizationError.invalidOutput = error else {
                    return XCTFail("Expected invalid diarization output, got \(error)")
                }
            }
    }

    func testEngineClampsSmallModelEndOvershootToSourceDuration() throws {
        let root = try makeComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let python = root.appendingPathComponent("runtime/bin/python3")
        try """
        #!/bin/sh
        cat > "$5" <<'JSON'
        {"duration_seconds":2.0,"segments":[{"start":1.2,"end":2.06,"speaker":0}]}
        JSON
        """.write(to: python, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)

        let turns = try SherpaOnnxSpeakerDiarizationEngine(componentURL: root)
            .diarize(audioURL: URL(fileURLWithPath: "/fixture/mic.wav"))

        XCTAssertEqual(turns, [SpeakerDiarizationTurn(startSeconds: 1.2, endSeconds: 2.0, clusterID: 0)])
    }

    func testEngineRejectsTurnMoreThanOneTenthSecondBeyondSourceDuration() throws {
        let root = try makeComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let python = root.appendingPathComponent("runtime/bin/python3")
        try """
        #!/bin/sh
        cat > "$5" <<'JSON'
        {"duration_seconds":2.0,"segments":[{"start":1.2,"end":2.11,"speaker":0}]}
        JSON
        """.write(to: python, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)

        XCTAssertThrowsError(try SherpaOnnxSpeakerDiarizationEngine(componentURL: root)
            .diarize(audioURL: URL(fileURLWithPath: "/fixture/mic.wav"))) { error in
                guard case SpeakerDiarizationError.invalidOutput = error else {
                    return XCTFail("Expected out-of-range timing to fail, got \(error)")
                }
            }
    }

    func testEngineReportsMissingLocalRuntimeOrModels() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StillmatterSherpaTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(try SherpaOnnxSpeakerDiarizationEngine(componentURL: root)
            .diarize(audioURL: URL(fileURLWithPath: "/fixture/mic.wav"))) { error in
                guard case SpeakerDiarizationError.missingConfiguration = error else {
                    return XCTFail("Expected setup guidance, got \(error)")
                }
            }
    }

    private func makeComponent() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StillmatterSherpaTests-\(UUID().uuidString)")
        let files = [
            "runtime/bin/python3",
            "diarize.py",
            "speaker-segmentation/model.onnx",
            "speaker-embedding/titanet-small.onnx"
        ]
        for file in files {
            let url = root.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: url)
        }
        return root
    }
}
