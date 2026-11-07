import AVFoundation
import AudioToolbox
import CoreMedia
import ScreenCaptureKit
#if SWIFT_PACKAGE
import StillmatterCore
#endif

@available(macOS 13.0, *)
protocol SystemAudioInputStream: AnyObject {
    func start() throws
    func stop() throws
}

@available(macOS 13.0, *)
protocol SystemAudioStreamCreating {
    func make(scope: CaptureAudioScope, sampleQueue: DispatchQueue,
              onSample: @escaping (CMSampleBuffer) -> Void,
              onError: @escaping (Error) -> Void) throws -> SystemAudioInputStream
}

@available(macOS 13.0, *)
final class ScreenCaptureKitAudioStreamFactory: SystemAudioStreamCreating {
    func make(scope: CaptureAudioScope, sampleQueue: DispatchQueue,
              onSample: @escaping (CMSampleBuffer) -> Void,
              onError: @escaping (Error) -> Void) throws -> SystemAudioInputStream {
        let content = try shareableContent()
        guard let display = content.displays.first else {
            throw NSError(domain: "Stillmatter.SystemAudioTrackRecorder", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "No display is available for system-audio capture."])
        }
        let filter: SCContentFilter
        switch scope {
        case .teamsApplication:
            let teamsIDs: Set<String> = ["com.microsoft.teams2", "com.microsoft.teams"]
            let teams = content.applications.filter { teamsIDs.contains($0.bundleIdentifier.lowercased()) }
            guard !teams.isEmpty else {
                throw NSError(domain: "Stillmatter.SystemAudioTrackRecorder", code: 6,
                    userInfo: [NSLocalizedDescriptionKey: "Teams is unavailable for application-only audio capture. Microphone recording can continue; no broader system audio will be captured."])
            }
            filter = SCContentFilter(display: display, including: teams, exceptingWindows: [])
        case .allSystemAudio:
            let currentApplication = content.applications.first { $0.processID == ProcessInfo.processInfo.processIdentifier }
            filter = SCContentFilter(display: display,
                excludingApplications: currentApplication.map { [$0] } ?? [], exceptingWindows: [])
        }
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
        let callbacks = ScreenCaptureKitAudioCallbacks(onSample: onSample, onError: onError)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: callbacks)
        try stream.addStreamOutput(callbacks, type: .audio, sampleHandlerQueue: sampleQueue)
        return ScreenCaptureKitAudioStream(stream: stream, callbacks: callbacks)
    }

    private func shareableContent() throws -> SCShareableContent {
        var result: Result<SCShareableContent, Error>?
        let semaphore = DispatchSemaphore(value: 0)
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
            if let content {
                result = .success(content)
            } else {
                result = .failure(error ?? NSError(domain: "Stillmatter.SystemAudioTrackRecorder", code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "macOS did not return shareable content. Check Screen Recording permission."]))
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try result!.get()
    }
}

@available(macOS 13.0, *)
private final class ScreenCaptureKitAudioCallbacks: NSObject, SCStreamOutput, SCStreamDelegate {
    let onSample: (CMSampleBuffer) -> Void
    let onError: (Error) -> Void

