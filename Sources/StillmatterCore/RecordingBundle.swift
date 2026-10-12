import Foundation
import CryptoKit

public enum RecordingBundleFinalizationReason: String, Codable, Equatable {
    case normalStop
    case recovery
}

public enum RecordingBundleState: String, Codable, Equatable {
    case ready
    case degraded
    case partial
}

public struct RecordingBundleTrack: Codable, Equatable {
    public let role: String
    public let status: String
    public let preferredAudioFilePath: String
    public let recoveryFilePath: String
    public let finalFilePath: String
    public let metadataFilePath: String
    public let recoveryFileExists: Bool
    public let finalFileExists: Bool
    public let metadataFileExists: Bool
    public let recoveryFileSHA256: String?
    public let finalFileSHA256: String?
    public let durationSeconds: Double
    public let codec: String
    public let sampleRate: Double
    public let channelCount: Int
    public let diagnostics: [String]
}

/// The canonical handoff from capture to later processing. It records what was actually
/// preserved on disk; downstream jobs consume this sidecar instead of assembling track paths.
public struct RecordingBundle: Codable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let captureSessionID: String
    public let meetingRelativePath: String
    public let bundleFilePath: String
    public let finalizedAt: Date
    public let reason: RecordingBundleFinalizationReason
    public let state: RecordingBundleState
    public let mic: RecordingBundleTrack
    public let system: RecordingBundleTrack?
    public let diagnostics: [String]
}

public enum RecordingBundleError: Error, Equatable, CustomStringConvertible {
    case mismatchedCaptureSession
    case mismatchedMeeting
    case missingMicrophoneAudio(String)
    case missingSystemAudio(String)
    case missingBundle(String)
    case changedArtifact(String)
    case unsupportedSchemaVersion(Int)

    public var description: String {
        switch self {
        case .mismatchedCaptureSession:
            return "Microphone and system tracks belong to different Capture Sessions"
        case .mismatchedMeeting:
            return "Microphone and system tracks refer to different Meetings"
        case let .missingMicrophoneAudio(path):
            return "The recording bundle has no readable microphone audio at \(path)"
        case let .missingSystemAudio(path):
            return "The recording bundle claims finalized system audio but it is missing at \(path)"
        case let .missingBundle(path):
            return "The recording bundle sidecar is missing at \(path)"
        case let .changedArtifact(path):
            return "A recording artifact changed after the bundle was created: \(path)"
        case let .unsupportedSchemaVersion(version):
            return "Unsupported recording bundle schema version: \(version)"
        }
    }
}

public protocol RecordingBundleFinalizing: AnyObject {
    func finalize(
        mic: MicTrackRecordingMetadata,
        system: SystemAudioTrackRecordingMetadata?,
        reason: RecordingBundleFinalizationReason
    ) throws -> RecordingBundle
    func validate(_ bundle: RecordingBundle) throws
}

public final class RecordingBundleFinalizer: RecordingBundleFinalizing {
    private let fileManager: FileManager
    private let now: () -> Date
    private let encoder: JSONEncoder

    public init(fileManager: FileManager = .default, now: @escaping () -> Date = Date.init) {
        self.fileManager = fileManager
        self.now = now
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
    }

