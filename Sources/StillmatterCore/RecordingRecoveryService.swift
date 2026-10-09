import Foundation

public struct RecordingRecoveryResult {
    public let bundle: RecordingBundle
    public let transcriptionAudio: TranscriptionAudioSidecar?
    public let job: JobRecord?

    public init(bundle: RecordingBundle, transcriptionAudio: TranscriptionAudioSidecar?, job: JobRecord?) {
        self.bundle = bundle
        self.transcriptionAudio = transcriptionAudio
        self.job = job
    }
}

/// Completes the capture-to-processing handoff after startup track recovery. The same
/// recording bundle contract is used for a recovered session and for a normal stop.
public final class RecordingRecoveryService {
    private let vault: WorkspaceVault
    private let jobStore: JobStore?
    private let bundleFinalizer: RecordingBundleFinalizing
    private let transcriptionSidecarGenerator: TranscriptionSidecarGenerating?

    public init(
        vault: WorkspaceVault,
        jobStore: JobStore? = nil,
        bundleFinalizer: RecordingBundleFinalizing,
        transcriptionSidecarGenerator: TranscriptionSidecarGenerating? = nil
    ) {
        self.vault = vault
        self.jobStore = jobStore
        self.bundleFinalizer = bundleFinalizer
        self.transcriptionSidecarGenerator = transcriptionSidecarGenerator
    }

    @discardableResult
    public func finalizeRecovered(
        mic: MicTrackRecordingMetadata,
        system: SystemAudioTrackRecordingMetadata?
    ) throws -> RecordingRecoveryResult {
        let bundle = try bundleFinalizer.finalize(mic: mic, system: system, reason: .recovery)
        let transcriptionAudio = try transcriptionSidecarGenerator?.generate(from: bundle)
        try updateMeeting(for: bundle, transcriptionAudio: transcriptionAudio)
        let job = try enqueue(bundle, transcriptionAudio: transcriptionAudio)
        return RecordingRecoveryResult(bundle: bundle, transcriptionAudio: transcriptionAudio, job: job)
    }

    private func updateMeeting(
        for bundle: RecordingBundle,
        transcriptionAudio: TranscriptionAudioSidecar?
    ) throws {
        let current = try vault.readMarkdown(relativePath: bundle.meetingRelativePath)
        guard var markdown = String(data: current.data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        var lines = markdown.components(separatedBy: "\n")
        if let captureIndex = lines.firstIndex(where: { $0.hasPrefix("capture: ") }) {
            lines[captureIndex] = "capture: recovered"
            if let referenceIndex = lines.firstIndex(where: { $0.hasPrefix("recording_bundle: ") }) {
                lines[referenceIndex] = "recording_bundle: \(bundle.bundleFilePath)"
            } else {
                lines.insert("recording_bundle: \(bundle.bundleFilePath)", at: captureIndex + 1)
            }
        }
        markdown = lines.joined(separator: "\n")

        let marker = "## Processing\n"
        if let markerRange = markdown.range(of: marker),
           let liveNotesRange = markdown.range(of: "\n## Live notes", range: markerRange.upperBound..<markdown.endIndex) {
            let systemLine: String
            if let system = bundle.system {
                systemLine = "- [x] System audio recovery state: `\(system.status)`"
            } else {
                systemLine = "- [!] No separate system-audio track was recovered"
            }
            let transcriptionLines: String
            if let transcriptionAudio = transcriptionAudio {
                transcriptionLines = transcriptionAudio.selection == .echoCancelledSidecar
                    ? "- [x] Echo-cancelled transcription sidecar: `\(transcriptionAudio.selectedAudioFilePath)`\n- [x] Transcription audio diagnostics: `\(transcriptionAudio.metadataFilePath)`"
                    : "- [!] Original microphone selected for transcription\n- [x] Transcription audio diagnostics: `\(transcriptionAudio.metadataFilePath)`"
            } else {
                transcriptionLines = "- [ ] Transcription audio selection pending"
            }
            let replacement = """
            ## Processing

            - [x] Recovered recording bundle (`\(bundle.state.rawValue)`): `\(bundle.bundleFilePath)`
            - [x] Microphone recovery state: `\(bundle.mic.status)`
            \(systemLine)
            \(transcriptionLines)
            - [ ] Transcription and summary
            """
            markdown.replaceSubrange(markerRange.lowerBound..<liveNotesRange.lowerBound, with: replacement)
        }
        _ = try vault.writeMarkdown(
            Data(markdown.utf8),
            relativePath: bundle.meetingRelativePath,
            expectedVersion: current.version
        )
    }

    private func enqueue(
        _ bundle: RecordingBundle,
        transcriptionAudio: TranscriptionAudioSidecar?
    ) throws -> JobRecord? {
        guard let jobStore = jobStore else { return nil }
        let manifest = TranscriptionJob.manifest(
            title: "recovered meeting",
            bundle: bundle,
            selection: transcriptionAudio,
            language: .english
        )
        return try jobStore.enqueue(manifest: manifest)
    }
}
