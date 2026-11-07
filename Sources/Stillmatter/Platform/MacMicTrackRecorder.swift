import AVFoundation
#if SWIFT_PACKAGE
import StillmatterCore
#endif

final class MacMicTrackRecorder: MicTrackCaptureReleasingBackend {
    private let engine: AVAudioEngine
    private let captureInput: () -> (AVAudioNode, AVAudioFormat)
    private var activeInput: AVAudioNode?
    private var recoveryFile: AVAudioFile?
    private var writeError: Error?
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var audioClock = RecordingAudioClock()
    private var writtenFrames: Int64 = 0

    init(engine: AVAudioEngine = AVAudioEngine(), captureInput: (() -> (AVAudioNode, AVAudioFormat))? = nil) {
        self.engine = engine
        self.captureInput = captureInput ?? {
            let input = engine.inputNode
            return (input, input.inputFormat(forBus: 0))
        }
    }

    func startWritingRecovery(to recoveryURL: URL) throws -> MicTrackTechnicalInfo {
        let (input, format) = captureInput()
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
        activeInput = input
        lock.lock()
        generation &+= 1
        let startedGeneration = generation
        recoveryFile = file
        writeError = nil
        audioClock = RecordingAudioClock()
        writtenFrames = 0
        lock.unlock()
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) { [weak self] buffer, time in
            guard let self = self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard self.generation == startedGeneration, let recoveryFile = self.recoveryFile else { return }
            do {
                try recoveryFile.write(from: buffer)
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
                if self.writeError == nil { self.writeError = error }
            }
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            activeInput = nil
            lock.lock()
            recoveryFile = nil
            lock.unlock()
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
        let stopped = try stopWritingRecovery(to: recoveryURL)
        return try finalizeRecovery(from: recoveryURL, to: finalURL, audioClockSpans: stopped.audioClockSpans)
    }

    func stopWritingRecovery(to recoveryURL: URL) throws -> MicTrackTechnicalInfo {
        activeInput?.removeTap(onBus: 0)
        activeInput = nil
        engine.stop()
        lock.lock()
        let file = recoveryFile
        recoveryFile = nil
        let recordedError = writeError
        writeError = nil
        let frames = writtenFrames
        let spans = audioClock.archive()
        lock.unlock()
        if let recordedError = recordedError { throw recordedError }
        let format = file?.processingFormat
        return MicTrackTechnicalInfo(
            durationSeconds: format.map { $0.sampleRate > 0 ? Double(frames) / $0.sampleRate : 0 } ?? 0,
            codec: "linear PCM recovery",
            sampleRate: format?.sampleRate ?? 0,
            channelCount: format.map { Int($0.channelCount) } ?? 0,
            audioClockSpans: spans
        )
    }

    func finalizeRecovery(from recoveryURL: URL, to finalURL: URL, audioClockSpans: [AudioClockSpan]?) throws -> MicTrackTechnicalInfo {
        try exportRecovery(recoveryURL, to: finalURL, audioClockSpans: audioClockSpans)
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
