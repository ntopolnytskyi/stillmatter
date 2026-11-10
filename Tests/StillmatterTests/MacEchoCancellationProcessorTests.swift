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

    func testProcessorRetainsAndReportsQuietSpeechOverlappingRemoteEcho() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StillmatterQuietDoubleTalkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sampleRate = Int(SpanAudioReader.sampleRate)
        let sampleCount = sampleRate * 8
        let reference = noise(sampleCount).enumerated().map { index, sample in
            let envelope: [Float] = [0.05, 0.8, 0.2, 1.0, 0.1, 0.6, 0.3, 0.9]
            return sample * envelope[(index / (sampleRate / 2)) % envelope.count]
        }
        let echo = echo(of: reference, delay: Int(0.146 * Double(sampleRate)))
        let reply = syntheticVoicedReply(sampleCount, sampleRate: sampleRate, amplitude: 0.01)
        let replyStart = sampleRate * 5
        let replyEnd = sampleRate * 7
        var microphoneWithReply = echo
        for index in replyStart..<replyEnd { microphoneWithReply[index] += reply[index] }

        let microphoneURL = root.appendingPathComponent("mic.wav")
        let referenceURL = root.appendingPathComponent("system.wav")
        let outputWithReplyURL = root.appendingPathComponent("with-reply.wav")
        let outputWithoutReplyURL = root.appendingPathComponent("without-reply.wav")
        try writeWav(microphoneWithReply, to: microphoneURL, sampleRate: sampleRate)
        try writeWav(reference, to: referenceURL, sampleRate: sampleRate)
        let originalMicrophone = try Data(contentsOf: microphoneURL)
        let clockSpan = AudioClockSpan(hostStart: 0, hostEnd: 8, startFrame: 0,
                                       endFrame: Int64(sampleCount), sampleRate: Double(sampleRate), generation: 0)
        let timing = RecordingAudioTiming(microphone: [clockSpan], system: [clockSpan])
        try JSONEncoder().encode(timing).write(to: root.appendingPathComponent(RecordingAudioTiming.fileName))

        let processor = MacEchoCancellationProcessor()
        let withReplyResult = try processor.process(microphoneURL: microphoneURL,
                                                    systemReferenceURL: referenceURL,
                                                    outputURL: outputWithReplyURL)
        let microphoneWithoutReply = echo
        let microphoneWithoutReplyURL = root.appendingPathComponent("mic-without-reply.wav")
        try writeWav(microphoneWithoutReply, to: microphoneWithoutReplyURL, sampleRate: sampleRate)
        let withoutReplyResult = try processor.process(microphoneURL: microphoneWithoutReplyURL,
                                                       systemReferenceURL: referenceURL,
                                                       outputURL: outputWithoutReplyURL)

        let withReplyReader = try SpanAudioReader(url: outputWithReplyURL)
        let withoutReplyReader = try SpanAudioReader(url: outputWithoutReplyURL)
        let withReplySamples = try withReplyReader.samples(from: 5, to: 7)
        let withoutReplySamples = try withoutReplyReader.samples(from: 5, to: 7)
        let retainedReply = zip(withReplySamples, withoutReplySamples).map { $0.0 - $0.1 }

        XCTAssertEqual(withReplyResult.shouldUseSidecar, true)
        XCTAssertEqual(withoutReplyResult.shouldUseSidecar, true)
        XCTAssertTrue(withReplyResult.diagnostics.contains { $0.contains("Possible local speech or echo-path variation") })
        XCTAssertTrue(withReplyResult.diagnostics.contains { $0.contains("Capture timing aligned") })
        XCTAssertGreaterThan(rms(retainedReply), rms(Array(reply[replyStart..<replyEnd])) * 0.7)
        XCTAssertEqual(try Data(contentsOf: microphoneURL), originalMicrophone,
                       "Echo processing must leave the original microphone evidence unchanged")
    }

    func testShortWindowsCancelEchoAroundSeparateMicrophoneSpeech() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StillmatterInterleavedEchoTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sampleRate = Int(SpanAudioReader.sampleRate)
        let sampleCount = sampleRate * 46
        let reference = noise(sampleCount).enumerated().map { index, sample in
            let envelope: [Float] = [0.05, 0.8, 0.2, 1.0, 0.1, 0.6, 0.3, 0.9]
            return sample * envelope[(index / (sampleRate / 2)) % envelope.count]
        }
        let microphoneWithoutVoice = echo(of: reference, delay: Int(0.146 * Double(sampleRate)))
        let voice = syntheticVoicedReply(sampleCount, sampleRate: sampleRate, amplitude: 0.01)
        let voiceRanges = [10..<15, 30..<35]
        var microphoneWithVoice = microphoneWithoutVoice
        for range in voiceRanges {
            for second in range {
                let start = sampleRate * second
                let end = start + sampleRate
                for index in start..<end { microphoneWithVoice[index] += voice[index] }
            }
        }

        let microphoneURL = root.appendingPathComponent("mic-with-voice.wav")
        let echoOnlyMicrophoneURL = root.appendingPathComponent("mic-echo-only.wav")
        let referenceURL = root.appendingPathComponent("system.wav")
        let outputURL = root.appendingPathComponent("selected-with-voice.wav")
        let echoOnlyOutputURL = root.appendingPathComponent("selected-echo-only.wav")
        try writeWav(microphoneWithVoice, to: microphoneURL, sampleRate: sampleRate)
        try writeWav(microphoneWithoutVoice, to: echoOnlyMicrophoneURL, sampleRate: sampleRate)
        try writeWav(reference, to: referenceURL, sampleRate: sampleRate)

        let processor = MacEchoCancellationProcessor()
        let result = try processor.process(microphoneURL: microphoneURL,
                                           systemReferenceURL: referenceURL,
                                           outputURL: outputURL)
        let echoOnlyResult = try processor.process(microphoneURL: echoOnlyMicrophoneURL,
                                                   systemReferenceURL: referenceURL,
                                                   outputURL: echoOnlyOutputURL)
        let outputReader = try SpanAudioReader(url: outputURL)
        let echoOnlyReader = try SpanAudioReader(url: echoOnlyOutputURL)

        XCTAssertEqual(result.shouldUseSidecar, true)
        XCTAssertEqual(echoOnlyResult.shouldUseSidecar, true)
        XCTAssertTrue(result.diagnostics.contains {
            $0.contains("5-second windows (short tails merge up to 7.5 seconds)")
        })
        for (start, end) in [(2.0, 9.0), (22.0, 29.0), (40.0, 46.0)] {
            let input = Array(microphoneWithoutVoice[Int(start * Double(sampleRate))..<Int(end * Double(sampleRate))])
            let output = try echoOnlyReader.samples(from: start, to: end)
            XCTAssertLessThan(rms(output), rms(input) * 0.4,
                               "Echo should be reduced in \(start)–\(end)s.")
        }
        for range in voiceRanges {
            let start = Double(range.lowerBound)
            let end = Double(range.upperBound)
            let withVoice = try outputReader.samples(from: start, to: end)
            let echoOnly = try echoOnlyReader.samples(from: start, to: end)
            let retainedVoice = zip(withVoice, echoOnly).map { $0.0 - $0.1 }
            let sourceStart = sampleRate * range.lowerBound
            let sourceEnd = sampleRate * range.upperBound
            let sourceVoice = Array(voice[sourceStart..<sourceEnd])
            XCTAssertGreaterThan(rms(retainedVoice), rms(sourceVoice) * 0.7,
                                 "Separate microphone speech should survive at \(start)–\(end)s.")
        }
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
        let retainedSelectionPath = environment["STILLMATTER_ECHO_REPLAY_SELECTED_OUTPUT"]
        let outputURL = retainedOutputPath.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("StillmatterEchoReplay-\(UUID().uuidString).wav")
        defer {
            if retainedOutputPath == nil {
                try? FileManager.default.removeItem(at: outputURL)
            }
        }

        let processingOutputURL = retainedSelectionPath.map { URL(fileURLWithPath: $0) }
            ?? (retainedOutputPath == nil
                ? outputURL
                : FileManager.default.temporaryDirectory
                    .appendingPathComponent("StillmatterEchoReplaySelection-\(UUID().uuidString).wav"))
        defer {
            if retainedOutputPath != nil && retainedSelectionPath == nil {
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

    // Harmonic, amplitude-modulated synthetic voice; this is not human speech-quality evidence.
    private func syntheticVoicedReply(_ count: Int, sampleRate: Int, amplitude: Float) -> [Float] {
        (0..<count).map { index in
            let time = Double(index) / Double(sampleRate)
            let envelope = 0.3 + 0.7 * abs(sin(2 * .pi * 2.2 * time))
            let voice = sin(2 * .pi * 180 * time)
                + 0.5 * sin(2 * .pi * 360 * time)
                + 0.2 * sin(2 * .pi * 540 * time)
            return amplitude * Float(envelope * voice / 1.7)
        }
    }

    private func rms(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0) { $0 + Double($1) * Double($1) } / Double(samples.count)).squareRoot()
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