    public func finalize(
        mic: MicTrackRecordingMetadata,
        system: SystemAudioTrackRecordingMetadata?,
        reason: RecordingBundleFinalizationReason
    ) throws -> RecordingBundle {
        if let system = system {
            guard system.captureSessionID == mic.captureSessionID else {
                throw RecordingBundleError.mismatchedCaptureSession
            }
            guard system.meetingRelativePath == mic.meetingRelativePath else {
                throw RecordingBundleError.mismatchedMeeting
            }
        }

        let directory = URL(fileURLWithPath: mic.metadataFilePath).deletingLastPathComponent()
        let bundleURL = directory.appendingPathComponent("recording-bundle.json")
        let micTrack = try makeMicTrack(mic)
        let systemTrack = try system.map(makeSystemTrack)
        let state = bundleState(mic: mic, system: system, micTrack: micTrack, systemTrack: systemTrack)
        var diagnostics = mic.diagnostics.map { "Microphone: \($0)" }
        if let system = system {
            diagnostics += system.diagnostics.map { "System audio: \($0)" }
        } else {
            diagnostics.append("System audio: no separate track metadata was available; bundle is microphone-only.")
        }
        let bundle = RecordingBundle(
            schemaVersion: RecordingBundle.currentSchemaVersion,
            captureSessionID: mic.captureSessionID,
            meetingRelativePath: mic.meetingRelativePath,
            bundleFilePath: bundleURL.path,
            finalizedAt: now(),
            reason: reason,
            state: state,
            mic: micTrack,
            system: systemTrack,
            diagnostics: diagnostics
        )
        try validateRequiredAudio(bundle)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporaryURL = directory.appendingPathComponent(".recording-bundle.json.tmp")
        try encoder.encode(bundle).write(to: temporaryURL, options: .atomic)
        if fileManager.fileExists(atPath: bundleURL.path) {
            _ = try fileManager.replaceItemAt(bundleURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: bundleURL)
        }
        guard fileManager.fileExists(atPath: bundleURL.path) else {
            throw RecordingBundleError.missingBundle(bundleURL.path)
        }
        return bundle
    }

    public func validate(_ bundle: RecordingBundle) throws {
        guard bundle.schemaVersion == RecordingBundle.currentSchemaVersion else {
            throw RecordingBundleError.unsupportedSchemaVersion(bundle.schemaVersion)
        }
        guard fileManager.fileExists(atPath: bundle.bundleFilePath) else {
            throw RecordingBundleError.missingBundle(bundle.bundleFilePath)
        }
        try validateReferences(bundle)
    }

    private func validateReferences(_ bundle: RecordingBundle) throws {
        try validate(track: bundle.mic)
        if let system = bundle.system {
            try validate(track: system)
        }
        try validateRequiredAudio(bundle)
    }

    private func validateRequiredAudio(_ bundle: RecordingBundle) throws {
        guard fileManager.fileExists(atPath: bundle.mic.preferredAudioFilePath) else {
            throw RecordingBundleError.missingMicrophoneAudio(bundle.mic.preferredAudioFilePath)
        }
        if let system = bundle.system {
            if (system.status == SystemAudioTrackRecordingStatus.completed.rawValue
                    || system.status == SystemAudioTrackRecordingStatus.recovered.rawValue)
                && !fileManager.fileExists(atPath: system.preferredAudioFilePath) {
                throw RecordingBundleError.missingSystemAudio(system.preferredAudioFilePath)
            }
        }
    }

    /// Confirms a track's recorded artifact-presence and hash evidence still match disk.
    /// Playback uses this without requiring every optional track to be present.
    public func validate(track: RecordingBundleTrack) throws {
        let artifacts: [(String, Bool, String?)] = [
            (track.recoveryFilePath, track.recoveryFileExists, track.recoveryFileSHA256),
            (track.finalFilePath, track.finalFileExists, track.finalFileSHA256),
            (track.metadataFilePath, track.metadataFileExists, nil)
        ]
        for (path, recordedExists, recordedHash) in artifacts {
            let exists = fileManager.fileExists(atPath: path)
            guard exists == recordedExists else { throw RecordingBundleError.changedArtifact(path) }
            if let recordedHash = recordedHash, try sha256(path: path) != recordedHash {
                throw RecordingBundleError.changedArtifact(path)
            }
        }
    }

