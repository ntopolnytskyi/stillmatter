import Foundation
import XCTest
@testable import StillmatterCore

final class EchoCancellationSidecarTests: XCTestCase {
    func testSuccessfulCancellationStoresTranscriptionOnlySidecarAndQualityDiagnostics() throws {
        let fixture = try EchoSidecarFixture(includeSystem: true)
        let processor = StubEchoProcessor(result: .success(EchoCancellationProcessingResult(
            quality: EchoCancellationQuality(
                confidence: 0.82,
                referenceCorrelation: 0.61,
                estimatedEchoReductionDB: 7.4,
                retainedSignalRatio: 0.73
            ),
            diagnostics: ["Reference aligned at capture start."]
        )))
        let stage = fixture.makeStage(processor: processor)
        let originalMic = try Data(contentsOf: URL(fileURLWithPath: fixture.bundle.mic.preferredAudioFilePath))
        let originalSystem = try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(fixture.bundle.system?.preferredAudioFilePath)))

        let sidecar = try stage.generate(from: fixture.bundle)

        XCTAssertEqual(sidecar.selection, .echoCancelledSidecar)
        XCTAssertEqual(sidecar.selectedAudioFilePath, sidecar.echoCancelledFilePath)
        XCTAssertNotEqual(sidecar.selectedAudioFilePath, fixture.bundle.mic.preferredAudioFilePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(sidecar.echoCancelledFilePath)))
        XCTAssertEqual(sidecar.quality?.confidence, 0.82)
        XCTAssertTrue(sidecar.diagnostics.contains { $0.contains("passed") })
        XCTAssertEqual(try fixture.decodeMetadata(), sidecar)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: fixture.bundle.mic.preferredAudioFilePath)), originalMic)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(fixture.bundle.system?.preferredAudioFilePath))), originalSystem)
        XCTAssertEqual(processor.inputs?.microphone.path, fixture.bundle.mic.preferredAudioFilePath)
        XCTAssertEqual(processor.inputs?.reference.path, fixture.bundle.system?.preferredAudioFilePath)
    }

    func testInsufficientQualityDeletesCandidateAndSelectsOriginalMicrophoneWithReason() throws {
        let fixture = try EchoSidecarFixture(includeSystem: true)
        let processor = StubEchoProcessor(result: .success(EchoCancellationProcessingResult(
            quality: EchoCancellationQuality(
                confidence: 0.18,
                referenceCorrelation: 0.04,
                estimatedEchoReductionDB: 0.1,
                retainedSignalRatio: 0.92
            ),
            diagnostics: ["Little correlated speaker bleed was detected."]
        )))

        let sidecar = try fixture.makeStage(processor: processor).generate(from: fixture.bundle)

        XCTAssertEqual(sidecar.selection, .originalMicrophone)
        XCTAssertEqual(sidecar.selectedAudioFilePath, fixture.bundle.mic.preferredAudioFilePath)
        XCTAssertNil(sidecar.echoCancelledFilePath)
        XCTAssertTrue(sidecar.diagnostics.contains { $0.contains("uncertain") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.generatedAudioPath))
        XCTAssertEqual(try fixture.decodeMetadata(), sidecar)
    }

    func testMissingSystemReferenceFailsOpenWithoutInvokingProcessor() throws {
        let fixture = try EchoSidecarFixture(includeSystem: false)
        let processor = StubEchoProcessor(result: .failure(TestEchoError.failed))

        let sidecar = try fixture.makeStage(processor: processor).generate(from: fixture.bundle)

        XCTAssertEqual(sidecar.selection, .originalMicrophone)
        XCTAssertNil(sidecar.systemReferenceFilePath)
        XCTAssertNil(processor.inputs)
        XCTAssertTrue(sidecar.diagnostics.contains { $0.contains("No usable System Audio Track") })
    }

    func testProcessorFailureFailsOpenAndRecordsDiagnostic() throws {
        let fixture = try EchoSidecarFixture(includeSystem: true)
        let processor = StubEchoProcessor(result: .failure(TestEchoError.failed))

        let sidecar = try fixture.makeStage(processor: processor).generate(from: fixture.bundle)

        XCTAssertEqual(sidecar.selection, .originalMicrophone)
        XCTAssertNil(sidecar.echoCancelledFilePath)
        XCTAssertTrue(sidecar.diagnostics.contains { $0.contains("could not be generated") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.generatedAudioPath))
    }

    func testCaptureClockSpansBecomeAudioTimingSidecar() throws {
        let fixture = try EchoSidecarFixture(includeSystem: true, includeTiming: true)
        let processor = StubEchoProcessor(result: .success(EchoCancellationProcessingResult(
            quality: EchoCancellationQuality(
                confidence: 1,
                referenceCorrelation: 1,
                estimatedEchoReductionDB: 7,
                retainedSignalRatio: 0.5
            )
        )))

        _ = try fixture.makeStage(processor: processor).generate(from: fixture.bundle)

        let timing = try XCTUnwrap(processor.timing)
        XCTAssertEqual(timing.microphone.count, 1)
        XCTAssertEqual(timing.system.count, 1)
        XCTAssertEqual(timing.microphone[0].hostStart, 100)
        XCTAssertEqual(timing.system[0].hostStart, 100.1)
    }
}

