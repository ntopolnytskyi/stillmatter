import AVFoundation
import AudioToolbox
import CoreMedia
import ScreenCaptureKit
#if SWIFT_PACKAGE
import StillmatterCore
#endif

@available(macOS 13.0, *)
final class MacSystemAudioTrackRecorder: NSObject, SystemAudioTrackRecordingBackend, SCStreamOutput, SCStreamDelegate {
    private let sampleQueue = DispatchQueue(label: "Stillmatter.SystemAudioCapture")
    private let lock = NSLock()
    private var stream: SCStream?
    private var recoveryFile: AVAudioFile?
    private var recoveryURL: URL?
    private var writeError: Error?
    private var audioClock = RecordingAudioClock()
    private var writtenFrames: Int64 = 0

    func startWritingRecovery(to recoveryURL: URL) throws -> SystemAudioTrackTechnicalInfo {
        guard stream == nil else {
            throw NSError(domain: "Stillmatter.SystemAudioTrackRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "System audio capture is already active."])
        }
        let content = try shareableContent()
        guard let display = content.displays.first else {
            throw NSError(domain: "Stillmatter.SystemAudioTrackRecorder", code: 2, userInfo: [NSLocalizedDescriptionKey: "No display is available for system-audio capture."])
        }
        let currentApplication = content.applications.first { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: currentApplication.map { [$0] } ?? [],
            exceptingWindows: []
        )
        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 1)
        configuration.queueDepth = 1
        configuration.showsCursor = false
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2

        self.recoveryURL = recoveryURL
        writeError = nil
        audioClock = RecordingAudioClock()
        writtenFrames = 0
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        do {
            try waitForCallback { completion in stream.startCapture(completionHandler: completion) }
            self.stream = stream
        } catch {
            self.recoveryURL = nil
            throw error
        }
        return SystemAudioTrackTechnicalInfo(
            durationSeconds: 0,
            codec: "linear PCM recovery",
            sampleRate: 48_000,
            channelCount: 2
        )
    }

    func stopAndFinalize(recoveryURL: URL, finalURL: URL) throws -> SystemAudioTrackTechnicalInfo {
        guard let activeStream = stream else {
            throw NSError(domain: "Stillmatter.SystemAudioTrackRecorder", code: 3, userInfo: [NSLocalizedDescriptionKey: "There is no active system-audio stream."])
        }
        defer {
            stream = nil
            self.recoveryURL = nil
            recoveryFile = nil
        }
        try waitForCallback { completion in activeStream.stopCapture(completionHandler: completion) }
        sampleQueue.sync {}
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

    func recover(recoveryURL: URL, finalURL: URL) throws -> SystemAudioTrackTechnicalInfo {
        if FileManager.default.fileExists(atPath: finalURL.path) {
            return try technicalInfo(for: finalURL, codec: "AAC in M4A")
        }
        return try exportRecovery(recoveryURL, to: finalURL)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio, sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        do {
            try write(sampleBuffer)
        } catch {
            lock.lock()
            if writeError == nil { writeError = error }
            lock.unlock()
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        audioClock.discontinuity()
        lock.lock()
        if writeError == nil { writeError = error }
        lock.unlock()
    }

    private func write(_ sampleBuffer: CMSampleBuffer) throws {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let format = AVAudioFormat(streamDescription: streamDescription),
              let recoveryURL = recoveryURL else { return }
        if recoveryFile == nil {
            recoveryFile = try AVAudioFile(forWriting: recoveryURL, settings: format.settings)
        }

        var requiredSize = 0
        var retainedBlockBuffer: CMBlockBuffer?
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &requiredSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &retainedBlockBuffer
        )
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: requiredSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        let audioBufferList = memory.bindMemory(to: AudioBufferList.self, capacity: 1)
        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferList,
            bufferListSize: requiredSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &retainedBlockBuffer
        )
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard let pcm = AVAudioPCMBuffer(
            pcmFormat: format,
            bufferListNoCopy: audioBufferList,
            deallocator: nil
        ) else {
            throw NSError(domain: "Stillmatter.SystemAudioTrackRecorder", code: 4, userInfo: [NSLocalizedDescriptionKey: "System audio could not be converted to PCM."])
        }
        pcm.frameLength = frameCount
        try recoveryFile?.write(from: pcm)
        let presentationSeconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let validTime = presentationSeconds.isFinite && presentationSeconds >= 0
        let hostTime = validTime
            ? AudioConvertNanosToHostTime(UInt64(presentationSeconds * 1_000_000_000))
            : 0
        audioClock.record(
            hostTime: hostTime,
            valid: validTime,
            startFrame: writtenFrames,
            frames: Int64(frameCount),
            sampleRate: format.sampleRate
        )
        writtenFrames += Int64(frameCount)
        _ = retainedBlockBuffer
    }

    private func shareableContent() throws -> SCShareableContent {
        var result: Result<SCShareableContent, Error>?
        let semaphore = DispatchSemaphore(value: 0)
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            if let content = content {
                result = .success(content)
            } else {
                result = .failure(error ?? NSError(
                    domain: "Stillmatter.SystemAudioTrackRecorder",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "macOS did not return shareable content. Check Screen Recording permission."]
                ))
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try result!.get()
    }

    private func waitForCallback(_ operation: (@escaping (Error?) -> Void) -> Void) throws {
        var callbackError: Error?
        let semaphore = DispatchSemaphore(value: 0)
        operation { error in
            callbackError = error
            semaphore.signal()
        }
        semaphore.wait()
        if let callbackError = callbackError { throw callbackError }
    }

    private func exportRecovery(
        _ recoveryURL: URL,
        to finalURL: URL,
        audioClockSpans: [AudioClockSpan]? = nil
    ) throws -> SystemAudioTrackTechnicalInfo {
        let recoveryFile = try AVAudioFile(forReading: recoveryURL)
        guard recoveryFile.length > 0, recoveryFile.processingFormat.sampleRate > 0 else {
            throw NSError(
                domain: "Stillmatter.SystemAudioTrackRecorder",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "The system-audio recovery artifact contains no audio frames. Play meeting audio during capture."]
            )
        }
        let asset = AVURLAsset(url: recoveryURL)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw NSError(domain: "Stillmatter.SystemAudioTrackRecorder", code: 7, userInfo: [NSLocalizedDescriptionKey: "macOS could not create an AAC system-audio exporter."])
        }
        exporter.outputURL = finalURL
        exporter.outputFileType = .m4a
        let semaphore = DispatchSemaphore(value: 0)
        exporter.exportAsynchronously { semaphore.signal() }
        semaphore.wait()
        guard exporter.status == .completed else {
            throw exporter.error ?? NSError(domain: "Stillmatter.SystemAudioTrackRecorder", code: 8, userInfo: [NSLocalizedDescriptionKey: "System audio export did not complete."])
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
    ) throws -> SystemAudioTrackTechnicalInfo {
        let audioFile = try AVAudioFile(forReading: url)
        let format = audioFile.processingFormat
        let duration = format.sampleRate > 0 ? Double(audioFile.length) / format.sampleRate : 0
        return SystemAudioTrackTechnicalInfo(
            durationSeconds: duration,
            codec: codec,
            sampleRate: format.sampleRate,
            channelCount: Int(format.channelCount),
            audioClockSpans: audioClockSpans
        )
    }
}