    /// Playback-only verification after a recording media directory has moved. The sidecar
    /// and doorway remain immutable; every referenced artifact must have the same basename,
    /// recorded presence, and (where supplied) SHA-256 in the candidate directory.
    public func validatedRelocatedAudio(track: RecordingBundleTrack, originalDirectory: URL, relocatedDirectory: URL) throws -> String {
        let originals = [track.recoveryFilePath, track.finalFilePath, track.metadataFilePath, track.preferredAudioFilePath]
        guard originals.allSatisfy({ URL(fileURLWithPath: $0).deletingLastPathComponent().standardizedFileURL == originalDirectory.standardizedFileURL }),
              track.preferredAudioFilePath == track.recoveryFilePath || track.preferredAudioFilePath == track.finalFilePath,
              Set(originals.prefix(3).map { URL(fileURLWithPath: $0).lastPathComponent }).count == 3 else {
            throw RecordingBundleError.changedArtifact(track.preferredAudioFilePath)
        }
        for (path, expected, hash) in [
            (track.recoveryFilePath, track.recoveryFileExists, track.recoveryFileSHA256),
            (track.finalFilePath, track.finalFileExists, track.finalFileSHA256),
            (track.metadataFilePath, track.metadataFileExists, nil)
        ] {
            let candidate = relocatedDirectory.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent).path
            guard fileManager.fileExists(atPath: candidate) == expected else {
                throw RecordingBundleError.changedArtifact(path)
            }
            if let hash, try sha256(path: candidate) != hash {
                throw RecordingBundleError.changedArtifact(path)
            }
        }
        let audio = relocatedDirectory.appendingPathComponent(URL(fileURLWithPath: track.preferredAudioFilePath).lastPathComponent).path
        guard fileManager.isReadableFile(atPath: audio) else { throw RecordingBundleError.missingMicrophoneAudio(audio) }
        return audio
    }

    private func makeMicTrack(_ metadata: MicTrackRecordingMetadata) throws -> RecordingBundleTrack {
        try makeTrack(
            role: "microphone",
            status: metadata.status.rawValue,
            recoveryPath: metadata.recoveryFilePath,
            finalPath: metadata.finalFilePath,
            metadataPath: metadata.metadataFilePath,
            duration: metadata.durationSeconds,
            codec: metadata.codec,
            sampleRate: metadata.sampleRate,
            channels: metadata.channelCount,
            diagnostics: metadata.diagnostics
        )
    }

    private func makeSystemTrack(_ metadata: SystemAudioTrackRecordingMetadata) throws -> RecordingBundleTrack {
        try makeTrack(
            role: "system-audio",
            status: metadata.status.rawValue,
            recoveryPath: metadata.recoveryFilePath,
            finalPath: metadata.finalFilePath,
            metadataPath: metadata.metadataFilePath,
            duration: metadata.durationSeconds,
            codec: metadata.codec,
            sampleRate: metadata.sampleRate,
            channels: metadata.channelCount,
            diagnostics: metadata.diagnostics
        )
    }

    private func makeTrack(
        role: String,
        status: String,
        recoveryPath: String,
        finalPath: String,
        metadataPath: String,
        duration: Double,
        codec: String,
        sampleRate: Double,
        channels: Int,
        diagnostics: [String]
    ) throws -> RecordingBundleTrack {
        let recoveryExists = fileManager.fileExists(atPath: recoveryPath)
        let finalExists = fileManager.fileExists(atPath: finalPath)
        let metadataExists = fileManager.fileExists(atPath: metadataPath)
        return RecordingBundleTrack(
            role: role,
            status: status,
            preferredAudioFilePath: finalExists ? finalPath : recoveryPath,
            recoveryFilePath: recoveryPath,
            finalFilePath: finalPath,
            metadataFilePath: metadataPath,
            recoveryFileExists: recoveryExists,
            finalFileExists: finalExists,
            metadataFileExists: metadataExists,
            recoveryFileSHA256: recoveryExists ? try sha256(path: recoveryPath) : nil,
            finalFileSHA256: finalExists ? try sha256(path: finalPath) : nil,
            durationSeconds: duration,
            codec: codec,
            sampleRate: sampleRate,
            channelCount: channels,
            diagnostics: diagnostics
        )
    }

    private func bundleState(
        mic: MicTrackRecordingMetadata,
        system: SystemAudioTrackRecordingMetadata?,
        micTrack: RecordingBundleTrack,
        systemTrack: RecordingBundleTrack?
    ) -> RecordingBundleState {
        let micFinal = mic.status == .completed || mic.status == .recovered
        guard micFinal && micTrack.finalFileExists else { return .partial }
        guard let system = system, let systemTrack = systemTrack else { return .degraded }
        let systemFinal = system.status == .completed || system.status == .recovered
        return systemFinal && systemTrack.finalFileExists ? .ready : .degraded
    }

    private func sha256(path: String) throws -> String {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = handle.readData(ofLength: 1024 * 1024)
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
