import Foundation
import CryptoKit

public enum TranscriptionAudioSelection: String, Codable, Equatable {
    case echoCancelledSidecar
    case originalMicrophone
}

public struct EchoCancellationQuality: Codable, Equatable {
    public let confidence: Double
    public let referenceCorrelation: Double
    public let estimatedEchoReductionDB: Double
    public let retainedSignalRatio: Double

    public init(
        confidence: Double,
        referenceCorrelation: Double,
        estimatedEchoReductionDB: Double,
        retainedSignalRatio: Double
    ) {
        self.confidence = confidence
        self.referenceCorrelation = referenceCorrelation
        self.estimatedEchoReductionDB = estimatedEchoReductionDB
        self.retainedSignalRatio = retainedSignalRatio
    }
}

public struct EchoCancellationProcessingResult: Equatable {
    public let quality: EchoCancellationQuality
    public let diagnostics: [String]
    /// A processor-specific acceptance decision. When absent, the generic quality policy applies.
    public let shouldUseSidecar: Bool?

    public init(
        quality: EchoCancellationQuality,
        diagnostics: [String] = [],
        shouldUseSidecar: Bool? = nil
    ) {
        self.quality = quality
        self.diagnostics = diagnostics
        self.shouldUseSidecar = shouldUseSidecar
    }
}

public struct TranscriptionAudioSidecar: Codable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let captureSessionID: String
    public let recordingBundlePath: String
    public let selection: TranscriptionAudioSelection
    public let selectedAudioFilePath: String
    public let originalMicrophoneFilePath: String
    public let systemReferenceFilePath: String?
    public let echoCancelledFilePath: String?
    public let metadataFilePath: String
    public let generatedAt: Date
    public let quality: EchoCancellationQuality?
    public let diagnostics: [String]
}

public struct EchoCancellationQualityPolicy: Equatable {
    public let minimumConfidence: Double
    public let minimumReferenceCorrelation: Double
    public let minimumEchoReductionDB: Double
    public let minimumRetainedSignalRatio: Double

    public init(
        minimumConfidence: Double = 0.35,
        minimumReferenceCorrelation: Double = 0.12,
        minimumEchoReductionDB: Double = 0.25,
        minimumRetainedSignalRatio: Double = 0.20
    ) {
        self.minimumConfidence = minimumConfidence
        self.minimumReferenceCorrelation = minimumReferenceCorrelation
        self.minimumEchoReductionDB = minimumEchoReductionDB
        self.minimumRetainedSignalRatio = minimumRetainedSignalRatio
    }

    public func accepts(_ quality: EchoCancellationQuality) -> Bool {
        quality.confidence >= minimumConfidence
            && abs(quality.referenceCorrelation) >= minimumReferenceCorrelation
            && quality.estimatedEchoReductionDB >= minimumEchoReductionDB
            && quality.retainedSignalRatio >= minimumRetainedSignalRatio
    }
}

public protocol EchoCancellationProcessing: AnyObject {
    /// Writes only to `outputURL`. The microphone and reference URLs are evidence inputs.
    func process(
        microphoneURL: URL,
        systemReferenceURL: URL,
        outputURL: URL
    ) throws -> EchoCancellationProcessingResult
}

public protocol TranscriptionSidecarGenerating: AnyObject {
    func generate(from bundle: RecordingBundle) throws -> TranscriptionAudioSidecar
}

public enum EchoCancellationSidecarError: Error, Equatable, CustomStringConvertible {
    case unsafeOutputPath(String)
    case missingGeneratedAudio(String)
    case originalRecordingChanged(String)

    public var description: String {
        switch self {
        case let .unsafeOutputPath(path):
            return "Echo cancellation refused to write over an original recording: \(path)"
        case let .missingGeneratedAudio(path):
            return "Echo cancellation reported success without creating audio at \(path)"
        case let .originalRecordingChanged(path):
            return "An original recording changed while generating the transcription sidecar: \(path)"
        }
    }
}

