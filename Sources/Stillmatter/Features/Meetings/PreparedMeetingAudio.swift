import AVFoundation
#if SWIFT_PACKAGE
import StillmatterCore
#endif

/// Owns playback-only files that insert recorded clock gaps as silence.
final class PreparedMeetingAudio: Sendable {
    struct Input: Sendable {
        let path: String
        let ranges: [MeetingPlaybackRange]
    }

    struct Track: Sendable {
        let path: String
        let offset: Double
    }

    let microphone: Track
    let system: Track?
    private let directory: URL

    private init(microphone: Track, system: Track?, directory: URL) {
        self.microphone = microphone
        self.system = system
        self.directory = directory
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    static func prepare(microphone: Input, system: Input?, duration: Double, in parent: URL) throws -> PreparedMeetingAudio {
        try Task.checkCancellation()
        let directory = parent.appendingPathComponent("stillmatter-playback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        do {
            let mic = try prepareTrack(microphone, duration: duration, output: directory.appendingPathComponent("microphone.caf"))
            let other = try system.map {
                try prepareTrack($0, duration: duration, output: directory.appendingPathComponent("system.caf"))
            }
            try Task.checkCancellation()
            return PreparedMeetingAudio(microphone: mic, system: other, directory: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private struct Slice {
        let fileEnd: AVAudioFramePosition
        let outputStart: AVAudioFramePosition
    }

    private static func prepareTrack(_ source: Input, duration: Double, output: URL) throws -> Track {
        let input = try AVAudioFile(forReading: URL(fileURLWithPath: source.path))
        let format = input.processingFormat
        let rate = format.sampleRate
        guard rate.isFinite, rate > 0, let offset = source.ranges.first?.timelineStart,
              offset.isFinite, offset >= 0, duration.isFinite else { throw PreparationError.invalidTiming }
        var fileEnd: AVAudioFramePosition = 0
        var outputEnd: AVAudioFramePosition = 0
        let slices = try source.ranges.map { range in
            guard let start = AVAudioFramePosition(exactly: (range.fileStart * rate).rounded()),
                  let end = AVAudioFramePosition(exactly: (range.fileEnd * rate).rounded()),
                  let position = AVAudioFramePosition(exactly: ((range.timelineStart - offset) * rate).rounded()),
                  start == fileEnd, end > start, end <= input.length, position >= outputEnd,
                  range.timelineEnd <= duration + 1 / rate,
                  position <= AVAudioFramePosition.max - (end - start) else { throw PreparationError.invalidTiming }
            fileEnd = end
            outputEnd = position + (end - start)
            return Slice(fileEnd: end, outputStart: position)
        }
        guard fileEnd == input.length else { throw PreparationError.invalidTiming }
        if outputEnd == input.length { return Track(path: source.path, offset: offset) }

        let capacity = try FileManager.default.attributesOfFileSystem(forPath: output.deletingLastPathComponent().path)
        guard let freeBytes = capacity[.systemFreeSize] as? NSNumber,
              Double(outputEnd) * Double(format.channelCount) * Double(MemoryLayout<Float>.size) < freeBytes.doubleValue
        else { throw PreparationError.insufficientSpace }

        let writer = try AVAudioFile(forWriting: output, settings: format.settings)
        let block: AVAudioFrameCount = 8_192
        guard let audio = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: block),
              let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: block),
              let channels = silence.floatChannelData else { throw PreparationError.invalidTiming }
        for channel in 0..<Int(format.channelCount) {
            channels[channel].update(repeating: 0, count: Int(block))
        }
        for slice in slices {
            while writer.framePosition < slice.outputStart {
                try Task.checkCancellation()
                silence.frameLength = AVAudioFrameCount(min(Int64(block), slice.outputStart - writer.framePosition))
                try writer.write(from: silence)
            }
            while input.framePosition < slice.fileEnd {
                try Task.checkCancellation()
                let frames = AVAudioFrameCount(min(Int64(block), slice.fileEnd - input.framePosition))
                try input.read(into: audio, frameCount: frames)
                guard audio.frameLength > 0 else { throw PreparationError.invalidTiming }
                try writer.write(from: audio)
            }
        }
        return Track(path: output.path, offset: offset)
    }

    private enum PreparationError: LocalizedError {
        case invalidTiming
        case insufficientSpace

        var errorDescription: String? {
            switch self {
            case .invalidTiming: "Playback cannot align the recording's timing with the retained audio."
            case .insufficientSpace: "Playback needs more temporary disk space to preserve gaps in this recording."
            }
        }
    }
}