private enum TestEchoError: Error { case failed }

private final class StubEchoProcessor: EchoCancellationProcessing {
    let result: Result<EchoCancellationProcessingResult, Error>
    private(set) var inputs: (microphone: URL, reference: URL, output: URL)?
    private(set) var timing: RecordingAudioTiming?

    init(result: Result<EchoCancellationProcessingResult, Error>) {
        self.result = result
    }

    func process(
        microphoneURL: URL,
        systemReferenceURL: URL,
        outputURL: URL
    ) throws -> EchoCancellationProcessingResult {
        inputs = (microphoneURL, systemReferenceURL, outputURL)
        let timingURL = microphoneURL.deletingLastPathComponent()
            .appendingPathComponent(RecordingAudioTiming.fileName)
        if let data = try? Data(contentsOf: timingURL) {
            timing = try? JSONDecoder().decode(RecordingAudioTiming.self, from: data)
        }
        let value = try result.get()
        try Data("echo-cancelled transcription audio".utf8).write(to: outputURL)
        return value
    }
}

private final class EchoSidecarFixture {
    let root: URL
    let bundle: RecordingBundle
    let validator: RecordingBundleFinalizer
    let generatedAt = Date(timeIntervalSince1970: 1_790_000_000)

    var generatedAudioPath: String {
        root.appendingPathComponent("mic-transcription-echo-cancelled.wav").path
    }

    init(includeSystem: Bool, includeTiming: Bool = false) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StillmatterEchoSidecarTests-\(UUID().uuidString)", isDirectory: true)
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func write(_ value: String, name: String) throws -> URL {
            let url = root.appendingPathComponent(name)
            try Data(value.utf8).write(to: url)
            return url
        }
        let micRecovery = try write("mic recovery", name: "mic-recovery.caf")
        let micFinal = try write("original mic", name: "mic.m4a")
        let micMetadata = try write("{}", name: "mic-recording.json")
        var mic = MicTrackRecordingMetadata(
            captureSessionID: "capture-echo",
            meetingRelativePath: "Meetings/2026/09/20/echo/meeting.md",
            recoveryFilePath: micRecovery.path,
            finalFilePath: micFinal.path,
            metadataFilePath: micMetadata.path,
            startedAt: Date(timeIntervalSince1970: 1_789_999_900),
            sampleRate: 48_000,
            channelCount: 1
        )
        mic.status = .completed
        mic.durationSeconds = 30
        mic.codec = "AAC in M4A"
        if includeTiming {
            mic.audioClockSpans = [AudioClockSpan(
                hostStart: 100,
                hostEnd: 130,
                startFrame: 0,
                endFrame: 1_440_000,
                sampleRate: 48_000,
                generation: 1
            )]
        }

        var system: SystemAudioTrackRecordingMetadata?
        if includeSystem {
            let recovery = try write("system recovery", name: "system-recovery.caf")
            let final = try write("system reference", name: "system.m4a")
            let metadata = try write("{}", name: "system-recording.json")
            var value = SystemAudioTrackRecordingMetadata(
                captureSessionID: "capture-echo",
                meetingRelativePath: mic.meetingRelativePath,
                recoveryFilePath: recovery.path,
                finalFilePath: final.path,
                metadataFilePath: metadata.path,
                startedAt: mic.startedAt,
                sampleRate: 48_000,
                channelCount: 2
            )
            value.status = .completed
            value.durationSeconds = 30
            value.codec = "AAC in M4A"
            if includeTiming {
                value.audioClockSpans = [AudioClockSpan(
                    hostStart: 100.1,
                    hostEnd: 130.1,
                    startFrame: 0,
                    endFrame: 1_440_000,
                    sampleRate: 48_000,
                    generation: 1
                )]
            }
            system = value
        }
        let metadataEncoder = JSONEncoder()
        metadataEncoder.dateEncodingStrategy = .iso8601
        try metadataEncoder.encode(mic).write(to: micMetadata)
        if let system = system {
            try metadataEncoder.encode(system).write(
                to: URL(fileURLWithPath: system.metadataFilePath)
            )
        }
        let generatedAt = self.generatedAt
        validator = RecordingBundleFinalizer(now: { generatedAt })
        bundle = try validator.finalize(mic: mic, system: system, reason: .normalStop)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func makeStage(processor: EchoCancellationProcessing) -> EchoCancellationSidecarStage {
        EchoCancellationSidecarStage(
            bundleValidator: validator,
            processor: processor,
            now: { self.generatedAt }
        )
    }

    func decodeMetadata() throws -> TranscriptionAudioSidecar {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(
            TranscriptionAudioSidecar.self,
            from: Data(contentsOf: root.appendingPathComponent("transcription-audio-selection.json"))
        )
    }

}
