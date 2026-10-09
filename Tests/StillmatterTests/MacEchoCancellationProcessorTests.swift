import XCTest
@testable import StillmatterCore

final class MacEchoCancellationProcessorTests: XCTestCase {
    func testProcessorUsesPortedDelayAwareAdaptiveCancellation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StillmatterMacEchoCancellationProcessorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sampleRate = Int(SpanAudioReader.sampleRate)
        let reference = noise(sampleRate * 8).enumerated().map { index, sample in
            let envelope: [Float] = [0.05, 0.8, 0.2, 1.0, 0.1, 0.6, 0.3, 0.9]
            return sample * envelope[(index / (sampleRate / 2)) % envelope.count]
        }
        let microphone = echo(of: reference, delay: Int(0.146 * Double(sampleRate)))
        let microphoneURL = root.appendingPathComponent("mic.wav")
        let referenceURL = root.appendingPathComponent("system.wav")
        let outputURL = root.appendingPathComponent("echo-cancelled.wav")
        try writeWav(microphone, to: microphoneURL, sampleRate: sampleRate)
        try writeWav(reference, to: referenceURL, sampleRate: sampleRate)

        let result = try MacEchoCancellationProcessor().process(
            microphoneURL: microphoneURL,
            systemReferenceURL: referenceURL,
            outputURL: outputURL
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertEqual(result.shouldUseSidecar, true)
        XCTAssertGreaterThanOrEqual(result.quality.referenceCorrelation, 0.55)
        XCTAssertGreaterThanOrEqual(result.quality.estimatedEchoReductionDB, 6)
        XCTAssertTrue(result.diagnostics.contains { $0.contains("reference-envelope correlation") })
        XCTAssertTrue(result.diagnostics.contains { $0.contains("Estimated microphone delay") })
    }

    func testExternalRecordingBundleMatchesRequestedSelection() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let bundlePath = environment["STILLMATTER_ECHO_REPLAY_BUNDLE"],
              let expectedValue = environment["STILLMATTER_ECHO_REPLAY_EXPECT_SIDECAR"],
              let expected = ["0": false, "1": true][expectedValue] else {
            throw XCTSkip("Set STILLMATTER_ECHO_REPLAY_BUNDLE and STILLMATTER_ECHO_REPLAY_EXPECT_SIDECAR=0|1 to replay a real recording bundle.")
        }
        let root = URL(fileURLWithPath: bundlePath, isDirectory: true)
        let retainedOutputPath = environment["STILLMATTER_ECHO_REPLAY_OUTPUT"]
        let outputURL = retainedOutputPath.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("StillmatterEchoReplay-\(UUID().uuidString).wav")
        defer {
            if retainedOutputPath == nil {
                try? FileManager.default.removeItem(at: outputURL)
            }
        }

        let processingOutputURL = retainedOutputPath == nil
            ? outputURL
            : FileManager.default.temporaryDirectory
                .appendingPathComponent("StillmatterEchoReplaySelection-\(UUID().uuidString).wav")
        defer {
            if retainedOutputPath != nil {
                try? FileManager.default.removeItem(at: processingOutputURL)
            }
        }
        let microphoneURL = root.appendingPathComponent("mic.m4a")
        let referenceURL = root.appendingPathComponent("system.m4a")
        let result = try MacEchoCancellationProcessor().process(
            microphoneURL: microphoneURL,
            systemReferenceURL: referenceURL,
            outputURL: processingOutputURL
        )
        if retainedOutputPath != nil {
            let timingURL = root.appendingPathComponent(RecordingAudioTiming.fileName)
            let timing = try? JSONDecoder().decode(
                RecordingAudioTiming.self,
                from: Data(contentsOf: timingURL)
            )
            _ = try EchoCancelledTrack.writeSynchronously(
                microphone: microphoneURL,
                reference: referenceURL,
                to: outputURL,
                timing: timing,
                retainRejectedCandidate: true
            )
        }

        let diagnostics = result.diagnostics.joined(separator: " | ")
        XCTAssertEqual(result.shouldUseSidecar, expected, "Diagnostics: \(diagnostics)")
    }

    private func noise(_ count: Int, seed: UInt64 = 42) -> [Float] {
        var state = seed
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Float(state >> 40) / Float(1 << 24)
            return unit * 2 - 1
        }
    }

    private func echo(of reference: [Float], delay: Int, gain: Float = 0.5) -> [Float] {
        var output = [Float](repeating: 0, count: reference.count)
        let tail: [Float] = [gain, gain * 0.4, gain * 0.15, gain * 0.05]
        for (offset, weight) in tail.enumerated() {
            let shift = delay + offset * 17
            for frame in shift..<reference.count {
                output[frame] += weight * reference[frame - shift]
            }
        }
        return output
    }

    private func writeWav(_ samples: [Float], to url: URL, sampleRate: Int) throws {
        let writer = try WavWriter(url: url, sampleRate: sampleRate)
        try writer.append(samples)
        try writer.finish()
    }
}
