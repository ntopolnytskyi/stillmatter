import Foundation

/// The blocking recorder work shared by synchronous capture stops and UI-triggered async stops.
struct CaptureFinalization {
    let mic: MicTrackRecordingMetadata?
    let system: SystemAudioTrackRecordingMetadata?
    let bundle: RecordingBundle?
    let selection: TranscriptionAudioSidecar?
    let statuses: [String]

    static func run(
        endedAt: Date,
        micRecorder: MicTrackRecordingManaging?,
        systemAudioRecorder: SystemAudioTrackRecordingManaging?,
        priorSystem: SystemAudioTrackRecordingMetadata?,
        bundleFinalizer: RecordingBundleFinalizing?,
        generator: TranscriptionSidecarGenerating?
    ) throws -> CaptureFinalization {
        var system = priorSystem
        var systemStatus: [String] = []
        if systemAudioRecorder?.activeMetadata != nil {
            do {
                system = try systemAudioRecorder?.stop(endedAt: endedAt)
                systemStatus = ["Separate system audio finalized (AAC)", "System-audio recovery/preview retained"]
            } catch {
                system = systemAudioRecorder?.latestMetadata
                systemStatus = ["System audio finalization failed; microphone track remains available: \(error)"]
            }
        } else if system?.status == .failed {
            systemStatus = ["System audio unavailable; microphone-only capture retained"]
        }
        let mic = try micRecorder?.stop(endedAt: endedAt)
        var statuses = mic == nil
            ? ["Placeholder capture finalized", "Audio finalization pending"]
            : ["Microphone track finalized (AAC)", "Microphone recovery/preview audio retained"]
        statuses += systemStatus + ["Transcription and summary pending"]
        var bundle: RecordingBundle?
        var selection: TranscriptionAudioSidecar?
        if let bundleFinalizer, let mic {
            let finalized = try bundleFinalizer.finalize(mic: mic, system: system, reason: .normalStop)
            bundle = finalized
            statuses.insert("Recording bundle validated (\(finalized.state.rawValue))", at: 0)
            if let generator {
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
