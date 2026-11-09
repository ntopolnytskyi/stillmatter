import Foundation
import StillmatterCore

private struct SherpaDiarizationOutput: Decodable {
    struct Segment: Decodable {
        let start: Double
        let end: Double
        let speaker: Int
    }

    let duration_seconds: Double
    let segments: [Segment]
}

/// Runs the locally installed sherpa-onnx CPU diarizer in the app-owned Python runtime.
/// The returned integer clusters remain anonymous and retain the model's original times.
public final class SherpaOnnxSpeakerDiarizationEngine: CancellableSpeakerDiarizationEngine {
    public let engineIdentifier = "sherpa-onnx"
    public let modelIdentifier = "pyannote-segmentation-3.0+titanet-small"

    private let componentURL: URL
    private let fileManager: FileManager
    private let runner: ProcessRunner

    public init(componentURL: URL, fileManager: FileManager = .default) {
        self.componentURL = componentURL
        self.fileManager = fileManager
        self.runner = ProcessRunner(fileManager: fileManager)
    }

    public func diarize(audioURL: URL) throws -> [SpeakerDiarizationTurn] {
        try diarize(audioURL: audioURL, cancellation: JobExecutionCancellation())
    }

    public func diarize(audioURL: URL, cancellation: JobExecutionCancellation) throws -> [SpeakerDiarizationTurn] {
        guard !cancellation.isCancelled else { throw JobsError.executionCancelled }
        let pythonURL = componentURL.appendingPathComponent("runtime/bin/python3")
        let scriptURL = componentURL.appendingPathComponent("diarize.py")
        let segmentationURL = componentURL.appendingPathComponent("speaker-segmentation/model.onnx")
        let embeddingURL = componentURL.appendingPathComponent("speaker-embedding/titanet-small.onnx")
        guard fileManager.isExecutableFile(atPath: pythonURL.path),
              fileManager.fileExists(atPath: scriptURL.path),
              fileManager.fileExists(atPath: segmentationURL.path),
              fileManager.fileExists(atPath: embeddingURL.path) else {
            throw SpeakerDiarizationError.missingConfiguration(
                "Local speaker diarization is not installed. Install the local meeting models, then Retry. The original recording is retained.")
        }

        let outputURL = fileManager.temporaryDirectory
            .appendingPathComponent("Stillmatter-speakers-\(UUID().uuidString).json")
        defer { try? fileManager.removeItem(at: outputURL) }
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONNOUSERSITE"] = "1"
        environment["OMP_NUM_THREADS"] = "2"
        environment["HF_HUB_OFFLINE"] = "1"
        environment["TRANSFORMERS_OFFLINE"] = "1"
        _ = try runner.run(executable: pythonURL,
            arguments: [scriptURL.path, segmentationURL.path, embeddingURL.path, audioURL.path, outputURL.path],
            jobCancellation: cancellation, environment: environment)

        let result: SherpaDiarizationOutput
        do {
            result = try JSONDecoder().decode(SherpaDiarizationOutput.self, from: Data(contentsOf: outputURL))
        } catch {
            throw SpeakerDiarizationError.invalidOutput("Local speaker diarization returned unreadable output: \(error.localizedDescription)")
        }
        guard result.duration_seconds.isFinite, result.duration_seconds > 0,
              result.segments.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start && $0.speaker >= 0 }) else {
            throw SpeakerDiarizationError.invalidOutput("Local speaker diarization returned invalid speaker timing or cluster IDs.")
        }
        return result.segments.map {
            SpeakerDiarizationTurn(startSeconds: $0.start, endSeconds: $0.end, clusterID: $0.speaker)
        }
    }
}