    init(onSample: @escaping (CMSampleBuffer) -> Void, onError: @escaping (Error) -> Void) {
        self.onSample = onSample
        self.onError = onError
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        onSample(buffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { onError(error) }
}

@available(macOS 13.0, *)
private final class ScreenCaptureKitAudioStream: SystemAudioInputStream {
    private let stream: SCStream
    private let callbacks: ScreenCaptureKitAudioCallbacks

    init(stream: SCStream, callbacks: ScreenCaptureKitAudioCallbacks) {
        self.stream = stream
        self.callbacks = callbacks // SCStream delegate/output may not retain its observer.
    }

    func start() throws { try waitForCallback { stream.startCapture(completionHandler: $0) } }
    func stop() throws { try waitForCallback { stream.stopCapture(completionHandler: $0) } }

    private func waitForCallback(_ operation: (@escaping (Error?) -> Void) -> Void) throws {
        var callbackError: Error?
        let semaphore = DispatchSemaphore(value: 0)
        operation { error in
            callbackError = error
            semaphore.signal()
        }
        semaphore.wait()
        if let callbackError { throw callbackError }
    }
}

@available(macOS 13.0, *)
final class MacSystemAudioTrackRecorder: SystemAudioCaptureReleasingBackend, SystemAudioCaptureFailureReportingBackend {
    private let sampleQueue = DispatchQueue(label: "Stillmatter.SystemAudioCapture")
    private let streamFactory: SystemAudioStreamCreating
    private let lock = NSLock()
    private var captureFailureHandler: ((Error) -> Void)?
    private var stream: SystemAudioInputStream?
    private var generation: UInt64 = 0
    private var sourceStoppedGeneration: UInt64?
    private var recoveryFile: AVAudioFile?
    private var recoveryURL: URL?
    private var writeError: Error?
    private var audioClock = RecordingAudioClock()
    private var writtenFrames: Int64 = 0

    func setCaptureFailureHandler(_ handler: ((Error) -> Void)?) {
        lock.lock()
        captureFailureHandler = handler
        lock.unlock()
    }

    init(streamFactory: SystemAudioStreamCreating = ScreenCaptureKitAudioStreamFactory()) {
        self.streamFactory = streamFactory
    }

    func startWritingRecovery(to recoveryURL: URL, scope: CaptureAudioScope) throws -> SystemAudioTrackTechnicalInfo {
        guard sampleQueue.sync(execute: { stream == nil }) else {
            throw NSError(domain: "Stillmatter.SystemAudioTrackRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "System audio capture is already active."])
        }
        let nextGeneration = generation &+ 1
        let input = try streamFactory.make(scope: scope, sampleQueue: sampleQueue,
            onSample: { [weak self] buffer in self?.accept(buffer, generation: nextGeneration) },
            onError: { [weak self] error in self?.fail(error, generation: nextGeneration) })
        sampleQueue.sync {
            generation = nextGeneration
            sourceStoppedGeneration = nil
            stream = input
            self.recoveryURL = recoveryURL
            recoveryFile = nil
            writeError = nil
            audioClock = RecordingAudioClock()
            writtenFrames = 0
        }
        do {
            try input.start()
        } catch {
            // A failed start callback does not prove the OS released the stream.
            // If cleanup also fails, retain ownership and refuse a second capture.
            if (try? input.stop()) != nil {
                sampleQueue.sync { stream = nil; self.recoveryURL = nil; recoveryFile = nil }
            }
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
        let stopped = try stopWritingRecovery(to: recoveryURL)
        return try finalizeRecovery(from: recoveryURL, to: finalURL, audioClockSpans: stopped.audioClockSpans)
    }

    func stopWritingRecovery(to recoveryURL: URL) throws -> SystemAudioTrackTechnicalInfo {
        guard let activeStream = sampleQueue.sync(execute: { stream }) else {
            throw NSError(domain: "Stillmatter.SystemAudioTrackRecorder", code: 3, userInfo: [NSLocalizedDescriptionKey: "There is no active system-audio stream."])
        }
        // A failed OS stop is not proof that the input was released: never offer B.
        let sourceAlreadyStopped = sampleQueue.sync { sourceStoppedGeneration == generation }
        if !sourceAlreadyStopped { try activeStream.stop() }
        let (file, frames, spans) = sampleQueue.sync { () -> (AVAudioFile?, Int64, [AudioClockSpan]) in
            let file = recoveryFile
            let frames = writtenFrames
            let spans = audioClock.archive()
            stream = nil
            sourceStoppedGeneration = nil
            self.recoveryURL = nil
            recoveryFile = nil
            return (file, frames, spans)
        }
        lock.lock()
        let recordedError = writeError
        writeError = nil
        lock.unlock()
        if let recordedError { throw recordedError }
        let format = file?.processingFormat
        return SystemAudioTrackTechnicalInfo(
            durationSeconds: format.map { $0.sampleRate > 0 ? Double(frames) / $0.sampleRate : 0 } ?? 0,
            codec: "linear PCM recovery",
            sampleRate: format?.sampleRate ?? 48_000,
            channelCount: format.map { Int($0.channelCount) } ?? 2,
            audioClockSpans: spans
        )
    }

    func finalizeRecovery(from recoveryURL: URL, to finalURL: URL, audioClockSpans: [AudioClockSpan]?) throws -> SystemAudioTrackTechnicalInfo {
        try exportRecovery(recoveryURL, to: finalURL, audioClockSpans: audioClockSpans)
    }

    func recover(recoveryURL: URL, finalURL: URL) throws -> SystemAudioTrackTechnicalInfo {
        if FileManager.default.fileExists(atPath: finalURL.path) {
            return try technicalInfo(for: finalURL, codec: "AAC in M4A")
        }
        return try exportRecovery(recoveryURL, to: finalURL)
    }

    private func accept(_ sampleBuffer: CMSampleBuffer, generation expected: UInt64) {
        // Stream output is delivered on sampleQueue; an old A callback cannot write B's file.
        guard stream != nil, generation == expected,
              sampleBuffer.isValid, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        do {
            try write(sampleBuffer)
        } catch {
            lock.lock()
            if writeError == nil { writeError = error }
            lock.unlock()
        }
    }

    private func fail(_ error: Error, generation expected: UInt64) {
        // The delegate may run on sampleQueue. Never synchronously wait on that queue here.
        sampleQueue.async { [self] in
            guard stream != nil, generation == expected else { return }
            audioClock.discontinuity()
            sourceStoppedGeneration = expected
            lock.lock()
            let failureHandler = captureFailureHandler
            lock.unlock()
            failureHandler?(error)
        }
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
