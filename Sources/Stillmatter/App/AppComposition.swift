import Foundation
#if SWIFT_PACKAGE
import StillmatterCore
import StillmatterTranscriptionRuntime
#endif

/// Builds process-wide operational dependencies once. Workspace-bound services receive
/// captured settings/root values from the runtime, never read the current Settings during work.
final class AppComposition {
    let settingsStore: SettingsStore
    let applicationSupportURL: URL
    private let onCaptureSnapshot: (CaptureSnapshot) -> Void
    private let captureBuild: ((AppSettings, JobStore?, TasksInbox?) -> MeetingCaptureService)?
    let workspaceRuntime = WorkspaceRuntime()

    init(settingsStore: SettingsStore, applicationSupportURL: URL,
         onCaptureSnapshot: @escaping (CaptureSnapshot) -> Void,
         captureBuild: ((AppSettings, JobStore?, TasksInbox?) -> MeetingCaptureService)? = nil) {
        self.settingsStore = settingsStore
        self.applicationSupportURL = applicationSupportURL
        self.onCaptureSnapshot = onCaptureSnapshot
        self.captureBuild = captureBuild
    }

    lazy var tasksInbox: TasksInbox? = {
        do {
            return try TasksInbox(databaseURL: applicationSupportURL.appendingPathComponent("operational.sqlite"))
        } catch {
            NSLog("Could not open Stillmatter operational store: \(error)")
            return nil
        }
    }()

    lazy var jobStore: JobStore? = {
        do {
            return try JobStore(databaseURL: applicationSupportURL.appendingPathComponent("operational.sqlite"), inbox: tasksInbox)
        } catch {
            NSLog("Could not open Stillmatter job store: \(error)")
            return nil
        }
    }()

    lazy var transcriptionComponentInstaller = TranscriptionComponentInstaller(
        paths: TranscriptionComponentPaths(applicationSupportURL: applicationSupportURL),
        acquirer: FasterWhisperModelAcquirer()
    )

    lazy var captureRuntime = CaptureSessionRuntime(
        build: { [weak self] settings in
            guard let self else { preconditionFailure("Capture composition was disposed") }
            let ownedInbox = settings.stillmatterRootURL.flatMap { try? self.tasksInbox?.scoped(to: $0) }
            if let captureBuild = self.captureBuild {
                return captureBuild(settings, self.jobStore, ownedInbox)
            }
            return CaptureSessionAssembly.makeService(
                settings: settings, settingsStore: self.settingsStore,
                jobStore: self.jobStore, inbox: ownedInbox,
                applicationSupportURL: self.applicationSupportURL
            )
        },
        onSnapshot: { [weak self] snapshot in self?.onCaptureSnapshot(snapshot) }
    )
}