/// Generates a replaceable transcription-only audio artifact beside a validated Recording Bundle.
/// Any uncertain or unavailable cancellation fails open to the original Microphone Track.
public final class EchoCancellationSidecarStage: TranscriptionSidecarGenerating {
    private let bundleValidator: RecordingBundleFinalizing
    private let processor: EchoCancellationProcessing
    private let policy: EchoCancellationQualityPolicy
    private let fileManager: FileManager
    private let now: () -> Date
    private let encoder: JSONEncoder

    public init(
        bundleValidator: RecordingBundleFinalizing,
        processor: EchoCancellationProcessing,
        policy: EchoCancellationQualityPolicy = EchoCancellationQualityPolicy(),
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.bundleValidator = bundleValidator
        self.processor = processor
        self.policy = policy
        self.fileManager = fileManager
        self.now = now
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
    }

    public func generate(from bundle: RecordingBundle) throws -> TranscriptionAudioSidecar {
        try bundleValidator.validate(bundle)
        let directory = URL(fileURLWithPath: bundle.bundleFilePath).deletingLastPathComponent()
        let outputURL = directory.appendingPathComponent("mic-transcription-echo-cancelled.wav")
        let metadataURL = directory.appendingPathComponent("transcription-audio-selection.json")
        let originalURL = URL(fileURLWithPath: bundle.mic.preferredAudioFilePath)
        try ensureOutputIsReplaceable(outputURL, bundle: bundle)

        let originalHashes = try evidenceHashes(bundle)
        var sidecar: TranscriptionAudioSidecar
        if let system = bundle.system,
           fileManager.fileExists(atPath: system.preferredAudioFilePath) {
            do {
                persistAudioTimingIfAvailable(bundle: bundle, directory: directory)
                if fileManager.fileExists(atPath: outputURL.path) {
                    try fileManager.removeItem(at: outputURL)
                }
                let result = try processor.process(
                    microphoneURL: originalURL,
                    systemReferenceURL: URL(fileURLWithPath: system.preferredAudioFilePath),
                    outputURL: outputURL
                )
                guard fileManager.fileExists(atPath: outputURL.path) else {
                    throw EchoCancellationSidecarError.missingGeneratedAudio(outputURL.path)
                }
                if result.shouldUseSidecar ?? policy.accepts(result.quality) {
                    sidecar = makeSidecar(
                        bundle: bundle,
                        selection: .echoCancelledSidecar,
                        selectedPath: outputURL.path,
                        referencePath: system.preferredAudioFilePath,
                        outputPath: outputURL.path,
                        metadataPath: metadataURL.path,
                        quality: result.quality,
                        diagnostics: result.diagnostics + ["Echo-cancelled sidecar passed the transcription quality policy."]
                    )
                } else {
                    try? fileManager.removeItem(at: outputURL)
                    sidecar = makeFallback(
                        bundle: bundle,
                        metadataPath: metadataURL.path,
                        referencePath: system.preferredAudioFilePath,
                        quality: result.quality,
                        diagnostics: result.diagnostics + ["Echo cancellation was uncertain; transcription will use the original microphone track."]
                    )
                }
            } catch {
                try? fileManager.removeItem(at: outputURL)
                sidecar = makeFallback(
                    bundle: bundle,
                    metadataPath: metadataURL.path,
                    referencePath: system.preferredAudioFilePath,
                    quality: nil,
                    diagnostics: ["Echo cancellation could not be generated: \(error). Transcription will use the original microphone track."]
                )
            }
        } else {
            try? fileManager.removeItem(at: outputURL)
            sidecar = makeFallback(
                bundle: bundle,
                metadataPath: metadataURL.path,
                referencePath: nil,
                quality: nil,
                diagnostics: ["No usable System Audio Track was available as an echo reference; transcription will use the original microphone track."]
            )
        }

        try verifyEvidenceHashes(originalHashes)
        try persist(sidecar, at: metadataURL)
        return sidecar
    }

