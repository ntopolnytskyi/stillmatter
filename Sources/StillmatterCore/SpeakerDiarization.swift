import Foundation

public enum SpeakerDiarizationModelManifest {
    public static let runtimeVersion = "sherpa-onnx-2.0.1"
    public static let segmentationModelURL = "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2"
    public static let segmentationArchiveSHA256 = "24615ee884c897d9d2ba09bb4d30da6bb1b15e685065962db5b02e76e4996488"
    public static let segmentationArchiveBytes: Int64 = 6_958_444
    public static let embeddingModelURL = "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/nemo_en_titanet_small.onnx"
    public static let embeddingModelSHA256 = "ad4a1802485d8b34c722d2a9d04249662f2ece5d28a7a039063ca22f515a789e"
    public static let embeddingModelBytes: Int64 = 40_257_283
    public static let downloadBytes = segmentationArchiveBytes + embeddingModelBytes
}

/// An anonymous acoustic cluster over a time range. A cluster ID is not a Person ID.
public struct SpeakerDiarizationTurn: Codable, Equatable {
    public let startSeconds: Double
    public let endSeconds: Double
    public let clusterID: Int

    public init(startSeconds: Double, endSeconds: Double, clusterID: Int) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.clusterID = clusterID
    }
}

public enum SpeakerDiarizationError: Error, Equatable, LocalizedError {
    case missingConfiguration(String)
    case invalidOutput(String)

    public var errorDescription: String? {
        switch self {
        case let .missingConfiguration(message), let .invalidOutput(message): return message
        }
    }
}

public protocol SpeakerDiarizationEngine: AnyObject {
    var engineIdentifier: String { get }
    var modelIdentifier: String { get }
    func diarize(audioURL: URL) throws -> [SpeakerDiarizationTurn]
}

public protocol CancellableSpeakerDiarizationEngine: SpeakerDiarizationEngine {
    func diarize(audioURL: URL, cancellation: JobExecutionCancellation) throws -> [SpeakerDiarizationTurn]
}
