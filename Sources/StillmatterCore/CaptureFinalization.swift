import Foundation

struct CaptureFinalization {
    let mic: MicTrackRecordingMetadata?
    let system: SystemAudioTrackRecordingMetadata?
    let bundle: RecordingBundle?
    let selection: TranscriptionAudioSidecar?
    let statuses: [String]

    /// Expensive encoding, bundle validation and echo processing happen only after each input
    /// device has been released by its Capture Session.
    static func run(
        releasedMic: MicTrackRecordingMetadata?,
        releasedSystem: SystemAudioTrackRecordingMetadata?,
        micRecorder: MicTrackRecordingManaging?,
        systemAudioRecorder: SystemAudioTrackRecordingManaging?,
        bundleFinalizer: RecordingBundleFinalizing?,
        generator: TranscriptionSidecarGenerating?
    ) throws -> CaptureFinalization {
        var system = releasedSystem
        var statuses: [String] = []
        if let releasedSystem = releasedSystem, let systemAudioRecorder = systemAudioRecorder {
            if releasedSystem.status == .finalizing {
                do {
                    system = try systemAudioRecorder.finalizeReleased(releasedSystem)
                    if system?.status == .completed || system?.status == .recovered {
                        statuses.append("Separate system audio finalized (AAC)")
                        statuses.append("System-audio recovery/preview retained")
                    }
                } catch {
                    var failed = releasedSystem
                    failed.status = .failed
                    failed.diagnostics.append("System-audio finalization failed; source artifacts retained: \(error)")
                    system = failed
                    statuses.append("System audio finalization failed; microphone track remains available: \(error)")
                }
            } else if releasedSystem.status == .failed || releasedSystem.status == .partial {
                statuses.append("System audio unavailable; microphone-only capture retained")
            }
        }
        let mic = try releasedMic.map { metadata in
            metadata.status == .finalizing ? try micRecorder?.finalizeReleased(metadata) ?? metadata : metadata
        }
        statuses += mic == nil
            ? ["Placeholder capture finalized", "Audio finalization pending"]
            : ["Microphone track finalized (AAC)", "Microphone recovery/preview audio retained"]
        statuses += ["Transcription and summary pending"]
        var bundle: RecordingBundle?
        var selection: TranscriptionAudioSidecar?
        if let bundleFinalizer = bundleFinalizer, let mic = mic {
            let finalized = try bundleFinalizer.finalize(mic: mic, system: system, reason: .normalStop)
            bundle = finalized
            statuses.insert("Recording bundle validated (\(finalized.state.rawValue))", at: 0)
            if let generator = generator {
                do {
                    let generated = try generator.generate(from: finalized)
                    selection = generated
                    statuses.append(generated.selection == .echoCancelledSidecar
                        ? "Echo-cancelled transcription sidecar selected"
                        : "Original microphone selected for transcription")
                } catch {
                    statuses.append("Echo cancellation unavailable; original microphone remains available: \(error)")
                }
            }
        }
        return CaptureFinalization(mic: mic, system: system, bundle: bundle, selection: selection, statuses: statuses)
    }
}