    private func makeFallback(
        bundle: RecordingBundle,
        metadataPath: String,
        referencePath: String?,
        quality: EchoCancellationQuality?,
        diagnostics: [String]
    ) -> TranscriptionAudioSidecar {
        makeSidecar(
            bundle: bundle,
            selection: .originalMicrophone,
            selectedPath: bundle.mic.preferredAudioFilePath,
            referencePath: referencePath,
            outputPath: nil,
            metadataPath: metadataPath,
            quality: quality,
            diagnostics: diagnostics
        )
    }

    private func makeSidecar(
        bundle: RecordingBundle,
        selection: TranscriptionAudioSelection,
        selectedPath: String,
        referencePath: String?,
        outputPath: String?,
        metadataPath: String,
        quality: EchoCancellationQuality?,
        diagnostics: [String]
    ) -> TranscriptionAudioSidecar {
        TranscriptionAudioSidecar(
            schemaVersion: TranscriptionAudioSidecar.currentSchemaVersion,
            captureSessionID: bundle.captureSessionID,
            recordingBundlePath: bundle.bundleFilePath,
            selection: selection,
            selectedAudioFilePath: selectedPath,
            originalMicrophoneFilePath: bundle.mic.preferredAudioFilePath,
            systemReferenceFilePath: referencePath,
            echoCancelledFilePath: outputPath,
            metadataFilePath: metadataPath,
            generatedAt: now(),
            quality: quality,
            diagnostics: diagnostics
        )
    }

    private func ensureOutputIsReplaceable(_ outputURL: URL, bundle: RecordingBundle) throws {
        let protected = [
            bundle.bundleFilePath,
            bundle.mic.recoveryFilePath,
            bundle.mic.finalFilePath,
            bundle.mic.metadataFilePath,
            bundle.system?.recoveryFilePath,
            bundle.system?.finalFilePath,
            bundle.system?.metadataFilePath
        ].compactMap { $0 }.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        if protected.contains(outputURL.standardizedFileURL.path) {
            throw EchoCancellationSidecarError.unsafeOutputPath(outputURL.path)
        }
    }

    private func evidenceHashes(_ bundle: RecordingBundle) throws -> [String: String] {
        let paths = [bundle.mic.preferredAudioFilePath, bundle.system?.preferredAudioFilePath].compactMap { $0 }
        return try Dictionary(uniqueKeysWithValues: paths.map { path in
            (path, try sha256(path: path))
        })
    }

    private func verifyEvidenceHashes(_ originals: [String: String]) throws {
        for (path, digest) in originals where (try? sha256(path: path)) != digest {
            throw EchoCancellationSidecarError.originalRecordingChanged(path)
        }
    }

    private func persistAudioTimingIfAvailable(bundle: RecordingBundle, directory: URL) {
        guard let system = bundle.system else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let microphoneData = try? Data(contentsOf: URL(fileURLWithPath: bundle.mic.metadataFilePath)),
              let microphone = try? decoder.decode(MicTrackRecordingMetadata.self, from: microphoneData),
              let referenceData = try? Data(contentsOf: URL(fileURLWithPath: system.metadataFilePath)),
              let reference = try? decoder.decode(SystemAudioTrackRecordingMetadata.self, from: referenceData) else { return }
        guard let microphoneSpans = microphone.audioClockSpans, !microphoneSpans.isEmpty,
              let systemSpans = reference.audioClockSpans, !systemSpans.isEmpty else { return }
        let timing = RecordingAudioTiming(microphone: microphoneSpans, system: systemSpans)
        let timingURL = directory.appendingPathComponent(RecordingAudioTiming.fileName)
        try? encoder.encode(timing).write(to: timingURL, options: .atomic)
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

    private func persist(_ sidecar: TranscriptionAudioSidecar, at url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".transcription-audio-selection.json.tmp")
        try encoder.encode(sidecar).write(to: temporary, options: .atomic)
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: url)
        }
    }
}
