import AVFoundation
#if SWIFT_PACKAGE
import StillmatterCore
#endif

final class MacMicTrackRecorder: MicTrackRecordingBackend {
    private let engine = AVAudioEngine()
    private var recoveryFile: AVAudioFile?
    private var writeError: Error?
    private let lock = NSLock()
    private var audioClock = RecordingAudioClock()
    private var writtenFrames: Int64 = 0

    func startWritingRecovery(to recoveryURL: URL) throws -> MicTrackTechnicalInfo {
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(
                domain: "Stillmatter.MicTrackRecorder",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The selected microphone has no recordable audio format."]
            )
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false
        ]
        let file = try AVAudioFile(forWriting: recoveryURL, settings: settings)
        recoveryFile = file
        writeError = nil
        audioClock = RecordingAudioClock()
        writtenFrames = 0
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak self] buffer, time in
            guard let self = self else { return }
            do {
                try self.recoveryFile?.write(from: buffer)
                let frames = Int64(buffer.frameLength)
                self.audioClock.record(
                    hostTime: time.hostTime,
                    valid: time.hostTime != 0,
                    startFrame: self.writtenFrames,
                    frames: frames,
                    sampleRate: format.sampleRate
                )
                self.writtenFrames += frames
            } catch {
                self.lock.lock()
                if self.writeError == nil { self.writeError = error }
                self.lock.unlock()
            }
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            recoveryFile = nil
            throw error
        }
        return MicTrackTechnicalInfo(
            durationSeconds: 0,
            codec: "linear PCM recovery",
            sampleRate: format.sampleRate,
            channelCount: Int(format.channelCount)
        )
    }

    func stopAndFinalize(recoveryURL: URL, finalURL: URL) throws -> MicTrackTechnicalInfo {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        recoveryFile = nil
        lock.lock()
        let recordedError = writeError
        writeError = nil
        lock.unlock()
        if let recordedError = recordedError { throw recordedError }
        return try exportRecovery(
            recoveryURL,
            to: finalURL,
            audioClockSpans: audioClock.archive()
        )
    }

    func recover(recoveryURL: URL, finalURL: URL) throws -> MicTrackTechnicalInfo {
        if FileManager.default.fileExists(atPath: finalURL.path) {
            return try technicalInfo(for: finalURL, codec: "AAC in M4A")
        }
        return try exportRecovery(recoveryURL, to: finalURL)
    }

    private func exportRecovery(
        _ recoveryURL: URL,
        to finalURL: URL,
        audioClockSpans: [AudioClockSpan]? = nil
    ) throws -> MicTrackTechnicalInfo {
        let recoveryFile = try AVAudioFile(forReading: recoveryURL)
        guard recoveryFile.length > 0, recoveryFile.processingFormat.sampleRate > 0 else {
            throw NSError(
                domain: "Stillmatter.MicTrackRecorder",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "The microphone recovery artifact contains no audio frames."]
            )
        }
        let asset = AVURLAsset(url: recoveryURL)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw NSError(
                domain: "Stillmatter.MicTrackRecorder",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "macOS could not create an AAC microphone exporter."]
            )
        }
        exporter.outputURL = finalURL
        exporter.outputFileType = .m4a
        let semaphore = DispatchSemaphore(value: 0)
        exporter.exportAsynchronously { semaphore.signal() }
        semaphore.wait()
        guard exporter.status == .completed else {
            throw exporter.error ?? NSError(
                domain: "Stillmatter.MicTrackRecorder",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Microphone audio export did not complete."]
            )
        }
        return try technicalInfo(
            for: finalURL,
            codec: "AAC in M4A",
            audioClockSpans: audioClockSpans
        )
    }

    private func technicalInfo(
        for url: URL,
        codec: String,
        audioClockSpans: [AudioClockSpan]? = nil
    ) throws -> MicTrackTechnicalInfo {
        let audioFile = try AVAudioFile(forReading: url)
        let format = audioFile.processingFormat
        let duration = format.sampleRate > 0 ? Double(audioFile.length) / format.sampleRate : 0
        return MicTrackTechnicalInfo(
            durationSeconds: duration,
            codec: codec,
            sampleRate: format.sampleRate,
            channelCount: Int(format.channelCount),
            audioClockSpans: audioClockSpans
        )
    }
}
