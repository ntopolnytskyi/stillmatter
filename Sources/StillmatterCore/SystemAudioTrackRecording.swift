import Foundation

public enum SystemAudioTrackRecordingStatus: String, Codable, Equatable {
    case recording
    case finalizing
    case completed
    case failed
    case recovered
    case partial
}

public struct SystemAudioTrackTechnicalInfo: Codable, Equatable {
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

public struct SystemAudioTrackRecordingMetadata: Codable, Equatable {
    public let schemaVersion: Int
    public let captureSessionID: String
    public let meetingRelativePath: String
    public let recoveryFilePath: String
    public let finalFilePath: String
    public let metadataFilePath: String
    public let startedAt: Date
    public var endedAt: Date?
    public var status: SystemAudioTrackRecordingStatus
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
        status: SystemAudioTrackRecordingStatus = .recording,
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

public protocol SystemAudioTrackRecordingBackend: AnyObject {
    func startWritingRecovery(to recoveryURL: URL) throws -> SystemAudioTrackTechnicalInfo
    func stopAndFinalize(recoveryURL: URL, finalURL: URL) throws -> SystemAudioTrackTechnicalInfo
    func recover(recoveryURL: URL, finalURL: URL) throws -> SystemAudioTrackTechnicalInfo
}

public protocol SystemAudioTrackRecordingManaging: AnyObject {
    var activeMetadata: SystemAudioTrackRecordingMetadata? { get }
    var latestMetadata: SystemAudioTrackRecordingMetadata? { get }
    func start(sessionID: String, meetingRelativePath: String, startedAt: Date) throws -> SystemAudioTrackRecordingMetadata
    func stop(endedAt: Date) throws -> SystemAudioTrackRecordingMetadata
}

public enum SystemAudioTrackRecordingError: Error, CustomStringConvertible {
    case alreadyRecording
    case noActiveRecording
    case recoveryArtifactMissing(String)

    public var description: String {
        switch self {
        case .alreadyRecording: return "A system audio track is already recording"
        case .noActiveRecording: return "There is no active system audio track"
        case let .recoveryArtifactMissing(path): return "System audio recovery artifact is missing: \(path)"
        }
    }
}

/// Owns the separate system-audio artifacts. Failures are persisted in the sidecar while
/// callers remain free to continue a microphone-only Capture Session.
public final class SystemAudioTrackRecordingCoordinator: SystemAudioTrackRecordingManaging {
    private let mediaRootURL: URL
    private let backend: SystemAudioTrackRecordingBackend
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    public private(set) var activeMetadata: SystemAudioTrackRecordingMetadata?
    public private(set) var latestMetadata: SystemAudioTrackRecordingMetadata?

    public init(mediaRootURL: URL, backend: SystemAudioTrackRecordingBackend, fileManager: FileManager = .default) {
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
    public func start(sessionID: String, meetingRelativePath: String, startedAt: Date) throws -> SystemAudioTrackRecordingMetadata {
        guard activeMetadata == nil else { throw SystemAudioTrackRecordingError.alreadyRecording }
        let directory = mediaRootURL
            .appendingPathComponent("Stillmatter Recordings", isDirectory: true)
            .appendingPathComponent(sessionID, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let recoveryURL = directory.appendingPathComponent("system-recovery.caf")
        let finalURL = directory.appendingPathComponent("system.m4a")
        let metadataURL = directory.appendingPathComponent("system-recording.json")
        var metadata = SystemAudioTrackRecordingMetadata(
            captureSessionID: sessionID,
            meetingRelativePath: meetingRelativePath,
            recoveryFilePath: recoveryURL.path,
            finalFilePath: finalURL.path,
            metadataFilePath: metadataURL.path,
            startedAt: startedAt,
            diagnostics: ["Separate crash-safe system-audio recovery/preview artifact allocated."]
        )
        try write(metadata)
        activeMetadata = metadata
        latestMetadata = metadata
        do {
            let info = try backend.startWritingRecovery(to: recoveryURL)
            apply(info, to: &metadata)
            metadata.diagnostics.append("Separate system-audio capture started.")
            try write(metadata)
            activeMetadata = metadata
            latestMetadata = metadata
            return metadata
        } catch {
            metadata.status = .failed
            metadata.diagnostics.append("System-audio start failed; microphone capture may continue: \(error)")
            try? write(metadata)
            activeMetadata = nil
            latestMetadata = metadata
            throw error
        }
    }

    @discardableResult
    public func stop(endedAt: Date) throws -> SystemAudioTrackRecordingMetadata {
        guard var metadata = activeMetadata else { throw SystemAudioTrackRecordingError.noActiveRecording }
        metadata.status = .finalizing
        metadata.endedAt = endedAt
        try write(metadata)
        activeMetadata = metadata
        latestMetadata = metadata
        do {
            let info = try backend.stopAndFinalize(
                recoveryURL: URL(fileURLWithPath: metadata.recoveryFilePath),
                finalURL: URL(fileURLWithPath: metadata.finalFilePath)
            )
            apply(info, to: &metadata)
            metadata.status = .completed
            metadata.diagnostics.append("Compact separate system-audio track finalized; recovery/preview artifact retained.")
            try write(metadata)
            activeMetadata = nil
            latestMetadata = metadata
            return metadata
        } catch {
            metadata.status = .failed
            metadata.diagnostics.append("System-audio finalization failed; source artifacts retained and microphone track is unaffected: \(error)")
            try? write(metadata)
            activeMetadata = nil
            latestMetadata = metadata
            throw error
        }
    }

    public func recoverUnfinished() -> [SystemAudioTrackRecordingMetadata] {
        guard let enumerator = fileManager.enumerator(
            at: mediaRootURL.appendingPathComponent("Stillmatter Recordings", isDirectory: true),
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }
        var results: [SystemAudioTrackRecordingMetadata] = []
        for case let url as URL in enumerator where url.lastPathComponent == "system-recording.json" {
            guard var metadata = try? decoder.decode(SystemAudioTrackRecordingMetadata.self, from: Data(contentsOf: url)),
                  metadata.status == .recording || metadata.status == .finalizing || metadata.status == .failed else { continue }
            let recoveryURL = URL(fileURLWithPath: metadata.recoveryFilePath)
            guard fileManager.fileExists(atPath: recoveryURL.path) else {
                metadata.status = .partial
                metadata.diagnostics.append(SystemAudioTrackRecordingError.recoveryArtifactMissing(recoveryURL.path).description)
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
                metadata.diagnostics.append("Recovered compact system-audio track from retained recovery/preview audio.")
            } catch {
                metadata.status = .partial
                metadata.diagnostics.append("Partial system audio remains available at \(recoveryURL.path): \(error)")
            }
            try? write(metadata)
            latestMetadata = metadata
            results.append(metadata)
        }
        return results
    }

    private func apply(_ info: SystemAudioTrackTechnicalInfo, to metadata: inout SystemAudioTrackRecordingMetadata) {
        metadata.durationSeconds = info.durationSeconds
        metadata.codec = info.codec
        metadata.sampleRate = info.sampleRate
        metadata.channelCount = info.channelCount
        if let spans = info.audioClockSpans { metadata.audioClockSpans = spans }
    }

    private func write(_ metadata: SystemAudioTrackRecordingMetadata) throws {
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
