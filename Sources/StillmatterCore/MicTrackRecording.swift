import Foundation

public enum MicTrackRecordingStatus: String, Codable, Equatable {
    case recording
    case finalizing
    case completed
    case failed
    case recovered
    case partial
}

public struct MicTrackTechnicalInfo: Codable, Equatable {
    public let durationSeconds: Double
    public let codec: String
    public let sampleRate: Double
    public let channelCount: Int
    public let audioClockSpans: [AudioClockSpan]?

    public init(
        durationSeconds: Double,
        codec: String,
        sampleRate: Double,
        channelCount: Int,
        audioClockSpans: [AudioClockSpan]? = nil
    ) {
        self.durationSeconds = durationSeconds
        self.codec = codec
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.audioClockSpans = audioClockSpans
    }
}

public struct MicTrackRecordingMetadata: Codable, Equatable {
    public let schemaVersion: Int
    public let captureSessionID: String
    public let meetingRelativePath: String
    public let recoveryFilePath: String
    public let finalFilePath: String
    public let metadataFilePath: String
    public let startedAt: Date
    public var endedAt: Date?
    public var status: MicTrackRecordingStatus
    public var durationSeconds: Double
    public var codec: String
    public var sampleRate: Double
    public var channelCount: Int
    public var audioClockSpans: [AudioClockSpan]?
    public var diagnostics: [String]

    public init(
        captureSessionID: String,
        meetingRelativePath: String,
        recoveryFilePath: String,
        finalFilePath: String,
        metadataFilePath: String,
        startedAt: Date,
        status: MicTrackRecordingStatus = .recording,
        durationSeconds: Double = 0,
        codec: String = "linear PCM recovery",
        sampleRate: Double = 0,
        channelCount: Int = 0,
        audioClockSpans: [AudioClockSpan]? = nil,
        diagnostics: [String] = []
    ) {
        schemaVersion = 1
        self.captureSessionID = captureSessionID
        self.meetingRelativePath = meetingRelativePath
        self.recoveryFilePath = recoveryFilePath
        self.finalFilePath = finalFilePath
        self.metadataFilePath = metadataFilePath
        self.startedAt = startedAt
        self.status = status
        self.durationSeconds = durationSeconds
        self.codec = codec
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.audioClockSpans = audioClockSpans
        self.diagnostics = diagnostics
    }
}

public protocol MicTrackRecordingBackend: AnyObject {
    func startWritingRecovery(to recoveryURL: URL) throws -> MicTrackTechnicalInfo
    func stopAndFinalize(recoveryURL: URL, finalURL: URL) throws -> MicTrackTechnicalInfo
    func recover(recoveryURL: URL, finalURL: URL) throws -> MicTrackTechnicalInfo
}

public protocol MicTrackRecordingManaging: AnyObject {
    var activeMetadata: MicTrackRecordingMetadata? { get }
    func start(sessionID: String, meetingRelativePath: String, startedAt: Date) throws -> MicTrackRecordingMetadata
    func stop(endedAt: Date) throws -> MicTrackRecordingMetadata
}

public enum MicTrackRecordingError: Error, CustomStringConvertible {
    case alreadyRecording
    case noActiveRecording
    case recoveryArtifactMissing(String)

    public var description: String {
        switch self {
        case .alreadyRecording: return "A microphone track is already recording"
        case .noActiveRecording: return "There is no active microphone track"
        case let .recoveryArtifactMissing(path): return "Microphone recovery artifact is missing: \(path)"
        }
    }
}

/// Owns crash-safe microphone artifacts and metadata. The recovery CAF is never removed:
/// successful finalization creates a compact M4A alongside it, and failures retain every source.
public final class MicTrackRecordingCoordinator: MicTrackRecordingManaging {
    private let mediaRootURL: URL
    private let backend: MicTrackRecordingBackend
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    public private(set) var activeMetadata: MicTrackRecordingMetadata?

