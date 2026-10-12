#if DEBUG
import AppKit
import StillmatterCore
import StillmatterTranscriptionRuntime

// Executed only by the disposable native shell probe. No diagnostic is persisted.
extension SettingsFormView {
    /// Constrained rows, validation, and redundant diagnostic meaning.
    func validateFixtures() {
        applyAdaptiveRowLayout(forWidth: 520)
        precondition(adaptiveRows.allSatisfy { $0.row.orientation == .vertical }, "Settings Form Rows must stack at narrow widths")
        applyAdaptiveRowLayout(forWidth: 680)
        precondition(adaptiveRows.allSatisfy { $0.row.orientation == .horizontal }, "Settings Form Rows must use aligned columns when space permits")

        let statuses: [DiagnosticStatus] = [.granted, .missing, .unavailable, .notConfigured, .unknown]
        precondition(statuses.allSatisfy { !statusText($0).isEmpty && !statusMeaning($0).symbol.isEmpty }, "Every diagnostic status must include a non-color symbol")
        renderDiagnosticItem(DiagnosticItem(
            id: "pi",
            title: "Pi CLI detection",
            status: .unavailable,
            explanation: "The pi CLI is unavailable.",
            affectedFeatures: ["Meeting summaries"],
            actionTitle: "Test Pi"
        ))
        precondition(diagnosticRows["pi"]?.detailLabel.stringValue.contains("Affects: Meeting summaries") == true, "Diagnostics must name affected capabilities")

        let originalTranscriptionState = transcriptionComponentInstaller.state()
        let transcriptionStates: [TranscriptionComponentState] = [
            .notInstalled,
            .installing(TranscriptionInstallProgress(phase: "Downloading", completedBytes: 50, totalBytes: 100)),
            .ready(URL(fileURLWithPath: "/tmp/stillmatter-ready-model")),
            .failed("Fixture installation failure")
        ]
        transcriptionStates.forEach {
            renderTranscriptionDiagnostic($0)
            precondition(diagnosticRows["localTranscription"]?.statusLabel.stringValue.isEmpty == false, "Transcription fixture state must expose status text")
            precondition(diagnosticRows["localTranscription"]?.detailLabel.stringValue.isEmpty == false, "Transcription fixture state must expose an explanation")
        }
        renderTranscriptionDiagnostic(originalTranscriptionState)
        applyAdaptiveRowLayout(forWidth: bounds.width)
    }
}
#endif
