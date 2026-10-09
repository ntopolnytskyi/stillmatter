import Foundation

/// Stillmatter integration adapter for the GPLv3 echo-cancellation port.
@available(macOS 10.15, *)
public final class MacEchoCancellationProcessor: EchoCancellationProcessing {
    public init() {}

    public func process(
        microphoneURL: URL,
        systemReferenceURL: URL,
        outputURL: URL
    ) throws -> EchoCancellationProcessingResult {
        let timingURL = microphoneURL.deletingLastPathComponent()
            .appendingPathComponent(RecordingAudioTiming.fileName)
        let timing = try? JSONDecoder().decode(
            RecordingAudioTiming.self,
            from: Data(contentsOf: timingURL)
        )
        let report = try EchoCancelledTrack.writeSynchronously(
            microphone: microphoneURL,
            reference: systemReferenceURL,
            to: outputURL,
            timing: timing
        )
        let acceptedSeconds = report.acceptedSeconds ?? 0
        let acceptedRatio = report.processedSeconds > 0
            ? min(1, acceptedSeconds / report.processedSeconds)
            : 0
        let retainedSignalRatio = report.echoReturnLossDB > 0
            ? pow(10, -report.echoReturnLossDB / 10)
            : 1
        let shouldUse = EchoCancelledTrack.shouldUse(report)
        let candidateDiagnostic = report.candidateEchoReturnLossDB.map {
            String(format: "Measured candidate-window ERLE %.2f dB before the acceptance gate.", $0)
        } ?? "Candidate ERLE was not measured because no window met the 0.550 correlation gate."
        return EchoCancellationProcessingResult(
            quality: EchoCancellationQuality(
                confidence: acceptedRatio,
                referenceCorrelation: report.referenceCorrelation,
                estimatedEchoReductionDB: report.echoReturnLossDB,
                retainedSignalRatio: retainedSignalRatio
            ),
            diagnostics: [
                String(format: "Processed %.1f seconds in 30-second, 16 kHz mono windows.", report.processedSeconds),
                String(format: "Accepted %.1f seconds after delay estimation and adaptive cancellation.", acceptedSeconds),
                String(format: "Estimated microphone delay %.1f ms for reliably correlated windows.", report.delaySeconds * 1_000),
                String(format: "Strongest reference-envelope correlation %.3f (minimum 0.550).", report.referenceCorrelation),
                String(format: "Measured accepted-window ERLE %.2f dB (minimum 6.00 dB).", report.echoReturnLossDB),
                candidateDiagnostic,
                timing == nil
                    ? "Capture timing was unavailable; alignment used acoustic estimation."
                    : String(format: "Capture timing aligned %.1f of %.1f processed seconds; unmatched audio passed through.", report.alignedSeconds, report.processedSeconds),
                "The generated WAV is transcription-only; microphone and system evidence files were opened read-only."
            ],
            shouldUseSidecar: shouldUse
        )
    }
}
