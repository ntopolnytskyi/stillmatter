import AppKit
#if SWIFT_PACKAGE
import StillmatterCore
#endif

/// The macOS adapter for Capture Session runtime assembly and Recording Bundle recovery.
enum CaptureSessionAssembly {
    static func makeService(
        settings: AppSettings,
        settingsStore: SettingsStore,
        jobStore: JobStore?,
        inbox: TasksInbox?,
        applicationSupportURL: URL
    ) -> MeetingCaptureService {
        guard let rootURL = settings.stillmatterRootURL else {
            preconditionFailure("Capture Session assembly requires a configured workspace root")
        }
        let preflightChecker = MacAudioCapturePreflight.makeChecker(settingsStore: settingsStore)
        let vault = WorkspaceVault(workspaceRootURL: rootURL, appSupportRootURL: applicationSupportURL)
        let micRecorder: MicTrackRecordingCoordinator?
        var systemAudioRecorder: SystemAudioTrackRecordingManaging?
        var bundleFinalizer: RecordingBundleFinalizer?
        var transcriptionSidecarGenerator: TranscriptionSidecarGenerating?
        if let mediaURL = settings.recordingMediaURL {
            let coordinator = MicTrackRecordingCoordinator(
                mediaRootURL: mediaURL, backend: MacMicTrackRecorder()
            )
            let recoveredMics = coordinator.recoverUnfinished()
            recoveredMics.forEach { NSLog("Microphone recovery \($0.status.rawValue): \($0.metadataFilePath)") }
            micRecorder = coordinator
            var recoveredSystems: [SystemAudioTrackRecordingMetadata] = []
            if #available(macOS 13.0, *) {
                let systemCoordinator = SystemAudioTrackRecordingCoordinator(
                    mediaRootURL: mediaURL, backend: MacSystemAudioTrackRecorder()
                )
                recoveredSystems = systemCoordinator.recoverUnfinished()
                recoveredSystems.forEach { NSLog("System audio recovery \($0.status.rawValue): \($0.metadataFilePath)") }
                systemAudioRecorder = systemCoordinator
            }
            let finalizer = RecordingBundleFinalizer()
            bundleFinalizer = finalizer
            let sidecarGenerator = EchoCancellationSidecarStage(
                bundleValidator: finalizer, processor: MacEchoCancellationProcessor()
            )
            transcriptionSidecarGenerator = sidecarGenerator
            finalizeRecoveredRecordings(
                micReports: recoveredMics, systemReports: recoveredSystems,
                mediaURL: mediaURL, vault: vault, jobStore: jobStore,
                finalizer: finalizer, transcriptionSidecarGenerator: sidecarGenerator
            )
        } else {
            micRecorder = nil
            systemAudioRecorder = nil
            bundleFinalizer = nil
            transcriptionSidecarGenerator = nil
        }
        return MeetingCaptureService(
            vault: vault, jobStore: jobStore, inbox: inbox,
            micRecorder: micRecorder, systemAudioRecorder: systemAudioRecorder,
            bundleFinalizer: bundleFinalizer, transcriptionSidecarGenerator: transcriptionSidecarGenerator,
            preflight: preflightChecker.check
        )
    }

    private static func finalizeRecoveredRecordings(
        micReports: [MicTrackRecordingMetadata],
        systemReports: [SystemAudioTrackRecordingMetadata],
        mediaURL: URL,
        vault: WorkspaceVault,
        jobStore: JobStore?,
        finalizer: RecordingBundleFinalizing,
        transcriptionSidecarGenerator: TranscriptionSidecarGenerating
    ) {
        var microphones = Dictionary(uniqueKeysWithValues: micReports.map { ($0.captureSessionID, $0) })
        var systems = Dictionary(uniqueKeysWithValues: systemReports.map { ($0.captureSessionID, $0) })
        let sessionIDs = Set(microphones.keys).union(systems.keys)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for sessionID in sessionIDs {
            let directory = mediaURL
                .appendingPathComponent("Stillmatter Recordings", isDirectory: true)
                .appendingPathComponent(sessionID, isDirectory: true)
            if microphones[sessionID] == nil,
               let data = try? Data(contentsOf: directory.appendingPathComponent("mic-recording.json")) {
                microphones[sessionID] = try? decoder.decode(MicTrackRecordingMetadata.self, from: data)
            }
            if systems[sessionID] == nil,
               let data = try? Data(contentsOf: directory.appendingPathComponent("system-recording.json")) {
                systems[sessionID] = try? decoder.decode(SystemAudioTrackRecordingMetadata.self, from: data)
            }
            guard let mic = microphones[sessionID] else {
                NSLog("Could not finalize recovered recording \(sessionID): microphone metadata is unavailable")
                continue
            }
            do {
                let recovery = RecordingRecoveryService(
                    vault: vault, jobStore: jobStore, bundleFinalizer: finalizer,
                    transcriptionSidecarGenerator: transcriptionSidecarGenerator
                )
                let result = try recovery.finalizeRecovered(mic: mic, system: systems[sessionID])
                NSLog("Recording bundle recovery \(result.bundle.state.rawValue): \(result.bundle.bundleFilePath)")
            } catch {
                NSLog("Could not finalize recovered recording \(sessionID): \(error)")
            }
        }
    }
}