    public init(mediaRootURL: URL, backend: MicTrackRecordingBackend, fileManager: FileManager = .default) {
        self.mediaRootURL = mediaRootURL
        self.backend = backend
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    @discardableResult
    public func start(sessionID: String, meetingRelativePath: String, startedAt: Date) throws -> MicTrackRecordingMetadata {
        guard activeMetadata == nil else { throw MicTrackRecordingError.alreadyRecording }
        let directory = mediaRootURL
            .appendingPathComponent("Stillmatter Recordings", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let recoveryURL = directory.appendingPathComponent("mic-recovery.caf")
        let finalURL = directory.appendingPathComponent("mic.m4a")
        let metadataURL = directory.appendingPathComponent("mic-recording.json")
        var metadata = MicTrackRecordingMetadata(
            captureSessionID: sessionID,
            meetingRelativePath: meetingRelativePath,
            recoveryFilePath: recoveryURL.path,
            finalFilePath: finalURL.path,
            metadataFilePath: metadataURL.path,
            startedAt: startedAt,
            diagnostics: ["Crash-safe linear PCM recovery/preview artifact allocated."]
        )
        try write(metadata)
        activeMetadata = metadata
        do {
            let info = try backend.startWritingRecovery(to: recoveryURL)
            metadata.sampleRate = info.sampleRate
            metadata.channelCount = info.channelCount
            metadata.diagnostics.append("Microphone capture started.")
            try write(metadata)
            activeMetadata = metadata
            return metadata
        } catch {
            metadata.status = .failed
            metadata.diagnostics.append("Microphone start failed: \(error)")
            try? write(metadata)
            activeMetadata = nil
            throw error
        }
    }

    @discardableResult
    public func stop(endedAt: Date) throws -> MicTrackRecordingMetadata {
        guard var metadata = activeMetadata else { throw MicTrackRecordingError.noActiveRecording }
        metadata.status = .finalizing
        metadata.endedAt = endedAt
        try write(metadata)
        activeMetadata = metadata
        do {
            let info = try backend.stopAndFinalize(
                recoveryURL: URL(fileURLWithPath: metadata.recoveryFilePath),
                finalURL: URL(fileURLWithPath: metadata.finalFilePath)
            )
            apply(info, to: &metadata)
            metadata.status = .completed
            metadata.diagnostics.append("Compact microphone track finalized; recovery/preview artifact retained.")
            try write(metadata)
            activeMetadata = nil
            return metadata
        } catch {
            metadata.status = .failed
            metadata.diagnostics.append("Microphone finalization failed; source artifacts retained: \(error)")
            try? write(metadata)
            activeMetadata = nil
            throw error
        }
    }

    /// Detects metadata left in an unfinished state, attempts compact finalization from the
    /// retained CAF, and records a recovered or partial result without deleting any artifact.
    public func recoverUnfinished() -> [MicTrackRecordingMetadata] {
        guard let enumerator = fileManager.enumerator(
            at: mediaRootURL.appendingPathComponent("Stillmatter Recordings", isDirectory: true),
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }
        var results: [MicTrackRecordingMetadata] = []
        for case let url as URL in enumerator where url.lastPathComponent == "mic-recording.json" {
            guard var metadata = try? decoder.decode(MicTrackRecordingMetadata.self, from: Data(contentsOf: url)),
                  metadata.status == .recording || metadata.status == .finalizing || metadata.status == .failed else { continue }
            let recoveryURL = URL(fileURLWithPath: metadata.recoveryFilePath)
            guard fileManager.fileExists(atPath: recoveryURL.path) else {
                metadata.status = .partial
                metadata.diagnostics.append(MicTrackRecordingError.recoveryArtifactMissing(recoveryURL.path).description)
                try? write(metadata)
                results.append(metadata)
                continue
            }
            do {
                let info = try backend.recover(
                    recoveryURL: recoveryURL,
                    finalURL: URL(fileURLWithPath: metadata.finalFilePath)
                )
                apply(info, to: &metadata)
                metadata.status = .recovered
                metadata.endedAt = metadata.endedAt ?? Date()
                metadata.diagnostics.append("Recovered compact microphone track from retained recovery/preview audio.")
            } catch {
                metadata.status = .partial
                metadata.diagnostics.append("Partial microphone audio remains available at \(recoveryURL.path): \(error)")
            }
            try? write(metadata)
            results.append(metadata)
        }
        return results
    }

    private func apply(_ info: MicTrackTechnicalInfo, to metadata: inout MicTrackRecordingMetadata) {
        metadata.durationSeconds = info.durationSeconds
        metadata.codec = info.codec
        metadata.sampleRate = info.sampleRate
        metadata.channelCount = info.channelCount
        if let spans = info.audioClockSpans { metadata.audioClockSpans = spans }
    }

    private func write(_ metadata: MicTrackRecordingMetadata) throws {
        let url = URL(fileURLWithPath: metadata.metadataFilePath)
        let temporaryURL = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp")
        try encoder.encode(metadata).write(to: temporaryURL, options: .atomic)
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: url)
        }
    }
}
